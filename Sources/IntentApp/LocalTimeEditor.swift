import AppKit
import SwiftUI

struct LocalTimeEditor: View {
    private enum Field: Hashable {
        case hour
        case minute
    }

    @Binding private var selection: Date
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedField: Field?

    @State private var hourText = ""
    @State private var minuteText = ""
    @State private var isPM = false

    init(selection: Binding<Date>) {
        _selection = selection
    }

    var body: some View {
        HStack(spacing: 7) {
            timeField(text: $hourText, field: .hour, accessibilityLabel: "Hour")

            Text(":")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(GraphTheme.muted(colorScheme))

            timeField(text: $minuteText, field: .minute, accessibilityLabel: "Minute")

            Picker("Period", selection: $isPM) {
                Text("AM").tag(false)
                Text("PM").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 82, height: 40)
            .onChange(of: isPM) { _ in
                updateSelection()
            }
        }
        .onAppear {
            synchronizeFromSelection()
        }
        .onChange(of: selection) { _ in
            guard focusedField == nil else { return }
            synchronizeFromSelection()
        }
        .onChange(of: focusedField) { field in
            guard let field else {
                commitAllFields()
                return
            }
            selectFocusedText(for: field)
        }
        .onChange(of: hourText) { value in
            handleHourChange(value)
        }
        .onChange(of: minuteText) { value in
            handleMinuteChange(value)
        }
    }

    private func timeField(
        text: Binding<String>,
        field: Field,
        accessibilityLabel: String
    ) -> some View {
        TextField("--", text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 18, weight: .semibold, design: .rounded).monospacedDigit())
            .multilineTextAlignment(.center)
            .focused($focusedField, equals: field)
            .onSubmit {
                if field == .hour {
                    commitHour()
                    focusedField = .minute
                    selectFocusedText(for: .minute)
                } else {
                    commitMinute()
                    focusedField = nil
                }
            }
            .frame(width: 64, height: 40)
            .background(GraphTheme.elevatedSurface(colorScheme))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        focusedField == field
                            ? GraphTheme.editBlue
                            : GraphTheme.stroke(colorScheme),
                        lineWidth: focusedField == field ? 1.5 : 1
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityLabel(accessibilityLabel)
    }

    private func handleHourChange(_ value: String) {
        let sanitized = String(value.filter(\.isNumber).prefix(2))
        if sanitized != value {
            hourText = sanitized
            return
        }
        guard focusedField == .hour, sanitized.count == 2 else { return }
        commitHour()
        focusedField = .minute
        selectFocusedText(for: .minute)
    }

    private func handleMinuteChange(_ value: String) {
        let sanitized = String(value.filter(\.isNumber).prefix(2))
        if sanitized != value {
            minuteText = sanitized
            return
        }
        guard focusedField == .minute, sanitized.count == 2 else { return }
        commitMinute()
        focusedField = nil
    }

    private func commitAllFields() {
        commitHour()
        commitMinute()
    }

    private func commitHour() {
        guard let value = Int(hourText), (1...12).contains(value) else {
            synchronizeFromSelection()
            return
        }
        hourText = String(format: "%02d", value)
        updateSelection()
    }

    private func commitMinute() {
        guard let value = Int(minuteText), (0...59).contains(value) else {
            synchronizeFromSelection()
            return
        }
        minuteText = String(format: "%02d", value)
        updateSelection()
    }

    private func updateSelection() {
        guard let hour = Int(hourText),
              (1...12).contains(hour),
              let minute = Int(minuteText),
              (0...59).contains(minute) else {
            return
        }

        let hour24 = (hour % 12) + (isPM ? 12 : 0)
        selection = Calendar.autoupdatingCurrent.date(
            bySettingHour: hour24,
            minute: minute,
            second: 0,
            of: selection
        ) ?? selection
    }

    private func synchronizeFromSelection() {
        let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: selection)
        let hour24 = components.hour ?? 0
        let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
        hourText = String(format: "%02d", hour12)
        minuteText = String(format: "%02d", components.minute ?? 0)
        isPM = hour24 >= 12
    }

    private func selectFocusedText(for field: Field) {
        DispatchQueue.main.async {
            guard focusedField == field else { return }
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
    }
}
