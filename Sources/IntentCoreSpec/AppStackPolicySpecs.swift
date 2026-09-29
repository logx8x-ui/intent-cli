import Foundation
import IntentCore

func runAppStackPolicySpecs() throws {
    let area = CGRect(x: 20, y: 80, width: 1300, height: 720)
    let panel = CGRect(x: 1050, y: 80, width: 270, height: 260)
    let items: [AppStackLayout.Item] = (0..<18).map { i in
        let source = CGRect(x: CGFloat(i * 40), y: CGFloat((i % 4) * 100), width: i % 2 == 0 ? 1100 : 600, height: 700)
        return AppStackLayout.Item(id: UInt32(i + 1), app: "app\(i / 3)", source: source, tabCount: i % 3)
    }
    let began = Date()
    let groups = AppStackLayout.groups(items, in: area, avoiding: panel)
    try expect(groups.count == 6, "Six app stacks fit around the panel")
    try expect(groups == AppStackLayout.groups(items.reversed(), in: area, avoiding: panel), "Stack layout is independent of enumeration order")
    for (index, group) in groups.enumerated() {
        try expect(group.ids.first == UInt32(index * 3 + 3), "Most-tab browser window begins at the front")
        try expect(area.contains(group.frame) && !group.frame.intersects(panel), "Stacks remain in bounds and avoid panels")
        try expect(groups.dropFirst(index + 1).allSatisfy { !$0.frame.intersects(group.frame) }, "Different app stacks cannot overlap")
    }
    print("App-stack pack: \(Int(Date().timeIntervalSince(began) * 1000)) ms for two 18-window layouts")
    var selection = QuickSelection()
    selection.toggleWindow(20, app: "com.apple.Notes")
    selection.toggleWindow(21, app: "com.apple.Notes")
    selection.toggleWindow(20, app: "com.apple.Notes")
    try expect(selection.windowIDsByApp["com.apple.Notes"] == [21], "Each Notes window is selected independently")
    let notes = try selection.makeIntention(apps: [.init(name: "Notes", bundleIdentifier: "com.apple.Notes")], snapshots: [])
    try expect(notes.selectionRequiresTabReselection, "Saving exact windows never silently grants the entire app")
    let instagram = WebsiteFeaturePolicy(site: .instagram), youtube = WebsiteFeaturePolicy(site: .youtube)
    try expect(instagram.allowedFeatures == ["messages"] && youtube.allowedFeatures == ["search"], "New-intention site defaults are deliberate")
    try expect(FocusWebsite.matching("youtube.com/watch?v=x") == .youtube && FocusWebsite.matching("https://youtube.com.evil.test") == nil, "URL normalization cannot confuse unrelated hosts")
    var invalid = instagram; invalid.allowedFeatures = []
    try expect(!invalid.isValid(for: .instagram), "Instagram needs at least one allowed area")
    var configured = notes; configured.websiteFeaturePolicies = ["instagram": instagram, "youtube": youtube]
    let roundtrip = try JSONDecoder().decode(Intention.self, from: JSONEncoder().encode(configured))
    try expect(roundtrip.websiteFeaturePolicies == configured.websiteFeaturePolicies, "Saved site policies survive round trip")
    var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(configured)) as! [String: Any]
    legacy.removeValue(forKey: "websiteFeaturePolicies")
    let old = try JSONDecoder().decode(Intention.self, from: JSONSerialization.data(withJSONObject: legacy))
    try expect(old.websiteFeaturePolicies.isEmpty, "Old saved intentions get no surprise restrictions")

    let chrome = "com.google.Chrome"
    let row = BrowserTabItem(id: 7, windowID: 2, index: 0, title: "Example", url: "https://example.com", active: true)
    let a = BrowserTabSnapshot(browserBundleIdentifier: chrome, browserSessionID: "profile-a", tabs: [row])
    let b = BrowserTabSnapshot(browserBundleIdentifier: chrome, browserSessionID: "profile-b", tabs: [row])
    let merged = BrowserProfileSnapshots.merged([a,b])!
    try expect(Set(merged.tabs.map(\.id)).count == 2 && Set(merged.tabs.map(\.windowID)).count == 2, "Equal native IDs in separate profiles remain distinct")
    try expect(BrowserProfileSnapshots.merged([a])?.tabs == [row], "Single-profile compatibility is preserved")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let base = directory.appendingPathComponent(BrowserTabSnapshotStore.fileURL(for: chrome).lastPathComponent)
    for snapshot in [a,b] {
        let file = BrowserProfileSnapshots.partition(base, session: snapshot.browserSessionID!)
        try BrowserTabSnapshotStore(fileURL: file).write(snapshot)
        try JSONEncoder().encode(Date()).write(to: file.appendingPathExtension("heartbeat"))
    }
    let commandBase = directory.appendingPathComponent(BrowserTabCommandStore.fileURL(for: chrome).lastPathComponent)
    try BrowserTabCommandStore(fileURL: commandBase).write(.init(tabID: merged.tabs[1].id, windowID: merged.tabs[1].windowID, browserSessionID: merged.browserSessionID))
    try expect(BrowserTabCommandStore(fileURL: BrowserProfileSnapshots.partition(commandBase, session: "profile-a")).take() == nil, "Wrong profile cannot consume activation")
    let command = BrowserTabCommandStore(fileURL: BrowserProfileSnapshots.partition(commandBase, session: "profile-b")).take()
    try expect(command?.tabID == 7 && command?.browserSessionID == "profile-b", "Activation is translated back to the correct profile's native ID")
    let since = Date().addingTimeInterval(-1)
    let ack = WebsitePolicyAcknowledgement(startupSessionID: "run", browserSessionID: "profile-a")
    try JSONEncoder().encode(ack).write(to: BrowserProfileSnapshots.partition(WebsitePolicyAcknowledgement.fileURL(browser: chrome, directory: directory), session: "profile-a"))
    try expect(!WebsitePolicyAcknowledgement.isReady(browser: chrome, session: "run", since: since, directory: directory), "Every profile must confirm policy installation")
    try JSONEncoder().encode(WebsitePolicyAcknowledgement(startupSessionID: "run", browserSessionID: "profile-b")).write(to: BrowserProfileSnapshots.partition(WebsitePolicyAcknowledgement.fileURL(browser: chrome, directory: directory), session: "profile-b"))
    try expect(WebsitePolicyAcknowledgement.isReady(browser: chrome, session: "run", since: since, directory: directory), "Both profile receipts unlock readiness")
    print("App stacks, website policy and profile identity specs passed")
}
