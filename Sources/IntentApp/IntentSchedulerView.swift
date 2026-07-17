import SwiftUI
import IntentCore

struct IntentSchedulerView: View {
    @EnvironmentObject private var model: IntentAppModel
    @Environment(\.colorScheme) private var colorScheme

    @State private var weekOffset = 0
    @State private var editorContext: ScheduleEditorContext?

    private let calendar = Calendar.current

    var body: some View {
        VStack(spacing: 0) {
            schedulerHeader
                .padding(.horizontal, 30)
                .padding(.top, 82)
                .padding(.bottom, 22)

            weekBoard
                .padding(.horizontal, 30)
                .padding(.bottom, 30)
                .frame(maxHeight: .infinity)
        }
        .sheet(item: $editorContext) { context in
            ScheduleEditorSheet(
                schedule: context.schedule,
                intentions: model.intentions,
                isNew: context.isNew,
                onSave: { schedule in
                    if context.isNew {
                        if let id = model.createSchedule(
                            intentionID: schedule.intentionID,
                            scheduledAt: schedule.scheduledAt
                        ), var created = model.schedules.first(where: { $0.id == id }) {
                            created.recurrence = schedule.recurrence
                            created.weekdays = schedule.weekdays
                            created.isEnabled = schedule.isEnabled
                            model.updateSchedule(created)
                        }
                    } else {
                        model.updateSchedule(schedule)
                    }
                    editorContext = nil
                },
                onDelete: context.isNew ? nil : {
                    model.deleteSchedule(id: context.schedule.id)
                    editorContext = nil
                }
            )
        }
    }

    private var schedulerHeader: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("SCHEDULER")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(GraphTheme.muted(colorScheme))
                Text("Make time decide for you.")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(GraphTheme.text(colorScheme))
                Text("Intent will begin the chosen session at its scheduled time.")
                    .font(.system(size: 12))
                    .foregroundStyle(GraphTheme.muted(colorScheme))
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    weekOffset -= 1
                } label: {
                    Image(systemName: "chevron.left")
                }
                Button("Today") {
                    weekOffset = 0
                }
                Button {
                    weekOffset += 1
                } label: {
                    Image(systemName: "chevron.right")
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .adaptiveGlassPanel(colorScheme: colorScheme, cornerRadius: 11)

            Button {
                createSchedule()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .adaptiveGlassPanel(colorScheme: colorScheme, cornerRadius: 11)
            .disabled(model.intentions.isEmpty)
            .help(model.intentions.isEmpty ? "Create an intention first" : "Schedule an intention")
        }
    }

    private var weekBoard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(weekDates, id: \.self) { date in
                    dayHeader(date)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 58)
            .overlay(alignment: .bottom) {
                Rectangle().fill(GraphTheme.stroke(colorScheme)).frame(height: 1)
            }

            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(weekDates.enumerated()), id: \.element) { index, date in
                    dayColumn(date)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .overlay(alignment: .trailing) {
                            if index < weekDates.count - 1 {
                                Rectangle().fill(GraphTheme.stroke(colorScheme).opacity(0.65)).frame(width: 1)
                            }
                        }
                }
            }
        }
        .adaptiveGlassPanel(colorScheme: colorScheme, cornerRadius: 18)
        .overlay {
            if model.schedules.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "calendar.badge.plus")
                        .font(.system(size: 30, weight: .light))
                    Text("No intentions scheduled")
                        .font(.system(size: 15, weight: .semibold))
                    Button("Schedule one") { createSchedule() }
                        .buttonStyle(.bordered)
                        .disabled(model.intentions.isEmpty)
                }
                .foregroundStyle(GraphTheme.muted(colorScheme))
                .padding(.top, 52)
            }
        }
    }

    private func dayHeader(_ date: Date) -> some View {
        let weekday = calendar.shortWeekdaySymbols[calendar.component(.weekday, from: date) - 1]
        let day = calendar.component(.day, from: date)
        let isToday = calendar.isDateInToday(date)
        return VStack(spacing: 4) {
            Text(weekday.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.9)
            Text("\(day)")
                .font(.system(size: 15, weight: isToday ? .bold : .medium))
        }
        .foregroundStyle(isToday ? GraphTheme.editBlue : GraphTheme.muted(colorScheme))
    }

    private func dayColumn(_ date: Date) -> some View {
        let schedules = schedules(on: date)
        return ScrollView(.vertical) {
            LazyVStack(spacing: 9) {
                ForEach(schedules) { schedule in
                    scheduleChip(schedule)
                }
            }
            .padding(10)
        }
        .scrollIndicators(.hidden)
    }

    private func scheduleChip(_ schedule: IntentSchedule) -> some View {
        let intention = model.intentions.first(where: { $0.id == schedule.intentionID })
        return Button {
            editorContext = ScheduleEditorContext(schedule: schedule, isNew: false)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(schedule.isEnabled ? Color.green : GraphTheme.muted(colorScheme))
                        .frame(width: 5, height: 5)
                    Text(timeText(schedule.scheduledAt))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    Spacer(minLength: 0)
                }
                Text(intention?.name ?? "Missing intention")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(schedule.recurrence.displayName)
                    .font(.system(size: 9))
                    .foregroundStyle(GraphTheme.muted(colorScheme))
            }
            .foregroundStyle(GraphTheme.text(colorScheme))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GraphTheme.elevatedSurface(colorScheme).opacity(schedule.isEnabled ? 0.82 : 0.34))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(GraphTheme.stroke(colorScheme)))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .opacity(schedule.isEnabled ? 1 : 0.58)
        }
        .buttonStyle(.plain)
    }

    private var weekDates: [Date] {
        var mondayCalendar = calendar
        mondayCalendar.firstWeekday = 2
        guard let interval = mondayCalendar.dateInterval(of: .weekOfYear, for: Date()),
              let start = mondayCalendar.date(byAdding: .weekOfYear, value: weekOffset, to: interval.start) else {
            return []
        }
        return (0..<7).compactMap { mondayCalendar.date(byAdding: .day, value: $0, to: start) }
    }

    private func schedules(on date: Date) -> [IntentSchedule] {
        model.schedules
            .filter { schedule in
                var visible = schedule
                visible.isEnabled = true
                return visible.occurs(on: date, calendar: calendar)
            }
            .sorted { $0.scheduledAt < $1.scheduledAt }
    }

    private func createSchedule() {
        guard let intention = model.intentions.first else { return }
        let now = Date()
        let nextHour = calendar.date(byAdding: .hour, value: 1, to: now) ?? now
        var components = calendar.dateComponents([.year, .month, .day, .hour], from: nextHour)
        components.minute = 0
        let rounded = calendar.date(from: components) ?? nextHour
        let schedule = IntentSchedule(
            intentionID: intention.id,
            recurrence: .once,
            scheduledAt: rounded
        )
        editorContext = ScheduleEditorContext(schedule: schedule, isNew: true)
    }

    private func timeText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

