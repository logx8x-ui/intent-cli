import AppKit
import SwiftUI
import IntentCore
import UniformTypeIdentifiers

struct IntentOptionalNameBar: View {
    @Binding var name: String
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil.line").font(.system(size: 13)).foregroundStyle(.white.opacity(0.65))
            TextField("Name your intention", text: $name)
                .textFieldStyle(.plain).font(.system(size: 17, weight: .medium, design: .serif))
                .focused($focused).onSubmit { focused = false }
                .accessibilityLabel("Name your intention, optional")
            if !name.isEmpty {
                Button { name = ""; focused = false } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.plain).accessibilityLabel("Clear optional name")
            } else { Text("optional").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)) }
        }.padding(.horizontal, 17).frame(height: 38)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(focused ? 0.5 : 0.22), lineWidth: 1))
    }
}

struct IntentionFramePreference: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}
extension View {
    func intentionFrame(_ id: String) -> some View {
        background(GeometryReader { geometry in Color.clear.preference(key: IntentionFramePreference.self,
            value: [id: geometry.frame(in: .named("IntentOverview"))]) })
    }
}

struct IntentSavedSlotsView: View {
    @ObservedObject var controller: QuickSelectionController
    @ObservedObject var model: IntentAppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragged: String?
    @State private var dragOffset: CGFloat = 0
    var body: some View {
        HStack(spacing: 10) {
            if controller.savedSlotPages > 1 {
                Button { controller.savedSlotPage = max(0, controller.savedSlotPage - 1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain).disabled(controller.savedSlotPage == 0).accessibilityLabel("Previous saved intentions")
            }
            ForEach(Array(controller.visibleSavedSlots.enumerated()), id: \.element.id) { index, intention in
                Button { controller.runSavedSlot(index) } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 5) {
                            ForEach(Array(intention.allowedApps.filter { app in !model.isAlwaysAllowed(app.bundleIdentifier) && !model.alwaysBlockedApps.contains(where: { $0.bundleIdentifier == app.bundleIdentifier }) }.prefix(3)), id: \.bundleIdentifier) { app in
                                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 22, height: 22)
                                }
                            }
                            Spacer(minLength: 0)
                            Color.clear.frame(width: 16, height: 20)
                        }
                        Text(intention.name).font(.system(size: 12, weight: .medium)).lineLimit(2)
                            .opacity(intention.nameIsAutomatic ? 0.6 : 1).padding(.trailing, 15).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(12).frame(width: 126, height: 88, alignment: .topLeading)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(controller.saveFlight?.savedID == intention.id ? 0.8 : 0.2)))
                        .contentShape(RoundedRectangle(cornerRadius: 16))
                }.buttonStyle(.plain).help("\(intention.name) · \(index + 1) to run · drag to reorder")
                    .accessibilityLabel("Saved intention \(index + 1), \(intention.name)")
                    .disabled(controller.closing)
                    .overlay(alignment: .topTrailing) {
                        Button {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { model.deleteIntention(id: intention.id) }
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 24, height: 24)
                        }.buttonStyle(.plain).padding(4).accessibilityLabel("Delete saved intention " + intention.name)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Text("\(index + 1)").font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.65)).padding(10).allowsHitTesting(false)
                    }
                    .intentionFrame("slot:" + intention.id)
                    .offset(x: dragged == intention.id ? dragOffset : 0).zIndex(dragged == intention.id ? 1 : 0)
                    .highPriorityGesture(DragGesture(minimumDistance: 10)
                        .onChanged { value in dragged = intention.id; dragOffset = value.translation.width }
                        .onEnded { value in
                            let slots = controller.visibleSavedSlots
                            let destination = min(slots.count - 1, max(0, index + Int((value.translation.width / 136).rounded())))
                            if slots.indices.contains(destination) {
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.4)) { model.moveSlot(intention.id, to: slots[destination].id) }
                            }
                            dragged = nil; dragOffset = 0
                        })
                    .contextMenu {
                        Button("Review workspace") { controller.prepare(intention, workspace: model.journal.workspaces[intention.id]) }
                        Button("Remove saved intention") { model.deleteIntention(id: intention.id) }
                    }
            }
            if controller.savedSlotPages > 1 {
                Button { controller.savedSlotPage = min(controller.savedSlotPages - 1, controller.savedSlotPage + 1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain).disabled(controller.savedSlotPage >= controller.savedSlotPages - 1)
                    .accessibilityLabel("Next saved intentions")
                    .help("Page \(controller.savedSlotPage + 1) of \(controller.savedSlotPages). Numbers run the visible slots.")
            }
        }.onChange(of: model.savedSlots.count) { _ in controller.savedSlotPage = min(controller.savedSlotPage, controller.savedSlotPages - 1) }
    }
}

