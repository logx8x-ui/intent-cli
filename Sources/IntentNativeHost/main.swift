import Darwin
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

struct HostRuleState: Codable, Equatable {
    var active: Bool
    var allowedWebsites: [String]
    var startupWebsites: [String]
    var blockTabSwitching: Bool
    var blockNavigation: Bool
    var blockNewTabs: Bool
    var allowGoogleSearchTabs: Bool
    var guardEnabled: Bool
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

    init(state: HostRuleState, tabCommand: BrowserTabCommand?) {
        active = state.active
        allowedWebsites = state.allowedWebsites
        startupWebsites = state.startupWebsites
        blockTabSwitching = state.blockTabSwitching
        blockNavigation = state.blockNavigation
        blockNewTabs = state.blockNewTabs
        allowGoogleSearchTabs = state.allowGoogleSearchTabs
        guardEnabled = state.guardEnabled
        self.tabCommand = tabCommand
    }
}

struct HostMetrics: Codable {
    var receivedMessages = 0
    var sentMessages = 0
    var heartbeatWrites = 0
    var snapshotWrites = 0
    var rulesReads = 0
    var rulePushes = 0
    var commandPushes = 0
}

private struct FileSignature: Equatable {
    var size: UInt64
    var modifiedAt: Date
}

private struct HostPaths {
    let directory: URL

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let override = environment["INTENT_NATIVE_HOST_DIRECTORY"], !override.isEmpty {
            directory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            directory = FileManager.default
                .homeDirectoryForCurrentUser
                .appendingPathComponent(".intent", isDirectory: true)
        }
    }

    var rules: URL { directory.appendingPathComponent("browser-rules.json") }

    func heartbeat(for browserBundleIdentifier: String) -> URL {
        guard browserBundleIdentifier != "org.mozilla.firefox" else {
            return directory.appendingPathComponent("browser-guard-heartbeat.json")
        }
        return directory.appendingPathComponent(
            "browser-guard-heartbeat-\(safeComponent(browserBundleIdentifier)).json"
        )
    }

    func state(for browserBundleIdentifier: String) -> URL {
        guard browserBundleIdentifier != "org.mozilla.firefox" else {
            return directory.appendingPathComponent("browser-guard-state.json")
        }
        return directory.appendingPathComponent(
            "browser-guard-state-\(safeComponent(browserBundleIdentifier)).json"
        )
    }

    func snapshot(for browserBundleIdentifier: String) -> URL {
        directory.appendingPathComponent(
            "browser-tabs-\(safeComponent(browserBundleIdentifier)).json"
        )
    }

    func command(for browserBundleIdentifier: String) -> URL {
        directory.appendingPathComponent(
            "browser-tab-command-\(safeComponent(browserBundleIdentifier)).json"
        )
    }

    private func safeComponent(_ value: String) -> String {
        value.map { character in
            character.isLetter || character.isNumber ? character : "-"
        }.reduce(into: "") { $0.append($1) }
    }
}

private final class HostRuntime {
    private static let heartbeatWriteInterval: TimeInterval = 1.5
    private static let directoryDebounceInterval: TimeInterval = 0.025

    private let queue = DispatchQueue(
        label: "dev.loganmondi.intent.native-host",
        qos: .utility
    )
    private let paths = HostPaths()
    private let metricsURL: URL?