private struct ScheduleEditorContext: Identifiable {
    let id = UUID()
    let schedule: IntentSchedule
    let isNew: Bool
}

private struct ScheduleEditorSheet: View {
    let intentions: [Intention]
    let isNew: Bool
    let onSave: (IntentSchedule) -> Void
    let onDelete: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @State private var draft: IntentSchedule

    init(
        schedule: IntentSchedule,
        intentions: [Intention],
        isNew: Bool,
        onSave: @escaping (IntentSchedule) -> Void,
        onDelete: (() -> Void)?
    ) {
        self.intentions = intentions
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
        _draft = State(initialValue: schedule)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: "calendar")
                Text(isNew ? "Schedule intention" : "Scheduled intention")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Toggle("Enabled", isOn: $draft.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            field("INTENTION") {
                Picker("Intention", selection: $draft.intentionID) {
                    ForEach(intentions) { intention in
                        Text(intention.name).tag(intention.id)
                    }
                }
                .labelsHidden()
            }

            HStack(alignment: .top, spacing: 16) {
                field("TIME") {
                    DatePicker("Time", selection: $draft.scheduledAt, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
                field("REPEAT") {
                    Picker("Repeat", selection: $draft.recurrence) {
                        ForEach(ScheduleRecurrence.allCases, id: \.self) { recurrence in
                            Text(recurrence.displayName).tag(recurrence)
                        }
                    }
                    .labelsHidden()
                }
            }

            if draft.recurrence == .once {
                field("DATE") {
                    DatePicker("Date", selection: $draft.scheduledAt, displayedComponents: .date)
                        .labelsHidden()
                }
            } else if draft.recurrence == .weekly {
                field("DAYS") {
                    HStack(spacing: 7) {
                        ForEach(ScheduleWeekday.mondayFirst) { weekday in
                            let selected = draft.weekdays.contains(weekday.rawValue)
                            Button(weekday.shortName.prefix(1).description) {
                                toggle(weekday)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .frame(width: 32, height: 32)
                            .background(selected ? GraphTheme.editBlue : GraphTheme.elevatedSurface(colorScheme))
                            .foregroundStyle(selected ? Color.white : GraphTheme.text(colorScheme))
                            .clipShape(Circle())
                        }
                    }
                }
            }

            Divider()

            HStack {
                if let onDelete {
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button(isNew ? "Schedule" : "Done") {
                    if draft.recurrence == .weekly, draft.weekdays.isEmpty {
                        draft.weekdays = [Calendar.current.component(.weekday, from: draft.scheduledAt)]
                    }
                    onSave(draft)
                }
                .buttonStyle(.borderedProminent)
                .tint(GraphTheme.editBlue)
                .disabled(intentions.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 500)
        .background(GraphTheme.background(colorScheme))
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(GraphTheme.muted(colorScheme))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggle(_ weekday: ScheduleWeekday) {
        if let index = draft.weekdays.firstIndex(of: weekday.rawValue) {
            draft.weekdays.remove(at: index)
        } else {
            draft.weekdays.append(weekday.rawValue)
            draft.weekdays.sort()
        }
    }
}
