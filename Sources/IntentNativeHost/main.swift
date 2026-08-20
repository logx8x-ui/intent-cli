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

let outputLock = NSLock()

func writeMessage<T: Encodable>(_ value: T) throws {
    let data = try JSONEncoder().encode(value)
    var length = UInt32(data.count).littleEndian
    let header = Data(bytes: &length, count: 4)
    outputLock.lock()
    defer { outputLock.unlock() }
    FileHandle.standardOutput.write(header)
    FileHandle.standardOutput.write(data)
}

struct HostTab: Codable {
    var id: Int
    var windowID: Int
    var index: Int
    var title: String
    var url: String
    var active: Bool
}

struct HostRequest: Codable {
    var type: String?
    var enabled: Bool?
    var browserBundleIdentifier: String?
    var tabs: [HostTab]?
    var url: String?
    var title: String?
}

struct HostResponse: Codable {
    var active: Bool
    var allowedWebsites: [String]
    var startupWebsites: [String]
    var blockTabSwitching: Bool
    var blockNavigation: Bool
    var blockNewTabs: Bool
    var allowGoogleSearchTabs: Bool
    var guardEnabled: Bool
    var tabCommand: BrowserTabCommand?
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

    if request?.type == "tabsSnapshot", let tabs = request?.tabs {
        let snapshot = BrowserTabSnapshot(
            browserBundleIdentifier: browserBundleIdentifier,
            tabs: tabs.map {
                BrowserTabItem(
                    id: $0.id,
                    windowID: $0.windowID,
                    index: $0.index,
                    title: $0.title,
                    url: $0.url,
                    active: $0.active
                )
            }
        )
        try? BrowserTabSnapshotStore(browserBundleIdentifier: browserBundleIdentifier).write(snapshot)
    }

    if request?.type == "recordWebsiteVisit", let url = request?.url {
        try? PurposeWebsiteHistoryStore(browserBundleIdentifier: browserBundleIdentifier).record(
            urlString: url,
            title: request?.title ?? ""
        )
    }

    let fileURL = ActiveBrowserRulesStore.defaultFileURL()
    let response: HostResponse
    let guardEnabled = stateStore.isEnabled()
    let tabCommand = BrowserTabCommandStore(
        browserBundleIdentifier: browserBundleIdentifier
    ).take()

    if let data = try? Data(contentsOf: fileURL),
       let rules = try? JSONDecoder().decode(ActiveBrowserRules.self, from: data),
       !rules.active || rules.isFresh() {
        let browserWebsites = rules.allowedWebsitesByBrowser[browserBundleIdentifier]
            ?? (browserBundleIdentifier == "org.mozilla.firefox" ? rules.allowedWebsites : [])
        let startupWebsites = rules.startupWebsitesByBrowser[browserBundleIdentifier] ?? []
        response = HostResponse(
            active: rules.active,
            allowedWebsites: browserWebsites,
            startupWebsites: startupWebsites,
            blockTabSwitching: rules.blockTabSwitching,
            blockNavigation: rules.blockNavigation,
            blockNewTabs: rules.blockNewTabs,
            allowGoogleSearchTabs: rules.allowGoogleSearchTabs,
            guardEnabled: guardEnabled,
            tabCommand: tabCommand
        )
    } else {
        response = HostResponse(
            active: false,
            allowedWebsites: [],
            startupWebsites: [],
            blockTabSwitching: false,
            blockNavigation: false,
            blockNewTabs: false,
            allowGoogleSearchTabs: false,
            guardEnabled: guardEnabled,
            tabCommand: tabCommand
        )
    }

    try writeMessage(response)
}
