import Foundation
import IntentCore

func runBrowserCommandSpecs() throws {
    for action in [BrowserTabCommandAction.activate, .close, .preview] {
        let command = BrowserTabCommand(tabID: 7, windowID: 3, action: action, browserSessionID: "browser-session-a")
        let encoded = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(BrowserTabCommand.self, from: encoded)
        try expect(decoded == command && decoded.browserSessionID == "browser-session-a", "Tab commands retain the snapshot session identity through native-host JSON transport")
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "browserSessionID")
        let oldCommand = try JSONDecoder().decode(BrowserTabCommand.self, from: JSONSerialization.data(withJSONObject: legacy))
        try expect(oldCommand.browserSessionID == nil, "Legacy commands decode without inventing a valid session identity")
    }
    let snapshotRequest = BrowserTabCommand(tabID: -1, windowID: -1, action: .snapshot)
    try expect(snapshotRequest.browserSessionID == nil, "Discovery can request the current browser identity without already knowing it")
    let create = BrowserTabCommand(tabID: 7, windowID: 3, action: .create, browserSessionID: "profile-one",
        url: "https://example.org/", expiresAtUnixMS: 2_000_000_000_000)
    let decoded = try JSONDecoder().decode(BrowserTabCommand.self, from: JSONEncoder().encode(create))
    try expect(decoded == create, "Website creation preserves URL, expiry and exact existing-tab owner through the command bridge")
    var receipt: [String: Any] = ["requestID": create.id, "browserSessionID": "profile-one", "windowID": 3,
        "anchorTabID": 7, "url": "https://example.org/", "tab": ["id": 8, "windowID": 3, "index": 2,
        "title": "Example", "url": "https://example.org/", "active": false]]
    func matches() throws -> Bool {
        try JSONDecoder().decode(BrowserTabCreationReceipt.self, from: JSONSerialization.data(withJSONObject: receipt)).matches(create)
    }
    let initialMatch = try matches()
    try expect(initialMatch, "Creation receipt confirms one actual inactive tab in its chosen browser window")
    receipt["browserSessionID"] = "other-profile"
    let wrongProfile = try matches()
    try expect(!wrongProfile, "A created tab from another profile cannot enter the selection")
    receipt["browserSessionID"] = "profile-one"; receipt["windowID"] = 4
    let wrongWindow = try matches()
    try expect(!wrongWindow, "A created tab receipt cannot change the chosen browser window")
    receipt["windowID"] = 3; receipt["anchorTabID"] = 9
    let wrongAnchor = try matches()
    try expect(!wrongAnchor, "A created tab receipt remains anchored to its original existing tab")
    try expect(BrowserTabCreationReceipt.fileURL(requestID: "../outside") == nil, "Receipt names cannot escape Intent's data directory")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("intent-create-mailbox-spec-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let mailbox = BrowserTabCreationMailbox(browser: "com.google.Chrome", session: "profile-one", directory: directory)
    let next = BrowserTabCommand(tabID: 7, windowID: 3, action: .create, browserSessionID: "profile-one", url: "https://example.net/")
    try mailbox.write(create); try mailbox.write(next)
    var cancel = create; cancel.action = .cancelCreate
    try mailbox.write(cancel)
    try BrowserTabCommandStore(fileURL: directory.appendingPathComponent("browser-tab-command-com-google-Chrome.json"))
        .write(.init(tabID: -1, windowID: -1, action: .snapshot))
    try expect(mailbox.take() == cancel, "Cancellation replaces only its matching pending request and has priority")
    try expect(mailbox.take() == next, "A late old cancellation and an ordinary snapshot cannot overwrite the newer creation")
    try expect(mailbox.take() == nil, "Creation mailbox consumes each queued effect only once")
    try expect(!FileManager.default.fileExists(atPath: mailbox.fileURL.path), "An exhausted creation queue leaves the native host's ordinary idle path free of JSON reads and locks")
}
