import CoreGraphics
import Foundation
import IntentCore

/// Value-only input state. Producers do discovery before publishing; the tap
/// never calls AppKit, Accessibility, WindowServer, or a browser store.
public struct FocusInputPolicySnapshot {
    public struct Window {
        public let id: UInt32
        public let bounds: CGRect
        public let permitted: Bool
        public init(id: UInt32, bounds: CGRect, permitted: Bool) {
            self.id = id; self.bounds = bounds; self.permitted = permitted
        }
    }
    public var observedAt: TimeInterval = 0
    public var stopped = false
    public var screenshotActive = false
    public var missionControl = false
    public var foregroundRejected = false
    public var browserFrontmost = false
    public var firefoxFrontmost = false
    public var nativeWindowBlocked = false
    public var addressSubmissionBlocked = false
    public var tabWindowID: UInt32 = 0
    public var tabRegions: [CGRect] = []
    public var tabRegionsValidUntil: TimeInterval = 0
    public var windows: [Window] = []
    public var panelRegions: [CGRect] = []
    public var panelKeyboardFocus = false
    public var menuBars: [CGRect] = []
    public var firefoxBounds: CGRect?
    public var pointerProbe: CGPoint?
    public var pointerPermitted = true
    public var finishShortcut: FocusKeyboardShortcut = .defaultFinish
    public var accessibilityTrusted = false
    public var coverageVerifiedAt: TimeInterval = 0
    public var coverageResolved = false
    public var allowedSwitchingBundles: Set<String> = []
    public var rcmd: RcmdCompatibilitySnapshot = .inactive
    public init() {}
}

public enum FocusInputForegroundPolicy {
    /// Process permission alone never grants a partially selected app's sibling
    /// window. Auxiliary permission must be an exact current controller proof.
    public static func rejectsWindow(hasWindowScope: Bool, foregroundWindowID: UInt32,
                                     windowPermitted: Bool, auxiliaryVerified: Bool) -> Bool {
        hasWindowScope && (foregroundWindowID == 0 || (!windowPermitted && !auxiliaryVerified))
    }
}

public struct FocusInputConfiguration {
    public var restrictSwitching: Bool
    public var blockSystemCommands: Bool
    public var blockBrowserEscape: Bool
    public var protectFirefoxChrome: Bool
    public var allowGoogleSearchTabs: Bool
    public init(restrictSwitching: Bool = true, blockSystemCommands: Bool = true,
                blockBrowserEscape: Bool = true, protectFirefoxChrome: Bool = false,
                allowGoogleSearchTabs: Bool = false) {
        self.restrictSwitching = restrictSwitching; self.blockSystemCommands = blockSystemCommands
        self.blockBrowserEscape = blockBrowserEscape; self.protectFirefoxChrome = protectFirefoxChrome
        self.allowGoogleSearchTabs = allowGoogleSearchTabs
    }
}

public struct FocusInputEvent {
    public let type: CGEventType
    public let keyCode: Int64
    public let flags: CGEventFlags
    public let isRepeat: Bool
    public let point: CGPoint
    public let button: Int64
    public let targetWindowID: UInt32
    public init(type: CGEventType, keyCode: Int64 = 0, flags: CGEventFlags = [], isRepeat: Bool = false,
                point: CGPoint = .zero, button: Int64 = 0, targetWindowID: UInt32 = 0) {
        self.type = type; self.keyCode = keyCode; self.flags = flags; self.isRepeat = isRepeat
        self.point = point; self.button = button; self.targetWindowID = targetWindowID
    }
}

public enum FocusInputAction: Equatable {
    case refocus, manualFinish, emergencyStop, switcherAdvance(steps: Int), switcherCommit, switcherCancel
    case activate(String), spaceNavigation, drag, mouseDown(missionControl: Bool), blockedClick
}
public struct FocusInputDecision {
    public let consume: Bool
    public let actions: [FocusInputAction]
    public init(consume: Bool = false, actions: [FocusInputAction] = []) { self.consume = consume; self.actions = actions }
}

