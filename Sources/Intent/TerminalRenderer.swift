import Foundation
import IntentCore

enum TerminalRenderer {
    static func clear() {
        print("\u{001B}[2J\u{001B}[H", terminator: "")
    }

    static func root() {
        clear()
        printHeader()
        print("""

        What kind of work are we doing?

          s  Shallow
          d  Deep

        """)
        printMuted("Press s or d. Ctrl+C quits.")
    }

    static func deep() {
        clear()
        printHeader()
        print("""

        Deep work

          1. Data science

        """)
        printMuted("Press 1, type a task name then Enter, Tab to autocomplete, Esc/b to go back.")
    }

    static func shallow(buffer: String = "", warning: String? = nil) {
        clear()
        printHeader()
        print("""

        Shallow tasks

          1. Imessages
          2. Instagram replies
          3. Emails

        """)

        if !buffer.isEmpty {
            print("  > \(buffer)")
        }

        if let warning {
            print("")
            printWarning(warning)
        }

        print("")
        printMuted("Press 1, type a task name then Enter, Tab to autocomplete, Esc/b to go back.")
    }

    static func deep(buffer: String = "", warning: String? = nil) {
        clear()
        printHeader()
        print("""

        Deep work

          1. Data science

        """)

        if !buffer.isEmpty {
            print("  > \(buffer)")
        }

        if let warning {
            print("")
            printWarning(warning)
        }

        print("")
        printMuted("Press 1, type a task name then Enter, Tab to autocomplete, Esc/b to go back.")
    }

    static func confirmation(for task: ShallowTask) {
        clear()
        printHeader()
        print("")
        printWarning("Are you sure?")
        print("")
        print("Type exactly:")
        print("  \(task.confirmationPhrase ?? "")")
        print("")
        printMuted("Press Enter after typing it, or leave blank to cancel.")
        print("")
        print("> ", terminator: "")
        fflush(stdout)
    }

    static func starting(_ task: IntentWorkTask) {
        clear()
        printHeader()
        print("")
        print("  Starting \(task.displayName) focus...")
        printMuted("  Press Shift+Cmd+M to finish and return here.")
    }

    static func lockFailed(_ message: String) {
        print("")
        printWarning(message)
        print("")
        printMuted("Press any key to return to shallow tasks.")
    }

    private static func printHeader() {
        print("\u{001B}[38;5;111m╭──────────────────────────────╮\u{001B}[0m")
        print("\u{001B}[38;5;111m│\u{001B}[0m           \u{001B}[1mINTENT\u{001B}[0m             \u{001B}[38;5;111m│\u{001B}[0m")
        print("\u{001B}[38;5;111m╰──────────────────────────────╯\u{001B}[0m")
    }

    private static func printMuted(_ value: String) {
        print("\u{001B}[2m\(value)\u{001B}[0m")
    }

    private static func printWarning(_ value: String) {
        print("\u{001B}[38;5;214m\(value)\u{001B}[0m")
    }
}
