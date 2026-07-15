import SwiftUI
import IntentCore

struct IntentionNodeView: View {
    let intention: Intention
    let installedApps: [InstalledApp]
    let selected: Bool

    private let squareSize: CGFloat = 148

    var body: some View {
        VStack(spacing: 8) {
            Text(intention.name)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: 190)

            ZStack {
                appSlices
                    .frame(width: squareSize, height: squareSize)
                    .adaptiveGlassPanel(colorScheme: colorScheme, cornerRadius: 20, selected: selected)
                    .frame(maxHeight: .infinity, alignment: .top)

                websiteSpikes
                    .allowsHitTesting(false)
            }
            .frame(width: 188, height: 194)
        }
        .foregroundStyle(GraphTheme.text(colorScheme))
        .frame(width: 200, height: 226)
        .contentShape(Rectangle())
    }

    @Environment(\.colorScheme) private var colorScheme

    private var appSlices: some View {
        HStack(spacing: 0) {
            if intention.allowedApps.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "plus")
                        .font(.system(size: 23, weight: .light))
                    Text("Add an app")
                        .font(.caption)
                }
                .foregroundStyle(GraphTheme.muted(colorScheme))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ForEach(Array(intention.allowedApps.enumerated()), id: \.element.bundleIdentifier) { index, app in
                    appIcon(app)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(GraphTheme.surface(colorScheme))
                    .clipped()
                    .overlay(alignment: .leading) {
                        if index > 0 {
                            Rectangle()
                                .fill(GraphTheme.stroke(colorScheme))
                                .frame(width: 1)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func appIcon(_ app: AllowedApp) -> some View {
        if let installed = installedApps.first(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
            Image(nsImage: installed.icon)
                .resizable()
                .scaledToFill()
        } else {
            Image(systemName: app.isBrowser ? "globe" : "app")
                .resizable()
                .scaledToFit()
                .padding(18)
                .foregroundStyle(GraphTheme.text(colorScheme).opacity(0.82))
        }
    }

    private var websiteSpikes: some View {
        Canvas { context, size in
            guard !intention.allowedApps.isEmpty else { return }
            let sliceWidth = squareSize / CGFloat(intention.allowedApps.count)
            let squareOriginX = (size.width - squareSize) / 2
            let squareBottom = squareSize

            for (appIndex, app) in intention.allowedApps.enumerated() where app.isBrowser {
                let websites = intention.websites(for: app.bundleIdentifier)
                let centerX = squareOriginX + sliceWidth * (CGFloat(appIndex) + 0.5)
                for websiteIndex in websites.indices {
                    let spread = CGFloat(websiteIndex) - CGFloat(websites.count - 1) / 2
                    let baseX = centerX + spread * 12
                    let lean = spread * 2.6
                    let height = 22 + min(abs(spread) * 3, 7)
                    let halfBase = CGFloat(6)
                    var path = Path()
                    path.move(to: CGPoint(x: baseX - halfBase, y: squareBottom - 1))
                    path.addLine(to: CGPoint(x: baseX + halfBase, y: squareBottom - 1))
                    path.addLine(to: CGPoint(x: baseX + lean + 2, y: squareBottom + height))
                    path.addLine(to: CGPoint(x: baseX + lean - 2, y: squareBottom + height))
                    path.closeSubpath()
                    context.fill(path, with: .color(GraphTheme.glassHighlight(colorScheme).opacity(0.42)))
                    context.stroke(path, with: .color(GraphTheme.text(colorScheme).opacity(0.62)), lineWidth: 0.9)
                }
            }
        }
        .frame(width: 188, height: 194)
    }
}

struct RestrictionNodeView: View {
    let node: RestrictionNode
    let selected: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().fill(GraphTheme.glassTint(colorScheme)))
                .overlay(
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [GraphTheme.glassHighlight(colorScheme).opacity(0.30), .clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    Circle()
                        .stroke(selected ? GraphTheme.editBlue : GraphTheme.stroke(colorScheme), lineWidth: selected ? 2 : 1.2)
                )
                .shadow(color: selected ? GraphTheme.editBlue.opacity(0.22) : GraphTheme.glassShadow(colorScheme), radius: 9, y: 5)
            VStack(spacing: 5) {
                Image(systemName: node.kind == .allowBrowserSearches ? "magnifyingglass" : "nosign")
                    .font(.system(size: 17, weight: .medium))
                Text(node.kind == .allowBrowserSearches ? "Browser\nsearches" : "Don't\nstart up")
                    .font(.system(size: 10, weight: .medium))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(GraphTheme.text(colorScheme))
        }
        .frame(width: 106, height: 106)
        .contentShape(Circle())
    }
}

struct FrictionNodeView: View {
    let node: FrictionNode
    let selected: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            TriangleShape()
                .fill(.ultraThinMaterial)
                .overlay(TriangleShape().fill(GraphTheme.glassTint(colorScheme)))
                .overlay(
                    TriangleShape()
                        .fill(
                            LinearGradient(
                                colors: [GraphTheme.glassHighlight(colorScheme).opacity(0.30), .clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    TriangleShape()
                        .stroke(selected ? GraphTheme.editBlue : GraphTheme.stroke(colorScheme), lineWidth: selected ? 2 : 1.2)
                )
                .shadow(color: selected ? GraphTheme.editBlue.opacity(0.22) : GraphTheme.glassShadow(colorScheme), radius: 9, y: 5)
            VStack(spacing: 5) {
                Image(systemName: frictionIcon)
                    .font(.system(size: 16, weight: .medium))
                Text(shortLabel)
                    .font(.system(size: 9, weight: .medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .foregroundStyle(GraphTheme.text(colorScheme))
            .offset(y: 14)
        }
        .frame(width: 118, height: 104)
        .contentShape(TriangleShape())
    }

    private var shortLabel: String {
        switch node.friction {
        case .none: "No friction"
        case .typedPhrase: "Typed phrase"
        case .countdown: "Countdown"
        case .reasonPrompt: "Write a reason"
        case .taskChecklist: "Task checklist"
        case .timeBudget: "Time budget"
        }
    }

    private var frictionIcon: String {
        switch node.friction {
        case .none: "minus"
        case .typedPhrase: "text.cursor"
        case .countdown: "timer"
        case .reasonPrompt: "quote.bubble"
        case .taskChecklist: "checklist"
        case .timeBudget: "hourglass"
        }
    }
}
