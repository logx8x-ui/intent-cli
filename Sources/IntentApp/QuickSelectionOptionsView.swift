import IntentCore
import SwiftUI

enum QuickSelectionOptionsSection { case session }

struct QuickSelectionOptionsView: View {
    @Binding var selection: QuickSelection
    let close: () -> Void
    @State private var startTime = Date()
    private var timerIndex: Int? { selection.restrictionNodes.firstIndex { $0.kind == .timer || $0.kind == .endTime } }
    private var checklistIndex: Int? { selection.frictionNodes.firstIndex { if case .taskChecklist = $0.friction { return true }; return false } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Session").font(.title2); Spacer(); Button("Done", action: close).buttonStyle(.plain) }
            Text("A little structure. Only what you need.").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle("Timer", isOn: Binding(get: { timerIndex != nil }, set: { enabled in
                        selection.restrictionNodes.removeAll { $0.kind == .timer || $0.kind == .endTime }
                        if enabled { selection.restrictionNodes.append(.init(kind: .timer, position: .init(x: 240, y: 260), durationMinutes: 25, showsRemainingTime: true, locksSessionUntilTimerEnds: false)) }
                    }))
                    if let index = timerIndex {
                        HStack(spacing: 8) {
                            timerModeButton("Duration", clock: false, index: index)
                            timerModeButton("End time", clock: true, index: index)
                        }
                        if selection.restrictionNodes[index].kind == .timer {
                            HStack { TextField("Minutes", value: Binding(get: { selection.restrictionNodes[index].durationMinutes ?? 25 }, set: { selection.restrictionNodes[index].durationMinutes = min(1440, max(1, $0)) }), format: .number).textFieldStyle(.roundedBorder); Text("minutes").foregroundStyle(.secondary) }
                        } else {
                            HStack { Text("Start:"); Text(startTime, style: .time).foregroundStyle(.secondary) }
                            DatePicker("End:", selection: Binding(get: {
                                Calendar.current.date(bySettingHour: selection.restrictionNodes[index].endTimeHour ?? 17, minute: selection.restrictionNodes[index].endTimeMinute ?? 0, second: 0, of: Date()) ?? Date()
                            }, set: { setEnd($0, index: index) }), displayedComponents: .hourAndMinute).datePickerStyle(.field)
                            Text("An earlier end time means tomorrow.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    Toggle("Task checklist", isOn: Binding(get: { checklistIndex != nil }, set: { enabled in
                        selection.frictionNodes.removeAll { if case .taskChecklist = $0.friction { return true }; return false }
                        if enabled { selection.frictionNodes.append(.init(friction: .taskChecklist([""]), position: .init(x: -240, y: 260))) }
                    }))
                    if let index = checklistIndex {
                        Text("Check tasks off during your session; the last check finishes it.").font(.caption).foregroundStyle(.secondary)
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
                    Divider()
                    Toggle("Allow browser searches", isOn: option(.allowBrowserSearches))
                    Toggle("Cooldown before replay", isOn: option(.coolDown))
                    if let index = selection.restrictionNodes.firstIndex(where: { $0.kind == .coolDown }) {
                        HStack { TextField("Minutes", value: Binding(get: { selection.restrictionNodes[index].durationMinutes ?? 30 }, set: { selection.restrictionNodes[index].durationMinutes = min(1440, max(1, $0)) }), format: .number).textFieldStyle(.roundedBorder); Text("minutes") }
                    }
                }.padding(2)
            }
        }.padding(20).tint(.green)
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
    private func option(_ kind: RestrictionKind) -> Binding<Bool> {
        Binding(get: { selection.restrictionNodes.contains { $0.kind == kind } }, set: { enabled in
            selection.restrictionNodes.removeAll { $0.kind == kind }
            if enabled { selection.restrictionNodes.append(.init(kind: kind, position: .init(x: 240, y: 390), durationMinutes: 30)) }
        })
    }
}
