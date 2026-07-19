import SwiftUI

struct IntentQuickGuideView: View {
    let onFinish: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 9) {
                    Image(systemName: "scope")
                    Text("Welcome to Intent")
                        .font(.system(size: 17, weight: .semibold))
                }
                Spacer()
                Text("\(page + 1) of 2")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(GraphTheme.muted(colorScheme))
            }
            .padding(.horizontal, 24)
            .frame(height: 58)

            Divider()

            Group {
                if page == 0 {
                    buildSlide
                } else {
                    runSlide
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(26)

            Divider()

            HStack {
                if page > 0 {
                    Button("Back") { page -= 1 }
                        .buttonStyle(.plain)
                }
                Spacer()
                Button(page == 0 ? "Next" : "Start with a blank desktop") {
                    if page == 0 {
                        page = 1
                    } else {
                        onFinish()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(GraphTheme.editBlue)
            }
            .padding(.horizontal, 24)
            .frame(height: 62)
        }
        .frame(width: 720, height: 500)
        .adaptiveGlassPanel(colorScheme: colorScheme, cornerRadius: 18)
        .shadow(color: .black.opacity(0.48), radius: 28, y: 16)
    }

    private var buildSlide: some View {
        HStack(spacing: 34) {
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(GraphTheme.surface(colorScheme))
                Canvas { context, size in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    var upper = Path()
                    upper.move(to: center)
                    upper.addLine(to: CGPoint(x: size.width * 0.78, y: size.height * 0.28))
                    context.stroke(upper, with: .color(GraphTheme.connection(colorScheme)), lineWidth: 1)
                    var lower = Path()
                    lower.move(to: center)
                    lower.addLine(to: CGPoint(x: size.width * 0.75, y: size.height * 0.74))
                    context.stroke(lower, with: .color(GraphTheme.connection(colorScheme)), lineWidth: 1)
                }
                RoundedRectangle(cornerRadius: 13)
                    .fill(GraphTheme.elevatedSurface(colorScheme))
                    .frame(width: 108, height: 108)
                    .overlay(Image(systemName: "square.grid.2x2").font(.system(size: 34)))
                    .offset(x: -54)
                Circle()
                    .fill(GraphTheme.elevatedSurface(colorScheme))
                    .frame(width: 76, height: 76)
                    .overlay(Image(systemName: "shield").font(.system(size: 23)))
                    .offset(x: 100, y: -58)
                TriangleShape()
                    .fill(GraphTheme.elevatedSurface(colorScheme))
                    .frame(width: 86, height: 78)
                    .overlay(Image(systemName: "hourglass").font(.system(size: 20)).offset(y: 9))
                    .offset(x: 96, y: 68)
            }
            .frame(width: 330, height: 300)

            VStack(alignment: .leading, spacing: 16) {
                Text("Build one clear intention")
                    .font(.system(size: 24, weight: .semibold))
                Text("Press E to enter edit mode, then place the pieces your session needs.")
                    .font(.system(size: 14))
                    .foregroundStyle(GraphTheme.muted(colorScheme))

                shortcut("E", "Enter or leave edit mode")
                shortcut("I", "Add an intention")
                shortcut("R", "Add a restriction")
                shortcut("F", "Add friction")
                shortcut("S", "Save and close an editor")
                shortcut("X / Delete", "Remove the selected shape")
                shortcut("Cmd Z", "Undo the last change")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var runSlide: some View {
        HStack(spacing: 34) {
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(GraphTheme.surface(colorScheme))
                VStack(spacing: 18) {
                    Image(systemName: "scope")
                        .font(.system(size: 54, weight: .light))
                    Text("Click an intention to start")
                        .font(.system(size: 17, weight: .semibold))
                    HStack(spacing: 8) {
                        keycap("⌘")
                        keycap("⇧")
                        keycap("M")
                    }
                    Text("ends every session")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(GraphTheme.muted(colorScheme))
                }
            }
            .frame(width: 330, height: 300)

            VStack(alignment: .leading, spacing: 16) {
                Text("Run it, then leave Intent")
                    .font(.system(size: 24, weight: .semibold))
                Text("Intent opens allowed resources and keeps everything else out until you finish.")
                    .font(.system(size: 14))
                    .foregroundStyle(GraphTheme.muted(colorScheme))

                shortcut("Click", "Start an intention")
                shortcut("Cmd Tab", "Switch between launched allowed apps")
                shortcut("Cmd Shift M", "Finish the active intention")
                shortcut(OverlayShortcutStore.load().displayName, "Show or hide Intent")
                shortcut("Three fingers", "Move between intentions and scheduler")
                shortcut("Pinch", "Zoom the desktop")
                shortcut("Two fingers", "Pan across the desktop")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func shortcut(_ keys: String, _ description: String) -> some View {
        HStack(spacing: 11) {
            Text(keys)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .frame(width: 78, alignment: .leading)
                .foregroundStyle(GraphTheme.text(colorScheme))
            Text(description)
                .font(.system(size: 12))
                .foregroundStyle(GraphTheme.muted(colorScheme))
        }
    }

    private func keycap(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 15, weight: .medium, design: .monospaced))
            .frame(width: 36, height: 32)
            .background(GraphTheme.elevatedSurface(colorScheme))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(GraphTheme.stroke(colorScheme)))
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}
