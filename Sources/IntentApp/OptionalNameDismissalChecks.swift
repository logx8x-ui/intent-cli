import AppKit

@MainActor
enum OptionalNameDismissalChecks {
    static func run(_ check: (Bool, String) throws -> Void) throws {
        let key = NSApp.keyWindow
        let panel = RecordingPanel(contentRect: .init(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.contentView = NSView(frame: .init(x: 0, y: 0, width: 600, height: 400))
        let editor = NSTextView(frame: .init(x: 100, y: 300, width: 300, height: 38))
        editor.string = "Study biology"
        panel.contentView?.addSubview(editor)
        panel.editingResponder = editor
        try check(editor.window === panel, "The production dismissal fixture attaches its editor to its own panel")
        try check(!panel.dismissTextEditing(at: .init(x: 150, y: 320)) && panel.resignations == 0,
            "Clicks inside the actual name editor keep caret placement and typing")
        try check(panel.dismissTextEditing(at: .init(x: 400, y: 200)) && panel.resignations == 1,
            "A wallpaper/control click outside the actual editor clears its first responder")
        try check(editor.string == "Study biology", "Clicking away commits the name without clearing it")
        try check(!panel.dismissTextEditing(at: .init(x: 400, y: 200)) && panel.resignations == 1,
            "Subsequent clicks cannot repeatedly resign an already dismissed editor")
        try check(NSApp.keyWindow === key && !panel.isVisible,
            "Optional-name focus fixtures never order windows or change the user's key window")
        panel.close()
    }

    private final class RecordingPanel: SelectionPanel {
        var editingResponder: NSResponder?
        var resignations = 0
        override var firstResponder: NSResponder? { editingResponder }
        override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
            if responder == nil { resignations += 1 }
            editingResponder = responder
            return true
        }
    }
}
