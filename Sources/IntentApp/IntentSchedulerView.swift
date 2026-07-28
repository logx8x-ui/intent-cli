import SwiftUI
import IntentCore

struct IntentSchedulerView: View {
    @EnvironmentObject private var model: IntentAppModel
    @EnvironmentObject private var calendarSync: CalendarSyncManager
    @Environment(\.colorScheme) private var colorScheme

    @State private var weekOffset = 0
    @State private var editorContext: ScheduleEditorContext?
    @State private var showCalendarConnections = false

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
        .onAppear {
            calendarSync.appear(visibleInterval: visibleWeekInterval)
        }
        .onChange(of: weekOffset) { _ in
            calendarSync.updateVisibleInterval(visibleWeekInterval)
        }
        .sheet(item: $editorContext) { context in
            ScheduleEditorSheet(
                schedule: context.schedule,
                intentions: model.intentions,
                isNew: context.isNew,
                appleConnected: calendarSync.appleState.isConnected,
                googleConnected: calendarSync.googleState.isConnected,
                onSave: { schedule, syncProvider in
                    Task {
                        await saveSchedule(schedule, isNew: context.isNew, syncProvider: syncProvider)
                    }
                },
                onDelete: context.isNew ? nil : {
                    Task {
                        if let existing = model.schedules.first(where: { $0.id == context.schedule.id }) {
                            await calendarSync.deleteSyncedEvent(for: existing)
                        }
                        model.deleteSchedule(id: context.schedule.id)
                        editorContext = nil
                    }
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
                Text(headerSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(GraphTheme.muted(colorScheme))
            }

            Spacer()

            Button {
                showCalendarConnections.toggle()
            } label: {
                Label(calendarConnectionLabel, systemImage: calendarConnectionIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 36)
            }
            .buttonStyle(.plain)
            .adaptiveGlassPanel(colorScheme: colorScheme, cornerRadius: 11)
            .help("Connect optional calendars. Local schedules always work.")
            .popover(isPresented: $showCalendarConnections, arrowEdge: .top) {
                CalendarConnectionsPopover(
                    dismiss: { showCalendarConnections = false }
                )
                .environmentObject(calendarSync)
            }

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

    private var headerSubtitle: String {
        if let message = calendarSync.syncStatusMessage, !message.isEmpty {
            return message
        }
        if calendarSync.appleState.isConnected || calendarSync.googleState.isConnected {
            return "Local Intent schedules stay authoritative. Linked calendar events stay in sync."
        }
        return "Intent will begin the chosen session at its scheduled time."
    }

    private var calendarConnectionLabel: String {
        calendarSync.appleState.isConnected || calendarSync.googleState.isConnected
            ? "Calendars"
            : "Connect calendar"
    }

    private var calendarConnectionIcon: String {
        calendarSync.appleState.isConnected || calendarSync.googleState.isConnected
            ? "calendar.badge.checkmark"
            : "calendar.badge.plus"
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
            if model.schedules.isEmpty && calendarSync.externalEvents.isEmpty {
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
        let items = calendarSync.displayItems(
            schedules: model.schedules,
            intentions: model.intentions,
            on: date,
            calendar: calendar
        )
        return ScrollView(.vertical) {
            LazyVStack(spacing: 9) {
                ForEach(items) { item in
                    displayChip(item)
                }
            }
            .padding(10)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func displayChip(_ item: SchedulerDisplayItem) -> some View {
        switch item {
        case .intentSchedule(let schedule, let intentionName):
            scheduleChip(schedule, intentionName: intentionName)
        case .linkedExternal(let event):
            externalChip(event, style: .linked)
        case .external(let event):
            externalChip(event, style: .external)
        case .task(let event):
            externalChip(event, style: .task)
        }
    }

    private func scheduleChip(_ schedule: IntentSchedule, intentionName: String) -> some View {
        Button {
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
                    if schedule.isSynced {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(GraphTheme.muted(colorScheme))
                    }
                }
                Text(intentionName)
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

    private enum ExternalStyle {
        case linked, external, task
    }

    private func externalChip(_ event: ExternalCalendarEvent, style: ExternalStyle) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: style == .task ? "checklist" : "calendar")
                    .font(.system(size: 9, weight: .semibold))
                Text(timeText(event.startAt))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                Spacer(minLength: 0)
            }
            Text(event.title)
                .font(.system(size: 11, weight: style == .external ? .medium : .semibold))
                .lineLimit(2)
            Text(styleLabel(style, provider: event.provider))
                .font(.system(size: 9))
                .foregroundStyle(GraphTheme.muted(colorScheme))
        }
        .foregroundStyle(GraphTheme.text(colorScheme).opacity(style == .external ? 0.72 : 0.92))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GraphTheme.surface(colorScheme).opacity(style == .linked ? 0.55 : 0.28),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(GraphTheme.stroke(colorScheme).opacity(style == .external ? 0.45 : 0.7))
        )
    }

    private func styleLabel(_ style: ExternalStyle, provider: CalendarProviderKind) -> String {
        switch style {
        case .linked: "Synced · \(provider.displayName)"
        case .external: provider.displayName
        case .task: provider == .apple ? "Reminder" : "Task"
        }
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

    private var visibleWeekInterval: DateInterval {
        let start = weekDates.first ?? calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 7, to: start)
            ?? start.addingTimeInterval(7 * 24 * 60 * 60)
        return DateInterval(start: start, end: end)
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

    private func saveSchedule(
        _ schedule: IntentSchedule,
        isNew: Bool,
        syncProvider: CalendarProviderKind
    ) async {
        var working = schedule
        if isNew {
            if let id = model.createSchedule(
                intentionID: schedule.intentionID,
                scheduledAt: schedule.scheduledAt
            ), var created = model.schedules.first(where: { $0.id == id }) {
                created.recurrence = schedule.recurrence
                created.weekdays = schedule.weekdays
                created.isEnabled = schedule.isEnabled
                model.updateSchedule(created)
                working = model.schedules.first(where: { $0.id == id }) ?? created
            }
        } else {
            model.updateSchedule(schedule)
            working = model.schedules.first(where: { $0.id == schedule.id }) ?? schedule
        }

        let previousSync = working.sync
        if syncProvider == .local {
            if previousSync != nil {
                await calendarSync.deleteSyncedEvent(for: working)
                working.sync = nil
                model.updateSchedule(working)
            }
        } else {
            if let previousSync, previousSync.provider != syncProvider {
                await calendarSync.deleteSyncedEvent(for: working)
                working.sync = nil
            }
            working.sync = ScheduleSyncMetadata(
                provider: syncProvider,
                calendarID: syncProvider == .apple
                    ? (calendarSync.appleState.writeCalendarID ?? "")
                    : (calendarSync.googleState.writeCalendarID ?? ""),
                externalEventID: working.sync?.provider == syncProvider
                    ? (working.sync?.externalEventID ?? "")
                    : ""
            )
            let name = model.intentions.first { $0.id == working.intentionID }?.name ?? "Intention"
            if let synced = await calendarSync.syncSchedule(working, intentionName: name) {
                model.updateSchedule(synced)
            } else {
                working.sync = previousSync?.provider == syncProvider ? previousSync : nil
                model.updateSchedule(working)
            }
        }

        editorContext = nil
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
    let appleConnected: Bool
    let googleConnected: Bool
    let onSave: (IntentSchedule, CalendarProviderKind) -> Void
    let onDelete: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @State private var draft: IntentSchedule
    @State private var syncDestination: CalendarProviderKind

    init(
        schedule: IntentSchedule,
        intentions: [Intention],
        isNew: Bool,
        appleConnected: Bool,
        googleConnected: Bool,
        onSave: @escaping (IntentSchedule, CalendarProviderKind) -> Void,
        onDelete: (() -> Void)?
    ) {
        self.intentions = intentions
        self.isNew = isNew
        self.appleConnected = appleConnected
        self.googleConnected = googleConnected
        self.onSave = onSave
        self.onDelete = onDelete
        _draft = State(initialValue: schedule)
        _syncDestination = State(initialValue: schedule.sync?.provider ?? .local)
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

            if appleConnected || googleConnected || draft.sync != nil {
                field("CALENDAR SYNC") {
                    Picker("Sync", selection: $syncDestination) {
                        Text("Local only").tag(CalendarProviderKind.local)
                        if appleConnected || draft.sync?.provider == .apple {
                            Text("Apple Calendar").tag(CalendarProviderKind.apple)
                        }
                        if googleConnected || draft.sync?.provider == .google {
                            Text("Google Calendar").tag(CalendarProviderKind.google)
                        }
                    }
                    .labelsHidden()
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
                    onSave(draft, syncDestination)
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

private struct CalendarConnectionsPopover: View {
    @EnvironmentObject private var calendarSync: CalendarSyncManager
    @Environment(\.colorScheme) private var colorScheme
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect calendar")
                .font(.system(size: 15, weight: .semibold))

            providerRow(
                title: "Apple Calendar",
                icon: "apple.logo",
                state: calendarSync.appleState,
                connect: {
                    if await calendarSync.connectApple() {
                        dismiss()
                    }
                },
                disconnect: {
                    await calendarSync.disconnectApple()
                }
            )

            Divider()

            providerRow(
                title: "Google Calendar",
                icon: "g.circle.fill",
                state: calendarSync.googleState,
                connect: {
                    if await calendarSync.connectGoogle() {
                        dismiss()
                    }
                },
                disconnect: {
                    await calendarSync.disconnectGoogle()
                }
            )

            Text("Your events appear here in the scheduler. Calendar contents stay on this Mac and are never sent to Intent AI.")
                .font(.system(size: 10))
                .foregroundStyle(GraphTheme.muted(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 360)
        .background(GraphTheme.background(colorScheme))
        .onExitCommand(perform: dismiss)
    }

    private func providerRow(
        title: String,
        icon: String,
        state: CalendarConnectionState,
        connect: @escaping () async -> Void,
        disconnect: @escaping () async -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 28, height: 28)
                .background(GraphTheme.elevatedSurface(colorScheme), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(providerDetail(state))
                    .font(.system(size: 10))
                    .foregroundStyle(state.status == .permissionDenied || state.status == .error
                        ? Color.red
                        : GraphTheme.muted(colorScheme))
                    .lineLimit(2)
            }

            Spacer()

            if state.status == .connecting {
                ProgressView()
                    .controlSize(.small)
            } else if state.isConnected {
                HStack(spacing: 7) {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Color.green)
                        .help("Connected")
                    Button {
                        Task { await disconnect() }
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(GraphTheme.muted(colorScheme))
                    .help("Disconnect \(title)")
                }
            } else {
                Button(state.status == .configurationMissing ? "Unavailable" : "Connect") {
                    Task {
                        await connect()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(GraphTheme.editBlue)
                .disabled(state.status == .configurationMissing)
            }
        }
    }

    private func providerDetail(_ state: CalendarConnectionState) -> String {
        if state.isConnected {
            if let account = state.accountLabel, !account.isEmpty {
                return account
            }
            return "Connected"
        }
        if state.status == .configurationMissing {
            return "Google sign-in is not configured in this build."
        }
        switch state.status {
        case .permissionDenied:
            return "Permission was not granted."
        case .restricted:
            return "Calendar access is restricted."
        case .offline:
            return "Could not refresh. Check your connection."
        case .error:
            return state.message ?? "Could not connect."
        default:
            return "Not connected"
        }
    }
}
