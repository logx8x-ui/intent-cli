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

            appGrid
                .frame(width: squareSize, height: squareSize)
                .adaptiveGlassPanel(colorScheme: colorScheme, cornerRadius: 20, selected: selected)
        }
        .foregroundStyle(GraphTheme.text(colorScheme))
        .frame(width: 200, height: 190)
        .contentShape(Rectangle())
    }

    @Environment(\.colorScheme) private var colorScheme

    private var appGrid: some View {
        Group {
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
                GeometryReader { proxy in
                    let layout = appGridLayout(count: intention.allowedApps.count)
                    let spacing = CGFloat(1)
                    let cellWidth = (proxy.size.width - CGFloat(layout.columns - 1) * spacing) / CGFloat(layout.columns)
                    let cellHeight = (proxy.size.height - CGFloat(layout.rows - 1) * spacing) / CGFloat(layout.rows)

                    VStack(spacing: spacing) {
                        ForEach(0..<layout.rows, id: \.self) { row in
                            HStack(spacing: spacing) {
                                ForEach(0..<layout.columns, id: \.self) { column in
                                    let index = row * layout.columns + column
                                    if index < intention.allowedApps.count {
                                        appTile(
                                            intention.allowedApps[index],
                                            width: cellWidth,
                                            height: cellHeight
                                        )
                                    } else {
                                        Color.clear
                                            .frame(width: cellWidth, height: cellHeight)
                                    }
                                }
                            }
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .background(GraphTheme.stroke(colorScheme).opacity(0.55))
                }
            }
        }
    }

    private func appTile(_ app: AllowedApp, width: CGFloat, height: CGFloat) -> some View {
        let websites = intention.websites(for: app.bundleIdentifier)
        let iconPadding = max(4, min(width, height) * 0.08)

        return ZStack(alignment: .bottomTrailing) {
            Group {
                if let installed = installedApps.first(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
                    Image(nsImage: installed.icon)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: app.isBrowser ? "globe" : "app")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(GraphTheme.text(colorScheme).opacity(0.82))
                }
            }
            .padding(iconPadding)
            .frame(width: width, height: height)

            if app.isBrowser, !websites.isEmpty {
                websiteIndicator(count: websites.count)
                    .padding(max(3, min(width, height) * 0.055))
                    .help(websites.map(\.displayName).joined(separator: ", "))
            }
        }
        .frame(width: width, height: height)
        .background(GraphTheme.surface(colorScheme))
        .clipped()
        .help(app.name)
    }

    private func websiteIndicator(count: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "globe")
                .font(.system(size: 7.5, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 8, weight: .bold, design: .rounded))
        }
        .foregroundStyle(GraphTheme.text(colorScheme).opacity(0.90))
        .padding(.horizontal, 5)
        .frame(height: 17)
        .background(.ultraThinMaterial, in: Capsule())
        .background(GraphTheme.glassTint(colorScheme), in: Capsule())
        .overlay(Capsule().stroke(GraphTheme.glassHighlight(colorScheme).opacity(0.45), lineWidth: 0.7))
        .shadow(color: GraphTheme.glassShadow(colorScheme).opacity(0.65), radius: 4, y: 2)
        .allowsHitTesting(false)
    }

    private func appGridLayout(count: Int) -> (columns: Int, rows: Int) {
        let columns = max(1, Int(ceil(sqrt(Double(max(count, 1))))))
        let rows = max(1, Int(ceil(Double(max(count, 1)) / Double(columns))))
        return (columns, rows)
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