struct SavedIntentionFlight: View {
    let source: CGRect
    let target: CGRect
    @State private var progress: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Image(systemName: "bookmark.fill").font(.system(size: 22)).foregroundStyle(.white)
            .scaleEffect(1 - progress * 0.65).opacity(1 - progress)
            .position(x: source.midX + (target.midX - source.midX) * progress,
                      y: source.midY + (target.midY - source.midY) * progress - sin(progress * .pi) * 70)
            .allowsHitTesting(false).accessibilityHidden(true)
            .onAppear { withAnimation(reduceMotion ? .linear(duration: 0.15) : .easeInOut(duration: 0.65)) { progress = 1 } }
    }
}

struct WebsiteSelectionFlight: View {
    let label: String
    let source: CGPoint
    let target: CGPoint
    @State private var progress: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe").foregroundStyle(.green)
            Text(label).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
            ProgressView().controlSize(.small)
        }.padding(.horizontal, 14).padding(.vertical, 11).frame(width: 300)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.25)))
            .shadow(color: .black.opacity(0.2), radius: 12, y: 5)
            .scaleEffect(1 - progress * 0.12)
            .position(x: reduceMotion ? target.x : source.x + (target.x - source.x) * progress,
                      y: reduceMotion ? target.y : source.y + (target.y - source.y) * progress - sin(progress * .pi) * 60)
            .allowsHitTesting(false).accessibilityLabel("Adding website to selected tabs")
            .onAppear { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.55)) { progress = 1 } }
    }
}

struct IntentSessionNotesView: View {
    @ObservedObject var controller: QuickSelectionController
    @ObservedObject var model: IntentAppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let recovery = model.journal.recovery {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Continue \(recovery.intention.name)?").lineLimit(2)
                            Spacer()
                            Button { model.dismissRecovery() } label: { Image(systemName: "xmark") }
                                .accessibilityLabel("Dismiss interrupted intention")
                        }
                        Button("Jump back in") { controller.prepare(recovery.intention, workspace: recovery.workspace, resume: recovery) }
                    }.font(.callout)
                    Divider()
                }
                notes("Today", day: Date())
                notes("Yesterday", day: Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date())
            }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
        }.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
    private func notes(_ title: String, day: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(.headline, design: .serif))
            let records = model.journal.records(on: day)
            if records.isEmpty { Text("Nothing yet").font(.caption).foregroundStyle(.secondary) }
            ForEach(records) { record in IntentRecentRow(controller: controller, model: model, record: record) }
        }
    }
}

private struct IntentRecentRow: View {
    @ObservedObject var controller: QuickSelectionController
    @ObservedObject var model: IntentAppModel
    let record: IntentSessionRecord
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var saved: Bool { model.savedIntentionID(for: record) != nil }
    private func commit() {
        guard editing else { return }
        editing = false; focused = false
        model.renameRecord(record.id, to: draft)
    }
    var body: some View {
        HStack(alignment: .center, spacing: 7) {
            if editing {
                TextField("Name this intention", text: $draft).textFieldStyle(.plain).focused($focused)
                    .onSubmit(commit).accessibilityLabel("Rename recent intention")
                    .onChange(of: focused) { if !$0 { commit() } }
                    .onDisappear { commit() }
            } else {
                Button {
                    draft = record.intention.nameIsAutomatic ? "" : record.intention.name
                    editing = true; focused = true
                } label: {
                    Text(record.intention.name).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        .opacity(record.intention.nameIsAutomatic ? 0.5 : 1)
                }.buttonStyle(.plain).help("Click to name this intention")
            }
            Button {
                commit()
                withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.6)) { controller.saveRecent(record) }
            } label: {
                Image(systemName: saved ? "bookmark.fill" : "bookmark")
                    .foregroundStyle(saved ? .white : .white.opacity(0.7))
                    .scaleEffect(controller.saveFlight?.recordID == record.id ? 1.2 : 1)
                    .frame(width: 24, height: 26)
            }.buttonStyle(.plain).help(saved ? "Saved" : "Save as an intention")
                .accessibilityLabel(saved ? "Intention saved" : "Save intention")
                .intentionFrame("record:" + record.id.uuidString)
        }.font(.callout).contextMenu {
            Button("Review workspace") { controller.prepare(record.intention, workspace: record.workspace) }
            Button("Run again") { controller.prepare(record.intention, workspace: record.workspace, run: true) }
        }
    }
}

