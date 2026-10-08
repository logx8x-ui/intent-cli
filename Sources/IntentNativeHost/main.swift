import AppKit
import Darwin
import Foundation
import IntentCore

let nativeHostEnvironment = ProcessInfo.processInfo.environment
if let override = nativeHostEnvironment["INTENT_NATIVE_HOST_DIRECTORY"], !override.isEmpty {
    try? IntentLocalDataSecurity.harden(directory: URL(fileURLWithPath: override, isDirectory: true))
} else {
    try? IntentLocalDataSecurity.hardenDefaultDirectory()
}

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
    var highlighted: Bool?
    var pinned: Bool?
    var discarded: Bool?
    var groupID: Int?
    var windowFrame: BrowserWindowFrame?
    var windowFocused: Bool?
    var searchSessionID: String?
    var cookieStoreID: String?
    var faviconURL: String?
    var id: Int
    var windowID: Int
    var index: Int
    var title: String
    var url: String
    var active: Bool
}

struct HostRequest: Codable {
    var appliedWebsitePolicySessionID: String?
    var browserSessionID: String?
    var browserProfileID: String?
    var preview: BrowserTabPreview?
    var creation: BrowserTabCreationReceipt?
    var finder: BrowserFinderReceipt?
    var type: String?
    var enabled: Bool?
    var browserBundleIdentifier: String?
    var extensionVersion: String?
    var extensionCapabilities: [String]?
    var visibilityPlan: BrowserWindowVisibilityPlan?
    var visibilityRestartRequest: HostVisibilityRestartRequest?
    var visibilityRecoveryRequest: HostVisibilityRecoveryRequest?
    var visibilityClosedRequest: HostVisibilityClosedRequest?
    var minimizeBootstrapClaim: HostMinimizeBootstrapClaim?
    var minimizeBootstrapResult: HostMinimizeBootstrapResult?
    var tabs: [HostTab]?
    var allTabs: [HostTab]?
    var snapshotRequestIDs: [String]?
    var completeWindowInventory: Bool?
    var url: String?
    var title: String?
}

private struct VisibilityPlanEnvelope: Decodable {
    struct Plan: Decodable { var revision: Int }
    var type: String
    var visibilityPlan: Plan
}

struct HostVisibilityPlanReceipt: Codable {
    var revision: Int
    var accepted: Bool
}

struct HostVisibilityRestartRequest: Codable {
    var requestID: String
    var intentionSessionID: String
    var previousBrowserSessionID: String
    var previousProcessIdentity: BrowserProcessIdentity
}

private struct VisibilityRestartEnvelope: Decodable {
    struct Request: Decodable { var requestID: String }
    var type: String
    var visibilityRestartRequest: Request
}

struct HostVisibilityRestartReceipt: Codable {
    var requestID: String
    var accepted: Bool
}

struct HostVisibilityRecoveryRequest: Codable {
    var requestID: String
    var intentionSessionID: String
    var previousBrowserSessionID: String
    var previousProcessIdentity: BrowserProcessIdentity
    var windowIDs: [Int]
}

private struct VisibilityRecoveryEnvelope: Decodable {
    struct Request: Decodable { var requestID: String }
    var type: String
    var visibilityRecoveryRequest: Request
}

struct HostVisibilityRecoveryReceipt: Codable {
    var requestID: String
    var accepted: Bool
}

struct HostVisibilityClosedRequest: Codable {
    var requestID: String
    var intentionSessionID: String
    var previousBrowserSessionID: String
    var previousProcessIdentity: BrowserProcessIdentity
    var windowIDs: [Int]
}

private struct VisibilityClosedEnvelope: Decodable {
    struct Request: Decodable { var requestID: String }
    var type: String
    var visibilityClosedRequest: Request
}

struct HostVisibilityClosedReceipt: Codable {
    var requestID: String
    var accepted: Bool
}

struct HostMinimizeBootstrapClaim: Codable {
    var effectID: String
    var intentionSessionID: String
    var previousBrowserSessionID: String
    var previousProcessIdentity: BrowserProcessIdentity
}
struct HostMinimizeBootstrapResult: Codable {
    var effectID: String
    var intentionSessionID: String
    var previousBrowserSessionID: String
    var previousProcessIdentity: BrowserProcessIdentity
    var outcome: BrowserWindowMinimizeBootstrap.Outcome
}
private struct MinimizeBootstrapEnvelope: Decodable {
    struct Effect: Decodable { var effectID: String }
    var type: String
    var minimizeBootstrapClaim: Effect?
    var minimizeBootstrapResult: Effect?
}
struct HostMinimizeBootstrapClaimReceipt: Codable { var effectID: String; var granted: Bool }
struct HostMinimizeBootstrapResultReceipt: Codable { var effectID: String; var accepted: Bool }
struct HostMinimizeBootstrapOffer: Codable, Equatable {
    var effectID: String
    var intentionSessionID: String
    var browserSessionID: String
    var browserProcessIdentity: BrowserProcessIdentity
    var windowID: Int
    var planRevision: Int
    var expiresAtUnixMS: Double
    var descriptor: BrowserWindowVisibilityWindow
}

struct HostRuleState: Codable, Equatable {
    var addAsYouGo: Bool = false
    var websiteFeaturePolicies: [String: WebsiteFeaturePolicy] = [:]
    var hideDistractions: Bool = false
    var nativeWindowVisibility: Bool = false
    var selectedBrowserSessionID: String? = nil
    var selectedTabIDs: [Int]? = nil
    var active: Bool
    var accessMode: String
    var allowedWebsites: [String]
    var startupWebsites: [String]
    var startupSessionID: String?
    var blockTabSwitching: Bool
    var blockNavigation: Bool
    var blockNewTabs: Bool
    var allowGoogleSearchTabs: Bool
    var guardEnabled: Bool
}

