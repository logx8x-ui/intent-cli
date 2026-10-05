import AppKit
import IntentCore
import SwiftUI

enum QuickSelectionOptionsSection: String, CaseIterable {
    case timer = "Timer", checklist = "Checklist", searches = "Tab searches", cooldown = "Cooldown", addAsYouGo = "Add as you go", stopwatch = "Stopwatch"
    static var ordered: [Self] {
        let stored = UserDefaults.standard.stringArray(forKey: "quickModificationOrder") ?? []
        return SessionModificationOrder.migrated(stored: stored, available: allCases.map(\.rawValue)).compactMap(Self.init(rawValue:))
    }
    func enable(in selection: inout QuickSelection, defaults: UserDefaults = .standard) {
        guard !enabled(in: selection) else { return }
        switch self {
        case .addAsYouGo: selection.restrictionNodes.append(.init(kind: .addAsYouGo, position: .zero))
        case .stopwatch: selection.restrictionNodes.append(.init(kind: .stopwatch, position: .zero))
        case .timer: selection.restrictionNodes.append(.init(kind: .timer, position: .init(x: 240, y: 260), durationMinutes: QuickSelectionPreferences.timerDuration(defaults: defaults), showsRemainingTime: true, locksSessionUntilTimerEnds: true))
        case .checklist: selection.frictionNodes.append(.init(friction: .taskChecklist([""]), position: .init(x: -240, y: 260)))
        case .searches: selection.restrictionNodes.append(.init(kind: .allowBrowserSearches, position: .init(x: 240, y: 390)))
        case .cooldown: selection.restrictionNodes.append(.init(kind: .coolDown, position: .init(x: 240, y: 390), durationMinutes: QuickSelectionPreferences.cooldownDuration(defaults: defaults)))
        }
    }
    func disable(in selection: inout QuickSelection) {
        switch self {
        case .addAsYouGo: selection.restrictionNodes.removeAll { $0.kind == .addAsYouGo }
        case .stopwatch: selection.restrictionNodes.removeAll { $0.kind == .stopwatch }
        case .timer: selection.restrictionNodes.removeAll { $0.kind == .timer || $0.kind == .endTime }
        case .checklist: selection.frictionNodes.removeAll { if case .taskChecklist = $0.friction { return true }; return false }
        case .searches: selection.restrictionNodes.removeAll { $0.kind == .allowBrowserSearches }
        case .cooldown: selection.restrictionNodes.removeAll { $0.kind == .coolDown }
        }
    }
    func dismissEditor(in selection: inout QuickSelection) {
        if self == .checklist { QuickSelectionChecklistEditing.dismiss(in: &selection) }
    }

