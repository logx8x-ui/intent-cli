import AppKit
import IntentCore
import ScreenCaptureKit
import SwiftUI

@MainActor
final class QuickSelectionController: ObservableObject {
    struct AppItem: Identifiable {
        let app: AllowedApp
        let icon: NSImage
        let pid: pid_t
        var preview: NSImage?
        var id: String { app.bundleIdentifier }
    }

    @Published var apps: [AppItem] = []
    @Published var snapshots: [BrowserTabSnapshot] = []
    @Published var selection = QuickSelection()
    @Published var message: String?
    @Published var hasPreviewPermission = CGPreflightScreenCaptureAccess()
    private let model: IntentAppModel
    private var panel: NSPanel?
    private var monitor: Any?
    private var refreshTimer: Timer?
    private var previewTask: Task<Void, Never>?
    private var previousApp: NSRunningApplication?
    private var wasOverlayVisible = false
    private var generation = UUID()

    init(model: IntentAppModel) { self.model = model }

    func toggle() {
        if panel?.isVisible == true { runSelection(); return }
        guard !model.hasActiveSession, !model.isZeroDriftActive,
              model.pendingPurposeSessionSave == nil, model.pendingFriction == nil,
              model.pendingEndTimeRequest == nil else {
            model.errorMessage = "Finish the current intention and save or dismiss its result before opening Quick Focus."
            model.showOverlay()
            return
        }
        selection = QuickSelection()
        message = nil
        previousApp = NSWorkspace.shared.frontmostApplication
        wasOverlayVisible = model.overlayPresenter?.isOverlayVisible == true
        refresh()
        generation = UUID()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        let panel = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = "Quick Focus"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.contentView = NSHostingView(rootView: QuickSelectionView(controller: self))
        self.panel = panel
        model.overlayPresenter?.hideOverlay(animated: false)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel?.isVisible == true else { return event }
            if event.keyCode == 53 { self.cancel(); return nil }
            return event
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refresh() }
        }
        loadPreviews()
    }

    func refresh() {
        if model.hasActiveSession, panel?.isVisible == true {
            close()
            return
        }
        let old = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        var seen: Set<String> = []
        apps = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, !app.isTerminated,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let id = app.bundleIdentifier, seen.insert(id).inserted else { return nil }
            return AppItem(app: .init(name: app.localizedName ?? id, bundleIdentifier: id),
                           icon: app.icon ?? NSImage(named: NSImage.applicationIconName)!,
                           pid: app.processIdentifier, preview: old[id]?.preview)
        }.sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
        snapshots = QuickSelection.browsers.sorted().compactMap { browser in
            guard apps.contains(where: { $0.id == browser }),
                  BrowserGuardHeartbeatStore(fileURL: BrowserGuardHeartbeatStore.fileURL(for: browser))
                    .supports(.quickSelection, maxAge: 5) else { return nil }
            try? BrowserTabCommandStore(browserBundleIdentifier: browser).write(.init(tabID: -1, windowID: -1, action: .snapshot))
            return BrowserTabSnapshotStore(browserBundleIdentifier: browser).load()
        }
        // Keep selections stable; do not silently select new tabs or remove a closed selection.
        // Start validates them against fresh data and explains any change.
    }

    func selectApp(_ app: AppItem) {
        if app.app.isBrowser && !QuickSelection.browsers.contains(app.id) {
            message = "Website selection supports Chrome and Firefox. Choose one of those browsers."
            return
        }
        if QuickSelection.browsers.contains(app.id), !snapshots.contains(where: { $0.browserBundleIdentifier == app.id }) {
            message = "Connect the latest Intent Browser Guard in \(app.app.name) to select its tabs."
            return
        }
        message = nil
        selection.toggleApp(app.id, snapshots: snapshots)
    }

    func runSelection() {
        refresh()
        guard model.startQuickSelection(selection, apps: apps.map(\.app), snapshots: snapshots) else {
            message = model.errorMessage
            return
        }
        close()
    }

    func cancel() {
        close()
        if wasOverlayVisible { model.showOverlay() }
        else { previousApp?.activate(options: []) }
    }

    private func close() {
        generation = UUID()
        previewTask?.cancel()
        previewTask = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        panel?.orderOut(nil)
        panel = nil
        apps = []
        snapshots = []
    }

    func enablePreviews() {
        hasPreviewPermission = CGRequestScreenCaptureAccess()
        if hasPreviewPermission { loadPreviews() }
        else { message = "Enable Screen Recording for Intent in System Settings to show window previews. App selection works without it." }
    }

    private func loadPreviews() {
        hasPreviewPermission = CGPreflightScreenCaptureAccess()
        guard hasPreviewPermission, #available(macOS 14.0, *) else { return }
        let token = generation
        previewTask = Task { [weak self] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return }
            guard let self, self.generation == token else { return }
            for app in self.apps {
                guard !Task.isCancelled, self.generation == token else { return }
                guard let window = content.windows.filter({
                    $0.owningApplication?.processID == app.pid && $0.windowLayer == 0 && $0.frame.width > 80 && $0.frame.height > 80
                }).max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { continue }
                let config = SCStreamConfiguration()
                config.width = 480
                config.height = max(1, Int(480 * window.frame.height / window.frame.width))
                config.showsCursor = false
                guard let image = try? await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config
                ), self.generation == token, let index = self.apps.firstIndex(where: { $0.id == app.id }) else { continue }
                self.apps[index].preview = NSImage(cgImage: image, size: .zero)
            }
        }
    }
}

