import SwiftUI

struct FrictionSheet: View {
    @EnvironmentObject private var model: IntentAppModel
    let pending: PendingFriction
    @State private var input = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Before \(pending.intention.name)")
                .font(.title2.weight(.semibold))

            Text(pending.prompt)
                .foregroundStyle(.secondary)

            if let expectedValue = pending.expectedValue {
                Text(expectedValue)
                    .font(.system(.body, design: .monospaced))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            TextField("Response", text: $input)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") {
                    model.pendingFriction = nil
                }
                Button("Start") {
                    model.submitFriction(input)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