    func durationSummary(in selection: QuickSelection) -> String? {
        guard self == .timer || self == .cooldown else { return nil }
        guard let node = selection.restrictionNodes.first(where: {
            self == .cooldown ? $0.kind == .coolDown : ($0.kind == .timer || $0.kind == .endTime)
        }) else { return nil }
        if node.kind == .endTime {
            let date = Calendar.current.date(bySettingHour: node.endTimeHour ?? 17,
                                             minute: node.endTimeMinute ?? 0, second: 0, of: Date()) ?? Date()
            return date.formatted(date: .omitted, time: .shortened)
        }
        let minutes = node.durationMinutes ?? (self == .cooldown ? QuickSelectionPreferences.initialCooldownDuration : QuickSelectionPreferences.initialTimerDuration)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
    var icon: String {
        switch self { case .addAsYouGo: return "plus.app"; case .stopwatch: return "stopwatch"; case .timer: return "timer"; case .checklist: return "checklist"; case .searches: return "magnifyingglass"; case .cooldown: return "hourglass" }
    }
    var hint: String {
        switch self {
        case .addAsYouGo: return "Start with only your selections, then open more apps, tabs and websites as you work. Explicit blocks still apply."
        case .stopwatch: return "Count time upwards, including while your Mac sleeps. No deadline; Timer and Checklist still decide when a locked intention finishes."
        case .timer: return "Finish after a duration or at a time you choose."
        case .checklist: return "Check off your tasks; completing them all ends the intention."
        case .searches: return "Open fresh tabs for Google searches and results during this intention. Other websites stay blocked."
        case .cooldown: return "Wait before starting this saved intention again."
        }
    }
    func enabled(in selection: QuickSelection) -> Bool {
        switch self {
        case .addAsYouGo: return selection.restrictionNodes.contains { $0.kind == .addAsYouGo }
        case .stopwatch: return selection.restrictionNodes.contains { $0.kind == .stopwatch }
        case .timer: return selection.restrictionNodes.contains { $0.kind == .timer || $0.kind == .endTime }
        case .checklist: return selection.frictionNodes.contains { if case .taskChecklist = $0.friction { return true }; return false }
        case .searches: return selection.restrictionNodes.contains { $0.kind == .allowBrowserSearches }
        case .cooldown: return selection.restrictionNodes.contains { $0.kind == .coolDown }
        }
    }
}

struct QuickSelectionOptionsView: View {
    @Binding var selection: QuickSelection
    let section: QuickSelectionOptionsSection
    let close: () -> Void
    var body: some View {
        Group {
            if section == .checklist,
               let node = selection.frictionNodes.first(where: { if case .taskChecklist = $0.friction { return true }; return false }) {
                checklistEditor(nodeID: node.id)
            } else if section == .timer || section == .cooldown,
                      let node = selection.restrictionNodes.first(where: {
                section == .cooldown ? $0.kind == .coolDown : ($0.kind == .timer || $0.kind == .endTime)
            }) {
                durationEditor(node: node)
            }
        }.padding(12).tint(selection.accessMode == .blacklist ? .red : .green)
            .background(Color(white: 0.10), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.12)))
    }

    private func durationEditor(node: RestrictionNode) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                if section == .timer {
                    timerModeButton(clock: false, nodeID: node.id)
                    timerModeButton(clock: true, nodeID: node.id)
                } else {
                    Image(systemName: "hourglass").foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Close \(section.rawValue.lowercased()) editor")
            }
            if node.kind == .endTime {
                DatePicker("End time", selection: endTimeBinding(nodeID: node.id), displayedComponents: .hourAndMinute)
                    .labelsHidden().datePickerStyle(.field)
                    .help("An earlier end time means tomorrow.")
            } else {
                QuickSelectionDurationFields(selection: $selection, nodeID: node.id, section: section,
                                             initialMinutes: QuickSelectionPreferences.configuredDuration(in: selection, nodeID: node.id, section: section))
                    .id(node.id + section.rawValue)
            }
        }.frame(width: 182)
    }

    private func checklistEditor(nodeID: String) -> some View {
        let lineCount = max(3, QuickSelectionChecklistEditing.tasks(in: selection, nodeID: nodeID).count)
        return VStack(spacing: 8) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(0..<lineCount, id: \.self) { row in
                        TextField("", text: Binding(get: {
                            let current = QuickSelectionChecklistEditing.tasks(in: selection, nodeID: nodeID)
                            return current.indices.contains(row) ? current[row] : ""
                        }, set: { QuickSelectionChecklistEditing.edit($0, row: row, in: &selection, nodeID: nodeID) }))
                            .textFieldStyle(.plain).font(.system(size: 13)).padding(.horizontal, 3).frame(height: 30)
                            .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.16)).frame(height: 1) }
                            .accessibilityLabel("Checklist line \(row + 1)")
                    }
                }
            }.frame(height: min(158, CGFloat(lineCount) * 32))
            HStack {
                Button { QuickSelectionChecklistEditing.appendRow(in: &selection, nodeID: nodeID) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add checklist line")
                Spacer()
                Button { section.disable(in: &selection); close() } label: { Image(systemName: "trash") }
                    .accessibilityLabel("Remove checklist")
            }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 3)
        }.frame(width: 252)
    }

    private func timerModeButton(clock: Bool, nodeID: String) -> some View {
        let selected = selection.restrictionNodes.first(where: { $0.id == nodeID }).map { ($0.kind == .endTime) == clock } ?? false
        return Button {
            guard let index = selection.restrictionNodes.firstIndex(where: { $0.id == nodeID && ($0.kind == .timer || $0.kind == .endTime) }) else { return }
            selection.restrictionNodes[index].kind = clock ? .endTime : .timer
            selection.restrictionNodes[index].usesPresetEndTime = clock
            if clock && selection.restrictionNodes[index].endTimeHour == nil {
                let minutes = QuickSelectionPreferences.configuredTimerDuration(selection.restrictionNodes[index])
                setEnd(Date().addingTimeInterval(TimeInterval(minutes) * 60), nodeID: nodeID)
            }
        } label: {
            Image(systemName: clock ? "clock" : "timer").font(.system(size: 12)).frame(width: 26, height: 22)
                .background(selected ? Color.white.opacity(0.13) : .clear, in: Capsule())
        }.buttonStyle(.plain).foregroundStyle(selected ? .primary : .secondary)
            .accessibilityLabel("\(clock ? "Set end time" : "Duration"), \(selected ? "selected" : "not selected")")
            .help(clock ? "Set end time" : "Duration")
    }

    private func endTimeBinding(nodeID: String) -> Binding<Date> {
        Binding(get: {
            let node = selection.restrictionNodes.first { $0.id == nodeID && $0.kind == .endTime }
            return Calendar.current.date(bySettingHour: node?.endTimeHour ?? 17, minute: node?.endTimeMinute ?? 0, second: 0, of: Date()) ?? Date()
        }, set: { setEnd($0, nodeID: nodeID) })
    }

    private func setEnd(_ date: Date, nodeID: String) {
        guard let index = selection.restrictionNodes.firstIndex(where: { $0.id == nodeID && $0.kind == .endTime }) else { return }
        selection.restrictionNodes[index].endTimeHour = Calendar.current.component(.hour, from: date)
        selection.restrictionNodes[index].endTimeMinute = Calendar.current.component(.minute, from: date)
    }
}

