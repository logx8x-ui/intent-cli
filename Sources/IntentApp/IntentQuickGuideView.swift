import AppKit
import QuartzCore
import ApplicationServices
import SwiftUI
import IntentCore

/// A real small window, rather than an onboarding page inside the full desktop.
struct IntentQuickGuidePresenter: NSViewRepresentable {
    let model: IntentAppModel
    let onFinish: () -> Void
    let onDismiss: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let anchor = NSView()
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            guard coordinator.active, coordinator.panel == nil else { return }
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 340),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "Your first intention"
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            coordinator.dismiss = onDismiss
            panel.delegate = coordinator
            panel.contentView = NSHostingView(rootView: IntentQuickGuideView(model: model, onFinish: onFinish, onDismiss: onDismiss, resize: { size in
                let screen = panel.screen ?? NSScreen.main
                let desktop = size.width > 800
                panel.titleVisibility = desktop ? .hidden : .visible
                panel.titlebarAppearsTransparent = desktop
                let bounds = screen?.visibleFrame ?? panel.frame
                let target = desktop ? bounds : panel.frameRect(forContentRect: NSRect(origin: .zero, size: size))
                let frame = NSRect(x: bounds.midX - target.width / 2, y: bounds.midY - target.height / 2, width: target.width, height: target.height)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.38
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    panel.animator().setFrame(frame, display: true)
                }
            }))
            coordinator.panel = panel
            panel.center()
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
        return anchor
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.active = false
        coordinator.panel?.delegate = nil
        coordinator.panel?.contentView = nil
        coordinator.panel?.close()
        coordinator.panel = nil
    }
    final class Coordinator: NSObject, NSWindowDelegate {
        var active = true
        var panel: NSPanel?
        var dismiss: (() -> Void)?
        func windowWillClose(_ notification: Notification) { dismiss?() }
    }
}

