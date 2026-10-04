import AppKit
import SwiftUI
import IntentCore
import IntentLock

extension NSScreen {
    var intentDisplayID: CGDirectDisplayID? { deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID }
    func intentNotchLayout(checklistCount: Int = 0, expanded: Bool = false) -> SessionNotchLayout {
        SessionNotchLayout(screen: frame, visibleFrame: visibleFrame, safeAreaTop: safeAreaInsets.top,
            auxiliaryLeft: auxiliaryTopLeftArea, auxiliaryRight: auxiliaryTopRightArea,
            checklistCount: checklistCount, checklistExpanded: expanded)
    }
}

/// Mouse-only checkboxes never make this panel (or Intent) the active application.
final class SessionNotchPanel: IntentInteractivePanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    static func make() -> SessionNotchPanel {
        let panel = SessionNotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.isMovable = false; panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true; panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }
}

struct SessionNotchView: View {
    @ObservedObject var model: IntentAppModel
    let layout: SessionNotchLayout
    var body: some View {
        if model.activeSessionEndsAt != nil || model.stopwatchStarted != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in content(now: context.date) }
        } else { content(now: .now) }
    }
    private func content(now: Date) -> SessionNotchContent {
        let showsEnd = SessionTimerFormatter.showsAbsoluteEnd(model.activeSessionAbsoluteEndTime, effectiveEnd: model.activeSessionEndsAt)
        return SessionNotchContent(title: model.activeSessionName ?? "intention", mode: model.activeSessionAccessMode,
            time: (showsEnd ? model.activeSessionAbsoluteEndTime?.formatted(date: .omitted, time: .shortened) : nil)
                ?? model.activeSessionEndsAt.map { SessionTimerFormatter.countdownText(until: $0, now: now) }
                ?? (model.stopwatchStarted == nil ? nil : model.stopwatchText),
            timeLabel: showsEnd ? "Ends at" : (model.stopwatchStarted != nil && model.activeSessionEndsAt == nil ? "Elapsed" : "Remaining"),
            checklist: model.activeChecklist, completed: model.completedChecklist, layout: layout,
            toggleChecklist: model.toggleSessionControlsExpansion,
            setCompleted: model.setTaskCompleted)
    }
}

/// Data-only content makes the real HUD renderable in isolated regression checks.
struct SessionNotchContent: View {
    let title: String
    let mode: IntentionAccessMode
    let time: String?
    let timeLabel: String
    let checklist: [String]
    let completed: Set<Int>
    let layout: SessionNotchLayout
    var toggleChecklist: () -> Void = {}
    var setCompleted: (Int, Bool) -> Void = { _, _ in }
    private var accent: Color { mode == .blacklist ? .red : .green }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 7) {
                    Circle().fill(accent).frame(width: 7, height: 7)
                        .shadow(color: accent.opacity(0.6), radius: 4)
                    Text(mode == .blacklist ? "BLOCK" : "FOCUS")
                        .font(.system(size: 8, weight: .semibold)).tracking(1).foregroundStyle(.white.opacity(0.6))
                }.frame(width: layout.wingWidth, height: layout.headerHeight)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(mode == .blacklist ? "Blacklist intention" : "Whitelist intention")
                Color.clear.frame(width: layout.notchWidth, height: layout.headerHeight).allowsHitTesting(false)
                VStack(spacing: 1) {
                    if let time {
                        Text(time).font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit()
                            .accessibilityLabel("\(timeLabel) \(time)")
                    }
                    if !checklist.isEmpty {
                        Button(action: toggleChecklist) {
                            HStack(spacing: 5) {
                                Image(systemName: "checkmark.circle").foregroundStyle(accent)
                                Text("\(completed.count)/\(checklist.count)").monospacedDigit()
                            }.font(.system(size: time == nil ? 12 : 9, weight: .medium))
                        }.buttonStyle(.plain)
                            .accessibilityLabel("\(completed.count) of \(checklist.count) tasks complete. Toggle checklist")
                    }
                }.frame(width: layout.wingWidth, height: layout.headerHeight)
            }
            Group {
                if checklist.isEmpty { titleLabel }
                else {
                    Button(action: toggleChecklist) {
                        HStack(spacing: 7) {
                            titleLabel
                            Image(systemName: layout.checklistHeight > 0 ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
                        }
                    }.buttonStyle(.plain).accessibilityLabel("\(title). Toggle checklist")
                }
            }.frame(width: layout.notchWidth + 24, height: layout.titleHeight)
            if layout.checklistHeight > 0 {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(checklist.enumerated()), id: \.offset) { index, task in
                            Button { setCompleted(index, !completed.contains(index)) } label: {
                                HStack(alignment: .center, spacing: 10) {
                                    Image(systemName: completed.contains(index) ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 16)).foregroundStyle(completed.contains(index) ? accent : .white.opacity(0.35))
                                    Text(task).font(.system(size: 12)).lineLimit(2)
                                        .strikethrough(completed.contains(index))
                                        .foregroundStyle(.white.opacity(completed.contains(index) ? 0.45 : 0.9))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }.padding(.horizontal, 20).frame(height: 44).contentShape(Rectangle())
                            }.buttonStyle(.plain).help(task)
                                .accessibilityLabel("\(task), \(completed.contains(index) ? "complete" : "incomplete")")
                        }
                    }.padding(.vertical, 10)
                }.frame(height: layout.checklistHeight)
            }
        }.frame(width: layout.frame.width, height: layout.frame.height, alignment: .top)
            .background(SessionNotchSilhouette(layout: layout).fill(.black))
            .foregroundStyle(.white).preferredColorScheme(.dark)
            .help("` hide or show running controls")
    }
    private var titleLabel: some View {
        Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
            .help(title).accessibilityLabel(title)
    }
}

/// The wings end at the camera's bottom edge; only the title branches below it.
private struct SessionNotchSilhouette: Shape {
    let layout: SessionNotchLayout
    func path(in rect: CGRect) -> Path {
        var p = Path()
        if layout.checklistHeight > 0 {
            p.addRoundedRect(in: rect, cornerSize: CGSize(width: 16, height: 16))
            p.addRect(CGRect(x: 0, y: 0, width: rect.width, height: layout.headerHeight / 2))
        } else {
            p.addRoundedRect(in: CGRect(x: 0, y: 0, width: rect.width, height: layout.headerHeight), cornerSize: CGSize(width: 12, height: 12))
            p.addRect(CGRect(x: 12, y: 0, width: rect.width - 24, height: layout.headerHeight))
            let tongue = CGRect(x: layout.wingWidth - 18, y: layout.headerHeight - 14,
                width: layout.notchWidth + 36, height: layout.titleHeight + 14)
            p.addRoundedRect(in: tongue, cornerSize: CGSize(width: 14, height: 14))
        }
        return p
    }
}