private struct QuickSelectionDurationFields: View {
    @Binding var selection: QuickSelection
    let nodeID: String
    let section: QuickSelectionOptionsSection
    @State private var draft: QuickSelectionDurationDraft
    @FocusState private var focus: Component?
    private enum Component: Hashable { case hours, minutes }

    init(selection: Binding<QuickSelection>, nodeID: String, section: QuickSelectionOptionsSection, initialMinutes: Int) {
        _selection = selection; self.nodeID = nodeID; self.section = section
        _draft = State(initialValue: .init(totalMinutes: initialMinutes))
    }

    var body: some View {
        HStack(spacing: 9) {
            field(.hours, label: "Hours")
            Text("h").foregroundStyle(.secondary)
            field(.minutes, label: "Minutes")
            Text("m").foregroundStyle(.secondary)
        }.font(.system(size: 14, weight: .medium, design: .rounded)).monospacedDigit()
            .onChange(of: focus) { value in
                if value == nil {
                    draft = .init(totalMinutes: QuickSelectionPreferences.configuredDuration(in: selection, nodeID: nodeID, section: section))
                }
            }
    }

    private func field(_ component: Component, label: String) -> some View {
        TextField("", text: Binding(get: { component == .hours ? draft.hours : draft.minutes }, set: { text in
            if component == .hours { draft.hours = text } else { draft.minutes = text }
            QuickSelectionPreferences.editDurationDraft(draft, in: &selection, nodeID: nodeID, section: section)
        })).textFieldStyle(.plain).multilineTextAlignment(.center).frame(width: 39, height: 29)
            .background(.white.opacity(0.06), in: Capsule()).focused($focus, equals: component)
            .accessibilityLabel("\(section.rawValue) \(label.lowercased())")
    }
}
