import SwiftUI
import IntentCore

struct FrictionSheet: View {
    @EnvironmentObject private var model: IntentAppModel
    let pending: PendingFriction

    @State private var input = ""
    @State private var checkedTasks = Set<Int>()
    @State private var remainingSeconds: Int
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(pending: PendingFriction) {
        self.pending = pending
        if case .countdown(let seconds) = pending.friction {
            _remainingSeconds = State(initialValue: seconds)
        } else {
            _remainingSeconds = State(initialValue: 0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Before \(pending.intentionName)")
                        .font(.title2.weight(.semibold))
                    if pending.totalSteps > 1 {
                        Text("Friction \(pending.step) of \(pending.totalSteps)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: frictionIcon)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(GraphTheme.editBlue)
            }

            frictionContent

            HStack {
                Button("Cancel") {
                    model.cancelFriction()
                }
                Spacer()
                Button(pending.step == pending.totalSteps ? "Start" : "Continue") {
                    submit()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canContinue)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onReceive(timer) { _ in
            guard case .countdown = pending.friction, remainingSeconds > 0 else { return }
            remainingSeconds -= 1
        }
    }

    @ViewBuilder
    private var frictionContent: some View {
        switch pending.friction {
        case .none:
            EmptyView()
        case .typedPhrase(let phrase):
            Text("Type this exactly:")
                .foregroundStyle(.secondary)
            Text(phrase)
                .font(.system(.body, design: .monospaced))
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            TextField("Commitment phrase", text: $input)
                .textFieldStyle(.roundedBorder)
        case .countdown:
            VStack(spacing: 8) {
                Text("\(remainingSeconds)")
                    .font(.system(size: 52, weight: .semibold, design: .rounded))
                Text(remainingSeconds == 0 ? "Pause complete" : "Wait before entering this intention")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        case .reasonPrompt(let prompt):
            Text(prompt)
                .foregroundStyle(.secondary)
            TextField("Write your reason", text: $input)
                .textFieldStyle(.roundedBorder)
        case .taskChecklist(let tasks):
            VStack(alignment: .leading, spacing: 9) {
                Text("Confirm the exact task before entering:")
                    .foregroundStyle(.secondary)
                ForEach(Array(tasks.enumerated()), id: \.offset) { index, task in
                    Toggle(task, isOn: Binding(
                        get: { checkedTasks.contains(index) },
                        set: { checked in
                            if checked { checkedTasks.insert(index) }
                            else { checkedTasks.remove(index) }
                        }
                    ))
                    .toggleStyle(.checkbox)
                }
            }
        case .timeBudget(let minutes):
            VStack(spacing: 8) {
                Text("\(minutes) minutes")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                Text("This is the time budget you chose for this intention.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
    }

    private var canContinue: Bool {
        switch pending.friction {
        case .none: true
        case .typedPhrase(let phrase): input == phrase
        case .countdown: remainingSeconds == 0
        case .reasonPrompt: !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .taskChecklist(let tasks): checkedTasks.count == tasks.count && !tasks.isEmpty
        case .timeBudget: true
        }
    }

    private var frictionIcon: String {
        switch pending.friction {
        case .none: "minus"
        case .typedPhrase: "text.cursor"
        case .countdown: "timer"
        case .reasonPrompt: "quote.bubble"
        case .taskChecklist: "checklist"
        case .timeBudget: "hourglass"
        }
    }

    private func submit() {
        switch pending.friction {
        case .typedPhrase, .reasonPrompt:
            model.submitFriction(input)
        case .taskChecklist:
            model.submitFriction("done")
        case .timeBudget(let minutes):
            model.submitFriction("\(minutes)")
        case .none, .countdown:
            model.completeCurrentFriction()
        }
    }
}
