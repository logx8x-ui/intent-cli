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
                    Text("Require an intention")
                        .font(.title2.weight(.semibold))
                    Text("Intentions become the only way through.")
                        .foregroundStyle(.secondary)
                }
            }

            Text("Between intentions, choose your next workspace. Always-allowed apps stay available. You can take timed breaks from overview settings.")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            Text("Need to recover? Press ⌃⌥⌘Esc for Safety Stop to release all restrictions immediately. Restarting Intent or your Mac also ends Require an intention; it never resumes automatically.")
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
        case indefinite = "Indefinitely"

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
                Text("How long should Require an intention run?")
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
                case .indefinite:
                    Text("Until you end the work period. Restart and Safety Stop always release restrictions.")
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
                Button("Start Require an intention") {
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
        case .indefinite:
            finishDate = .distantFuture
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
