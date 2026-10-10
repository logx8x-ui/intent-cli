import Foundation
import IntentCore

private func checkAppStackGeometry(_ items: [AppStackLayout.Item], bounds: CGRect, panel: CGRect? = nil) throws -> [AppStackLayout.Group] {
    let groups = AppStackLayout.groups(items, in: bounds, avoiding: panel)
    let windows = groups.flatMap(\.windows)
    try expect(Set(windows.map(\.id)) == Set(items.map(\.id)), "Every source window remains directly present in the larger overview")
    try expect(groups == AppStackLayout.groups(items.reversed(), in: bounds, avoiding: panel), "Free-space packing is independent of source enumeration")
    let sources = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.source) })
    let scale = windows[0].frame.width / sources[windows[0].id]!.width
    try expect(scale > 0 && scale <= 1, "Larger previews never exceed their native source size")
    for window in windows {
        let source = sources[window.id]!
        try expect(abs(window.frame.width / source.width - scale) < 0.0001
                   && abs(window.frame.height / source.height - scale) < 0.0001,
                   "Portrait, landscape and tiny windows retain their shape and shared scale")
        try expect(bounds.insetBy(dx: -0.0001, dy: -0.0001).contains(window.frame)
                   && bounds.insetBy(dx: -0.0001, dy: -0.0001).contains(window.captionFrame),
                   "Larger thumbnails reserve their full caption before reaching any screen control")
        if let panel {
            try expect(!window.frame.intersects(panel) && !window.captionFrame.intersects(panel),
                       "A moved recent-intentions panel never covers a thumbnail or its title")
        }
        try expect(windows.allSatisfy { !window.captionFrame.intersects($0.frame) }, "A caption stays exposed even when another app window is hovered")
        try expect(windows.filter { $0.id != window.id }.allSatisfy { !window.captionFrame.intersects($0.captionFrame) }, "Mixed-size window titles remain separate")
    }
    for (index, group) in groups.enumerated() {
        for other in groups.dropFirst(index + 1) {
            try expect(group.windows.allSatisfy { window in
                other.windows.allSatisfy { !window.frame.intersects($0.frame) }
            }, "Different app previews do not overlap as their scale increases")
        }
    }
    return groups
}

private func appPreviewCenter(_ groups: [AppStackLayout.Group]) -> CGPoint {
    let windows: [AppStackLayout.WindowPlacement] = groups.flatMap { $0.windows }
    let total = windows.reduce(CGFloat.zero) { $0 + $1.frame.width * $1.frame.height }
    let x = windows.reduce(CGFloat.zero) { $0 + $1.frame.midX * $1.frame.width * $1.frame.height }
    let y = windows.reduce(CGFloat.zero) { $0 + $1.frame.midY * $1.frame.width * $1.frame.height }
    return CGPoint(x: x / total, y: y / total)
}

