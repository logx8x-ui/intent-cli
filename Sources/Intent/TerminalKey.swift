import Darwin
import Foundation

enum TerminalKey: Equatable {
    case character(Character)
    case escape
    case tab
    case enter
    case backspace
    case controlC
    case unknown
}

final class TerminalRawMode {
    private var original = termios()
    private var isEnabled = false

    func enable() throws {
        guard !isEnabled else { return }

        if tcgetattr(STDIN_FILENO, &original) != 0 {
            throw POSIXError(.EIO)
        }

        var raw = original
        raw.c_lflag &= ~UInt(ECHO | ICANON | IEXTEN)
        raw.c_iflag &= ~UInt(IXON | ICRNL | BRKINT | INPCK | ISTRIP)
        raw.c_oflag &= ~UInt(OPOST)
        raw.c_cflag |= UInt(CS8)
        raw.c_cc.16 = 1
        raw.c_cc.17 = 0

        if tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) != 0 {
            throw POSIXError(.EIO)
        }

        isEnabled = true
    }

    func disable() {
        guard isEnabled else { return }
        var restored = original
        _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &restored)
        isEnabled = false
    }

    deinit {
        disable()
    }
}

struct TerminalInput {
    private let rawMode = TerminalRawMode()

    func readKey() throws -> TerminalKey {
        try rawMode.enable()
        defer { rawMode.disable() }

        var byte: UInt8 = 0
        let count = read(STDIN_FILENO, &byte, 1)
        guard count == 1 else { return .unknown }

        switch byte {
        case 3:
            return .controlC
        case 9:
            return .tab
        case 10, 13:
            return .enter
        case 27:
            drainEscapeSequenceIfPresent()
            return .escape
        case 127:
            return .backspace
        default:
            if let scalar = UnicodeScalar(Int(byte)) {
                return .character(Character(scalar))
            }
            return .unknown
        }
    }

    private func drainEscapeSequenceIfPresent() {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        while poll(&descriptor, 1, 0) > 0 {
            var ignored: UInt8 = 0
            _ = read(STDIN_FILENO, &ignored, 1)
        }
    }
}
