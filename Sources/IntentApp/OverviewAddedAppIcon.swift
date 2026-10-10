import AppKit
import SwiftUI

/// A staged app is represented by its own artwork, never a fake window card.
/// Keep the remove action available on hover and through accessibility.
struct OverviewAddedAppIcon: View {
    let icon: NSImage
    let name: String
    let selected: Bool
    let opening: Bool
    let hovered: Bool
    let size: CGFloat
    let select: () -> Void
    let remove: () -> Void

    var body: some View {
        Button(action: select) {
            Image(nsImage: icon).resizable().scaledToFit()
                .frame(width: size, height: size)
                .opacity(selected ? 1 : 0.55)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("\(name), \(selected ? "selected" : "not selected")")
            .accessibilityAction(named: Text("Remove added app"), remove)
            .help(name)
            .overlay(alignment: .topTrailing) {
                if hovered {
                    Button(action: remove) {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                            .frame(width: 24, height: 24).background(.regularMaterial, in: Circle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel("Remove added app \(name)")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if opening {
                    ProgressView().controlSize(.small).padding(4)
                        .accessibilityLabel("Opening \(name) in background")
                }
            }
    }
}
