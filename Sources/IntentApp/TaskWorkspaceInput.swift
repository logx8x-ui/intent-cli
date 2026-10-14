import AppKit
import SwiftUI

/// Local field-editor routing: mentions own arrows and Return only while their
/// menu is visible. No event tap, app activation or key-window changes.
struct TaskWorkspaceInput: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var accessibilityName: String
    var focusRequest: Int = 0
    var initiallyFocused = false
    var onCommand: (TaskWorkspaceInputCommand) -> Bool = { _ in false }
    var onFocusChange: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> TaskWorkspaceTextField {
        let field = TaskWorkspaceTextField(frame: .zero)
        field.isBordered = false
        field.drawsBackground = false
        field.isEditable = true
        field.isSelectable = true
        field.font = .systemFont(ofSize: 13)
        field.textColor = .white
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        context.coordinator.field = field
        field.stringValue = text
        field.placeholderAttributedString = NSAttributedString(string: placeholder,
            attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.48)])
        field.setAccessibilityLabel(accessibilityName)
        field.initialFocusPending = initiallyFocused
        return field
    }

    func updateNSView(_ field: TaskWorkspaceTextField, context: Context) {
        context.coordinator.parent = self
        guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            field.initialFocusPending = true
        }
        field.requestLocalFocus()
    }

    static func dismantleNSView(_ field: TaskWorkspaceTextField, coordinator: Coordinator) {
        field.invalidateFocus()
        if coordinator.isEditing { coordinator.parent.onFocusChange(false) }
        field.delegate = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TaskWorkspaceInput
        weak var field: TaskWorkspaceTextField?
        var lastFocusRequest: Int
        var isEditing = false

        init(_ parent: TaskWorkspaceInput) {
            self.parent = parent
            lastFocusRequest = parent.focusRequest
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            isEditing = true
            field?.initialFocusPending = false
            parent.onFocusChange(true)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            if let field { parent.text = field.stringValue }
            isEditing = false
            parent.onFocusChange(false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            if let field { parent.text = field.stringValue }
            let action: TaskWorkspaceInputCommand
            switch command {
            case #selector(NSResponder.insertNewline(_:)): action = .submit
            case #selector(NSResponder.cancelOperation(_:)): action = .cancel
            case #selector(NSResponder.moveUp(_:)): action = .up
            case #selector(NSResponder.moveDown(_:)): action = .down
            case #selector(NSResponder.insertTab(_:)): action = .complete
            default: return false
            }
            return parent.onCommand(action)
        }
    }
}

enum TaskWorkspaceInputCommand: Equatable { case submit, cancel, up, down, complete }

struct TaskWorkspaceMention: Equatable {
    let prefix: String
    let query: String

    static func parse(_ text: String) -> Self? {
        guard let index = text.lastIndex(of: "@"),
              index == text.startIndex || text[text.index(before: index)].isWhitespace else { return nil }
        let query = String(text[text.index(after: index)...])
        guard !query.contains("@"), !query.contains("\n") else { return nil }
        return .init(prefix: String(text[..<index]).trimmingCharacters(in: .whitespacesAndNewlines), query: query)
    }
}

final class TaskWorkspaceTextField: NSTextField {
    var initialFocusPending = false
    private var attachment = UUID()
    private var focusScheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachment = UUID()
        focusScheduled = false
        requestLocalFocus()
    }

    func invalidateFocus() {
        attachment = UUID()
        initialFocusPending = false
        focusScheduled = false
    }

    func requestLocalFocus() {
        guard initialFocusPending, !focusScheduled, window != nil else { return }
        let expectedAttachment = attachment
        focusScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, attachment == expectedAttachment else { return }
            focusScheduled = false
            guard initialFocusPending, let window, window.isVisible, window.isKeyWindow,
                  window.attachedSheet == nil, !isHiddenOrHasHiddenAncestor else { return }
            if window.makeFirstResponder(self) {
                initialFocusPending = false
                (currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: stringValue.utf16.count, length: 0))
            }
        }
    }
}