private func appCluster(_ groups: [AppStackLayout.Group]) -> CGRect {
    groups.reduce(CGRect.null) { $0.union($1.frame) }
}

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
    let placed = groups.flatMap(\.windows)
    try expect(Set(placed.map(\.id)) == Set(items.map(\.id)), "Every app window is visible directly without opening a group sheet")
    for window in placed {
        try expect(area.contains(window.frame) && area.contains(window.captionFrame), "Previews and their complete captions fit inside the overview")
        try expect(!window.captionFrame.intersects(panel), "Window titles never overlap the recent-intentions panel")
        try expect(placed.allSatisfy { !window.captionFrame.intersects($0.frame) }, "No title is drawn over any window preview")
        try expect(placed.filter { $0.id != window.id }.allSatisfy { !window.captionFrame.intersects($0.captionFrame) }, "Window titles never overlap each other")
    }
    let roomy = CGRect(x: 0, y: 0, width: 2600, height: 1400)
    let sameSource = CGRect(x: 100, y: 100, width: 1000, height: 700)
    let equalWindows = (1...3).map { AppStackLayout.Item(id: UInt32($0), app: "Firefox", source: sameSource) }
        + [AppStackLayout.Item(id: 4, app: "Notes", source: sameSource)]
    let spreadGroups = AppStackLayout.groups(equalWindows, in: roomy)
    let firefoxGroup = spreadGroups.first { $0.app == "Firefox" }!
    let notesGroup = spreadGroups.first { $0.app == "Notes" }!
    try expect(firefoxGroup.windows.allSatisfy { $0.frame.size == notesGroup.windows[0].frame.size }, "A multi-window app keeps exactly the same preview scale as a single-window app")
    try expect(firefoxGroup.frame.width * firefoxGroup.frame.height > notesGroup.frame.width * notesGroup.frame.height * 2, "Three windows reserve substantially more overview space than one")
    try expect(Set(firefoxGroup.windows.map { $0.frame.minY }).count == 3, "Three windows use a staggered spread instead of a hidden pile or a rigid row")
    for window in firefoxGroup.windows {
        let covered = firefoxGroup.windows.filter { $0.id != window.id }.reduce(CGFloat.zero) { total, other in
            let intersection = window.frame.intersection(other.frame)
            return total + (intersection.isNull ? 0 : intersection.width * intersection.height)
        }
        try expect(covered < window.frame.width * window.frame.height * 0.30, "Each preview remains predominantly exposed even before hover brings it forward")
    }
    var updatedTabs = equalWindows
    updatedTabs[2].tabCount = 40
    let afterTabUpdate = AppStackLayout.groups(updatedTabs, in: roomy)
    try expect(afterTabUpdate.flatMap(\.windows) == spreadGroups.flatMap(\.windows), "Tab counts and default front order cannot move window positions")
    let many = (1...9).map { AppStackLayout.Item(id: UInt32($0), app: "Notes", source: sameSource) }
    let allNine = AppStackLayout.groups(many, in: roomy).flatMap(\.windows)
    try expect(allNine.count == 9, "Windows beyond the old four-window pile limit are not omitted")
    for window in allNine {
        try expect(allNine.allSatisfy { !window.captionFrame.intersects($0.frame) }, "A second spread row cannot cover a preceding row's title")
    }

    // The previous hard cap made even a single ordinary window less than half
    // size on an otherwise empty desktop. Occupied geometry now determines the
    // scale, including labels; a spacious sparse desktop needs no shrinkage.
    for count in [1, 2, 4] {
        let sparse: [AppStackLayout.Item] = (0..<count).map { (index: Int) -> AppStackLayout.Item in
            let x: CGFloat = CGFloat(index % 2) * 1000
            let y: CGFloat = CGFloat(index / 2) * 700
            let source = CGRect(x: x, y: y, width: CGFloat(1000), height: CGFloat(600))
            return AppStackLayout.Item(id: UInt32(index + 1), app: "sparse\(index)", source: source)
        }
        let groups = try checkAppStackGeometry(sparse, bounds: roomy)
        let nativeWindows: [AppStackLayout.WindowPlacement] = groups.flatMap { $0.windows }
        try expect(nativeWindows.allSatisfy { $0.frame.width == 1000 && $0.frame.height == 600 },
                   "One, two and four windows use native preview size whenever their complete footprints fit")
        let laptop = try checkAppStackGeometry(sparse, bounds: CGRect(x: 24, y: 96, width: 1600, height: 900))
        let laptopWindows: [AppStackLayout.WindowPlacement] = laptop.flatMap { $0.windows }
        try expect(laptopWindows.allSatisfy { $0.frame.width / 1000 > 0.68 },
                   "Sparse laptop layouts are substantially larger than the old 0.42 scale ceiling")
    }

    for count in [6, 18, 36, 50] {
        let mixed: [AppStackLayout.Item] = (0..<count).map { index in
            let sizes: [CGSize] = [.init(width: 1400, height: 850), .init(width: 600, height: 1000),
                                   .init(width: 280, height: 180), .init(width: 900, height: 520)]
            return .init(id: UInt32(index + 1), app: "mixed\(index / 3)",
                         source: CGRect(origin: CGPoint(x: CGFloat(index % 5) * 220, y: CGFloat(index / 5) * 90), size: sizes[index % sizes.count]))
        }
        for bounds in [area, CGRect(x: -2580, y: -250, width: 2540, height: 680), CGRect(x: 20, y: 40, width: 850, height: 1250)] {
            _ = try checkAppStackGeometry(mixed, bounds: bounds)
        }
    }

    let movedPanels = [CGRect(x: roomy.minX, y: roomy.minY, width: 270, height: 310),
                       CGRect(x: roomy.maxX - 270, y: roomy.minY, width: 270, height: 310),
                       CGRect(x: roomy.midX - 135, y: roomy.midY - 155, width: 270, height: 310)]
    for movedPanel in movedPanels {
        let spread = try checkAppStackGeometry(equalWindows, bounds: roomy, panel: movedPanel)
        let three = spread.first { $0.app == "Firefox" }!, one = spread.first { $0.app == "Notes" }!
        try expect(three.windows.allSatisfy { $0.frame.size == one.windows[0].frame.size }
                   && three.frame.width * three.frame.height > one.frame.width * one.frame.height * 2,
                   "Moving the panel to either top corner preserves equal sibling scale and the larger app-group footprint")
    }
    try expect(AppStackLayout.groups([], in: area).isEmpty && AppStackLayout.groups(equalWindows, in: .zero).isEmpty,
               "Unavailable desktops do not emit invalid preview geometry")
    try expect(AppStackLayout.groups(equalWindows, in: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 700)).isEmpty,
               "Nonfinite display geometry cannot escape preview bounds")
    let translated = equalWindows.map { item -> AppStackLayout.Item in
        var translated = item; translated.source = item.source.offsetBy(dx: -3000, dy: 700); return translated
    }
    try expect(AppStackLayout.groups(translated, in: roomy) == spreadGroups,
               "The same desktop moved to another monitor keeps its app arrangement")

    // Native window coordinates describe the desktop the user had open, not
    // where an app must be pinned in the overview. Widely separated sources
    // should still form a centered, full-size composition rather than corners.
    let sparseBounds = CGRect(x: 20, y: 90, width: 2200, height: 1300)
    let separated: [AppStackLayout.Item] = [
        .init(id: 1, app: "Browser", source: CGRect(x: -4000, y: -2000, width: 400, height: 240)),
        .init(id: 2, app: "Editor", source: CGRect(x: 7000, y: 4500, width: 400, height: 240))
    ]
    let centeredSparse = try checkAppStackGeometry(separated, bounds: sparseBounds)
    let sparseCluster = appCluster(centeredSparse), sparseCenter = appPreviewCenter(centeredSparse)
    try expect(abs(sparseCenter.x - sparseBounds.midX) < sparseBounds.width * 0.035
               && abs(sparseCenter.y - sparseBounds.midY) < sparseBounds.height * 0.035,
               "Sparse app windows are the centered primary surface even when source positions span multiple monitors")
    try expect(sparseCluster.width < sparseBounds.width * 0.60 && sparseCluster.height < sparseBounds.height * 0.60,
               "Spacious sparse previews gather into a cluster instead of stretching to opposite screen edges")
    let centeredSparseWindows: [AppStackLayout.WindowPlacement] = centeredSparse.flatMap { $0.windows }
    try expect(centeredSparseWindows.allSatisfy { $0.frame.width == 400 && $0.frame.height == 240 },
               "Centering cannot make already-fitting native previews smaller")

    // Mirrors the uneven screenshot: six apps, one portrait browser, and
    // several large landscape windows whose source centers were on the right.
    let compositionBounds = CGRect(x: 28, y: 88, width: 1600, height: 850)
    let compositionSources: [CGRect] = [
        .init(x: 850, y: 10, width: 780, height: 620), .init(x: 950, y: 200, width: 960, height: 600),
        .init(x: 1100, y: 700, width: 800, height: 560), .init(x: 1200, y: 10, width: 1200, height: 850),
        .init(x: 1350, y: 650, width: 520, height: 860), .init(x: 30, y: 600, width: 1100, height: 720)
    ]
    let compositionItems: [AppStackLayout.Item] = compositionSources.indices.map { index in
        .init(id: UInt32(index + 1), app: "composition\(index)", source: compositionSources[index])
    }
    for compositionPanel in [CGRect(x: compositionBounds.minX, y: compositionBounds.minY, width: 252, height: 280),
                             CGRect(x: compositionBounds.maxX - 252, y: compositionBounds.minY, width: 252, height: 280)] {
        let composition = try checkAppStackGeometry(compositionItems, bounds: compositionBounds, panel: compositionPanel)
        let center = appPreviewCenter(composition), cluster = appCluster(composition)
        try expect(abs(center.x - compositionBounds.midX) < compositionBounds.width * 0.13
                   && abs(center.y - compositionBounds.midY) < compositionBounds.height * 0.13,
                   "Six mixed app groups stay visually balanced with history in either top corner")
        let left = cluster.minX - compositionBounds.minX, right = compositionBounds.maxX - cluster.maxX
        try expect(abs(left - right) < compositionBounds.width * 0.15,
                   "A corner log cannot leave a wide empty side while app previews crowd the other side")
        let composedWindows: [AppStackLayout.WindowPlacement] = composition.flatMap { $0.windows }
        try expect(composedWindows[0].frame.width / compositionSources[0].width > 0.42,
                   "The centered composition retains the larger Mission Control preview scale")
    }

    let singleComposition = try checkAppStackGeometry([separated[0]], bounds: sparseBounds)
    let singleCenter = appPreviewCenter(singleComposition)
    try expect(abs(singleCenter.x - sparseBounds.midX) < 1 && abs(singleCenter.y - sparseBounds.midY) < 8,
               "A lone window is centered as the focus of the overview, including its caption clearance")
    let nineComposition = try checkAppStackGeometry(many, bounds: roomy)
    let nineCenter = appPreviewCenter(nineComposition)
    try expect(abs(nineCenter.x - roomy.midX) < roomy.width * 0.04 && abs(nineCenter.y - roomy.midY) < roomy.height * 0.06,
               "A nine-window app stays centered without changing sibling scale or hiding any window")

    let crowdedComposition: [AppStackLayout.Item] = (0..<36).map { (index: Int) -> AppStackLayout.Item in
        let width: CGFloat = index % 2 == 0 ? 1100 : 600
        let source = CGRect(x: CGFloat(index * 40), y: CGFloat(index % 4) * 100, width: width, height: CGFloat(700))
        return .init(id: UInt32(index + 1), app: "crowded\(index / 3)", source: source)
    }
    let crowdedGroups = try checkAppStackGeometry(crowdedComposition, bounds: roomy)
    let crowdedCenter = appPreviewCenter(crowdedGroups)
    try expect(abs(crowdedCenter.x - roomy.midX) < roomy.width * 0.15 && abs(crowdedCenter.y - roomy.midY) < roomy.height * 0.15,
               "A crowded many-window desktop remains centered while every sibling and caption stays exposed")

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
