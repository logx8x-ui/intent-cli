import ApplicationServices
import Foundation

/// Positively exposed public window objects, not proof that every native window
/// was enumerated. Some apps return AXWindows=[] while exposing a real window
/// through their direct children, main window or focused window.
public enum PublicAccessibilityWindowInventory {
    public enum Attribute: CaseIterable, Equatable { case windows, children, mainWindow, focusedWindow }
    public enum Value<Element> { case array([Element]), element(Element), absent, failed }
    public struct Observation<Element> {
        public let windows: [Element]
        public let primaryWindows: [Element]
        /// Additional roots positively prove that AXWindows omitted an exposed
        /// window. Such a union cannot authorize primary-enumeration absence.
        public let primaryWasSupplemented: Bool
    }

    /// The same bounded collector is used by native readers and opaque-token
    /// fixtures. A failed primary enumeration or malformed root stays unknown.
    public static func collect<Element>(pid: Int32, maximumCount: Int = 64,
        hasTime: () -> Bool, read: (Attribute) -> Value<Element>,
        role: (Element) -> String?, processID: (Element) -> Int32?,
        equal: (Element, Element) -> Bool) -> [Element]? {
        collectObservation(pid: pid, maximumCount: maximumCount, hasTime: hasTime,
            read: read, role: role, processID: processID, equal: equal)?.windows
    }

    public static func collectObservation<Element>(pid: Int32, maximumCount: Int = 64,
        hasTime: () -> Bool, read: (Attribute) -> Value<Element>,
        role: (Element) -> String?, processID: (Element) -> Int32?,
        equal: (Element, Element) -> Bool) -> Observation<Element>? {
        guard pid > 0, maximumCount > 0, maximumCount <= 256, hasTime(),
              case .array(let listed) = read(.windows), listed.count <= maximumCount else { return nil }
        var result: [Element] = []
        func append(_ element: Element, requiredWindow: Bool) -> Bool {
            guard hasTime() else { return false }
            if result.contains(where: { equal($0, element) }) { return true }
            guard let observedRole = role(element), hasTime() else { return false }
            if observedRole != kAXWindowRole { return !requiredWindow }
            guard processID(element) == pid, hasTime(), result.count < maximumCount else { return false }
            result.append(element)
            return true
        }
        for element in listed { guard append(element, requiredWindow: true) else { return nil } }
        let primaryWindows = result
        guard hasTime() else { return nil }
        switch read(.children) {
        case .array(let children):
            guard children.count <= maximumCount else { return nil }
            // Menu bars and other ordinary application children are not windows.
            for child in children { guard append(child, requiredWindow: false) else { return nil } }
        case .absent: break
        case .element, .failed: return nil
        }
        for attribute in [Attribute.mainWindow, .focusedWindow] {
            guard hasTime() else { return nil }
            switch read(attribute) {
            case .element(let window):
                guard append(window, requiredWindow: true) else { return nil }
            case .absent: break
            case .array, .failed: return nil
            }
        }
        return hasTime() ? .init(windows: result, primaryWindows: primaryWindows,
            primaryWasSupplemented: result.count != primaryWindows.count) : nil
    }

    /// Validate the native CF boundary before passing any member to AX APIs.
    public static func validatedElements(in value: CFTypeRef, maximumCount: Int = 64) -> [AXUIElement]? {
        guard maximumCount > 0, maximumCount <= 256, CFGetTypeID(value) == CFArrayGetTypeID() else { return nil }
        let array = unsafeBitCast(value, to: CFArray.self)
        let count = CFArrayGetCount(array)
        guard count <= maximumCount else { return nil }
        var result: [AXUIElement] = []
        for index in 0..<count {
            guard let pointer = CFArrayGetValueAtIndex(array, index) else { return nil }
            let member = unsafeBitCast(pointer, to: CFTypeRef.self)
            guard CFGetTypeID(member) == AXUIElementGetTypeID() else { return nil }
            result.append(unsafeBitCast(member, to: AXUIElement.self))
        }
        return result
    }

    /// Only public attributes are read. No accessibility mode, window state,
    /// app activation or permission setting is changed.
    public static func read(pid: Int32, deadline: TimeInterval, maximumCount: Int = 64) -> [AXUIElement]? {
        readObservation(pid: pid, deadline: deadline, maximumCount: maximumCount)?.windows
    }

    public static func readObservation(pid: Int32, deadline: TimeInterval, maximumCount: Int = 64) -> Observation<AXUIElement>? {
        let app = AXUIElementCreateApplication(pid)
        func hasTime() -> Bool { ProcessInfo.processInfo.systemUptime < deadline }
        func attribute(_ element: AXUIElement, _ key: String) -> (AXError, CFTypeRef?) {
            guard hasTime() else { return (.cannotComplete, nil) }
            AXUIElementSetMessagingTimeout(element, Float(min(0.025, max(0.001,
                deadline - ProcessInfo.processInfo.systemUptime))))
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, key as CFString, &value)
            return (status, status == .success ? value : nil)
        }
        return collectObservation(pid: pid, maximumCount: maximumCount, hasTime: hasTime, read: { source in
            let key: String
            switch source {
            case .windows: key = kAXWindowsAttribute
            case .children: key = kAXChildrenAttribute
            case .mainWindow: key = kAXMainWindowAttribute
            case .focusedWindow: key = kAXFocusedWindowAttribute
            }
            let (status, value) = attribute(app, key)
            if source != .windows, (status == .noValue || status == .attributeUnsupported) { return .absent }
            guard status == .success, let value else { return .failed }
            switch source {
            case .windows, .children:
                guard let elements = validatedElements(in: value, maximumCount: maximumCount) else { return .failed }
                return .array(elements)
            case .mainWindow, .focusedWindow:
                guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return .failed }
                return .element(unsafeBitCast(value, to: AXUIElement.self))
            }
        }, role: { attribute($0, kAXRoleAttribute).1 as? String }, processID: { element in
            var owner: pid_t = 0
            return AXUIElementGetPid(element, &owner) == .success ? owner : nil
        }, equal: { CFEqual($0, $1) })
    }
}
