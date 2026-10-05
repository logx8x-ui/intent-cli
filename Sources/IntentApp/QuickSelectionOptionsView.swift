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
        case .cooldown: selection.restrictionNodes.append(.init(kind: .coolDown, position: .init(x: 240, y: 390), durationMinutes: 30))
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
    @State private var startTime = Date()
    private var timerIndex: Int? { selection.restrictionNodes.firstIndex { $0.kind == .timer || $0.kind == .endTime } }
    private var checklistIndex: Int? { selection.frictionNodes.firstIndex { if case .taskChecklist = $0.friction { return true }; return false } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(section.rawValue).font(.system(size: 15, weight: .semibold)); Spacer(); Button("Done", action: close).buttonStyle(.plain) }
            Text(section.hint).font(.system(size: 12)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if section == .timer {
                    if let index = timerIndex {
                        Text("Finish when time is up; use your exit passcode to finish early.").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            timerModeButton("Duration", clock: false, index: index)
                            timerModeButton("Set end time", clock: true, index: index)
                        }
                        if selection.restrictionNodes[index].kind == .timer {
                            let timerID = selection.restrictionNodes[index].id
                            HStack {
                                TextField("Minutes", value: Binding(get: {
                                    QuickSelectionPreferences.configuredTimerDuration(in: selection, nodeID: timerID)
                                }, set: {
                                    QuickSelectionPreferences.editTimerDuration($0, in: &selection, nodeID: timerID)
                                }), format: .number).textFieldStyle(.roundedBorder)
                                Text("minutes").foregroundStyle(.secondary)
                            }
                        } else {
                            HStack { Text("Start:"); Text(startTime, style: .time).foregroundStyle(.secondary) }
                            DatePicker("End:", selection: Binding(get: {
                                Calendar.current.date(bySettingHour: selection.restrictionNodes[index].endTimeHour ?? 17, minute: selection.restrictionNodes[index].endTimeMinute ?? 0, second: 0, of: Date()) ?? Date()
                            }, set: { setEnd($0, index: index) }), displayedComponents: .hourAndMinute).datePickerStyle(.field)
                            Text("An earlier end time means tomorrow.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    }
                    if section == .checklist {
                    if let index = checklistIndex {
                        Text("The last checked task finishes the intention. Your exit passcode lets you stop early.").font(.caption).foregroundStyle(.secondary)
                        if case .taskChecklist(let tasks) = selection.frictionNodes[index].friction {
                            ForEach(tasks.indices, id: \.self) { taskIndex in
                                HStack {
                                    Image(systemName: "square").foregroundStyle(.secondary)
                                    TextField("Your task", text: Binding(get: {
                                        guard case .taskChecklist(let current) = selection.frictionNodes[index].friction, current.indices.contains(taskIndex) else { return "" }
                                        return current[taskIndex]
                                    }, set: { text in
                                        guard case .taskChecklist(var current) = selection.frictionNodes[index].friction, current.indices.contains(taskIndex) else { return }
                                        current[taskIndex] = text; selection.frictionNodes[index].friction = .taskChecklist(current)
                                    })).textFieldStyle(.roundedBorder)
                                    Button { var current = tasks; current.remove(at: taskIndex); selection.frictionNodes[index].friction = .taskChecklist(current) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                                }
                            }
                            Button("Add task", systemImage: "plus") { selection.frictionNodes[index].friction = .taskChecklist(tasks + [""]) }.buttonStyle(.plain)
                        }
                    }
                    }
                    if section == .cooldown {
                    if let index = selection.restrictionNodes.firstIndex(where: { $0.kind == .coolDown }) {
                        HStack { TextField("Minutes", value: Binding(get: { selection.restrictionNodes[index].durationMinutes ?? 30 }, set: { selection.restrictionNodes[index].durationMinutes = min(1440, max(1, $0)) }), format: .number).textFieldStyle(.roundedBorder); Text("minutes") }
                    }
                    }
                }.padding(2)
            }
            Button("Remove \(section.rawValue.lowercased())") {
                section.disable(in: &selection); close()
            }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
        }.padding(14).tint(.green)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.16)))
    }
    private func timerModeButton(_ title: String, clock: Bool, index: Int) -> some View {
        let selected = (selection.restrictionNodes[index].kind == .endTime) == clock
        return Button {
            selection.restrictionNodes[index].kind = clock ? .endTime : .timer
            selection.restrictionNodes[index].usesPresetEndTime = clock
            if clock && selection.restrictionNodes[index].endTimeHour == nil { setEnd(Date().addingTimeInterval(1500), index: index) }
        } label: {
            Text(title).font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(selected ? Color.green.opacity(0.25) : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.green : Color.white.opacity(0.15)))
        }.buttonStyle(.plain).accessibilityLabel("\(title), \(selected ? "selected" : "not selected")")
    }

    private func setEnd(_ date: Date, index: Int) {
        selection.restrictionNodes[index].endTimeHour = Calendar.current.component(.hour, from: date)
        selection.restrictionNodes[index].endTimeMinute = Calendar.current.component(.minute, from: date)
    }
}