/// Session-local, tap-thread-owned state; all dependencies are scalar snapshots.
public struct FocusInputRouter {
    private var suppressedKeys: Set<Int64> = []
    private var suppressedButtons: Set<Int64> = []
    private var switcherRequested = false
    private var draggingUntil: TimeInterval = 0
    private var rcmd = RcmdInputRouter()
    public init() {}
    public mutating func route(_ input: FocusInputEvent, snapshot s: FocusInputPolicySnapshot,
                               configuration c: FocusInputConfiguration, now: TimeInterval) -> FocusInputDecision {
        guard !s.stopped else { return .init() }
        if input.type == .keyUp {
            let rcmdResult = rcmd.route(type: input.type, keyCode: input.keyCode, flags: input.flags,
                isRepeat: false, now: now, snapshot: s.rcmd, allowedBundleIdentifiers: s.allowedSwitchingBundles)
            return .init(consume: suppressedKeys.remove(input.keyCode) != nil || rcmdResult != .pass)
        }
        if [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(input.type) {
            return .init(consume: suppressedButtons.remove(input.button) != nil)
        }
        if input.type == .flagsChanged {
            let rcmdResult = rcmd.route(type: input.type, keyCode: input.keyCode, flags: input.flags,
                isRepeat: false, now: now, snapshot: s.rcmd, allowedBundleIdentifiers: s.allowedSwitchingBundles)
            if switcherRequested && !input.flags.contains(.maskCommand) {
                switcherRequested = false
                return .init(consume: rcmdResult != .pass, actions: [.switcherCommit])
            }
            return .init(consume: rcmdResult != .pass)
        }
        let fresh = now >= s.observedAt && now - s.observedAt <= 0.6
        let screenshotActive = s.screenshotActive && fresh
        if screenshotActive && input.type != .keyDown { return .init() }
        if input.type == .leftMouseDragged {
            if suppressedButtons.contains(0) { return .init(consume: true) }
            draggingUntil = now + 0.25
            return .init(actions: [.drag])
        }
        let panel = s.panelRegions.contains { $0.contains(input.point) }
        let tabMatches = s.tabWindowID != 0 && s.tabWindowID == input.targetWindowID && now < s.tabRegionsValidUntil
        let blockedTabPoint = tabMatches && !panel && s.tabRegions.contains { $0.contains(input.point) }
        if input.type == .scrollWheel {
            return .init(consume: s.nativeWindowBlocked && blockedTabPoint && !s.missionControl)
        }
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(input.type) {
            var blocked = !fresh && !panel
            if !panel && fresh {
                if s.missionControl {
                    // A point hit-test is sampled off-thread. It is usable only
                    // at that exact pointer location; no guessed tile identity.
                    if let point = s.pointerProbe, abs(point.x - input.point.x) < 3, abs(point.y - input.point.y) < 3 {
                        blocked = !s.pointerPermitted
                    }
                } else if blockedTabPoint && (s.nativeWindowBlocked || now >= draggingUntil) {
                    blocked = true
                } else if c.protectFirefoxChrome, s.firefoxFrontmost, let bounds = s.firefoxBounds,
                          FirefoxClickProtection.isProtected(point: input.point,
                            windowBounds: .init(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height),
                            protectTopChrome: !c.allowGoogleSearchTabs) {
                    blocked = true
                } else if c.restrictSwitching, !s.menuBars.contains(where: { $0.contains(input.point) }) {
                    if let exact = s.windows.first(where: { $0.id == input.targetWindowID }), input.targetWindowID != 0 {
                        blocked = !exact.permitted
                    } else if input.targetWindowID != 0 {
                        // A newly appeared window is not the allowed rectangle
                        // it happens to cover. Wait for its exact inventory row.
                        blocked = true
                    } else if let top = s.windows.first(where: { $0.bounds.contains(input.point) }) {
                        blocked = !top.permitted
                    }
                    if let point = s.pointerProbe, abs(point.x - input.point.x) < 3, abs(point.y - input.point.y) < 3 {
                        blocked = blocked || !s.pointerPermitted
                    }
                }
            }
            if blocked {
                suppressedButtons.insert(input.button)
                return .init(consume: true, actions: [.mouseDown(missionControl: s.missionControl), .blockedClick, .refocus])
            }
            return .init(actions: [.mouseDown(missionControl: s.missionControl)])
        }
        guard input.type == .keyDown else { return .init() }
        if input.isRepeat && suppressedKeys.contains(input.keyCode),
           !(input.keyCode == 48 && input.flags.contains(.maskCommand) && c.restrictSwitching) {
            return .init(consume: true)
        }
        let command = input.flags.contains(.maskCommand), shift = input.flags.contains(.maskShift)
        let control = input.flags.contains(.maskControl), option = input.flags.contains(.maskAlternate)
        if FocusSystemShortcutPolicy.isScreenshotShortcut(keyCode: input.keyCode, command: command, shift: shift) { return .init() }
        if command && control && option && input.keyCode == 53 { return consume(input, actions: [.emergencyStop]) }
        if s.finishShortcut.matches(keyCode: input.keyCode, command: command, shift: shift, control: control, option: option) {
            return consume(input, actions: input.isRepeat ? [] : [.manualFinish])
        }
        let tabRoute = FocusSystemShortcutPolicy.tabRoute(keyCode: input.keyCode, command: command, control: control,
            restrictApplicationSwitching: c.restrictSwitching)
        if tabRoute == .allowedApplications {
            switcherRequested = true
            return consume(input, actions: [.switcherAdvance(steps: shift ? -1 : 1)])
        }
        if input.keyCode == 53 && switcherRequested {
            switcherRequested = false
            return consume(input, actions: [.switcherCancel])
        }
        // A configured right-Control stage trigger must not escape through the
        // native Control-Tab/Space exceptions. Ordinary left-Control shortcuts
        // still pass unchanged; screenshot/finish/emergency have priority above.
        switch rcmd.route(type: input.type, keyCode: input.keyCode, flags: input.flags, isRepeat: input.isRepeat,
                          now: now, snapshot: s.rcmd, allowedBundleIdentifiers: s.allowedSwitchingBundles) {
        case .consume: return consume(input)
        case .activate(let bundle): return consume(input, actions: fresh ? [.activate(bundle)] : [])
        case .pass: break
        }
        if screenshotActive { return .init() }
        if tabRoute == .nativeBrowser { return .init() }
        if control && c.blockSystemCommands && FocusSystemShortcutPolicy.isSpaceNavigationKey(input.keyCode) {
            return .init(actions: [.spaceNavigation])
        }
        if !fresh && input.keyCode != 50 { return consume(input) }
        if command && c.blockSystemCommands && FocusSystemShortcutPolicy.shouldBlock(keyCode: input.keyCode) {
            return consume(input, actions: [.refocus])
        }
        if FocusSystemShortcutPolicy.shouldBlockInertBrowserInput(keyCode: input.keyCode, command: command,
            control: control, option: option, shift: shift, allowGoogleSearchTabs: c.allowGoogleSearchTabs,
            hasPanelKeyboardFocus: s.panelKeyboardFocus, windowBlocked: s.nativeWindowBlocked) {
            return consume(input)
        }
        if [Int64(36), Int64(76)].contains(input.keyCode) && !s.panelKeyboardFocus && s.addressSubmissionBlocked {
            return consume(input)
        }
        if c.blockBrowserEscape && s.browserFrontmost && FocusBrowserShortcutPolicy.shouldBlock(keyCode: input.keyCode,
            command: command, control: control, option: option, shift: shift, allowGoogleSearchTabs: c.allowGoogleSearchTabs) {
            return consume(input, actions: [.refocus])
        }
        // Prevent typing into an excluded foreground app while hide/refocus work
        // catches up. Intent's own grave-key controls remain available.
        if s.foregroundRejected && !s.panelKeyboardFocus && input.keyCode != 50 {
            return consume(input, actions: [.refocus])
        }
        return .init()
    }
    private mutating func consume(_ input: FocusInputEvent, actions: [FocusInputAction] = []) -> FocusInputDecision {
        suppressedKeys.insert(input.keyCode)
        return .init(consume: true, actions: actions)
    }
}

/// Fixed-capacity semantic mailbox. An arbitrarily stalled UI worker cannot
/// accumulate one closure per keystroke, activation, drag or pointer event.
public struct FocusInputPendingEffects {
    public private(set) var actions: [FocusInputAction] = []
    public private(set) var coalesced = 0
    public init() {}
    public mutating func append(_ incoming: [FocusInputAction]) {
        for action in incoming {
            if case .switcherAdvance(let steps) = action,
               let last = actions.last, case .switcherAdvance(let prior) = last {
                actions[actions.count - 1] = .switcherAdvance(steps: max(-1_000_000, min(1_000_000, prior + steps)))
                coalesced = min(1_000_000, coalesced + 1)
            } else if !isSwitcher(action), let index = actions.firstIndex(where: { sameSlot($0, action) }) {
                actions[index] = action
                coalesced = min(1_000_000, coalesced + 1)
            } else if actions.count < 16 { actions.append(action) }
            else if action == .switcherCommit || action == .switcherCancel {
                // Never drop the release/cancel that closes a chooser. Collapse
                // obsolete switcher sequences rather than replaying a backlog.
                actions.removeAll(where: isSwitcher)
                actions.append(action)
                coalesced = min(1_000_000, coalesced + 1)
            } else { coalesced = min(1_000_000, coalesced + 1) }
        }
    }
    public mutating func take() -> [FocusInputAction] { let result = actions; actions.removeAll(keepingCapacity: true); return result }
    public mutating func takeCoalesced() -> Int { let result = coalesced; coalesced = 0; return result }
    private func isSwitcher(_ action: FocusInputAction) -> Bool {
        switch action { case .switcherAdvance, .switcherCommit, .switcherCancel: return true; default: return false }
    }
    private func sameSlot(_ a: FocusInputAction, _ b: FocusInputAction) -> Bool {
        switch (a, b) {
        case (.activate, .activate), (.mouseDown, .mouseDown): return true
        default: return a == b
        }
    }
}

/// Finish requests may open a friction prompt rather than finish immediately.
/// One request is in flight until the owner processes it and acknowledges it.
public struct FocusInputManualFinishPolicy {
    public private(set) var pending = false
    public init() {}
    public mutating func request() -> Bool {
        guard !pending else { return false }; pending = true; return true
    }
    public mutating func acknowledge() { pending = false }
}

public struct FocusInputRecoveryPolicy {
    public enum State: Equatable { case healthy, recovering(started: TimeInterval, deadline: TimeInterval), failed, stopped }
    public private(set) var state: State = .healthy
    public private(set) var attempts = 0
    public init() {}
    public mutating func interrupted(timeout: Bool, now: TimeInterval) -> Bool {
        guard state != .stopped else { return false }
        guard timeout, attempts == 0, state == .healthy else { state = .failed; return false }
        attempts = 1; state = .recovering(started: now, deadline: now + 1)
        return true
    }
    public mutating func verify(now: TimeInterval, tapEnabled: Bool, trusted: Bool, coverageResolved: Bool,
                                coverageVerifiedAt: TimeInterval, snapshotObservedAt: TimeInterval) -> State {
        guard case .recovering(let started, let deadline) = state else { return state }
        if now >= deadline { state = .failed }
        else if tapEnabled && trusted && coverageResolved && coverageVerifiedAt >= started && snapshotObservedAt >= started {
            state = .healthy
        }
        return state
    }
    public mutating func stop() { state = .stopped }
}
