import AppKit
import Carbon
import Foundation

struct OverlayShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    static let defaultShortcut = OverlayShortcut(
        keyCode: UInt32(kVK_ANSI_Grave),
        modifiers: UInt32(shiftKey),
        keyLabel: "~"
    )

    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.supportedCarbonModifiers
        self.keyLabel = keyLabel
    }

    init(event: NSEvent) {
        self.init(
            keyCode: UInt32(event.keyCode),
            modifiers: Self.carbonModifiers(from: event.modifierFlags),
            keyLabel: Self.keyLabel(for: event)
        )
    }

    var displayName: String {
        var pieces: [String] = []
        if modifiers & UInt32(controlKey) != 0 { pieces.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { pieces.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { pieces.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { pieces.append("⌘") }
        pieces.append(keyLabel)
        return pieces.joined()
    }

    var cocoaModifiers: NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { result.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { result.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { result.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { result.insert(.command) }
        return result
    }

    private static let supportedCarbonModifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private static func keyLabel(for event: NSEvent) -> String {
        let specialKeys: [UInt16: String] = [
            UInt16(kVK_Return): "Return",
            UInt16(kVK_Tab): "Tab",
            UInt16(kVK_Space): "Space",
            UInt16(kVK_Delete): "Delete",
            UInt16(kVK_ForwardDelete): "Forward Delete",
            UInt16(kVK_LeftArrow): "←",
            UInt16(kVK_RightArrow): "→",
            UInt16(kVK_UpArrow): "↑",
            UInt16(kVK_DownArrow): "↓",
            UInt16(kVK_Home): "Home",
            UInt16(kVK_End): "End",
            UInt16(kVK_PageUp): "Page Up",
            UInt16(kVK_PageDown): "Page Down",
            UInt16(kVK_F1): "F1",
            UInt16(kVK_F2): "F2",
            UInt16(kVK_F3): "F3",
            UInt16(kVK_F4): "F4",
            UInt16(kVK_F5): "F5",
            UInt16(kVK_F6): "F6",
            UInt16(kVK_F7): "F7",
            UInt16(kVK_F8): "F8",
            UInt16(kVK_F9): "F9",
            UInt16(kVK_F10): "F10",
            UInt16(kVK_F11): "F11",
            UInt16(kVK_F12): "F12"
        ]
        if let special = specialKeys[event.keyCode] {
            return special
        }
        if event.keyCode == UInt16(kVK_ANSI_Grave), event.modifierFlags.contains(.shift) {
            return "~"
        }
        let characters = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return characters.isEmpty ? "Key \(event.keyCode)" : characters.uppercased()
    }
}

enum OverlayShortcutStore {
    private static let key = "intentOverlayShortcut"

    static func load() -> OverlayShortcut {
        guard let data = UserDefaults.standard.data(forKey: key),
              let shortcut = try? JSONDecoder().decode(OverlayShortcut.self, from: data) else {
            return .defaultShortcut
        }
        return shortcut
    }

    static func save(_ shortcut: OverlayShortcut) {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

enum OverlayShortcutConflictChecker {
    static func validationMessage(for shortcut: OverlayShortcut) -> String? {
        let modifiers = shortcut.cocoaModifiers
        let hasStrongModifier = !modifiers.intersection([.command, .option, .control]).isEmpty
        let isDefaultStyle = shortcut.keyCode == UInt32(kVK_ANSI_Grave) && modifiers == [.shift]

        if !hasStrongModifier && !isDefaultStyle {
            return "Add Command, Option, or Control so normal typing is never intercepted."
        }
        if shortcut.keyCode == UInt32(kVK_Escape) {
            return "Escape is reserved for closing Intent and macOS panels."
        }
        if isCommonMacShortcut(shortcut) {
            return "\(shortcut.displayName) is already used by macOS or standard Mac apps."
        }
        if conflictsWithEnabledMacShortcut(shortcut) {
            return "\(shortcut.displayName) is already assigned in macOS Keyboard Shortcuts."
        }
        return nil
    }

    private static func isCommonMacShortcut(_ shortcut: OverlayShortcut) -> Bool {
        let modifiers = shortcut.cocoaModifiers
        let code = Int(shortcut.keyCode)

        if modifiers == [.command] {
            let standardCommandKeys = [
                kVK_ANSI_A, kVK_ANSI_C, kVK_ANSI_F, kVK_ANSI_H, kVK_ANSI_M,
                kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_S,
                kVK_ANSI_T, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Z,
                kVK_Space, kVK_Tab, kVK_ANSI_Comma
            ]
            if standardCommandKeys.contains(code) { return true }
        }

        if modifiers == [.command, .shift], [kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5].contains(code) {
            return true
        }

        if modifiers == [.control], [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow].contains(code) {
            return true
        }

        return false
    }

    private static func conflictsWithEnabledMacShortcut(_ shortcut: OverlayShortcut) -> Bool {
        guard let domain = UserDefaults.standard.persistentDomain(forName: "com.apple.symbolichotkeys"),
              let hotKeys = domain["AppleSymbolicHotKeys"] as? [String: Any] else {
            return false
        }

        let expectedModifiers = shortcut.cocoaModifiers.rawValue
        for value in hotKeys.values {
            guard let entry = value as? [String: Any],
                  (entry["enabled"] as? Bool) == true,
                  let details = entry["value"] as? [String: Any],
                  let parameters = details["parameters"] as? [NSNumber],
                  parameters.count >= 3 else {
                continue
            }
            let keyCode = parameters[1].uint32Value
            let modifiers = UInt(parameters[2].uint64Value)
            if keyCode == shortcut.keyCode && modifiers == expectedModifiers {
                return true
            }
        }
        return false
    }
}

final class GlobalHotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let handler: () -> Void
    private(set) var shortcut: OverlayShortcut
    private(set) var registrationStatus: OSStatus = OSStatus(eventNotHandledErr)

    var isRegistered: Bool {
        hotKeyRef != nil && registrationStatus == noErr
    }

    init(shortcut: OverlayShortcut = OverlayShortcutStore.load(), handler: @escaping () -> Void) {
        self.shortcut = shortcut
        self.handler = handler
        registrationStatus = installHandler()
        guard registrationStatus == noErr else { return }

        registrationStatus = register(shortcut)
        if registrationStatus != noErr, shortcut != .defaultShortcut {
            self.shortcut = .defaultShortcut
            registrationStatus = register(.defaultShortcut)
            if registrationStatus == noErr {
                OverlayShortcutStore.save(.defaultShortcut)
            }
        }
    }

    deinit {
        unregister()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    func update(to candidate: OverlayShortcut) -> OSStatus {
        guard candidate != shortcut || !isRegistered else { return noErr }
        let previous = shortcut
        unregister()

        let status = register(candidate)
        if status == noErr {
            shortcut = candidate
            registrationStatus = noErr
            return noErr
        }

        registrationStatus = register(previous)
        return status
    }

    private func installHandler() -> OSStatus {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            manager.handler()
            return noErr
        }

        return InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
    }

    private func register(_ shortcut: OverlayShortcut) -> OSStatus {
        let hotKeyID = EventHotKeyID(signature: fourCharCode("IntO"), id: 1)
        var newHotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &newHotKeyRef
        )
        if status == noErr {
            hotKeyRef = newHotKeyRef
        }
        return status
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        registrationStatus = OSStatus(eventNotHandledErr)
    }
}

private func fourCharCode(_ string: String) -> OSType {
    string.utf8.reduce(0) { result, byte in
        (result << 8) + OSType(byte)
    }
}
