// Independent, read-only foreground sampling. No AX calls, application launch,
// activation, UI input, private Space API, browser command or recovery access.
// Compile with: swiftc scripts/sample-finish-trace.swift -o /tmp/intent-finish-sampler
// Run BEFORE Finish: /tmp/intent-finish-sampler 45 > TRACE.jsonl
import AppKit
import CoreGraphics

guard CommandLine.arguments.count <= 2,
      let duration = Double(CommandLine.arguments.dropFirst().first ?? "45"),
      duration.isFinite, duration >= 25, duration <= 600 else {
    fputs("Usage: intent-finish-sampler [SECONDS: 25...600]\n", stderr)
    exit(2)
}

let interval: TimeInterval = 0.05
let end = ProcessInfo.processInfo.systemUptime + duration
var spaceChangeCount = 0
let observer = NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
) { _ in spaceChangeCount += 1 }
defer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }

while ProcessInfo.processInfo.systemUptime < end {
    let sampledAt = Date().timeIntervalSince1970
    let sampledUptime = ProcessInfo.processInfo.systemUptime
    let query = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    let rows = query as? [[String: Any]]
    let windows = (rows ?? []).filter {
        ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0
    }
    let item: [String: Any] = [
        "at": sampledAt,
        "uptime": sampledUptime,
        "pid": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
        // This ordering is a separate onscreen-only query. Filtering an
        // all-window inventory would not establish foreground ordering.
        "frontWindowIDs": windows.compactMap { $0[kCGWindowNumber as String] as? UInt32 },
        "nativeWindowQuerySucceeded": rows != nil,
        "spaceChangeCount": spaceChangeCount,
        "requestedIntervalSeconds": interval,
        "observer": "public-native-readonly-v1",
        "exactSpaceIdentity": "unverified-public-api-unavailable",
        "exactBrowserTab": "unverified-no-independent-tab-sampler"
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: item) else {
        fputs("Could not encode foreground observation.\n", stderr)
        exit(1)
    }
    print(String(decoding: data, as: UTF8.self))
    fflush(stdout)
    // A slow WindowServer query is exposed as a gap, never silently filled
    // with duplicate samples. No action is dispatched to repair the desktop.
    let remaining = max(0, sampledUptime + interval - ProcessInfo.processInfo.systemUptime)
    RunLoop.main.run(until: Date().addingTimeInterval(remaining))
}