private final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct QuickSelectionView: View {
    @ObservedObject var controller: QuickSelectionController
    private let green = Color(red: 0.25, green: 0.9, blue: 0.48)

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 18) {
                // Browser tabs occupy the topmost content area, above the app overview.
                if !controller.snapshots.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 18) {
                            ForEach(controller.snapshots, id: \.browserBundleIdentifier) { snapshot in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(snapshot.browserBundleIdentifier == "com.google.Chrome" ? "CHROME TABS" : "FIREFOX TABS")
                                        .font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.65))
                                    HStack(spacing: 10) {
                                        ForEach(snapshot.tabs.sorted { ($0.windowID, $0.index) < ($1.windowID, $1.index) }) { tab in
                                            tabCard(tab, browser: snapshot.browserBundleIdentifier)
                                        }
                                    }
                                }
                            }
                        }.padding(4)
                    }.frame(height: 125)
                }

                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Choose your focus").font(.system(size: 30, weight: .semibold))
                        Text("Click apps and tabs to turn them green. Only your selection will be allowed.")
                            .font(.system(size: 14)).foregroundStyle(.white.opacity(0.65))
                    }
                    Spacer()
                    Button("Cancel · Esc") { controller.cancel() }.buttonStyle(.bordered)
                }

                GeometryReader { area in
                    let columns = max(1, Int(ceil(sqrt(Double(max(1, controller.apps.count)) * Double(area.size.width / max(1, area.size.height)) / 1.55))))
                    let rows = max(1, Int(ceil(Double(controller.apps.count) / Double(columns))))
                    let height = max(76, min(240, (area.size.height - CGFloat(rows - 1) * 14) / CGFloat(rows)))
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: columns), spacing: 14) {
                            ForEach(controller.apps) { app in appCard(app, height: height) }
                        }.padding(4)
                    }
                }

                if let message = controller.message {
                    Text(message).font(.system(size: 13)).foregroundStyle(.orange).accessibilityLabel(message)
                }
                HStack {
                    if !controller.hasPreviewPermission {
                        Button("Enable window previews") { controller.enablePreviews() }.buttonStyle(.bordered)
                    }
                    Text("\(controller.selection.apps.count) apps · \(controller.selection.tabs.count) tabs selected")
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.65))
                    Spacer()
                    Button("Clear selection") { controller.selection = QuickSelection(); controller.message = nil }
                        .buttonStyle(.bordered)
                    Button("Start intention · ⌘G") { controller.runSelection() }
                        .buttonStyle(.borderedProminent).tint(green).foregroundStyle(.black)
                        .disabled(controller.selection.apps.isEmpty)
                }
            }
            .padding(.horizontal, 36).padding(.top, max(30, geometry.safeAreaInsets.top + 16)).padding(.bottom, 30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.055, green: 0.065, blue: 0.08).opacity(0.97))
            .foregroundStyle(.white)
            .preferredColorScheme(.dark)
        }
    }

    private func tabCard(_ tab: BrowserTabItem, browser: String) -> some View {
        let key = QuickSelectionTab(browser: browser, id: tab.id)
        let selected = controller.selection.tabs.contains(key)
        let supported = QuickSelection.isSelectable(tab)
        return Button {
            controller.message = nil
            controller.selection.toggleTab(key)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Image(systemName: selected ? "checkmark.circle.fill" : "globe")
                        .foregroundStyle(selected ? green : .white.opacity(0.6))
                    Text(tab.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                }
                Text(URL(string: tab.url)?.host ?? "Browser page — cannot select")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }.frame(width: 190, height: 63, alignment: .leading).padding(12)
                .background(selected ? green.opacity(0.12) : .white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? green : .white.opacity(0.12), lineWidth: selected ? 3 : 1))
        }.buttonStyle(.plain).disabled(!supported).opacity(supported ? 1 : 0.45)
            .accessibilityLabel("\(tab.title), \(selected ? "selected" : "not selected")")
    }

    private func appCard(_ app: QuickSelectionController.AppItem, height: CGFloat) -> some View {
        let selected = controller.selection.apps.contains(app.id)
        return Button { controller.selectApp(app) } label: {
            VStack(spacing: 8) {
                if let image = app.preview, height > 110 {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                } else {
                    Image(nsImage: app.icon).resizable().scaledToFit().frame(height: max(24, min(64, height - 64)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                HStack(spacing: 6) {
                    Text(app.app.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(green) }
                }
            }.padding(12).frame(maxWidth: .infinity).frame(height: height)
                .background(selected ? green.opacity(0.10) : .white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? green : .white.opacity(0.12), lineWidth: selected ? 3 : 1))
        }.buttonStyle(.plain)
            .accessibilityLabel("\(app.app.name), \(selected ? "selected" : "not selected")")
    }
}
