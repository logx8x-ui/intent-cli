import AppKit
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
                let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
                panel.setContentSize(size)
                panel.setFrameOrigin(NSPoint(x: center.x - panel.frame.width / 2, y: center.y - panel.frame.height / 2))
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
        .background(.regularMaterial)
        .onAppear {
            if draft.step == 3 && !model.hasActiveSession { draft.step = 4 }
            refresh(); updateSize(); nameFocused = true
        }
        .onChange(of: draft) { _ in persist(); updateSize() }
        .onReceive(clock) { _ in refreshPermissions() }
        .onChange(of: model.installedApps) { _ in refresh() }
        .onChange(of: model.hasActiveSession) { active in
            if starting && active { starting = false; draft.step = 3; error = nil }
            else if draft.step == 3 && !active {
                if let message = model.errorMessage { error = message; draft.step = 2 }
                else { draft.step = 4 }
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
            HStack { Spacer(); Button("Choose apps →", action: advanceToResources).buttonStyle(.borderedProminent).disabled(cleanName.isEmpty) }
        }
    }
    private var resources: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What do you need for “\(cleanName)”?").font(.title2.weight(.semibold)).lineLimit(2)
            Text("Click the apps and websites you want to use.").foregroundStyle(.secondary)
            TextField("Find an app", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(query.isEmpty ? "OPEN & FREQUENTLY USED" : "INSTALLED APPS").font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 125))], spacing: 8) {
                        ForEach(displayedApps) { app in
                            Button { toggleApp(app.bundleIdentifier) } label: {
                                HStack {
                                    Image(nsImage: app.icon).resizable().frame(width: 25, height: 25)
                                    Text(app.name).lineLimit(1)
                                    Spacer(minLength: 0)
                                    if draft.appIDs.contains(app.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                                }.padding(8).frame(maxWidth: .infinity)
                                    .background(draft.appIDs.contains(app.id) ? Color.green.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain).accessibilityLabel("\(app.name), \(draft.appIDs.contains(app.id) ? "selected" : "not selected")")
                        }
                    }
                    Text("BROWSER TABS & WEBSITES").font(.caption).foregroundStyle(.secondary)
                    if suggestedSites.isEmpty {
                        Text("No tabs shared yet. Add a website below; we’ll connect your browser in the next step.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(suggestedSites, id: \.resourceID) { site in siteButton(site) }
                    ForEach(draft.websites.filter { selected in !suggestedSites.contains(where: { $0.resourceID == selected.resourceID }) }, id: \.resourceID) { site in siteButton(site) }
                }
            }
            HStack {
                Picker("Browser", selection: $browser) { Text("Chrome").tag("com.google.Chrome"); Text("Firefox").tag("org.mozilla.firefox") }.labelsHidden().frame(width: 100)
                TextField("Add a website, e.g. docs.google.com", text: $website).textFieldStyle(.roundedBorder).onSubmit(addWebsite)
                Button("Add", action: addWebsite).disabled(website.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                Button("Back") { draft.step = 0 }
                Spacer()
                Text("\(draft.appIDs.count) apps · \(draft.websites.count) websites").font(.caption).foregroundStyle(.secondary)
                Button("Continue →") {
                    do { _ = try draft.makeIntention(availableApps: availableApps); error = nil; draft.step = 2 }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(draft.appIDs.isEmpty)
            }
        }
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
            Text("“\(cleanName)” is saved. Run it again from your desktop, or press ⌘G to choose a new set of apps and tabs.")
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
        let ids = suggestedAppIDs + draft.appIDs.sorted()
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
        else { draft.appIDs.insert(id) }
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
            let id: String
            if let saved = draft.savedIntentionID, let original = model.intentions.first(where: { $0.id == saved }) {
                var updated = intention; updated.id = saved; updated.graphPosition = original.graphPosition
                model.updateIntention(updated); id = saved
            }
            else {
                guard let saved = model.addDraftIntention(intention, at: .init(x: 100, y: 100)) else { error = "Couldn’t save your intention. Try again."; return }
                draft.savedIntentionID = saved; id = saved
            }
            persist(); starting = true; error = nil; model.errorMessage = nil
            model.requestStart(intentionID: id)
            if model.hasActiveSession { starting = false; draft.step = 3 }
            else if let message = model.errorMessage { starting = false; error = message }
        } catch { self.error = error.localizedDescription }
    }
    private func updateSize() { resize(NSSize(width: draft.step == 1 ? 620 : 540, height: draft.step == 1 ? 610 : draft.step == 2 ? CGFloat(430 + selectedBrowsers.count * 80) : 340)) }
    private func persist() { if let data = try? JSONEncoder().encode(draft) { UserDefaults.standard.set(data, forKey: Self.draftKey) } }
    private static func loadDraft() -> FirstIntentionDraft {
        guard let data = UserDefaults.standard.data(forKey: draftKey), let draft = try? JSONDecoder().decode(FirstIntentionDraft.self, from: data) else { return .init() }
        return draft
    }
}
