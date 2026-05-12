import AppKit
import SwiftUI

struct WindowBackgroundController: NSViewRepresentable {
    let appearance: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            apply(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            apply(to: nsView.window)
        }
    }

    private func apply(to window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.backgroundColor = AnkiTheme.windowBackground(for: appearance)
        window.toolbarStyle = .unified
        window.toolbar?.showsBaselineSeparator = false
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
    }
}
