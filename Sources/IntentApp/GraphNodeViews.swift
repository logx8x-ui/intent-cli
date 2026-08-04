import SwiftUI
import IntentCore

struct IntentionNodeView: View {
    let intention: Intention
    let installedApps: [InstalledApp]
    let selected: Bool
    let cooldownExpiresAt: Date?

    private let squareSize: CGFloat = 148

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(intention.name)
                    .lineLimit(1)

                if intention.isLeisure {
                    Label("LEISURE", systemImage: "sun.horizon.fill")
                        .font(.system(size: 7.5, weight: .bold, design: .rounded))
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(
                            Capsule()
                                .stroke(leisureGradient.opacity(0.72), lineWidth: 0.8)
                        )
                }
            }
            .font(.system(size: 14, weight: .semibold))
            .frame(maxWidth: 190)

            ZStack {
                if intention.isLeisure {
                    RoundedRectangle(cornerRadius: 25)
                        .fill(leisureGradient)
                        .frame(width: squareSize + 16, height: squareSize + 16)
                        .blur(radius: 13)
                        .opacity(colorScheme == .dark ? 0.38 : 0.28)
                        .allowsHitTesting(false)
                }

                intentionArtwork
                    .frame(width: squareSize, height: squareSize)
                    .adaptiveGlassPanel(colorScheme: colorScheme, cornerRadius: 20, selected: selected)

                if intention.isLeisure {
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(leisureGradient, lineWidth: selected ? 2.4 : 1.5)
                        .frame(width: squareSize, height: squareSize)
                        .allowsHitTesting(false)
                }

                if intention.showsCooldownRemainingTime, let cooldownExpiresAt {
                    CooldownBadge(expiresAt: cooldownExpiresAt)
                        .frame(width: squareSize - 10, height: squareSize - 10)
                }
            }
        }
        .foregroundStyle(GraphTheme.text(colorScheme))
        .frame(width: 200, height: 190)
        .contentShape(Rectangle())
    }

    @Environment(\.colorScheme) private var colorScheme

    private var leisureGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color.cyan.opacity(0.88),
                Color.white.opacity(colorScheme == .dark ? 0.72 : 0.92),
                Color.orange.opacity(0.82)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    @ViewBuilder
    private var intentionArtwork: some View {
        if intention.usesCustomIcon {
            if let data = intention.customIconData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                ZStack {
                    GraphTheme.elevatedSurface(colorScheme)
                    Image(systemName: intention.icon)
                        .resizable()
                        .scaledToFit()
                        .padding(34)
                        .foregroundStyle(GraphTheme.text(colorScheme))
                }
            }
        } else {
            appGrid
        }
    }

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

        return ZStack(alignment: .bottomTrailing) {
            Group {
                if let installed = installedApps.first(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
                    Image(nsImage: installed.icon)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(1.34)
                } else {
                    Image(systemName: app.isBrowser ? "globe" : "app")
                        .resizable()
                        .scaledToFit()
                        .padding(max(8, min(width, height) * 0.18))
                        .foregroundStyle(GraphTheme.text(colorScheme).opacity(0.82))
                }
            }
            .frame(width: width, height: height)
            .clipped()

            if app.isBrowser, !websites.isEmpty {
                websiteIndicator(count: websites.count)
                    .padding(max(3, min(width, height) * 0.055))
                    .help(websites.map(\.displayName).joined(separator: ", "))
            }
        }
        .frame(width: width, height: height)
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
                .overlay(
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    GraphTheme.glassHighlight(colorScheme).opacity(0.22),
                                    GraphTheme.glassTint(colorScheme),
                                    Color.black.opacity(colorScheme == .dark ? 0.18 : 0.03)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    Circle()
                        .inset(by: 7)
                        .stroke(GraphTheme.glassHighlight(colorScheme).opacity(0.14), lineWidth: 1)
                )
                .overlay {
                    Circle()
                        .trim(from: 0.58, to: 0.89)
                        .stroke(
                            GraphTheme.glassHighlight(colorScheme).opacity(0.48),
                            style: StrokeStyle(lineWidth: 1.4, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-18))
                        .padding(2)
                }
                .overlay(
                    Circle()
                        .stroke(selected ? GraphTheme.editBlue : GraphTheme.stroke(colorScheme), lineWidth: selected ? 2 : 1)
                )
                .shadow(color: selected ? GraphTheme.editBlue.opacity(0.25) : GraphTheme.glassShadow(colorScheme), radius: 12, y: 7)

            VStack(spacing: 4) {
                if let durationLabel {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: restrictionIcon)
                            .font(.system(size: 12, weight: .semibold))
                        Text(durationLabel)
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                    .frame(height: 34)
                } else {
                    ZStack {
                        Circle()
                            .fill(GraphTheme.elevatedSurface(colorScheme))
                            .overlay(Circle().stroke(GraphTheme.glassHighlight(colorScheme).opacity(0.22), lineWidth: 0.8))
                        Image(systemName: restrictionIcon)
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .frame(width: 31, height: 31)
                }

                Text("RESTRICTION")
                    .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                    .tracking(0.9)
                    .foregroundStyle(GraphTheme.muted(colorScheme))

                Text(restrictionTitle)
                    .font(.system(size: 10, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineSpacing(-1)
            }
            .foregroundStyle(GraphTheme.text(colorScheme))
        }
        .frame(width: 116, height: 116)
        .contentShape(Circle())
    }

    private var restrictionIcon: String {
        switch node.kind {
        case .allowBrowserSearches: "magnifyingglass"
        case .dontStartUp: "poweroff"
        case .coolDown: "hourglass"
        case .timer: "timer"
        case .endTime: "clock.badge.checkmark"
        }
    }

    private var restrictionTitle: String {
        switch node.kind {
        case .allowBrowserSearches: "Browser\nsearches"
        case .dontStartUp: "Don't\nstart up"
        case .coolDown: "Cooldown"
        case .timer: "Timer"
        case .endTime: "End Time"
        }
    }

    private var durationLabel: String? {
        if node.kind == .endTime {
            guard node.usesPresetEndTime ?? false else {
                return "Choose at start"
            }
            let hour = min(max(node.endTimeHour ?? 17, 0), 23)
            let minute = min(max(node.endTimeMinute ?? 0, 0), 59)
            let date = Calendar.autoupdatingCurrent.date(
                bySettingHour: hour,
                minute: minute,
                second: 0,
                of: Date()
            ) ?? Date()
            return date.formatted(date: .omitted, time: .shortened)
        }
        guard node.kind == .timer || node.kind == .coolDown else { return nil }
        let minutes = max(1, node.durationMinutes ?? (node.kind == .timer ? 25 : 30))
        if minutes >= 1_440, minutes % 1_440 == 0 {
            return "\(minutes / 1_440)d"
        }
        if minutes >= 60, minutes % 60 == 0 {
            return "\(minutes / 60)h"
        }
        if minutes >= 60 {
            return "\(minutes / 60)h\(minutes % 60)m"
        }
        return "\(minutes)m"
    }
}

