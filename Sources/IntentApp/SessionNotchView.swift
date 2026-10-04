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

    /// Replacing NSWindow.contentViewController can resize and reposition its
    /// window. The physical notch anchor must be applied after that assignment,
    /// and SwiftUI content updates must never negotiate a different window size.
    static func setHostedContent<Content: View>(_ content: Content, in panel: NSPanel, frame: CGRect) {
        let host = NSHostingController(rootView: content)
        host.sizingOptions = []
        host.view.frame = CGRect(origin: .zero, size: frame.size)
        host.view.autoresizingMask = [.width, .height]
        panel.contentViewController = host
        host.view.layoutSubtreeIfNeeded()
        panel.setFrame(frame, display: panel.isVisible)
    }

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
    var slice: SessionNotchSlice = .whole
    var body: some View {
        if (model.activeSessionEndsAt != nil || model.stopwatchStarted != nil)
            && !(slice == .controls && layout.hasHardwareNotch) {
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
            slice: slice,
            toggleChecklist: model.toggleSessionControlsExpansion,
            setCompleted: model.setTaskCompleted)
    }
}

enum SessionNotchSlice { case whole, header, controls }

/// Data-only content makes the real HUD renderable in isolated regression checks.
struct SessionNotchContent: View {
    let title: String
    let mode: IntentionAccessMode
    let time: String?
    let timeLabel: String
    let checklist: [String]
    let completed: Set<Int>
    let layout: SessionNotchLayout
    var slice: SessionNotchSlice = .whole
    var toggleChecklist: () -> Void = {}
    var setCompleted: (Int, Bool) -> Void = { _, _ in }
    private var accent: Color { Color(nsColor: SessionChromeStyle.accent(for: mode)) }
    @ViewBuilder var body: some View {
        switch slice {
        case .whole: chrome
        case .header:
            chrome.frame(height: layout.headerHeight, alignment: .top).clipped()
        case .controls:
            let crop = layout.controlsCrop
            chrome.offset(x: -crop.minX, y: -crop.minY)
                .frame(width: crop.width, height: crop.height, alignment: .topLeading).clipped()
        }
    }
    private var chrome: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Circle().fill(accent).frame(width: 5, height: 5)
                    .frame(width: layout.leadingWingWidth, height: layout.headerHeight)
                    .accessibilityLabel(mode == .blacklist ? "Blacklist intention" : "Whitelist intention")
                Group {
                    if layout.hasHardwareNotch { Color.clear.allowsHitTesting(false) }
                    else { nameControl }
                }.frame(width: layout.notchWidth, height: layout.headerHeight)
                Group {
                    if let time {
                        Text(time).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                            .accessibilityLabel("\(timeLabel) \(time)")
                    } else if !checklist.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(accent)
                            Text("\(completed.count)/\(checklist.count)").monospacedDigit()
                        }.accessibilityLabel("\(completed.count) of \(checklist.count) tasks complete")
                    }
                }.font(.system(size: SessionChromeStyle.timingFontSize, weight: .medium))
                    .frame(width: min(SessionChromeStyle.timingContentWidth, layout.trailingWingWidth), alignment: .leading)
                    .padding(.leading, 4)
                    .frame(width: layout.trailingWingWidth, height: layout.headerHeight, alignment: .leading)
            }.accessibilityHidden(slice == .controls && layout.hasHardwareNotch)
            if layout.hasHardwareNotch {
                nameControl.frame(width: layout.notchWidth, height: layout.titleHeight)
                    .frame(width: layout.frame.width, alignment: .leading).offset(x: layout.leadingWingWidth)
                    .accessibilityHidden(slice == .header)
            }
            if layout.checklistHeight > 0 {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(checklist.enumerated()), id: \.offset) { index, task in
                            Button { setCompleted(index, !completed.contains(index)) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: completed.contains(index) ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 13)).foregroundStyle(completed.contains(index) ? accent : .white.opacity(0.35))
                                    Text(task).font(.system(size: 11)).lineLimit(2)
                                        .strikethrough(completed.contains(index))
                                        .foregroundStyle(.white.opacity(completed.contains(index) ? 0.45 : 0.88))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }.padding(.horizontal, 14).frame(height: 34).contentShape(Rectangle())
                            }.buttonStyle(.plain).help(task)
                                .accessibilityLabel("\(task), \(completed.contains(index) ? "complete" : "incomplete")")
                        }
                    }.padding(.vertical, 6)
                }.frame(height: layout.checklistHeight).accessibilityHidden(slice == .header)
            }
        }.frame(width: layout.frame.width, height: layout.frame.height, alignment: .top)
            .background(SessionNotchSilhouette(layout: layout).fill(
                LinearGradient(colors: [Color(white: 0.005), Color(white: 0.045)], startPoint: .top, endPoint: .bottom)))
            .foregroundStyle(.white.opacity(0.92)).preferredColorScheme(.dark)
            .help("` hide or show running controls")
    }
    @ViewBuilder private var nameControl: some View {
        if checklist.isEmpty { titleLabel.padding(.horizontal, 8) }
        else {
            Button(action: toggleChecklist) {
                HStack(spacing: 5) {
                    titleLabel
                    if time != nil {
                        Text("\(completed.count)/\(checklist.count)").font(.system(size: 9)).monospacedDigit().foregroundStyle(accent)
                    }
                    Image(systemName: layout.checklistHeight > 0 ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
                }.padding(.horizontal, 8).frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("\(title). Toggle checklist")
        }
    }
    private var titleLabel: some View {
        Text(title).font(.system(size: SessionChromeStyle.titleFontSize, weight: .medium))
            .foregroundStyle(.white.opacity(0.65)).lineLimit(1).truncationMode(.middle)
            .help(title).accessibilityLabel(title)
    }
}

/// The wings end at the camera's bottom edge; only the title branches below it.
struct SessionNotchSilhouette: Shape {
    let layout: SessionNotchLayout
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let h = layout.headerHeight, w = rect.width, bottom = rect.height
        let left = layout.leadingWingWidth, right = left + layout.notchWidth
        p.move(to: .zero); p.addLine(to: CGPoint(x: w, y: 0))
        p.addQuadCurve(to: CGPoint(x: w - 3, y: 4), control: CGPoint(x: w - 2, y: 0))
        if layout.checklistHeight > 0 {
            p.addLine(to: CGPoint(x: w, y: h + 8))
            p.addLine(to: CGPoint(x: w, y: bottom - 10))
            p.addQuadCurve(to: CGPoint(x: w - 10, y: bottom), control: CGPoint(x: w, y: bottom))
            p.addLine(to: CGPoint(x: 10, y: bottom))
            p.addQuadCurve(to: CGPoint(x: 0, y: bottom - 10), control: CGPoint(x: 0, y: bottom))
            p.addLine(to: CGPoint(x: 0, y: h + 8))
        } else if layout.hasHardwareNotch {
            p.addLine(to: CGPoint(x: w - 7, y: h - 5))
            p.addQuadCurve(to: CGPoint(x: w - 12, y: h), control: CGPoint(x: w - 8, y: h))
            p.addLine(to: CGPoint(x: right + 4, y: h))
            p.addQuadCurve(to: CGPoint(x: right, y: h + 4), control: CGPoint(x: right, y: h))
            p.addLine(to: CGPoint(x: right, y: bottom - 6))
            p.addQuadCurve(to: CGPoint(x: right - 6, y: bottom), control: CGPoint(x: right, y: bottom))
            p.addLine(to: CGPoint(x: left + 6, y: bottom))
            p.addQuadCurve(to: CGPoint(x: left, y: bottom - 6), control: CGPoint(x: left, y: bottom))
            p.addLine(to: CGPoint(x: left, y: h + 4))
            p.addQuadCurve(to: CGPoint(x: left - 4, y: h), control: CGPoint(x: left, y: h))
            p.addLine(to: CGPoint(x: 16, y: h))
            p.addQuadCurve(to: CGPoint(x: 11, y: h - 5), control: CGPoint(x: 12, y: h))
        } else {
            p.addLine(to: CGPoint(x: w - 6, y: bottom - 5))
            p.addQuadCurve(to: CGPoint(x: w - 12, y: bottom), control: CGPoint(x: w - 7, y: bottom))
            p.addLine(to: CGPoint(x: 12, y: bottom))
            p.addQuadCurve(to: CGPoint(x: 6, y: bottom - 5), control: CGPoint(x: 7, y: bottom))
        }
        p.addLine(to: CGPoint(x: 3, y: 4))
        p.addQuadCurve(to: .zero, control: CGPoint(x: 2, y: 0)); p.closeSubpath()
        return p
    }
}
