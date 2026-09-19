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
}