struct HostResponse: Codable {
    var websiteFeaturePolicies: [String: WebsiteFeaturePolicy]
    var addAsYouGo: Bool
    var hideDistractions: Bool
    var nativeWindowVisibility: Bool = false
    var bundledExtensionVersion: String = "0.2.39"
    var hostCapabilities: [String] = ["quick-selection-host-v1", "tab-preview-host-v1", "native-tab-groups-host-v1", "tab-session-identity-host-v1", "native-window-visibility-host-v1", "firefox-window-minimize-bootstrap-host-v1", "background-tab-create-host-v1", "native-website-finder-host-v1", "native-website-finder-observe-host-v1"]
    var selectedTabIDs: [Int]?
    var selectedBrowserSessionID: String?
    var active: Bool
    var accessMode: String
    var allowedWebsites: [String]
    var startupWebsites: [String]
    var startupSessionID: String?
    var blockTabSwitching: Bool
    var blockNavigation: Bool
    var blockNewTabs: Bool
    var allowGoogleSearchTabs: Bool
    var guardEnabled: Bool
    var tabCommand: BrowserTabCommand?
    var visibilityPlanReceipt: HostVisibilityPlanReceipt?
    var browserProcessIdentity: BrowserProcessIdentity?
    var visibilityRestartReceipt: HostVisibilityRestartReceipt?
    var visibilityRecoveryReceipt: HostVisibilityRecoveryReceipt?
    var visibilityClosedReceipt: HostVisibilityClosedReceipt?
    var minimizeBootstrapOffers: [HostMinimizeBootstrapOffer] = []
    var minimizeBootstrapClaimReceipt: HostMinimizeBootstrapClaimReceipt?
    var minimizeBootstrapResultReceipt: HostMinimizeBootstrapResultReceipt?
    var visibilityEnforcement: BrowserWindowVisibilityEnforcement?
    var tabCreationAllowed = false
    var finderCommand: BrowserFinderCommand?

    init(state: HostRuleState, tabCommand: BrowserTabCommand?, visibilityPlanReceipt: HostVisibilityPlanReceipt? = nil,
         browserProcessIdentity: BrowserProcessIdentity? = nil, visibilityRestartReceipt: HostVisibilityRestartReceipt? = nil,
         visibilityRecoveryReceipt: HostVisibilityRecoveryReceipt? = nil,
         visibilityClosedReceipt: HostVisibilityClosedReceipt? = nil) {
        addAsYouGo = state.addAsYouGo
        websiteFeaturePolicies = state.websiteFeaturePolicies
        hideDistractions = state.hideDistractions
        nativeWindowVisibility = state.nativeWindowVisibility
        selectedBrowserSessionID = state.selectedBrowserSessionID
        selectedTabIDs = state.selectedTabIDs
        active = state.active
        accessMode = state.accessMode
        allowedWebsites = state.allowedWebsites
        startupWebsites = state.startupWebsites
        startupSessionID = state.startupSessionID
        blockTabSwitching = state.blockTabSwitching
        blockNavigation = state.blockNavigation
        blockNewTabs = state.blockNewTabs
        allowGoogleSearchTabs = state.allowGoogleSearchTabs
        guardEnabled = state.guardEnabled
        self.tabCommand = tabCommand
        self.visibilityPlanReceipt = visibilityPlanReceipt
        self.browserProcessIdentity = browserProcessIdentity
        self.visibilityRestartReceipt = visibilityRestartReceipt
        self.visibilityRecoveryReceipt = visibilityRecoveryReceipt
        self.visibilityClosedReceipt = visibilityClosedReceipt
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
    private var profileSessionID: String?
    private var browserProfileID: String?
    private var extensionVersion: String?
    private var extensionCapabilities: [String] = []
    private var guardEnabled = true
    private var cachedRules: ActiveBrowserRules?
    private var rulesSignature: FileSignature?
    private var hasLoadedRules = false
    private var lastPushedState: HostRuleState?
    private var lastPushedOffers: [HostMinimizeBootstrapOffer] = []
    private var lastPushedEnforcement: BrowserWindowVisibilityEnforcement?
    private var lastHeartbeatWriteAt: Date?
    private var lastMessageReceivedAt: Date?
    private var lastSnapshotTabs: [BrowserTabItem]?
    private var requestedSnapshotRefresh = false
    private var issuedSnapshotRequests: [String: Date] = [:]
    private var issuedTabCreations: [String: BrowserTabCommand] = [:]
    private var issuedFinderCommands: [String: BrowserFinderCommand] = [:]
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
            // Preserve the request revision even when a malformed descriptor
            // cannot decode, so the extension can abandon the dependent move.
            if let envelope = try? JSONDecoder().decode(VisibilityPlanEnvelope.self, from: requestData),
               envelope.type == "windowVisibilityPlan" {
                queue.sync {
                    metrics.receivedMessages += 1
                    refreshRulesIfNeeded()
                    sendCurrentState(tabCommand: takePendingCommand(), force: true,
                        visibilityPlanReceipt: .init(revision: envelope.visibilityPlan.revision, accepted: false))
                }
            } else if let envelope = try? JSONDecoder().decode(VisibilityRestartEnvelope.self, from: requestData),
                      envelope.type == "windowVisibilityRestartRecovery" {
                queue.sync {
                    metrics.receivedMessages += 1
                    refreshRulesIfNeeded()
                    sendCurrentState(tabCommand: takePendingCommand(), force: true,
                        visibilityRestartReceipt: .init(requestID: envelope.visibilityRestartRequest.requestID, accepted: false))
                }
            } else if let envelope = try? JSONDecoder().decode(VisibilityRecoveryEnvelope.self, from: requestData),
                      envelope.type == "windowVisibilityRecovery" {
                queue.sync {
                    metrics.receivedMessages += 1
                    refreshRulesIfNeeded()
                    sendCurrentState(tabCommand: takePendingCommand(), force: true,
                        visibilityRecoveryReceipt: .init(requestID: envelope.visibilityRecoveryRequest.requestID, accepted: false))
                }
            } else if let envelope = try? JSONDecoder().decode(VisibilityClosedEnvelope.self, from: requestData),
                      envelope.type == "windowVisibilityClosed" {
                queue.sync {
                    metrics.receivedMessages += 1
                    refreshRulesIfNeeded()
                    sendCurrentState(tabCommand: takePendingCommand(), force: true,
                        visibilityClosedReceipt: .init(requestID: envelope.visibilityClosedRequest.requestID, accepted: false))
                }
            } else if let envelope = try? JSONDecoder().decode(MinimizeBootstrapEnvelope.self, from: requestData) {
                queue.sync {
                    refreshRulesIfNeeded()
                    if envelope.type == "windowMinimizeBootstrapClaim", let effect = envelope.minimizeBootstrapClaim {
                        sendCurrentState(tabCommand: takePendingCommand(), force: true,
                            minimizeBootstrapClaimReceipt: .init(effectID: effect.effectID, granted: false))
                    } else if envelope.type == "windowMinimizeBootstrapResult", let effect = envelope.minimizeBootstrapResult {
                        sendCurrentState(tabCommand: takePendingCommand(), force: true,
                            minimizeBootstrapResultReceipt: .init(effectID: effect.effectID, accepted: false))
                    }
                }
            }
            return
        }