struct IntentWorkPeriodSettings: View {
    @ObservedObject var model: IntentAppModel
    @AppStorage("intentGentleReminder") private var reminder = false
    @State private var end = Date().addingTimeInterval(3600)
    @State private var startTime = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var endTime = Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var days: Set<Int> = [2,3,4,5,6]
    @State private var showSchedules = false
    @State private var credentialMessage: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Starting work").font(.headline)
            Toggle("Gentle hourly reminder", isOn: $reminder)
            Text("Require an intention").font(.headline)
            if model.isZeroDriftActive {
                Text(model.breakEndsAt == nil ? "Choose an intention between tasks." : "On a timed break.").font(.caption)
                HStack { Button("5-minute break") { model.takeWorkBreak() }; Button("End work period") { model.endWorkPeriod() } }
            } else {
                DatePicker("Until", selection: $end, displayedComponents: [.date, .hourAndMinute])
                HStack {
                    Button("Start until then") { model.activateZeroDrift(until: end) }
                    Button("Start indefinitely") { model.activateZeroDrift(until: .distantFuture) }
                }
            }
            DisclosureGroup("Scheduled work periods", isExpanded: $showSchedules) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        ForEach(1...7, id: \.self) { day in
                            Button(Calendar.current.shortWeekdaySymbols[day-1]) {
                                if days.contains(day) { days.remove(day) } else { days.insert(day) }
                            }.tint(days.contains(day) ? .green : .gray).buttonStyle(.bordered).controlSize(.mini)
                        }
                    }
                    DatePicker("Start", selection: $startTime, displayedComponents: .hourAndMinute)
                    DatePicker("End", selection: $endTime, displayedComponents: .hourAndMinute)
                    Button("Add schedule") {
                        var value = WorkPeriodSchedule(); value.weekdays = days
                        let cal = Calendar.current
                        value.startMinute = cal.component(.hour, from: startTime) * 60 + cal.component(.minute, from: startTime)
                        value.endMinute = cal.component(.hour, from: endTime) * 60 + cal.component(.minute, from: endTime)
                        if !days.isEmpty && value.startMinute != value.endMinute { model.addWorkSchedule(value) }
                    }.disabled(days.isEmpty || Calendar.current.isDate(startTime, equalTo: endTime, toGranularity: .minute))
                    ForEach(model.journal.workSchedules) { schedule in
                        HStack {
                            Text(schedule.weekdays.sorted().map { Calendar.current.shortWeekdaySymbols[$0-1] }.joined(separator: ", ") + String(format: " · %02d:%02d–%02d:%02d", schedule.startMinute/60, schedule.startMinute%60, schedule.endMinute/60, schedule.endMinute%60)).font(.caption)
                            Spacer(); Button("Remove") { model.removeWorkSchedule(schedule.id) }
                        }
                    }
                }.padding(.top, 8)
            }
            Text("Earlier end times mean the next day. Restart ends the current work period. Safety Stop: ⌃⌥⌘Esc.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Set up exit passcode") { IntentExitPasscode.configure() }
                Button("Reset passcode") {
                    Task { credentialMessage = await IntentExitPasscode.reset() ? "Passcode reset." : "Reset cancelled or unavailable." }
                }.disabled(model.hasActiveSession || model.isZeroDriftActive)
            }
            if let credentialMessage { Text(credentialMessage).font(.caption) }
        }.font(.callout)
    }
}

@MainActor
final class IntentGentleReminder {
    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?
    func show(start: @escaping () -> Void) {
        guard let screen = NSScreen.main else { return }
        panel?.orderOut(nil); dismissal?.cancel()
        let frame = CGRect(x: screen.visibleFrame.maxX - 350, y: screen.visibleFrame.maxY - 125, width: 330, height: 110)
        let next = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        next.isOpaque = false; next.backgroundColor = .clear; next.hidesOnDeactivate = false; next.level = .floating
        next.contentView = NSHostingView(rootView: VStack(alignment: .leading, spacing: 10) {
            Text("What did you come to do?").font(.headline)
            HStack {
                Button("Start an intention") { [weak self] in self?.hide(); start() }
                Spacer(); Button("Not now") { [weak self] in self?.hide() }
            }.font(.callout)
        }.padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18)))
        panel = next; next.orderFrontRegardless()
        dismissal = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled else { return }; self?.hide()
        }
    }
    private func hide() { panel?.orderOut(nil); panel = nil }
}
