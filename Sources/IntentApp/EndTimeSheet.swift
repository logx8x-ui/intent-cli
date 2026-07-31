import SwiftUI

struct EndTimeSheet: View {
    @EnvironmentObject private var model: IntentAppModel
    let pending: PendingEndTimeRequest

    @State private var endDate: Date

    init(pending: PendingEndTimeRequest) {
        self.pending = pending
        _endDate = State(initialValue: pending.suggestedEndDate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Set an end time")
                        .font(.title2.weight(.semibold))
                    Text(pending.intentionName)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "clock.badge.checkmark")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(GraphTheme.editBlue)
            }

            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 14) {
                    timeCard(
                        label: "Now",
                        time: context.date.formatted(date: .omitted, time: .shortened)
                    )

                    Image(systemName: "arrow.right")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 7) {
                        Text("Finish")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        LocalTimeEditor(selection: $endDate)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }

            Text("Intent uses the local time shown by this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel") {
                    model.cancelEndTimeSelection()
                }
                Spacer()
                Button("Continue") {
                    model.confirmEndTime(endDate)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private func timeCard(label: String, time: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(time)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
