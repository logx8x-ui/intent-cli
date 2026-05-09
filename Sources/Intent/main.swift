import Foundation
import IntentCore
import IntentLock

var menu = IntentMenu()
let input = TerminalInput()

func runFocusSession(_ task: IntentWorkTask) {
    TerminalRenderer.starting(task)

    do {
        try FocusLock(spec: FocusSessionSpec.make(for: task)).run()
    } catch {
        TerminalRenderer.lockFailed(String(describing: error))
        _ = try? input.readKey()
    }
}

func confirmIfNeeded(_ task: IntentWorkTask) -> Bool {
    guard case .shallow(let shallowTask) = task,
          let phrase = shallowTask.confirmationPhrase else {
        return true
    }

    TerminalRenderer.confirmation(for: shallowTask)
    return readLine() == phrase
}

func runRoot() throws {
    TerminalRenderer.root()

    while true {
        switch try input.readKey() {
        case .controlC:
            TerminalRenderer.clear()
            exit(0)
        case .character(let character):
            let action = menu.handle(String(character))
            switch action {
            case .showShallow, .showDeep, .showRoot:
                return
            case .invalid, .start:
                continue
            }
        default:
            continue
        }
    }
}

func runDeep() throws {
    var buffer = ""
    var warning: String?

    while true {
        TerminalRenderer.deep(buffer: buffer, warning: warning)
        warning = nil

        switch try input.readKey() {
        case .controlC:
            TerminalRenderer.clear()
            exit(0)
        case .escape:
            _ = menu.handle("\u{1B}")
            return
        case .tab:
            if let completion = IntentCompleter.complete(buffer, in: DeepTask.allCases) {
                buffer = completion
            } else {
                warning = "No matching task."
            }
        case .enter:
            let action = menu.handle(buffer)
            switch action {
            case .start(let task):
                runFocusSession(task)
                buffer = ""
            default:
                warning = "Choose 1 or Data science."
            }
        case .backspace:
            if !buffer.isEmpty {
                buffer.removeLast()
            }
        case .character("b"), .character("B"):
            if buffer.isEmpty {
                _ = menu.handle("b")
                return
            }
            buffer.append("b")
        case .character(let character):
            if buffer.isEmpty && character == "1" {
                if case .start(let task) = menu.handle("1") {
                    runFocusSession(task)
                }
            } else if !character.isNewline {
                buffer.append(character)
            }
        default:
            continue
        }
    }
}

func runShallow() throws {
    var buffer = ""
    var warning: String?

    while true {
        TerminalRenderer.shallow(buffer: buffer, warning: warning)
        warning = nil

        switch try input.readKey() {
        case .controlC:
            TerminalRenderer.clear()
            exit(0)
        case .escape:
            _ = menu.handle("\u{1B}")
            return
        case .tab:
            if let completion = IntentCompleter.complete(buffer, in: ShallowTask.allCases) {
                buffer = completion
            } else {
                warning = "No matching task."
            }
        case .enter:
            let action = menu.handle(buffer)
            switch action {
            case .start(let task):
                if confirmIfNeeded(task) {
                    runFocusSession(task)
                }
                buffer = ""
            default:
                warning = "Choose 1, 2, 3, or a task name."
            }
        case .backspace:
            if !buffer.isEmpty {
                buffer.removeLast()
            }
        case .character(let character):
            if buffer.isEmpty && (character == "b" || character == "B") {
                _ = menu.handle("b")
                return
            }

            if buffer.isEmpty && ["1", "2", "3"].contains(character) {
                if case .start(let task) = menu.handle(String(character)),
                   confirmIfNeeded(task) {
                    runFocusSession(task)
                }
            } else if !character.isNewline {
                buffer.append(character)
            }
        case .unknown:
            continue
        }
    }
}

while true {
    do {
        switch menu.screen {
        case .root:
            try runRoot()
        case .deep:
            try runDeep()
        case .shallow:
            try runShallow()
        }
    } catch {
        TerminalRenderer.clear()
        fputs("Intent failed: \(error)\n", stderr)
        exit(1)
    }
}
