import IntentCore
import SwiftUI

struct ActivityRecordingControl: View {
    @ObservedObject var recorder: ActivityRecordingController
    @Binding var isPresented: Bool
    let installedApps: [InstalledApp]
    let onOpen: () -> Void
    let onAddSuggestions: ([AIIntentionSuggestion]) -> [String]

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button {
            onOpen()
            isPresented = true
        } label: {
            Image(systemName: recorder.isRecording ? "record.circle.fill" : "record.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(recorder.isRecording ? Color.red : Color.primary)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Recording Mode")
        .adaptiveGlassPanel(colorScheme: colorScheme, cornerRadius: 11)
        .help(recorder.isRecording ? recorder.statusText : "Recording Mode")
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            ActivityRecordingView(
                recorder: recorder,
                installedApps: installedApps,
                onAddSuggestions: onAddSuggestions
            )
        }
    }
}

struct ActivityRecordingView: View {
    @ObservedObject var recorder: ActivityRecordingController
    let installedApps: [InstalledApp]
    let onAddSuggestions: ([AIIntentionSuggestion]) -> [String]

    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedPeriod = ActivityRecordingPeriod.twentyFourHours
    @State private var selectedSuggestionNames = Set<String>()
    @State private var statusMessage: String?

    private var suggestions: [AIIntentionSuggestion] {
        guard let state = recorder.state, !state.isActive else { return [] }
        return ActivitySuggestionBuilder.suggestions(
            from: state,
            installedApps: installedApps.map {
                AllowedApp(name: $0.name, bundleIdentifier: $0.bundleIdentifier)
            },
            maximumCount: 7
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                privacySummary

                if recorder.isRecording {
                    activeRecording
                } else if recorder.hasCompletedRecording {
                    completedRecording
                } else {
                    startControls
                }

                if let errorMessage = recorder.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if let statusMessage {
                    Label(statusMessage, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            .padding(18)
        }
        .frame(width: 430)
        .frame(maxHeight: 720)
        .background(GraphTheme.background(colorScheme).opacity(0.96))
        .onAppear(perform: selectAllSuggestions)
        .onChange(of: recorder.state?.completedAt) { _ in
            selectAllSuggestions()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: recorder.isRecording ? "record.circle.fill" : "record.circle")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(recorder.isRecording ? .red : GraphTheme.editBlue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recording Mode")
                    .font(.system(size: 17, weight: .semibold))
                Text("Learn your real workflows, then suggest up to 7 intentions.")
                    .font(.caption)
                    .foregroundStyle(GraphTheme.muted(colorScheme))
            }
            Spacer()
        }
    }

    private var privacySummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Private activity totals only", systemImage: "hand.raised.fill")
                .font(.system(size: 12, weight: .semibold))
            Text("Intent records active app IDs, time totals, and browser domains. It never captures screen pixels, keystrokes, page contents, URL paths, or searches. The recording stays on this Mac and is never sent to AI.")
                .font(.caption)
                .foregroundStyle(GraphTheme.muted(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            Text("No Screen Recording permission is needed. Browser domains are included only while Intent Browser Guard is enabled in Firefox or Chrome.")
                .font(.caption2)
                .foregroundStyle(GraphTheme.muted(colorScheme))
        }
        .padding(12)
        .background(GraphTheme.surface(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var startControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("RECORD FOR")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(GraphTheme.muted(colorScheme))

            Picker("Recording period", selection: $selectedPeriod) {
                ForEach(ActivityRecordingPeriod.allCases) { period in
                    Text(period.displayName).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Button {
                statusMessage = nil
                recorder.start(period: selectedPeriod)
            } label: {
                Label("Start Recording Mode", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var activeRecording: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text(recorder.statusText)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            Text(recorder.recordedTimeText)
                .font(.caption)
                .foregroundStyle(GraphTheme.muted(colorScheme))

            HStack(spacing: 8) {
                Button("Stop & review") {
                    recorder.stop()
                    selectAllSuggestions()
                }
                .buttonStyle(.borderedProminent)

                Button("Delete recording", role: .destructive) {
                    recorder.clear()
                    selectedSuggestionNames.removeAll()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(Color.red.opacity(colorScheme == .dark ? 0.12 : 0.07))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.red.opacity(0.28)))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var completedRecording: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Suggested intentions")
                        .font(.system(size: 14, weight: .semibold))
                    Text("\(recorder.recordedTimeText). Every result is Allow Only and editable.")
                        .font(.caption)
                        .foregroundStyle(GraphTheme.muted(colorScheme))
                }
                Spacer()
                Text("\(suggestions.count) / 7")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(GraphTheme.editBlue)
            }

            if suggestions.isEmpty {
                Text("There is not enough activity yet to make a reliable suggestion. Try a longer recording period.")
                    .font(.caption)
                    .foregroundStyle(GraphTheme.muted(colorScheme))
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { _, suggestion in
                        suggestionRow(suggestion)
                    }
                }

                Button {
                    let selected = suggestions.filter { selectedSuggestionNames.contains(selectionKey(for: $0)) }
                    let added = onAddSuggestions(selected)
                    guard !added.isEmpty else {
                        statusMessage = nil
                        recorder.errorMessage = "Finish the active intention before adding suggestions."
                        return
                    }
                    recorder.clear()
                    selectedSuggestionNames.removeAll()
                    statusMessage = "Added \(added.count) whitelisted intention\(added.count == 1 ? "" : "s") to your desktop."
                } label: {
                    Label("Add selected to desktop", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedSuggestionNames.isEmpty)
            }

            HStack {
                Button("Record again") {
                    recorder.clear()
                    selectedSuggestionNames.removeAll()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Delete data", role: .destructive) {
                    recorder.clear()
                    selectedSuggestionNames.removeAll()
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func suggestionRow(_ suggestion: AIIntentionSuggestion) -> some View {
        Button {
            let key = selectionKey(for: suggestion)
            if selectedSuggestionNames.contains(key) {
                selectedSuggestionNames.remove(key)
            } else {
                selectedSuggestionNames.insert(key)
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selectedSuggestionNames.contains(selectionKey(for: suggestion)) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedSuggestionNames.contains(selectionKey(for: suggestion)) ? GraphTheme.editBlue : GraphTheme.muted(colorScheme))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(suggestion.name)
                            .font(.system(size: 12, weight: .semibold))
                        Text("ALLOW ONLY")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(GraphTheme.editBlue)
                    }
                    Text("\(suggestion.appBundleIdentifiers.count) app\(suggestion.appBundleIdentifiers.count == 1 ? "" : "s") · \(suggestion.websites.count) site\(suggestion.websites.count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(GraphTheme.muted(colorScheme))
                }
                Spacer()
            }
            .padding(10)
            .background(GraphTheme.surface(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func selectAllSuggestions() {
        selectedSuggestionNames = Set(suggestions.map { selectionKey(for: $0) })
    }

    private func selectionKey(for suggestion: AIIntentionSuggestion) -> String {
        suggestion.name + "|" + suggestion.appBundleIdentifiers.joined(separator: ",")
    }
}
