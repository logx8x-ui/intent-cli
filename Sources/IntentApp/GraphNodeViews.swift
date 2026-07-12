import SwiftUI
import IntentCore

struct IntentionNodeView: View {
    let intention: Intention
    let installedApps: [InstalledApp]
    let selected: Bool
    let editMode: Bool
    let onConnectionChanged: (CGPoint) -> Void
    let onConnectionEnded: (CGPoint) -> Void

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
                    .background(GraphTheme.surface(colorScheme))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(selected ? GraphTheme.editBlue : GraphTheme.stroke(colorScheme), lineWidth: selected ? 2 : 1.2)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                websiteSpikes
                    .allowsHitTesting(false)

                if editMode {
                    connectorHandle
                        .offset(x: squareSize / 2 + 9)
                }
            }
            .frame(width: 188, height: 172)
        }
        .foregroundStyle(GraphTheme.text(colorScheme))
        .frame(width: 200, height: 205)
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
                    VStack(spacing: 8) {
                        appIcon(app, appCount: intention.allowedApps.count)
                        Text(app.name)
                            .font(.system(size: intention.allowedApps.count > 3 ? 8 : 9))
                            .foregroundStyle(GraphTheme.muted(colorScheme))
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)
                            .padding(.horizontal, 3)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    private func appIcon(_ app: AllowedApp, appCount: Int) -> some View {
        let size = max(CGFloat(22), min(CGFloat(42), 88 / CGFloat(max(appCount, 1))))
        if let installed = installedApps.first(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
            Image(nsImage: installed.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: app.isBrowser ? "globe" : "app")
                .font(.system(size: size * 0.7))
                .frame(width: size, height: size)
        }
    }

    private var websiteSpikes: some View {
        Canvas { context, size in
            guard !intention.allowedApps.isEmpty else { return }
            let sliceWidth = squareSize / CGFloat(intention.allowedApps.count)
            let squareOriginX = (size.width - squareSize) / 2
            let squareBottom = size.height / 2 + squareSize / 2

            for (appIndex, app) in intention.allowedApps.enumerated() where app.isBrowser {
                let websites = intention.websites(for: app.bundleIdentifier)
                let centerX = squareOriginX + sliceWidth * (CGFloat(appIndex) + 0.5)
                for websiteIndex in websites.indices {
                    let spread = CGFloat(websiteIndex) - CGFloat(websites.count - 1) / 2
                    let x = centerX + spread * 9
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: squareBottom - 1))
                    path.addLine(to: CGPoint(x: x + spread * 2, y: squareBottom + 15 + abs(spread) * 3))
                    context.stroke(path, with: .color(GraphTheme.text(colorScheme).opacity(0.72)), lineWidth: 1.2)
                    context.fill(
                        Path(ellipseIn: CGRect(x: x + spread * 2 - 2, y: squareBottom + 13 + abs(spread) * 3, width: 4, height: 4)),
                        with: .color(GraphTheme.text(colorScheme).opacity(0.9))
                    )
                }
            }
        }
        .frame(width: 188, height: 172)
    }

    private var connectorHandle: some View {
        Circle()
            .fill(GraphTheme.editBlue)
            .frame(width: 12, height: 12)
            .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 1))
            .shadow(color: GraphTheme.editBlue.opacity(0.5), radius: 5)
            .help("Drag to add a restriction or friction")
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("graphViewport"))
                    .onChanged { onConnectionChanged($0.location) }
                    .onEnded { onConnectionEnded($0.location) }
            )
    }
}

struct RestrictionNodeView: View {
    let node: RestrictionNode
    let selected: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Circle()
                .fill(GraphTheme.surface(colorScheme))
                .overlay(
                    Circle()
                        .stroke(selected ? GraphTheme.editBlue : GraphTheme.stroke(colorScheme), lineWidth: selected ? 2 : 1.2)
                )
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
                .fill(GraphTheme.surface(colorScheme))
                .overlay(
                    TriangleShape()
                        .stroke(selected ? GraphTheme.editBlue : GraphTheme.stroke(colorScheme), lineWidth: selected ? 2 : 1.2)
                )
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