struct IntentQuickGuideView: View {
    @ObservedObject var model: IntentAppModel
    let onFinish: () -> Void
    let onDismiss: () -> Void
    let resize: (NSSize) -> Void
    @State private var draft = Self.loadDraft()
    @State private var query = ""
    @State private var website = ""
    @State private var browser = "com.google.Chrome"
    @State private var suggestedSites: [AllowedWebsite] = []
    @State private var siteTitles: [String: String] = [:]
    @State private var suggestedAppIDs: [String] = []
    @State private var trusted = AXIsProcessTrusted()
    @State private var screenAccess = CGPreflightScreenCaptureAccess()
    @State private var connectedBrowsers: Set<String> = []
    @State private var error: String?
    @State private var starting = false
    @State private var expandedBrowser: String?
    @State private var openedAccessibility = false
    @State private var overviewVisible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var nameFocused: Bool
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private static let draftKey = "intentFirstIntentionDraftV1"
    private var cleanName: String { draft.name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var selectedBrowsers: Set<String> { draft.appIDs.intersection(QuickSelection.browsers) }
    private var availableApps: [AllowedApp] { model.installedApps.map { AllowedApp(name: $0.name, bundleIdentifier: $0.bundleIdentifier) } }
    private var ready: Bool { trusted && selectedBrowsers.isSubset(of: connectedBrowsers) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if draft.step < 3 {
                HStack {
                    Text("\(draft.step + 1) of 3").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Later") { onDismiss() }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            switch draft.step {
            case 0: question
            case 1: resources
            case 2: permissions
            case 3: running
            default: completed
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if draft.step == 1 {
                ZStack {
                    if let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen), let wallpaper = NSImage(contentsOf: url) {
                        Image(nsImage: wallpaper).resizable().scaledToFill().blur(radius: 24)
                    }
                    Color.black.opacity(0.65)
                }.clipped()
            } else { Rectangle().fill(.regularMaterial) }
        }
        .preferredColorScheme(draft.step == 1 ? .dark : nil)
        .onAppear {
            if draft.step == 3 && !model.hasActiveSession { draft.step = 4 }
            refresh(); updateSize(); openRequiredPermission(); nameFocused = true
        }
        .onChange(of: draft) { _ in persist() }
        .onChange(of: draft.step) { _ in updateSize(); openRequiredPermission() }
        .onReceive(clock) { _ in refreshPermissions() }
        .onChange(of: model.installedApps) { _ in refresh() }
        .onChange(of: model.hasActiveSession) { active in
            if starting && active { starting = false; draft.step = 3; error = nil }
            else if draft.step == 3 && !active {
                if let message = model.errorMessage { error = message; draft.step = 2 }
                else { UserDefaults.standard.removeObject(forKey: Self.draftKey); onFinish() }
            }
        }
        .onChange(of: model.errorMessage) { value in
            if starting, let value { starting = false; error = value }
        }
        .onExitCommand { onDismiss() }
    }
    private var question: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("What do you want to do on your computer right now?").font(.system(size: 25, weight: .semibold))
            TextField("For example, finish my assignment", text: $draft.name)
                .textFieldStyle(.roundedBorder).font(.title3).focused($nameFocused)
                .onSubmit { if !cleanName.isEmpty { advanceToResources() } }
            Text("That will be the name of your first intention.").font(.callout).foregroundStyle(.secondary)
            Text("⌘G  Choose apps anytime     ·     \(FinishShortcutStore.load().displayName)  Finish a session")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Choose apps →", action: advanceToResources).buttonStyle(.borderedProminent).disabled(cleanName.isEmpty) }
        }
    }
    private var resources: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                Text("Make room for “\(cleanName)”").font(.system(size: 28, weight: .semibold)).lineLimit(1)
                Text("Choose what belongs in this moment.").foregroundStyle(.secondary)
                VStack(spacing: 10) {
                    TextField("Search your apps", text: $query).textFieldStyle(.plain)
                        .font(.system(size: 22, weight: .light)).multilineTextAlignment(.center)
                        .accessibilityLabel("Search your apps")
                    Rectangle().fill(Color.white.opacity(0.35)).frame(height: 1)
                }.frame(maxWidth: 360).padding(.top, 10)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if query.isEmpty {
                        appRow("Open on your Mac", apps: displayedApps.filter { runningAppIDs.contains($0.id) })
                        appRow("Your familiar apps", apps: displayedApps.filter { !runningAppIDs.contains($0.id) })
                    } else {
                        appRow("Search results", apps: displayedApps)
                        if displayedApps.isEmpty { Text("No apps found. Try another name.").foregroundStyle(.secondary) }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Your websites").font(.title3.weight(.semibold))
                        Text("Open a browser below to choose its websites. Selecting a site also selects its browser.").font(.callout).foregroundStyle(.secondary)
                        ForEach(model.installedApps.filter { QuickSelection.browsers.contains($0.id) }) { app in
                            browserGroup(app)
                        }
                    }.frame(maxWidth: 760, alignment: .leading)
                }.padding(.horizontal, 8).padding(.vertical, 8)
            }
            HStack {
                Button("← Back") { draft.step = 0 }.buttonStyle(.plain)
                Spacer()
                Text("\(draft.appIDs.count) apps · \(draft.websites.count) websites").foregroundStyle(.secondary)
                Button("Continue →") {
                    do { _ = try draft.makeIntention(availableApps: availableApps); error = nil; draft.step = 2 }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(draft.appIDs.isEmpty)
            }
            Text("⌘G opens the app picker · \(FinishShortcutStore.load().displayName) finishes your intention")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
        .opacity(overviewVisible ? 1 : 0).scaleEffect(overviewVisible ? 1 : 0.96)
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.45).delay(0.12)) { overviewVisible = true }
        }
        .onDisappear { overviewVisible = false }
    }
    private var runningAppIDs: Set<String> {
        Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.bundleIdentifier))
    }
    @ViewBuilder private func appRow(_ title: String, apps: [InstalledApp]) -> some View {
        if !apps.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.title3.weight(.semibold))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) { ForEach(apps) { app in appTile(app) } }.padding(4)
                }
            }
        }
    }
    private func appTile(_ app: InstalledApp) -> some View {
        let selected = draft.appIDs.contains(app.id)
        return Button { toggleApp(app.id) } label: {
            VStack(spacing: 14) {
                Image(nsImage: app.icon).resizable().frame(width: 76, height: 76).shadow(color: .black.opacity(0.2), radius: 10, y: 5)
                Text(app.name).font(.system(size: 15, weight: .medium)).lineLimit(1)
            }
            .frame(width: 196, height: 158)
            .background(LinearGradient(colors: [Color.white.opacity(selected ? 0.19 : 0.10), Color.white.opacity(0.035)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(selected ? Color.green : Color.white.opacity(0.13), lineWidth: selected ? 2 : 1))
            .overlay(alignment: .topTrailing) {
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3).padding(12) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(.plain).accessibilityLabel("\(app.name), \(selected ? "selected" : "not selected")")
    }
    private func browserGroup(_ app: InstalledApp) -> some View {
        let sites = suggestedSites.filter { $0.browserBundleIdentifier == app.id }
            + draft.websites.filter { $0.browserBundleIdentifier == app.id && !suggestedSites.contains($0) }
        return DisclosureGroup(isExpanded: Binding(get: { expandedBrowser == app.id }, set: { expandedBrowser = $0 ? app.id : nil; browser = app.id; website = "" })) {
            VStack(alignment: .leading, spacing: 8) {
                if sites.isEmpty { Text("No shared tabs yet. Add a website to get started.").foregroundStyle(.secondary).font(.callout) }
                ForEach(sites, id: \.resourceID) { site in siteButton(site) }
                HStack {
                    TextField("Add a website, e.g. docs.google.com", text: $website).textFieldStyle(.plain)
                        .onSubmit { browser = app.id; addWebsite() }
                    Button("Add") { browser = app.id; addWebsite() }.disabled(website.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(12).background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            }.padding(.top, 12)
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: app.icon).resizable().frame(width: 28, height: 28)
                Text(app.name).fontWeight(.medium)
                Spacer()
                Text("\(draft.websites.filter { $0.browserBundleIdentifier == app.id }.count) selected").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16).background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }
    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("One quick setup.").font(.title.weight(.semibold))
            Text("Then you can start “\(cleanName)”.").foregroundStyle(.secondary)
            permissionRow("Allow Intent to keep you focused", detail: "Turn on Intent in Accessibility. macOS asks you to approve this yourself.", granted: trusted, action: {
                let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
                openSettings("Privacy_Accessibility")
            })
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)).resizable().frame(width: 38, height: 38)
                    .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
                    .help("Drag Intent into the Accessibility app list, then turn its switch on.")
                Text("Can’t find Intent? Drag this icon into the app list, then turn it on.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(selectedBrowsers.sorted(), id: \.self) { id in
                permissionRow("Connect \(browserName(id))", detail: "Browser Guard keeps your chosen websites available. Return here when it’s connected.", granted: connectedBrowsers.contains(id), action: {
                    openBrowserSetup(id)
                })
            }
            permissionRow("Window previews & blur", detail: "Optional. Screen Recording lets Intent show and blur window previews.", granted: screenAccess, action: {
                _ = CGRequestScreenCaptureAccess()
                openSettings("Privacy_ScreenCapture")
            })
            Text("Your choices are saved on this Mac if macOS asks you to restart Intent.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Back") { draft.step = 1; refresh() }
                Spacer()
                Button(starting ? "Starting…" : "Start my first intention", action: start)
                    .buttonStyle(.borderedProminent).disabled(!ready || starting)
            }
        }
    }
    private var running: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Your intention is running", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Text(cleanName).font(.title.weight(.semibold))
            Text("Use your chosen apps now. When you’re done, finish here or press \(FinishShortcutStore.load().displayName).")
            HStack {
                Button("Let me work") { onDismiss() }
                Spacer()
                Button("Finish this intention") { model.endActiveSession() }.buttonStyle(.borderedProminent)
            }
        }
    }
    private var completed: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("That’s your first intention.").font(.title.weight(.semibold))
            Text("You can save your intention from the session’s save prompt, or keep it as a one-off.")
            Button("Done") { UserDefaults.standard.removeObject(forKey: Self.draftKey); onFinish() }.buttonStyle(.borderedProminent)
        }
    }
    private func permissionRow(_ title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle").foregroundStyle(granted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 4) { Text(title).fontWeight(.medium); Text(detail).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if !granted { Button("Set up", action: action) }
        }.padding(12).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
    private var displayedApps: [InstalledApp] {
        let catalog = model.installedApps.filter { !$0.bundleIdentifier.hasPrefix("dev.loganmondi.intent") && (!$0.name.isEmpty) }
        if !query.isEmpty { return catalog.filter { $0.matchesSearch(query) } }
        let byID = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Background macOS helpers are searchable, but do not belong in the suggested row.
        let suggested = suggestedAppIDs.filter { id in
            guard let app = byID[id] else { return false }
            return !app.url.path.hasPrefix("/System/Library/") || runningAppIDs.contains(id)
        }
        let ids = suggested + draft.appIDs.sorted()
        var seen = Set<String>()
        let recommended = ids.compactMap { id -> InstalledApp? in guard seen.insert(id).inserted else { return nil }; return byID[id] }
        return recommended.isEmpty ? Array(catalog.prefix(24)) : recommended
    }
    private func siteButton(_ site: AllowedWebsite) -> some View {
        let selected = draft.websites.contains { $0.resourceID == site.resourceID }
        return Button {
            if selected { draft.websites.removeAll { $0.resourceID == site.resourceID } }
            else { draft.websites.append(site); if let browser = site.browserBundleIdentifier { draft.appIDs.insert(browser) } }
            error = nil
        } label: {
            HStack { Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(siteTitles[site.resourceID] ?? site.value).lineLimit(1)
                    if siteTitles[site.resourceID] != nil { Text(site.value).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }; Spacer(); Text(browserName(site.browserBundleIdentifier ?? "")).font(.caption).foregroundStyle(.secondary)
            }.padding(8).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func toggleApp(_ id: String) {
        if draft.appIDs.remove(id) != nil { draft.websites.removeAll { $0.browserBundleIdentifier == id } }
        else {
            draft.appIDs.insert(id)
            if QuickSelection.browsers.contains(id) { expandedBrowser = id; browser = id; website = "" }
        }
        error = nil
    }
    private func addWebsite() {
        let raw = website.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = raw.contains("://") ? raw : "https://" + raw
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme ?? ""), url.host != nil,
              model.installedApps.contains(where: { $0.id == browser }) else { error = "Enter a website and choose an installed browser."; return }
        let site = AllowedWebsite(value, browserBundleIdentifier: browser)
        if !draft.websites.contains(where: { $0.resourceID == site.resourceID }) { draft.websites.append(site) }
        draft.appIDs.insert(browser); website = ""; error = nil
    }
    private func advanceToResources() { guard !cleanName.isEmpty else { return }; draft.name = cleanName; draft.step = 1; refresh() }
    private func refresh() {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.bundleIdentifier)
        suggestedAppIDs = running + AppCatalog.mostUsed(in: model.installedApps).map(\.id)
        var sites: [AllowedWebsite] = []
        var titles: [String: String] = [:]
        for id in QuickSelection.browsers.sorted() {
            if let snapshot = BrowserTabSnapshotStore(browserBundleIdentifier: id).load() {
                for tab in snapshot.allTabs ?? snapshot.tabs where QuickSelection.isSelectable(tab) {
                    let site = AllowedWebsite(tab.url, browserBundleIdentifier: id)
                    if !sites.contains(where: { $0.resourceID == site.resourceID }) { sites.append(site); titles[site.resourceID] = tab.title }
                }
            }
        }
        suggestedSites = sites; siteTitles = titles
        refreshPermissions()
    }
    private func refreshPermissions() {
        trusted = AXIsProcessTrusted(); screenAccess = CGPreflightScreenCaptureAccess()
        connectedBrowsers = Set(QuickSelection.browsers.filter {
            BrowserGuardHeartbeatStore(fileURL: BrowserGuardHeartbeatStore.fileURL(for: $0)).supports(.singleStartupLaunch, maxAge: 5)
                && BrowserGuardStateStore(fileURL: BrowserGuardStateStore.fileURL(for: $0)).isEnabled()
        })
    }
    private func openBrowserSetup(_ id: String) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        let link = id == "org.mozilla.firefox"
            ? "https://github.com/logx8x-ui/intent-cli/releases/latest/download/Intent-Firefox-Extension.xpi"
            : "https://github.com/logx8x-ui/intent-cli#chrome"
        NSWorkspace.shared.open([URL(string: link)!], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }
    private func openSettings(_ pane: String) { persist(); NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane)!) }
    private func browserName(_ id: String) -> String { id == "org.mozilla.firefox" ? "Firefox" : "Chrome" }
    private func start() {
        refreshPermissions(); guard ready else { return }
        do {
            let intention = try draft.makeIntention(availableApps: availableApps)
            persist(); starting = true; error = nil; model.errorMessage = nil
            _ = model.startFirstIntention(intention)
            if model.hasActiveSession { starting = false; draft.step = 3 }
            else { starting = false; error = model.errorMessage ?? "Couldn’t start. Try again." }
        } catch { self.error = error.localizedDescription }
    }
    private func openRequiredPermission() {
        guard draft.step == 2, !trusted, !openedAccessibility else { return }
        openedAccessibility = true
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        openSettings("Privacy_Accessibility")
    }
    private func updateSize() { resize(NSSize(width: draft.step == 1 ? 1200 : 540, height: draft.step == 1 ? 800 : draft.step == 2 ? CGFloat(430 + selectedBrowsers.count * 80) : 380)) }
    private func persist() { if let data = try? JSONEncoder().encode(draft) { UserDefaults.standard.set(data, forKey: Self.draftKey) } }
    private static func loadDraft() -> FirstIntentionDraft {
        guard let data = UserDefaults.standard.data(forKey: draftKey), let draft = try? JSONDecoder().decode(FirstIntentionDraft.self, from: data) else { return .init() }
        return draft
    }
}
