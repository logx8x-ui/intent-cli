import SwiftUI
import IntentCore

struct ZeroDriftWarningSheet: View {
    let onCancel: () -> Void
    let onContinue: (Bool) -> Void

    @State private var doNotShowAgain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "scope")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Zero Drift")
                        .font(.title2.weight(.semibold))
                    Text("Intentions become the only way through.")
                        .foregroundStyle(.secondary)
                }
            }

            Text("Until the time you choose, an intention must always be running. Between intentions, Intent stays open and blocks access to other apps.")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            Text("Zero Drift cannot be ended early through Intent. Force Quit, restarting the Mac, or administrator tools remain outside this app's control.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Don't show this warning again", isOn: $doNotShowAgain)

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Continue") {
                    onContinue(doNotShowAgain)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 470)
    }
}

struct ZeroDriftTimingSheet: View {
    enum TimingMode: String, CaseIterable, Identifiable {
        case duration = "Duration"
        case endTime = "End time"

        var id: String { rawValue }
    }

    let onCancel: () -> Void
    let onActivate: (Date) -> Void

    @State private var timingMode: TimingMode = .duration
    @State private var days = 0
    @State private var hours = 1
    @State private var minutes = 0
    @State private var endTime = Date()
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("How long should Zero Drift run?")
                    .font(.title2.weight(.semibold))
                Text("The lock releases automatically at the finish time.")
                    .foregroundStyle(.secondary)
            }

            Picker("Timing", selection: $timingMode) {
                ForEach(TimingMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Group {
                switch timingMode {
                case .duration:
                    HStack(spacing: 12) {
                        durationField("Days", value: $days)
                        durationField("Hours", value: $hours)
                        durationField("Minutes", value: $minutes)
                    }
                case .endTime:
                    HStack {
                        Text(Date(), style: .time)
                            .font(.title3.monospacedDigit())
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        LocalTimeEditor(selection: $endTime)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 10)
                }
            }

            if let validationMessage {
                Text(validationMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Start Zero Drift") {
                    activate()
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 470)
    }

    private func durationField(_ label: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("0", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func activate() {
        let finishDate: Date?
        switch timingMode {
        case .duration:
            finishDate = ZeroDriftTiming.durationEndDate(
                days: days,
                hours: hours,
                minutes: minutes
            )
        case .endTime:
            finishDate = ZeroDriftTiming.nextEndDate(matching: endTime)
        }

        guard let finishDate, finishDate > Date() else {
            validationMessage = "Choose a duration or finish time in the future."
            return
        }
        onActivate(finishDate)
    }
}
