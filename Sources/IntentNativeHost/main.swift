import Foundation
import IntentCore

func readMessage() -> Data? {
    var lengthBytes = [UInt8](repeating: 0, count: 4)
    let lengthRead = FileHandle.standardInput.readData(ofLength: 4)
    guard lengthRead.count == 4 else { return nil }
    lengthRead.copyBytes(to: &lengthBytes, count: 4)

    let length = UInt32(lengthBytes[0])
        | UInt32(lengthBytes[1]) << 8
        | UInt32(lengthBytes[2]) << 16
        | UInt32(lengthBytes[3]) << 24

    return FileHandle.standardInput.readData(ofLength: Int(length))
}

func writeMessage<T: Encodable>(_ value: T) throws {
    let data = try JSONEncoder().encode(value)
    var length = UInt32(data.count).littleEndian
    let header = Data(bytes: &length, count: 4)
    FileHandle.standardOutput.write(header)
    FileHandle.standardOutput.write(data)
}

struct HostRequest: Codable {
    var type: String?
    var enabled: Bool?
    var browserBundleIdentifier: String?
}

struct HostResponse: Codable {
    var active: Bool
    var allowedWebsites: [String]
    var blockTabSwitching: Bool
    var blockNavigation: Bool
    var blockNewTabs: Bool
    var allowGoogleSearchTabs: Bool
    var guardEnabled: Bool
}

while let requestData = readMessage() {
    let request = try? JSONDecoder().decode(HostRequest.self, from: requestData)
    let browserBundleIdentifier = request?.browserBundleIdentifier ?? "org.mozilla.firefox"
    let heartbeatStore = BrowserGuardHeartbeatStore(
        fileURL: BrowserGuardHeartbeatStore.fileURL(for: browserBundleIdentifier)
    )
    let stateStore = BrowserGuardStateStore(
        fileURL: BrowserGuardStateStore.fileURL(for: browserBundleIdentifier)
    )
    try? heartbeatStore.write()

    if request?.type == "setGuardEnabled", let enabled = request?.enabled {
        try? stateStore.write(enabled: enabled)
    }

    let fileURL = ActiveBrowserRulesStore.defaultFileURL()
    let response: HostResponse
    let guardEnabled = stateStore.isEnabled()

    if let data = try? Data(contentsOf: fileURL),
       let rules = try? JSONDecoder().decode(ActiveBrowserRules.self, from: data),
       !rules.active || rules.isFresh() {
        let browserWebsites = rules.allowedWebsitesByBrowser[browserBundleIdentifier]
            ?? (browserBundleIdentifier == "org.mozilla.firefox" ? rules.allowedWebsites : [])
        response = HostResponse(
            active: rules.active,
            allowedWebsites: browserWebsites,
            blockTabSwitching: rules.blockTabSwitching,
            blockNavigation: rules.blockNavigation,
            blockNewTabs: rules.blockNewTabs,
            allowGoogleSearchTabs: rules.allowGoogleSearchTabs,
            guardEnabled: guardEnabled
        )
    } else {
        response = HostResponse(
            active: false,
            allowedWebsites: [],
            blockTabSwitching: false,
            blockNavigation: false,
            blockNewTabs: false,
            allowGoogleSearchTabs: false,
            guardEnabled: guardEnabled
        )
    }

    try writeMessage(response)
}