    private var browserBundleIdentifier: String?
    private var guardEnabled = true
    private var cachedRules: ActiveBrowserRules?
    private var rulesSignature: FileSignature?
    private var hasLoadedRules = false
    private var lastPushedState: HostRuleState?
    private var lastHeartbeatWriteAt: Date?
    private var lastSnapshotTabs: [BrowserTabItem]?
    private var directorySource: DispatchSourceFileSystemObject?
    private var directoryDescriptor: Int32 = -1
    private var directoryRefreshWorkItem: DispatchWorkItem?
    private var rulesExpirationWorkItem: DispatchWorkItem?
    private var metrics = HostMetrics()

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let path = environment["INTENT_NATIVE_HOST_METRICS_FILE"], !path.isEmpty {
            metricsURL = URL(fileURLWithPath: path)
        } else {
            metricsURL = nil
        }
    }

    func handle(_ requestData: Data) {
        guard let request = try? JSONDecoder().decode(HostRequest.self, from: requestData) else {
            return
        }

        queue.sync {
            metrics.receivedMessages += 1
            let browser = request.browserBundleIdentifier ?? browserBundleIdentifier ?? "org.mozilla.firefox"
            registerBrowserIfNeeded(browser)
            maybeWriteHeartbeat()

            switch request.type ?? "getRules" {
            case "setGuardEnabled":
                if let enabled = request.enabled, enabled != guardEnabled {
                    guardEnabled = enabled
                    try? BrowserGuardStateStore(fileURL: paths.state(for: browser)).write(enabled: enabled)
                }
            case "tabsSnapshot":
                if let tabs = request.tabs {
                    persistSnapshot(tabs, browserBundleIdentifier: browser)
                }
            case "recordWebsiteVisit":
                if let url = request.url {
                    try? PurposeWebsiteHistoryStore(browserBundleIdentifier: browser).record(
                        urlString: url,
                        title: request.title ?? ""
                    )
                }
            default:
                break
            }

            _ = refreshRulesIfNeeded()
            let tabCommand = takePendingCommand()
            let expectsResponse = request.type == nil
                || request.type == "getRules"
                || request.type == "setGuardEnabled"

            if expectsResponse || tabCommand != nil {
                sendCurrentState(tabCommand: tabCommand, force: true)
            }
        }
    }

    func flushMetrics() {
        guard let metricsURL else { return }
        queue.sync {
            try? FileManager.default.createDirectory(
                at: metricsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let data = try? JSONEncoder().encode(metrics) {
                try? data.write(to: metricsURL, options: .atomic)
            }
        }
    }

    private func registerBrowserIfNeeded(_ browser: String) {
        guard browserBundleIdentifier == nil else { return }
        browserBundleIdentifier = browser
        try? FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true)
        guardEnabled = BrowserGuardStateStore(fileURL: paths.state(for: browser)).isEnabled()
        _ = refreshRulesIfNeeded(force: true)
        startDirectoryWatcher()
        maybeWriteHeartbeat(force: true)
    }

    private func maybeWriteHeartbeat(force: Bool = false) {
        guard let browserBundleIdentifier else { return }
        let now = Date()
        if !force,
           let lastHeartbeatWriteAt,
           now.timeIntervalSince(lastHeartbeatWriteAt) < Self.heartbeatWriteInterval {
            return
        }
        let store = BrowserGuardHeartbeatStore(
            fileURL: paths.heartbeat(for: browserBundleIdentifier)
        )
        if (try? store.write(date: now)) != nil {
            metrics.heartbeatWrites += 1
            lastHeartbeatWriteAt = now
        }
    }

    private func persistSnapshot(_ tabs: [HostTab], browserBundleIdentifier: String) {
        let items = tabs.map {
            BrowserTabItem(
                id: $0.id,
                windowID: $0.windowID,
                index: $0.index,
                title: $0.title,
                url: $0.url,
                active: $0.active
            )
        }
        guard items != lastSnapshotTabs else { return }
        let snapshot = BrowserTabSnapshot(
            browserBundleIdentifier: browserBundleIdentifier,
            tabs: items
        )
        let store = BrowserTabSnapshotStore(fileURL: paths.snapshot(for: browserBundleIdentifier))
        if (try? store.write(snapshot)) != nil {
            metrics.snapshotWrites += 1
            lastSnapshotTabs = items
        }
    }

    private func currentFileSignature(for fileURL: URL) -> FileSignature? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber,
              let modifiedAt = attributes[.modificationDate] as? Date else {
            return nil
        }
        return FileSignature(size: size.uint64Value, modifiedAt: modifiedAt)
    }

    @discardableResult
    private func refreshRulesIfNeeded(force: Bool = false) -> Bool {
        let nextSignature = currentFileSignature(for: paths.rules)
        if !force, hasLoadedRules, nextSignature == rulesSignature {
            return false
        }

        hasLoadedRules = true
        rulesSignature = nextSignature
        metrics.rulesReads += 1
        if let data = try? Data(contentsOf: paths.rules),
           let rules = try? JSONDecoder().decode(ActiveBrowserRules.self, from: data) {
            cachedRules = rules
        } else {
            cachedRules = nil
        }
        scheduleRulesExpiration()
        return true
    }

    private func scheduleRulesExpiration() {
        rulesExpirationWorkItem?.cancel()
        rulesExpirationWorkItem = nil
        guard let rules = cachedRules, rules.active else { return }

        let expectedUpdatedAt = rules.updatedAt
        let delay = max(
            0,
            rules.updatedAt
                .addingTimeInterval(ActiveBrowserRules.freshnessWindow)
                .timeIntervalSinceNow
        )
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.cachedRules?.updatedAt == expectedUpdatedAt else {
                return
            }
            self.sendCurrentState(tabCommand: self.takePendingCommand(), force: false)
        }
        rulesExpirationWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func makeRuleState() -> HostRuleState {
        guard let browserBundleIdentifier,
              let rules = cachedRules,
              !rules.active || rules.isFresh() else {
            return HostRuleState(
                active: false,
                allowedWebsites: [],
                startupWebsites: [],
                blockTabSwitching: false,
                blockNavigation: false,
                blockNewTabs: false,
                allowGoogleSearchTabs: false,
                guardEnabled: guardEnabled
            )
        }

        let browserWebsites = rules.allowedWebsitesByBrowser[browserBundleIdentifier]
            ?? (browserBundleIdentifier == "org.mozilla.firefox" ? rules.allowedWebsites : [])
        return HostRuleState(
            active: rules.active,
            allowedWebsites: browserWebsites,
            startupWebsites: rules.startupWebsitesByBrowser[browserBundleIdentifier] ?? [],
            blockTabSwitching: rules.blockTabSwitching,
            blockNavigation: rules.blockNavigation,
            blockNewTabs: rules.blockNewTabs,
            allowGoogleSearchTabs: rules.allowGoogleSearchTabs,
            guardEnabled: guardEnabled
        )
    }

    private func takePendingCommand() -> BrowserTabCommand? {
        guard let browserBundleIdentifier else { return nil }
        return BrowserTabCommandStore(
            fileURL: paths.command(for: browserBundleIdentifier)
        ).take()
    }

    private func sendCurrentState(tabCommand: BrowserTabCommand?, force: Bool) {
        let state = makeRuleState()
        guard force || tabCommand != nil || state != lastPushedState else { return }
        if (try? writeMessage(HostResponse(state: state, tabCommand: tabCommand))) != nil {
            metrics.sentMessages += 1
            if tabCommand != nil {
                metrics.commandPushes += 1
            } else if !force {
                metrics.rulePushes += 1
            }
            lastPushedState = state
        }
    }

    private func startDirectoryWatcher() {
        guard directorySource == nil else { return }
        directoryDescriptor = open(paths.directory.path, O_EVTONLY)
        guard directoryDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.scheduleDirectoryRefresh()
        }
        source.setCancelHandler { [descriptor = directoryDescriptor] in
            close(descriptor)
        }
        source.resume()
        directorySource = source
    }

    private func scheduleDirectoryRefresh() {
        directoryRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let rulesChanged = self.refreshRulesIfNeeded()
            let tabCommand = self.takePendingCommand()
            if rulesChanged || tabCommand != nil {
                self.sendCurrentState(tabCommand: tabCommand, force: false)
            }
        }
        directoryRefreshWorkItem = workItem
        queue.asyncAfter(
            deadline: .now() + Self.directoryDebounceInterval,
            execute: workItem
        )
    }
}

private let runtime = HostRuntime()
while true {
    let shouldContinue = autoreleasepool { () -> Bool in
        guard let requestData = readMessage() else { return false }
        runtime.handle(requestData)
        return true
    }
    if !shouldContinue { break }
}
runtime.flushMetrics()
