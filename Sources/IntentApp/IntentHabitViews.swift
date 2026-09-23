import AppKit
import SwiftUI
import IntentCore
import UniformTypeIdentifiers

struct IntentNameFirstView: View {
    @ObservedObject var controller: QuickSelectionController
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("NAME → CHOOSE → START").font(.caption.weight(.semibold)).foregroundStyle(.green)
            Text("What did you come to do?").font(.system(size: 28, weight: .medium, design: .serif))
            TextField("Reply to emails, study chapter 2…", text: $controller.pendingName)
                .textFieldStyle(.plain).font(.title3).focused($focused).onSubmit { controller.confirmName() }
            Rectangle().fill(.white.opacity(0.35)).frame(height: 1)
            Text("Name it first. Then choose only what belongs to it.").font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Use a saved intention") { controller.toggleSlots() }.buttonStyle(.plain)
                Spacer()
                Button("Choose my workspace") { controller.confirmName() }.buttonStyle(.borderedProminent).tint(.green)
                    .disabled(controller.pendingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
            .onAppear { focused = true }
    }
}

struct IntentSavedSlotsView: View {
    @ObservedObject var controller: QuickSelectionController
    @ObservedObject var model: IntentAppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Your intentions").font(.title2); Spacer(); Button("Workspace · Space") { controller.toggleSlots() } }
            Text("Ready for next time. Drag to reorder.").foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 10) {
                    if model.savedSlots.isEmpty { Text("Save a session from Today or Yesterday to keep it here.").padding(24) }
                    ForEach(model.savedSlots) { intention in
                        HStack(spacing: 10) {
                            Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(intention.name).font(.headline)
                                HStack(spacing: 4) {
                                    ForEach(Array(intention.allowedApps.prefix(7)), id: \.bundleIdentifier) { app in
                                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) {
                                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20).help(app.name)
                                        }
                                    }
                                }
                            }
                            Spacer()
                            Button("Review") { controller.prepare(intention, workspace: model.journal.workspaces[intention.id]) }
                            Button("Run") { controller.prepare(intention, workspace: model.journal.workspaces[intention.id], run: true) }
                                .buttonStyle(.borderedProminent).tint(.green).disabled(controller.loading || controller.closing)
                        }.padding(14).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                            .onDrag { NSItemProvider(object: intention.id as NSString) }
                            .onDrop(of: [.text], isTargeted: nil) { providers in
                                guard let provider = providers.first else { return false }
                                _ = provider.loadObject(ofClass: String.self) { value, _ in
                                    guard let value else { return }; Task { @MainActor in model.moveSlot(value, to: intention.id) }
                                }; return true
                            }
                    }
                }
            }
        }.padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
    }
}

struct IntentSessionNotesView: View {
    @ObservedObject var controller: QuickSelectionController
    @ObservedObject var model: IntentAppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                notes("Today", day: Date())
                notes("Yesterday", day: Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date())
            }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
        }.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
    private func notes(_ title: String, day: Date) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(.headline, design: .serif))
            let records = model.journal.records(on: day)
            if records.isEmpty { Text("Nothing yet").font(.caption).foregroundStyle(.secondary) }
            ForEach(records) { record in
                HStack {
                    Button(record.intention.name) { controller.prepare(record.intention, workspace: record.workspace) }
                        .buttonStyle(.plain).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    Button { model.saveRecord(record) } label: { Image(systemName: "bookmark") }.buttonStyle(.plain).help("Save as an intention")
                }.font(.callout)
            }
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
                Button("Name an intention") { [weak self] in self?.hide(); start() }
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