private struct CooldownBadge: View {
    let expiresAt: Date

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if expiresAt > context.date {
                VStack(spacing: 5) {
                    Image(systemName: "hourglass")
                        .font(.system(size: 14, weight: .semibold))
                    Text(remainingText(at: context.date))
                        .font(.system(size: 35, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("COOLDOWN")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(GraphTheme.muted(colorScheme))
                }
                .foregroundStyle(GraphTheme.text(colorScheme))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .background(GraphTheme.elevatedSurface(colorScheme).opacity(0.88), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .stroke(GraphTheme.glassHighlight(colorScheme).opacity(0.68), lineWidth: 1)
                )
                .shadow(color: GraphTheme.glassShadow(colorScheme), radius: 10, y: 5)
            }
        }
        .allowsHitTesting(false)
    }

    private func remainingText(at date: Date) -> String {
        let minutes = max(1, Int(ceil(expiresAt.timeIntervalSince(date) / 60)))
        if minutes >= 1_440 {
            return "\(Int(ceil(Double(minutes) / 1_440)))d"
        }
        if minutes >= 60 {
            return "\(Int(ceil(Double(minutes) / 60)))h"
        }
        return "\(minutes)m"
    }
}

struct FrictionNodeView: View {
    let node: FrictionNode
    let selected: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            RoundedTriangleShape(cornerRadius: 13)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedTriangleShape(cornerRadius: 13)
                        .fill(
                            LinearGradient(
                                colors: [
                                    GraphTheme.glassHighlight(colorScheme).opacity(0.22),
                                    GraphTheme.glassTint(colorScheme),
                                    Color.black.opacity(colorScheme == .dark ? 0.20 : 0.04)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    RoundedTriangleShape(cornerRadius: 11)
                        .stroke(GraphTheme.glassHighlight(colorScheme).opacity(0.13), lineWidth: 1)
                        .scaleEffect(0.84)
                        .offset(y: 6)
                )
                .overlay(
                    RoundedTriangleShape(cornerRadius: 13)
                        .stroke(selected ? GraphTheme.editBlue : GraphTheme.stroke(colorScheme), lineWidth: selected ? 2 : 1)
                )
                .shadow(color: selected ? GraphTheme.editBlue.opacity(0.25) : GraphTheme.glassShadow(colorScheme), radius: 12, y: 7)

            VStack(spacing: 3) {
                ZStack {
                    Circle()
                        .fill(GraphTheme.elevatedSurface(colorScheme))
                        .overlay(Circle().stroke(GraphTheme.glassHighlight(colorScheme).opacity(0.22), lineWidth: 0.8))
                    Image(systemName: frictionIcon)
                        .font(.system(size: 14, weight: .semibold))
                }
                .frame(width: 29, height: 29)

                Text("FRICTION")
                    .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                    .tracking(0.9)
                    .foregroundStyle(GraphTheme.muted(colorScheme))

                Text(shortLabel)
                    .font(.system(size: 9.5, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .foregroundStyle(GraphTheme.text(colorScheme))
            .offset(y: 17)
        }
        .frame(width: 126, height: 112)
        .contentShape(RoundedTriangleShape(cornerRadius: 13))
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
