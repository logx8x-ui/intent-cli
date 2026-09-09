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
        var id: String { app.bundleIdentifier }
    }
    struct WindowItem: Identifiable {
        let id: CGWindowID
        let appID: String
        let title: String
        let sourceFrame: CGRect
        var preview: NSImage?
    }
    @Published var apps: [AppItem] = []
    @Published var windows: [WindowItem] = []
    @Published var snapshots: [BrowserTabSnapshot] = []
    @Published var selection = QuickSelection()
    @Published var message: String?
    @Published var hasPreviewPermission = CGPreflightScreenCaptureAccess()
    @Published var wallpaper: NSImage?
    @Published var expanded = false
    @Published var loading = false
    @Published var closing = false
    @Published var focusedBrowserWindow: CGWindowID?
    @Published var hoveredTab: BrowserTabItem?
    @Published var tabPreview: NSImage?
    @Published var tabPreviewError: String?
    @Published var tabPreviewLoading = false
    private var hoverTask: Task<Void, Never>?
    private(set) var displayFrame = CGRect.zero
    private let model: IntentAppModel
    private var panel: NSPanel?
    private var monitor: Any?
    private var refreshTimer: Timer?
    private var previewTask: Task<Void, Never>?
    private var previousApp: NSRunningApplication?
    private var wasOverlayVisible = false
    private var generation = UUID()

    init(model: IntentAppModel) { self.model = model }
    var windowlessApps: [AppItem] {
        guard hasPreviewPermission, !loading else { return [] }
        return apps.filter { app in !windows.contains { $0.appID == app.id } }
    }
    func toggle() {
        if panel?.isVisible == true { runSelection(); return }
        guard !model.hasActiveSession, !model.isZeroDriftActive,
              model.pendingPurposeSessionSave == nil, model.pendingFriction == nil,
              model.pendingEndTimeRequest == nil else {
            model.errorMessage = "Finish the current intention and save or dismiss its result before opening the field of view."
            model.showOverlay(); return
        }
        selection = QuickSelection(); message = nil; expanded = false; closing = false; windows = []; focusedBrowserWindow = nil
        previousApp = NSWorkspace.shared.frontmostApplication
        wasOverlayVisible = model.overlayPresenter?.isOverlayVisible == true
        refresh(); generation = UUID()
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        // Capture coordinates are top-left; AppKit screens are bottom-left.
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        displayFrame = CGRect(x: screen.frame.minX, y: primaryTop - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
        wallpaper = NSWorkspace.shared.desktopImageURL(for: screen).flatMap { NSImage(contentsOf: $0) }
        let panel = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = "intent field of view"
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear; panel.isOpaque = false
        panel.contentView = NSHostingView(rootView: QuickSelectionView(controller: self))
        self.panel = panel
        model.overlayPresenter?.hideOverlay(animated: false)
        NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil)
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
        if model.hasActiveSession, panel?.isVisible == true, !closing { close(); return }
        var seen: Set<String> = []
        apps = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, !app.isTerminated,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let id = app.bundleIdentifier, seen.insert(id).inserted else { return nil }
            return AppItem(app: .init(name: app.localizedName ?? id, bundleIdentifier: id),
                           icon: app.icon ?? NSImage(named: NSImage.applicationIconName)!, pid: app.processIdentifier)
        }.sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
        snapshots = QuickSelection.browsers.sorted().compactMap { browser in
            guard apps.contains(where: { $0.id == browser }),
                  BrowserGuardHeartbeatStore(fileURL: BrowserGuardHeartbeatStore.fileURL(for: browser)).supports(.quickSelection, maxAge: 5) else { return nil }
            try? BrowserTabCommandStore(browserBundleIdentifier: browser).write(.init(tabID: -1, windowID: -1, action: .snapshot))
            return BrowserTabSnapshotStore(browserBundleIdentifier: browser).load()
        }
    }
    func browserWindowID(for window: WindowItem) -> Int? {
        guard let snapshot = snapshots.first(where: { $0.browserBundleIdentifier == window.appID }) else { return nil }
        let siblings = windows.filter { $0.appID == window.appID }
        guard let id = BrowserWindowMatching.match(title: window.title, tabs: snapshot.tabs, nativeWindowCount: siblings.count) else { return nil }
        // Never attach the same tab strip to two windows with ambiguous titles.
        guard siblings.filter({ BrowserWindowMatching.match(title: $0.title, tabs: snapshot.tabs, nativeWindowCount: siblings.count) == id }).count == 1 else { return nil }
        return id
    }
    func tabs(for window: WindowItem) -> [BrowserTabItem] {
        guard let id = browserWindowID(for: window) else { return [] }
        return (snapshots.first { $0.browserBundleIdentifier == window.appID }?.tabs ?? []).filter { $0.windowID == id }.sorted { $0.index < $1.index }
    }
    func isSelected(_ window: WindowItem) -> Bool {
        guard QuickSelection.browsers.contains(window.appID) else { return selection.apps.contains(window.appID) }
        let selectable = tabs(for: window).filter(QuickSelection.isSelectable)
        return !selectable.isEmpty && selectable.allSatisfy { selection.tabs.contains(.init(browser: window.appID, id: $0.id)) }
    }
    func selectWindow(_ window: WindowItem) {
        guard !closing else { return }
        if QuickSelection.browsers.contains(window.appID) {
            guard browserWindowID(for: window) != nil, tabs(for: window).contains(where: QuickSelection.isSelectable) else {
                message = "Tabs could not be matched to this window. Connect Browser Guard, or give duplicate browser windows distinct active tabs and reopen ⌘G."; return
            }
            focusedBrowserWindow = window.id
            message = "Choose individual tabs above this window. Clicking the window does not select its tabs."
        } else if let app = apps.first(where: { $0.id == window.appID }) { selectApp(app) }
    }
    func selectApp(_ app: AppItem) {
        if app.app.isBrowser {
            message = "Select website tabs above a Chrome or Firefox window."; return
        }
        message = nil; selection.toggleApp(app.id, snapshots: snapshots)
    }
    func runSelection() {
        guard !closing, !loading, !tabPreviewLoading, !selection.apps.isEmpty else { return }
        refresh()
        do { _ = try selection.makeIntention(apps: apps.map(\.app), snapshots: snapshots) }
        catch { message = error.localizedDescription; return }
        dismissAnimated(start: true)
    }
    func cancel() { if !closing { dismissAnimated(start: false) } }
    private func dismissAnimated(start: Bool) {
        closing = true
        let token = generation
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduced ? nil : .easeInOut(duration: 0.24)) { expanded = false }
        Task { [weak self] in
            if !reduced { try? await Task.sleep(nanoseconds: 240_000_000) }
            guard let self, self.generation == token else { return }
            if start {
                self.refresh()
                guard self.model.startQuickSelection(self.selection, apps: self.apps.map(\.app), snapshots: self.snapshots) else {
                    self.message = self.model.errorMessage; self.closing = false
                    withAnimation(.easeOut(duration: 0.2)) { self.expanded = true }; return
                }
                self.close()
            } else {
                self.close()
                if self.wasOverlayVisible { self.model.showOverlay() } else { self.previousApp?.activate(options: []) }
            }
        }
    }
    private func close() {
        hoverTask?.cancel(); hoverTask = nil; hoveredTab = nil; tabPreview = nil; tabPreviewLoading = false
        for browser in QuickSelection.browsers { try? FileManager.default.removeItem(at: BrowserTabPreview.fileURL(browser: browser)) }
        generation = UUID(); previewTask?.cancel(); previewTask = nil
        refreshTimer?.invalidate(); refreshTimer = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        panel?.orderOut(nil); panel = nil
        windows = []; apps = []; snapshots = []; wallpaper = nil; loading = false; closing = false
    }
    func enablePreviews() {
        hasPreviewPermission = CGRequestScreenCaptureAccess()
        if hasPreviewPermission { loadPreviews() }
        else { message = "Allow Screen Recording for Intent in System Settings, then reopen ⌘G. Previews stay on this Mac and are discarded when you close the overview." }
    }
    func hoverTab(_ tab: BrowserTabItem, browser: String, entered: Bool) {
        hoverTask?.cancel(); hoveredTab = nil; tabPreview = nil; tabPreviewError = nil
        guard entered else { return }
        hoverTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            guard let self, !self.closing, self.panel?.isVisible == true else { return }
            self.hoveredTab = tab
            let heartbeat = BrowserGuardHeartbeatStore(fileURL: BrowserGuardHeartbeatStore.fileURL(for: browser))
            guard heartbeat.supports(.tabPreview, maxAge: 5) else {
                self.tabPreviewError = "Reload Browser Guard to enable tab previews."; return
            }
            self.tabPreviewLoading = true
            defer { self.tabPreviewLoading = false }
            let command = BrowserTabCommand(tabID: tab.id, windowID: tab.windowID, action: .preview)
            let url = BrowserTabPreview.fileURL(browser: browser)
            try? FileManager.default.removeItem(at: url)
            try? BrowserTabCommandStore(browserBundleIdentifier: browser).write(command)
            for _ in 0..<40 {
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                guard !self.closing else { return }
                if let data = try? Data(contentsOf: url),
                   let result = try? JSONDecoder().decode(BrowserTabPreview.self, from: data), result.requestID == command.id {
                    try? FileManager.default.removeItem(at: url)
                    if let encoded = result.image?.split(separator: ",", maxSplits: 1).last,
                       let imageData = Data(base64Encoded: String(encoded)), let image = NSImage(data: imageData) {
                        self.tabPreview = image
                    } else { self.tabPreviewError = result.error ?? "Preview unavailable." }
                    return
                }
            }
            self.tabPreviewError = "Preview timed out. Try hovering again."
        }
    }
    private func loadPreviews() {
        guard !loading, !closing else { return }
        hasPreviewPermission = CGPreflightScreenCaptureAccess()
        guard hasPreviewPermission else { return }
        guard #available(macOS 14.0, *) else { message = "Window previews require macOS 14 or newer."; return }
        let token = generation
        loading = true
        previewTask = Task { [weak self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let self, !Task.isCancelled, self.generation == token else { return }
                // Capture only the desktop behind all ordinary windows. A private
                // background-layer window can be transparent/black when captured alone.
                if self.wallpaper == nil, let display = content.displays.first(where: { $0.frame == self.displayFrame }) {
                    let config = SCStreamConfiguration()
                    config.width = Int(self.displayFrame.width); config.height = Int(self.displayFrame.height)
                    config.showsCursor = false
                    let excluded = content.windows.filter { window in
                        let owner = window.owningApplication?.bundleIdentifier ?? ""
                        return window.windowLayer >= 0 || owner == "com.apple.finder"
                            || owner == "com.apple.notificationcenterui" || owner.localizedCaseInsensitiveContains("widget")
                    }
                    let filter = SCContentFilter(display: display, excludingWindows: excluded)
                    if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config), self.generation == token {
                        self.wallpaper = NSImage(cgImage: image, size: .zero)
                    }
                }
                let appByPID = Dictionary(uniqueKeysWithValues: self.apps.map { ($0.pid, $0.id) })
                let candidates = content.windows.filter {
                    $0.windowLayer == 0 && $0.frame.width > 140 && $0.frame.height > 140
                        && !($0.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && $0.owningApplication.flatMap { appByPID[$0.processID] } != nil
                }.sorted {
                    let rowA = Int($0.frame.midY / 120), rowB = Int($1.frame.midY / 120)
                    if rowA != rowB { return rowA < rowB }
                    if $0.frame.midX != $1.frame.midX { return $0.frame.midX < $1.frame.midX }
                    return $0.windowID < $1.windowID
                }
                var items: [WindowItem] = []
                for window in candidates {
                    guard !Task.isCancelled, self.generation == token else { return }
                    guard let pid = window.owningApplication?.processID, let appID = appByPID[pid] else { continue }
                    let config = SCStreamConfiguration()
                    let scale = min(1, 1000 / max(window.frame.width, window.frame.height))
                    config.width = max(1, Int(window.frame.width * scale))
                    config.height = max(1, Int(window.frame.height * scale))
                    config.showsCursor = false; config.ignoreShadowsSingleWindow = true
                    let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
                    items.append(.init(id: window.windowID, appID: appID, title: window.title ?? "", sourceFrame: window.frame,
                                       preview: image.map { NSImage(cgImage: $0, size: .zero) }))
                }
                guard !Task.isCancelled, self.generation == token else { return }
                self.windows = items; self.loading = false; self.refresh()
                // Mount at desktop positions before animating into the overview.
                try? await Task.sleep(nanoseconds: 30_000_000)
                guard self.generation == token, !self.closing else { return }
                withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .spring(response: 0.46, dampingFraction: 0.88)) { self.expanded = true }
            } catch {
                guard let self, self.generation == token else { return }
                self.loading = false; self.message = "Couldn't capture your windows. Check Screen Recording access and reopen ⌘G."
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
    @State private var hoveredWindow: CGWindowID?
    private let green = Color(red: 0.20, green: 0.91, blue: 0.42)
    var body: some View {
        GeometryReader { geometry in
            let footerHeight: CGFloat = controller.windowlessApps.isEmpty ? 72 : 132
            let area = CGRect(x: 32, y: 98, width: max(1, geometry.size.width - 64), height: max(1, geometry.size.height - 98 - footerHeight))
            let frames = FieldOfViewLayout.frames(sizes: controller.windows.map { $0.sourceFrame.size }, in: area)
            ZStack(alignment: .topLeading) {
                wallpaper(size: geometry.size)
                Color.black.opacity(0.14).ignoresSafeArea()
                ForEach(Array(controller.windows.enumerated()), id: \.element.id) { index, window in
                    if index < frames.count { windowView(window, target: frames[index]) }
                }
                VStack(spacing: 0) {
                    Text("intent field of view").font(.system(size: 19, weight: .medium))
                        .frame(maxWidth: .infinity).frame(height: 76).background(.black.opacity(0.24))
                    Spacer()
                    if controller.loading {
                        ProgressView("Gathering windows…").padding(18).background(.ultraThinMaterial, in: Capsule())
                        Spacer()
                    } else if !controller.hasPreviewPermission {
                        VStack(spacing: 14) {
                            Image(systemName: "macwindow.on.rectangle").font(.system(size: 36))
                            Text("See your actual windows").font(.title2)
                            Text("Allow Screen Recording to show previews here.\nLocal previews only—no video recording or upload.")
                                .multilineTextAlignment(.center).foregroundStyle(.secondary)
                            Button("Enable window previews") { controller.enablePreviews() }.buttonStyle(.borderedProminent)
                        }.padding(28).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                        Spacer()
                    }
                    footer
                }
                if let tab = controller.hoveredTab {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(tab.title).font(.headline).lineLimit(2)
                        Text(URL(string: tab.url)?.host ?? tab.url).font(.caption).foregroundStyle(.secondary)
                        Group {
                            if let image = controller.tabPreview {
                                Image(nsImage: image).resizable().scaledToFit()
                            } else if let error = controller.tabPreviewError {
                                Text(error).padding(30)
                            } else { ProgressView("Loading tab preview…").padding(30) }
                        }.frame(maxWidth: .infinity, maxHeight: 380)
                    }.padding(16).frame(width: min(640, geometry.size.width - 80))
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .shadow(radius: 22).position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                        .allowsHitTesting(false)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
                .foregroundStyle(.white).preferredColorScheme(.dark)
        }
    }
    private func wallpaper(size: CGSize) -> some View {
        Group {
            if let image = controller.wallpaper { Image(nsImage: image).resizable().scaledToFill() }
            else { LinearGradient(colors: [Color(red: 0.16, green: 0.25, blue: 0.32), .black], startPoint: .top, endPoint: .bottom) }
        }.frame(width: size.width, height: size.height).clipped().ignoresSafeArea()
    }
    private func windowView(_ window: QuickSelectionController.WindowItem, target: CGRect) -> some View {
        let original = window.sourceFrame.offsetBy(dx: -controller.displayFrame.minX, dy: -controller.displayFrame.minY)
        let frame = controller.expanded ? target : original
        let selected = controller.isSelected(window)
        let app = controller.apps.first { $0.id == window.appID }
        let tabs = controller.tabs(for: window)
        let isBrowser = QuickSelection.browsers.contains(window.appID)
        return ZStack(alignment: .top) {
            Button { controller.selectWindow(window) } label: {
                Group {
                    if let preview = window.preview { Image(nsImage: preview).resizable().scaledToFit() }
                    else {
                        ZStack {
                            Color.black.opacity(0.4)
                            VStack(spacing: 7) {
                                if let app { Image(nsImage: app.icon).resizable().frame(width: 32, height: 32) }
                                Text("Preview unavailable").font(.caption)
                            }
                        }
                    }
                }.frame(width: frame.width, height: frame.height)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? green : .white.opacity(0.18), lineWidth: selected ? 4 : 1))
                    .shadow(color: selected ? green.opacity(0.65) : .black.opacity(0.35), radius: selected ? 12 : 8, y: selected ? 0 : 5)
            }.buttonStyle(.plain)
                .onHover { hoveredWindow = $0 ? window.id : (hoveredWindow == window.id ? nil : hoveredWindow) }
                .accessibilityLabel("\(app?.app.name ?? window.appID): \(window.title), \(selected ? "selected" : "not selected")")
                .help(isBrowser ? "Choose tabs—no tabs are automatically selected" : "Allow \(app?.app.name ?? window.appID)—all its windows")
            if controller.expanded {
                if isBrowser {
                    if !tabs.isEmpty {
                        ScrollView(.horizontal, showsIndicators: true) {
                            HStack(spacing: 5) { ForEach(tabs) { tab in tabBubble(tab, browser: window.appID, width: min(156, max(70, target.width * 0.36))) } }.padding(4)
                        }.frame(width: target.width, height: 58)
                            .background(controller.focusedBrowserWindow == window.id ? .white.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 12))
                            .offset(y: -60)
                    } else {
                        Text("Tabs unavailable · reconnect Browser Guard").font(.system(size: 10)).lineLimit(2).padding(5)
                            .frame(width: target.width).background(.black.opacity(0.6), in: Capsule()).offset(y: -38)
                    }
                }
                HStack(spacing: 5) {
                    if let app { Image(nsImage: app.icon).resizable().frame(width: 17, height: 17) }
                    Text(window.title.isEmpty ? (app?.app.name ?? window.appID) : window.title).lineLimit(1)
                }.font(.system(size: 11, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 3)
                    .frame(maxWidth: target.width).background(.black.opacity(0.42), in: Capsule())
                    .offset(y: target.height * 0.48).opacity(hoveredWindow == window.id ? 1 : 0).allowsHitTesting(false)
            }
        }.frame(width: frame.width, height: frame.height)
            .padding(.top, 62).padding(.bottom, 26)
            .position(x: frame.midX, y: frame.midY - 18)
            .allowsHitTesting(controller.expanded && !controller.closing)
    }
    private func tabBubble(_ tab: BrowserTabItem, browser: String, width: CGFloat) -> some View {
        let key = QuickSelectionTab(browser: browser, id: tab.id)
        let selected = controller.selection.tabs.contains(key)
        return Button { controller.message = nil; controller.selection.toggleTab(key) } label: {
            HStack(spacing: 5) {
                TabSiteIcon(url: tab.faviconURL)
                    .overlay(alignment: .bottomTrailing) {
                        if selected { Image(systemName: "checkmark.circle.fill").font(.system(size: 9)).foregroundStyle(green).offset(x: 4, y: 4) }
                    }
                Text(tab.title).font(.system(size: 11, weight: .medium)).lineLimit(2)
            }.padding(.horizontal, 8).frame(width: width, height: 43)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(selected ? green : .white.opacity(0.25), lineWidth: selected ? 3 : 1))
                .shadow(color: selected ? green.opacity(0.45) : .clear, radius: 5)
        }.buttonStyle(.plain).disabled(!QuickSelection.isSelectable(tab)).opacity(QuickSelection.isSelectable(tab) ? 1 : 0.45)
            .onHover { controller.hoverTab(tab, browser: browser, entered: $0) }
            .accessibilityLabel("Tab: \(tab.title), \(selected ? "selected" : "not selected")")
    }
    private var footer: some View {
        VStack(spacing: 9) {
            if !controller.windowlessApps.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        Text("No window").font(.caption).foregroundStyle(.secondary)
                        ForEach(controller.windowlessApps) { app in
                            Button { controller.selectApp(app) } label: {
                                Image(nsImage: app.icon).resizable().frame(width: 30, height: 30).padding(5)
                                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(controller.selection.apps.contains(app.id) ? green : .clear, lineWidth: 3))
                            }.buttonStyle(.plain).help(app.app.name)
                                .accessibilityLabel("\(app.app.name), no window, \(controller.selection.apps.contains(app.id) ? "selected" : "not selected")")
                        }
                    }.padding(.horizontal, 4)
                }.frame(height: 46)
            }
            if let message = controller.message { Text(message).font(.system(size: 12)).foregroundStyle(.orange).lineLimit(3) }
            HStack(spacing: 18) {
                Button("Cancel · Esc") { controller.cancel() }.buttonStyle(.plain)
                Spacer()
                Text("Apps \(controller.selection.apps.count) · Tabs \(controller.selection.tabs.count)").foregroundStyle(.white.opacity(0.7))
                Button("Clear") { controller.selection = QuickSelection(); controller.message = nil }.buttonStyle(.plain)
                Button("Start · ⌘G") { controller.runSelection() }.buttonStyle(.borderedProminent).tint(green).foregroundStyle(.black)
                    .disabled(controller.selection.apps.isEmpty || controller.loading || controller.closing || controller.tabPreviewLoading)
            }.font(.system(size: 13, weight: .medium))
        }.padding(.horizontal, 28).padding(.vertical, 14).background(.black.opacity(0.25))
    }
}

private struct TabSiteIcon: View {
    let url: String?
    @State private var icon: NSImage?
    var body: some View {
        Group {
            if let icon { Image(nsImage: icon).resizable().scaledToFit() }
            else { Image(systemName: "globe").foregroundStyle(.secondary) }
        }.frame(width: 18, height: 18).task(id: url) {
            icon = nil
            guard let url, let address = URL(string: url) else { return }
            if address.scheme == "data", let encoded = url.split(separator: ",", maxSplits: 1).last,
               let data = Data(base64Encoded: String(encoded)) { icon = NSImage(data: data); return }
            guard ["https", "http"].contains(address.scheme ?? "") else { return }
            var request = URLRequest(url: address); request.timeoutInterval = 5
            if let (data, _) = try? await URLSession.shared.data(for: request), data.count < 1_000_000, !Task.isCancelled {
                icon = NSImage(data: data)
            }
        }
    }
}