        queue.sync {
            metrics.receivedMessages += 1
            let browser = request.browserBundleIdentifier ?? browserBundleIdentifier ?? "org.mozilla.firefox"
            var capabilitiesChanged = false
            // A visibility plan cannot register or change the identity/capabilities
            // it is about to be checked against. They belong to this connection.
            if request.type != "windowVisibilityPlan" && request.type != "windowVisibilityRestartRecovery"
                && request.type != "windowVisibilityRecovery" && request.type != "windowVisibilityClosed"
                && request.type != "windowMinimizeBootstrapClaim" && request.type != "windowMinimizeBootstrapResult" {
                if (browser == browserBundleIdentifier || browserBundleIdentifier == nil),
                   (request.browserSessionID == nil || profileSessionID == nil || request.browserSessionID == profileSessionID) {
                    if let session = request.browserSessionID, !session.isEmpty, profileSessionID == nil {
                        profileSessionID = session
                    }
                    if let profile = request.browserProfileID, UUID(uuidString: profile) != nil,
                       browserProfileID == nil || browserProfileID == profile {
                        browserProfileID = profile
                    }
                    if let version = request.extensionVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !version.isEmpty {
                        extensionVersion = version
                    }
                    if let capabilities = request.extensionCapabilities {
                        let updated = Array(Set(capabilities)).sorted()
                        capabilitiesChanged = updated != extensionCapabilities
                        extensionCapabilities = updated
                    }
                }
                registerBrowserIfNeeded(browser)
            }
            // Stop and replacement rules must be visible before accepting a plan,
            // including messages that beat the directory watcher's debounce.
            let rulesChanged = refreshRulesIfNeeded()
            let now = Date()
            let isMessageBurst = lastMessageReceivedAt.map {
                now.timeIntervalSince($0) < 0.1
            } ?? false
            lastMessageReceivedAt = now
            if capabilitiesChanged || !isMessageBurst {
                maybeWriteHeartbeat(force: capabilitiesChanged)
            }

            var visibilityPlanReceipt: HostVisibilityPlanReceipt?
            var visibilityRestartReceipt: HostVisibilityRestartReceipt?
            var visibilityRecoveryReceipt: HostVisibilityRecoveryReceipt?
            var visibilityClosedReceipt: HostVisibilityClosedReceipt?
            var minimizeBootstrapClaimReceipt: HostMinimizeBootstrapClaimReceipt?
            var minimizeBootstrapResultReceipt: HostMinimizeBootstrapResultReceipt?
            switch request.type ?? "getRules" {
            case "windowMinimizeBootstrapClaim":
                minimizeBootstrapClaimReceipt = .init(effectID: request.minimizeBootstrapClaim?.effectID ?? "",
                    granted: requestData.count <= 16_384 && claimMinimizeBootstrap(request))
            case "windowMinimizeBootstrapResult":
                minimizeBootstrapResultReceipt = .init(effectID: request.minimizeBootstrapResult?.effectID ?? "",
                    accepted: requestData.count <= 16_384 && receiveMinimizeBootstrapResult(request))
            case "windowVisibilityClosed":
                visibilityClosedReceipt = .init(requestID: request.visibilityClosedRequest?.requestID ?? "",
                    accepted: requestData.count <= 16_384 && confirmNativeParkingClosed(request))
            case "windowVisibilityRecovery":
                visibilityRecoveryReceipt = .init(requestID: request.visibilityRecoveryRequest?.requestID ?? "",
                    accepted: requestData.count <= 16_384 && requestNativeWindowVisibilityRecovery(request))
            case "windowVisibilityRestartRecovery":
                visibilityRestartReceipt = .init(requestID: request.visibilityRestartRequest?.requestID ?? "",
                    accepted: requestData.count <= 16_384 && permitsWindowVisibilityRestartRecovery(request))
            case "windowVisibilityPlan":
                let accepted = requestData.count <= 1_000_000 && persistWindowVisibilityPlan(request)
                if accepted, let plan = request.visibilityPlan, !hasNativeParkingCapture(plan),
                   isCurrentNativeVisibilitySession(plan.intentionSessionID) {
                    // Moving tabs can change the holding window's title. Delay
                    // permission until the app has persisted its exact native
                    // identity, without blocking stdin or the runtime queue.
                    awaitNativeParkingCapture(plan, deadline: .now() + 1.5)
                } else {
                    visibilityPlanReceipt = .init(revision: request.visibilityPlan?.revision ?? 0,
                        accepted: accepted && request.visibilityPlan.map(hasNativeParkingCapture) == true)
                }
            case "websitePolicyReady":
                if let session = request.appliedWebsitePolicySessionID,
                   let browserSession = request.browserSessionID, !browserSession.isEmpty,
                   let data = try? JSONEncoder().encode(WebsitePolicyAcknowledgement(startupSessionID: session, browserSessionID: browserSession)) {
                    let base = WebsitePolicyAcknowledgement.fileURL(browser: browser, directory: paths.directory)
                    try? data.write(to: base, options: .atomic)
                    try? data.write(to: BrowserProfileSnapshots.partition(base, session: browserSession), options: .atomic)
                }
            case "tabPreview":
                if let preview = request.preview,
                   let data = try? JSONEncoder().encode(preview), data.count < 8_000_000 {
                    let url = paths.directory.appendingPathComponent(BrowserTabPreview.fileURL(browser: browser).lastPathComponent)
                    try? data.write(to: url, options: .atomic)
                    queue.asyncAfter(deadline: .now() + 10) {
                        if let current = try? Data(contentsOf: url),
                           let item = try? JSONDecoder().decode(BrowserTabPreview.self, from: current),
                           item.requestID == preview.requestID { try? FileManager.default.removeItem(at: url) }
                    }
                }
            case "nativeFinderResult":
                if let receipt = request.finder, request.browserSessionID == profileSessionID,
                   let issued = issuedFinderCommands[receipt.requestID], receipt.matches(issued),
                   let url = BrowserFinderReceipt.fileURL(requestID: receipt.requestID, directory: paths.directory),
                   let data = try? JSONEncoder().encode(receipt), data.count <= 20000 {
                    try? data.write(to: url, options: .atomic)
                    issuedFinderCommands.removeValue(forKey: receipt.requestID)
                    queue.asyncAfter(deadline: .now() + 30) { try? FileManager.default.removeItem(at: url) }
                }
            case "tabCreateResult":
                if let receipt = request.creation, request.browserSessionID == profileSessionID,
                   let issued = issuedTabCreations[receipt.requestID], receipt.matches(issued),
                   let url = BrowserTabCreationReceipt.fileURL(requestID: receipt.requestID, directory: paths.directory),
                   let data = try? JSONEncoder().encode(receipt), data.count <= 20000 {
                    try? data.write(to: url, options: .atomic)
                    issuedTabCreations.removeValue(forKey: receipt.requestID)
                    queue.asyncAfter(deadline: .now() + 30) { try? FileManager.default.removeItem(at: url) }
                }
            case "setGuardEnabled":
                if let enabled = request.enabled, enabled != guardEnabled {
                    guardEnabled = enabled
                    try? BrowserGuardStateStore(fileURL: paths.state(for: browser)).write(enabled: enabled)
                }
            case "tabsSnapshot":
                if let tabs = request.tabs {
                    persistSnapshot(tabs, allTabs: request.allTabs, browserSessionID: request.browserSessionID, browserBundleIdentifier: browser, snapshotRequestIDs: request.snapshotRequestIDs, completeWindowInventory: request.completeWindowInventory)
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

            let tabCommand = takePendingCommand()
            let expectsResponse = request.type == nil
                || request.type == "getRules"
                || request.type == "setGuardEnabled"

            // A heartbeat or snapshot can observe a rules change before the
            // directory watcher. Publish it here; the watcher now sees its cached signature.
            let hasReceipt = visibilityPlanReceipt != nil || visibilityRestartReceipt != nil
                || visibilityRecoveryReceipt != nil || visibilityClosedReceipt != nil
                || minimizeBootstrapClaimReceipt != nil || minimizeBootstrapResultReceipt != nil
            if expectsResponse || rulesChanged || tabCommand != nil || hasReceipt || request.type == "nativeFinderResult" {
                sendCurrentState(tabCommand: tabCommand,
                    force: expectsResponse || hasReceipt,
                    visibilityPlanReceipt: visibilityPlanReceipt, visibilityRestartReceipt: visibilityRestartReceipt,
                    visibilityRecoveryReceipt: visibilityRecoveryReceipt, visibilityClosedReceipt: visibilityClosedReceipt,
                    minimizeBootstrapClaimReceipt: minimizeBootstrapClaimReceipt, minimizeBootstrapResultReceipt: minimizeBootstrapResultReceipt)
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

    private var supportsNativeWindowVisibility: Bool {
        guard let browserBundleIdentifier,
              ["org.mozilla.firefox", "com.google.Chrome"].contains(browserBundleIdentifier),
              let profileSessionID,
              !profileSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              profileSessionID.utf8.count <= 256 else { return false }
        return extensionCapabilities.contains(BrowserGuardCapability.nativeWindowVisibility.rawValue)
    }

    private var supportsMinimizeBootstrap: Bool {
        supportsNativeWindowVisibility && browserBundleIdentifier == "org.mozilla.firefox"
            && extensionCapabilities.contains(BrowserGuardCapability.firefoxWindowMinimizeBootstrap.rawValue)
    }
    private func currentVisibilityRecord() -> BrowserWindowVisibilityRecord? {
        guard supportsNativeWindowVisibility, let browser = browserBundleIdentifier, let profile = profileSessionID,
              let rules = cachedRules, rules.active, rules.isFresh(), makeRuleState().nativeWindowVisibility,
              let session = rules.startupSessionID, let proof = currentBrowserProcessIdentity,
              let record = BrowserWindowVisibilityStore(directory: paths.directory).record(browserBundleIdentifier: browser,
                browserSessionID: profile, intentionSessionID: session), record.browserProcessIdentity == proof else { return nil }
        return record
    }
    private func bootstrapOffers(_ record: BrowserWindowVisibilityRecord?) -> [HostMinimizeBootstrapOffer] {
        guard supportsMinimizeBootstrap, let record, let proof = record.browserProcessIdentity else { return [] }
        let now = Date().timeIntervalSince1970 * 1000
        return record.bootstrapEffects.compactMap { effect in
            guard effect.phase == .prepared, effect.expiresAtUnixMS > now,
                  let current = record.plan.windows.first(where: { $0.windowID == effect.descriptor.windowID }),
                  ["normal", "maximized"].contains(current.state) else { return nil }
            // Native already bound the exact CG/browser lifetime. A title or
            // unrelated parking revision cannot strand that one-shot offer.
            return .init(effectID: effect.effectID, intentionSessionID: record.plan.intentionSessionID,
                browserSessionID: record.browserSessionID, browserProcessIdentity: proof, windowID: effect.descriptor.windowID,
                planRevision: record.plan.revision, expiresAtUnixMS: effect.expiresAtUnixMS, descriptor: current)
        }
    }
    private func validBootstrapIdentity(_ effect: String, _ session: String, _ profile: String) -> Bool {
        [effect, session, profile].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 256 }
    }
    private func claimMinimizeBootstrap(_ request: HostRequest) -> Bool {
        guard supportsMinimizeBootstrap, let browser = browserBundleIdentifier, request.browserBundleIdentifier == browser,
              let profile = profileSessionID, request.browserSessionID == profile,
              let claim = request.minimizeBootstrapClaim, claim.previousBrowserSessionID == profile,
              validBootstrapIdentity(claim.effectID, claim.intentionSessionID, claim.previousBrowserSessionID),
              let proof = currentBrowserProcessIdentity, proof == claim.previousProcessIdentity,
              let record = currentVisibilityRecord(), record.plan.intentionSessionID == claim.intentionSessionID else { return false }
        return (try? BrowserWindowVisibilityStore(directory: paths.directory).claimBootstrap(effectID: claim.effectID,
            browserBundleIdentifier: browser, browserSessionID: profile, intentionSessionID: claim.intentionSessionID,
            browserProcessIdentity: proof, currentIntentionSessionID: record.plan.intentionSessionID)) == true
    }
    private func receiveMinimizeBootstrapResult(_ request: HostRequest) -> Bool {
        guard supportsMinimizeBootstrap, let browser = browserBundleIdentifier, request.browserBundleIdentifier == browser,
              let profile = profileSessionID, request.browserSessionID == profile,
              let result = request.minimizeBootstrapResult,
              validBootstrapIdentity(result.effectID, result.intentionSessionID, result.previousBrowserSessionID),
              let proof = currentBrowserProcessIdentity, proof == result.previousProcessIdentity else { return false }
        return (try? BrowserWindowVisibilityStore(directory: paths.directory).recordBootstrapResult(effectID: result.effectID,
            browserBundleIdentifier: browser, browserSessionID: result.previousBrowserSessionID,
            intentionSessionID: result.intentionSessionID, browserProcessIdentity: proof, outcome: result.outcome)) == true
    }

    private var currentBrowserProcessIdentity: BrowserProcessIdentity? {
        // The existing QA executable/root contract confines simulated identities
        // to private marked temporary data. Production host names cannot opt in.
        let environment = ProcessInfo.processInfo.environment
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath(),
           executable.lastPathComponent == "IntentQASpec",
           let root = environment["INTENT_QA_ROOT"],
           let directory = try? IntentEnvironment.validatedQADirectory(path: root, bundleIdentifier: nil,
                executableName: executable.lastPathComponent),
           directory == paths.directory.standardizedFileURL.resolvingSymlinksInPath(),
           let injected = environment["INTENT_QA_BROWSER_PROCESS_IDENTITY"], injected.utf8.count <= 1024,
           let identity = try? JSONDecoder().decode(BrowserProcessIdentity.self, from: Data(injected.utf8)),
           identity.isValid {
            return identity
        }
        let parentPID = getppid()
        guard let browserBundleIdentifier, parentPID > 0,
              let app = NSRunningApplication(processIdentifier: parentPID),
              !app.isTerminated, app.bundleIdentifier == browserBundleIdentifier,
              let launchDate = app.launchDate else { return nil }
        let identity = BrowserProcessIdentity(pid: parentPID, launched: launchDate.timeIntervalSinceReferenceDate)
        return identity.isValid ? identity : nil
    }

    private func previousBrowserProcessState(_ previous: BrowserProcessIdentity) -> BrowserWindowVisibilityRestartPolicy.PreviousProcessState {
        guard previous.isValid else { return .unknown }
        if kill(previous.pid, 0) == -1 {
            // Lack of permission or missing AppKit metadata is not proof of exit.
            return errno == ESRCH ? .terminated : .unknown
        }
        if let app = NSRunningApplication(processIdentifier: previous.pid),
           let launchDate = app.launchDate {
            let observed = BrowserProcessIdentity(pid: previous.pid, launched: launchDate.timeIntervalSinceReferenceDate)
            if observed.isValid, observed != previous { return .reused(observed) }
        }
        return .running
    }

    private func permitsWindowVisibilityRestartRecovery(_ request: HostRequest) -> Bool {
        guard supportsNativeWindowVisibility,
              let browserBundleIdentifier, request.browserBundleIdentifier == browserBundleIdentifier,
              let profileSessionID, request.browserSessionID == profileSessionID,
              let recovery = request.visibilityRestartRequest,
              [recovery.requestID, recovery.intentionSessionID, recovery.previousBrowserSessionID].allSatisfy({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 256
              }), recovery.previousProcessIdentity.isValid,
              let currentIdentity = currentBrowserProcessIdentity,
              let previous = BrowserWindowVisibilityStore(directory: paths.directory)
                .records(browserBundleIdentifier: browserBundleIdentifier).first(where: {
                    $0.browserSessionID == recovery.previousBrowserSessionID
                        && $0.plan.intentionSessionID == recovery.intentionSessionID
                }), previous.browserProcessIdentity == recovery.previousProcessIdentity else { return false }

        return BrowserWindowVisibilityRestartPolicy.permits(
            requestedPreviousIdentity: recovery.previousProcessIdentity,
            storedPreviousIdentity: previous.browserProcessIdentity,
            currentIdentity: currentIdentity,
            previousProcessState: previousBrowserProcessState(recovery.previousProcessIdentity),
            hasFreshActiveIntention: cachedRules.map { $0.active && $0.isFresh() } ?? false,
            requestedPreviousBrowserSessionID: recovery.previousBrowserSessionID,
            storedPreviousBrowserSessionID: previous.browserSessionID,
            currentBrowserSessionID: profileSessionID)
    }

    private func requestNativeWindowVisibilityRecovery(_ request: HostRequest) -> Bool {
        guard supportsNativeWindowVisibility,
              let browserBundleIdentifier, request.browserBundleIdentifier == browserBundleIdentifier,
              let profileSessionID, request.browserSessionID == profileSessionID,
              let recovery = request.visibilityRecoveryRequest,
              [recovery.requestID, recovery.intentionSessionID, recovery.previousBrowserSessionID].allSatisfy({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 256
              }), let currentIdentity = currentBrowserProcessIdentity,
              currentIdentity == recovery.previousProcessIdentity else { return false }
        if let rules = cachedRules, rules.active, rules.isFresh(), rules.startupSessionID == recovery.intentionSessionID {
            return false
        }
        do {
            let result = try BrowserWindowVisibilityStore(directory: paths.directory).requestRegisteredRecovery(
                browserBundleIdentifier: browserBundleIdentifier, browserSessionID: recovery.previousBrowserSessionID,
                intentionSessionID: recovery.intentionSessionID, browserProcessIdentity: currentIdentity,
                windowIDs: recovery.windowIDs)
            // This queues a native reveal and never grants JS restoration permission.
            return result == .written || result == .unchanged
        } catch {
            return false
        }
    }

    private func confirmNativeParkingClosed(_ request: HostRequest) -> Bool {
        guard supportsNativeWindowVisibility,
              let browserBundleIdentifier, request.browserBundleIdentifier == browserBundleIdentifier,
              let profileSessionID, request.browserSessionID == profileSessionID,
              let closure = request.visibilityClosedRequest,
              [closure.requestID, closure.intentionSessionID, closure.previousBrowserSessionID].allSatisfy({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 256
              }), let currentIdentity = currentBrowserProcessIdentity,
              currentIdentity == closure.previousProcessIdentity else { return false }
        do {
            // May acknowledge a confirmed empty holder during the same active
            // intention. Only registered + captured parking IDs can be retired;
            // this path never permits JS/native restoration or ordinary windows.
            let result = try BrowserWindowVisibilityStore(directory: paths.directory).confirmRegisteredParkingClosed(
                browserBundleIdentifier: browserBundleIdentifier, browserSessionID: closure.previousBrowserSessionID,
                intentionSessionID: closure.intentionSessionID, browserProcessIdentity: currentIdentity,
                windowIDs: closure.windowIDs)
            return result == .written || result == .unchanged
        } catch {
            return false
        }
    }

    private func persistWindowVisibilityPlan(_ request: HostRequest) -> Bool {
        guard supportsNativeWindowVisibility,
              let browserBundleIdentifier,
              request.browserBundleIdentifier == browserBundleIdentifier,
              let profileSessionID,
              request.browserSessionID == profileSessionID,
              let browserProcessIdentity = currentBrowserProcessIdentity,
              let plan = request.visibilityPlan, plan.isValid else { return false }

        let store = BrowserWindowVisibilityStore(directory: paths.directory)
        do {
            let result: BrowserWindowVisibilityStore.Acceptance
            if let rules = cachedRules, rules.active, rules.isFresh(),
               plan.intentionSessionID == rules.startupSessionID {
                guard makeRuleState().nativeWindowVisibility else { return false }
                result = try store.accept(plan, browserBundleIdentifier: browserBundleIdentifier,
                    browserSessionID: profileSessionID, currentIntentionSessionID: rules.startupSessionID,
                    browserProcessIdentity: browserProcessIdentity)
            } else {
                // Finish/recovery may reveal only parking windows already recorded
                // by this same profile and intention, with all metadata unchanged.
                result = try store.acceptReveal(plan, browserBundleIdentifier: browserBundleIdentifier,
                    browserSessionID: profileSessionID)
            }
            return result == .written || result == .unchanged
        } catch {
            return false
        }
    }

    private func isCurrentNativeVisibilitySession(_ intentionSessionID: String) -> Bool {
        cachedRules?.startupSessionID == intentionSessionID && makeRuleState().nativeWindowVisibility
            && supportsNativeWindowVisibility && currentBrowserProcessIdentity != nil
    }

    private func hasNativeParkingCapture(_ plan: BrowserWindowVisibilityPlan) -> Bool {
        let required = Set(plan.parkingWindows.map(\.windowID)).union(plan.revealWindowIDs)
        guard !required.isEmpty else { return true }
        guard let browserBundleIdentifier, let profileSessionID else { return false }
        let captured = BrowserWindowVisibilityStore(directory: paths.directory).capturedWindowIDs(
            browserBundleIdentifier: browserBundleIdentifier, browserSessionID: profileSessionID,
            intentionSessionID: plan.intentionSessionID)
        return required.isSubset(of: captured)
    }

    private func awaitNativeParkingCapture(_ plan: BrowserWindowVisibilityPlan, deadline: DispatchTime) {
        queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.refreshRulesIfNeeded()
            let currentSession = self.isCurrentNativeVisibilitySession(plan.intentionSessionID)
            let captured = currentSession && self.hasNativeParkingCapture(plan)
            if captured || !currentSession || DispatchTime.now() >= deadline {
                // A true receipt means identity was durably captured; it does
                // not report that minimizing or restoring the window succeeded.
                self.sendCurrentState(tabCommand: self.takePendingCommand(), force: true,
                    visibilityPlanReceipt: .init(revision: plan.revision, accepted: captured))
            } else {
                self.awaitNativeParkingCapture(plan, deadline: deadline)
            }
        }
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
        if let session = profileSessionID, let data = try? JSONEncoder().encode(now) {
            let file = BrowserProfileSnapshots.partition(paths.snapshot(for: browserBundleIdentifier), session: session).appendingPathExtension("heartbeat")
            try? data.write(to: file, options: .atomic)
        }
        if (try? store.write(
            date: now,
            extensionVersion: extensionVersion,
            // This heartbeat gates new session starts. Advertise native readiness
            // only after both sides negotiated it and the parent is verified.
            capabilities: extensionCapabilities.filter {
                if $0 == BrowserGuardCapability.firefoxWindowMinimizeBootstrap.rawValue {
                    return supportsMinimizeBootstrap && currentBrowserProcessIdentity != nil
                }
                return $0 != BrowserGuardCapability.nativeWindowVisibility.rawValue
                    || (supportsNativeWindowVisibility && currentBrowserProcessIdentity != nil)
            }
        )) != nil {
            metrics.heartbeatWrites += 1
            lastHeartbeatWriteAt = now
        }
    }

    private var lastSnapshotSessionID: String?
    private var lastSnapshotProfileID: String?
    private var lastSnapshotAllTabs: [BrowserTabItem]?
    private func persistSnapshot(_ tabs: [HostTab], allTabs: [HostTab]?, browserSessionID: String?, browserBundleIdentifier: String,
                                 snapshotRequestIDs: [String]?, completeWindowInventory: Bool?) {
        let now = Date()
        issuedSnapshotRequests = issuedSnapshotRequests.filter { now.timeIntervalSince($0.value) <= 3 }
        let proof = self.browserBundleIdentifier == browserBundleIdentifier && self.profileSessionID == browserSessionID
            ? currentBrowserProcessIdentity : nil
        let profileAnswered = self.browserBundleIdentifier == browserBundleIdentifier && self.profileSessionID == browserSessionID
            && browserSessionID != nil && allTabs != nil && (snapshotRequestIDs ?? []).count <= 16
            ? Array(Set((snapshotRequestIDs ?? []).filter { issuedSnapshotRequests[$0] != nil })).sorted() : []
        let answered = (snapshotRequestIDs ?? []).count <= 16 && allTabs != nil && proof != nil && completeWindowInventory == true
            ? Array(Set((snapshotRequestIDs ?? []).filter { issuedSnapshotRequests[$0] != nil })).sorted() : []
        let items = tabs.map {
            BrowserTabItem(
                id: $0.id,
                windowID: $0.windowID,
                index: $0.index,
                title: $0.title,
                url: $0.url,
                active: $0.active,
                faviconURL: $0.faviconURL, highlighted: $0.highlighted, pinned: $0.pinned, discarded: $0.discarded, groupID: $0.groupID, windowFrame: $0.windowFrame, windowFocused: $0.windowFocused, searchSessionID: $0.searchSessionID, cookieStoreID: $0.cookieStoreID
            )
        }
        let allItems = allTabs?.map { BrowserTabItem(id: $0.id, windowID: $0.windowID, index: $0.index, title: $0.title, url: $0.url, active: $0.active, faviconURL: $0.faviconURL, highlighted: $0.highlighted, pinned: $0.pinned, discarded: $0.discarded, groupID: $0.groupID, windowFrame: $0.windowFrame, windowFocused: $0.windowFocused, searchSessionID: $0.searchSessionID, cookieStoreID: $0.cookieStoreID) }
        // Explicit discovery is also a freshness acknowledgment. Preserve idle
        // deduplication, but refresh the timestamp even if requested tabs did not change.
        guard !profileAnswered.isEmpty || !answered.isEmpty || requestedSnapshotRefresh || items != lastSnapshotTabs || allItems != lastSnapshotAllTabs || browserSessionID != lastSnapshotSessionID || browserProfileID != lastSnapshotProfileID else { return }
        let snapshot = BrowserTabSnapshot(
            browserBundleIdentifier: browserBundleIdentifier,
            browserSessionID: browserSessionID,
            browserProfileID: self.profileSessionID == browserSessionID ? browserProfileID : nil,
            tabs: items,
            allTabs: allItems,
            browserProcessIdentity: proof,
            snapshotRequestIDs: answered.isEmpty ? nil : answered,
            profileDiscoveryRequestIDs: profileAnswered.isEmpty ? nil : profileAnswered,
            completeWindowInventory: answered.isEmpty ? nil : true,
            guardEnabled: guardEnabled,
            guardCapabilities: extensionCapabilities
        )
        let store = BrowserTabSnapshotStore(fileURL: paths.snapshot(for: browserBundleIdentifier))
        if (try? store.write(snapshot)) != nil {
            if let session = browserSessionID {
                try? BrowserTabSnapshotStore(fileURL: BrowserProfileSnapshots.partition(paths.snapshot(for: browserBundleIdentifier), session: session)).write(snapshot)
                // Keep the exact correlated response separate from ordinary
                // active-tab refreshes, which may arrive before the app polls.
                if !answered.isEmpty {
                    try? BrowserTabSnapshotStore(fileURL: BrowserProfileSnapshots.coveragePartition(paths.snapshot(for: browserBundleIdentifier), session: session)).write(snapshot)
                }
                if !profileAnswered.isEmpty {
                    try? BrowserTabSnapshotStore(fileURL: BrowserProfileSnapshots.discoveryPartition(paths.snapshot(for: browserBundleIdentifier), session: session)).write(snapshot)
                }
                maybeWriteHeartbeat(force: true)
            }
            requestedSnapshotRefresh = false
            metrics.snapshotWrites += 1
            lastSnapshotSessionID = browserSessionID
            lastSnapshotProfileID = browserProfileID
            lastSnapshotTabs = items
            lastSnapshotAllTabs = allItems
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
                accessMode: IntentionAccessMode.whitelist.rawValue,
                allowedWebsites: [],
                startupWebsites: [],
                startupSessionID: nil,
                blockTabSwitching: false,
                blockNavigation: false,
                blockNewTabs: false,
                allowGoogleSearchTabs: false,
                guardEnabled: guardEnabled
            )
        }

        let browserWebsites = rules.allowedWebsitesByBrowser[browserBundleIdentifier]
            ?? (browserBundleIdentifier == "org.mozilla.firefox" ? rules.allowedWebsites : [])
        let expected = rules.selectedBrowserSessionIDsByBrowser?[browserBundleIdentifier]
        var selectedIDs = rules.selectedTabIDsByBrowser?[browserBundleIdentifier]
        var selectedSession = expected
        if let selected = selectedIDs, let session = profileSessionID {
            if expected?.hasPrefix("profiles:") == true {
                let participating = String(expected!.dropFirst("profiles:".count)).components(separatedBy: "|").contains(session)
                selectedIDs = participating ? (lastSnapshotAllTabs ?? lastSnapshotTabs ?? []).compactMap { tab in
                    selected.contains(BrowserProfileSnapshots.compositeID(session: session, id: tab.id)) ? tab.id : nil
                } : []
                selectedSession = session
            } else if expected != nil && expected != session {
                selectedIDs = []; selectedSession = session
            }
        }
        let unrestricted = rules.unrestrictedBrowserBundleIdentifiers.contains(browserBundleIdentifier)
        let active = rules.active && (!unrestricted || !rules.websiteFeaturePolicies.isEmpty)
        return HostRuleState(
            addAsYouGo: rules.addAsYouGo || (unrestricted && rules.accessMode == .whitelist),
            websiteFeaturePolicies: rules.websiteFeaturePolicies,
            hideDistractions: rules.hideDistractions,
            nativeWindowVisibility: active && rules.isFresh() && rules.nativeWindowVisibility
                && rules.hideDistractions && rules.startupSessionID?.isEmpty == false
                // Required ownership is not a readiness signal. Clearing it on
                // a temporary handshake/proof failure would enable JS fallback.
                && ["org.mozilla.firefox", "com.google.Chrome"].contains(browserBundleIdentifier),
            selectedBrowserSessionID: unrestricted ? nil : selectedSession,
            selectedTabIDs: unrestricted ? nil : selectedIDs,
            active: active,
            accessMode: rules.accessMode.rawValue,
            allowedWebsites: browserWebsites,
            startupWebsites: rules.startupWebsitesByBrowser[browserBundleIdentifier] ?? [],
            startupSessionID: rules.startupSessionID,
            blockTabSwitching: rules.blockTabSwitching,
            blockNavigation: rules.blockNavigation,
            blockNewTabs: rules.blockNewTabs,
            allowGoogleSearchTabs: rules.allowGoogleSearchTabs,
            guardEnabled: guardEnabled
        )
    }

    private func takePendingCommand() -> BrowserTabCommand? {
        guard let browserBundleIdentifier else { return nil }
        if let session = profileSessionID,
           let creation = BrowserTabCreationMailbox(browser: browserBundleIdentifier, session: session, directory: paths.directory).take() {
            return creation
        }
        if let session = profileSessionID,
           let command = BrowserTabCommandStore(fileURL: BrowserProfileSnapshots.partition(paths.command(for: browserBundleIdentifier), session: session)).take() {
            return command
        }
        if let command = BrowserTabCommandStore(fileURL: paths.command(for: browserBundleIdentifier)).take() {
            return command
        }
        // Presence checks have their own read-only mailbox so background session
        // monitoring cannot overwrite a pending user activation/preview command.
        if let session = profileSessionID,
           let command = BrowserTabCommandStore(fileURL: BrowserSelectedTabPresenceCheck.commandFileURL(
                base: paths.command(for: browserBundleIdentifier), session: session)).take(),
           command.action == .snapshot, command.browserSessionID == session,
           Date().timeIntervalSince(command.createdAt) >= -0.25,
           Date().timeIntervalSince(command.createdAt) <= 3 { return command }
        return nil
    }

    private func sendCurrentState(tabCommand: BrowserTabCommand?, force: Bool, visibilityPlanReceipt: HostVisibilityPlanReceipt? = nil,
                                  visibilityRestartReceipt: HostVisibilityRestartReceipt? = nil,
                                  visibilityRecoveryReceipt: HostVisibilityRecoveryReceipt? = nil,
                                  visibilityClosedReceipt: HostVisibilityClosedReceipt? = nil,
                                  minimizeBootstrapClaimReceipt: HostMinimizeBootstrapClaimReceipt? = nil,
                                  minimizeBootstrapResultReceipt: HostMinimizeBootstrapResultReceipt? = nil) {
        let state = makeRuleState()
        var finderCommand: BrowserFinderCommand?
        if let browser = browserBundleIdentifier, let session = profileSessionID,
           let command = BrowserFinderMailbox(browser: browser, session: session, directory: paths.directory).take() {
            let now = Date().timeIntervalSince1970 * 1000
            issuedFinderCommands = issuedFinderCommands.filter { $0.value.expiresAtUnixMS + 12000 > now }
            if command.isValid, command.browserSessionID == session, command.expiresAtUnixMS > now,
               command.expiresAtUnixMS <= now + 15000,
               extensionCapabilities.contains("native-website-finder-v1"),
               command.action != .observe || extensionCapabilities.contains("native-website-finder-observe-v1"),
               command.action == .cancel || (cachedRules?.active != true && guardEnabled),
               issuedFinderCommands[command.id] == nil {
                issuedFinderCommands[command.id] = command; finderCommand = command
            }
        }
        var tabCommand = tabCommand
        if let command = tabCommand, command.action == .create {
            issuedTabCreations = issuedTabCreations.filter { Date().timeIntervalSince($0.value.createdAt) < 20 }
            let nowMS = Date().timeIntervalSince1970 * 1000
            let eligible = cachedRules?.active != true && guardEnabled && command.browserSessionID == profileSessionID
                && extensionCapabilities.contains(BrowserGuardCapability.backgroundTabCreation.rawValue)
                && UUID(uuidString: command.id) != nil && command.tabID >= 0 && command.windowID >= 0
                && command.url.flatMap(WebsiteFinderPolicy.validatedURL) != nil
                && (command.expiresAtUnixMS ?? 0) > nowMS && (command.expiresAtUnixMS ?? 0) <= nowMS + 15000
            if !eligible || issuedTabCreations[command.id] != nil { tabCommand = nil }
            else { issuedTabCreations[command.id] = command }
        }
        let record = currentVisibilityRecord()
        let offers = bootstrapOffers(record)
        let enforcement = record.flatMap { value -> BrowserWindowVisibilityEnforcement? in
            value.verificationRevision == value.plan.revision ? .init(record: value) : nil
        }
        guard force || tabCommand != nil || finderCommand != nil || state != lastPushedState || offers != lastPushedOffers
            || enforcement != lastPushedEnforcement else { return }
        var response = HostResponse(state: state, tabCommand: tabCommand, visibilityPlanReceipt: visibilityPlanReceipt,
            browserProcessIdentity: currentBrowserProcessIdentity, visibilityRestartReceipt: visibilityRestartReceipt,
            visibilityRecoveryReceipt: visibilityRecoveryReceipt, visibilityClosedReceipt: visibilityClosedReceipt)
        // Effective rules can be inactive for an unrestricted browser during a
        // global intention. Website creation is a pre-session operation only.
        response.tabCreationAllowed = cachedRules?.active != true && guardEnabled
        response.finderCommand = finderCommand
        response.minimizeBootstrapOffers = offers
        response.visibilityEnforcement = enforcement
        response.minimizeBootstrapClaimReceipt = minimizeBootstrapClaimReceipt
        response.minimizeBootstrapResultReceipt = minimizeBootstrapResultReceipt
        if (try? writeMessage(response)) != nil {
            lastPushedOffers = offers; lastPushedEnforcement = enforcement
            if let command = tabCommand, command.action == .snapshot {
                requestedSnapshotRefresh = true
                issuedSnapshotRequests = issuedSnapshotRequests.filter { Date().timeIntervalSince($0.value) <= 3 }
                issuedSnapshotRequests[command.id] = Date()
                if issuedSnapshotRequests.count > 16,
                   let oldest = issuedSnapshotRequests.min(by: { $0.value < $1.value })?.key { issuedSnapshotRequests.removeValue(forKey: oldest) }
            }
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
            self.refreshRulesIfNeeded()
            // Native effect/verification records can change with unchanged rules.
            // sendCurrentState compares their values and suppresses idle pushes.
            self.sendCurrentState(tabCommand: self.takePendingCommand(), force: false)
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
