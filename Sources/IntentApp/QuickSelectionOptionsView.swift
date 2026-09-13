import IntentCore
import SwiftUI

enum QuickSelectionOptionsSection: String {
    case restrictions = "Restrictions"
    case frictions = "Frictions"
    var symbol: String { self == .restrictions ? "slider.horizontal.3" : "hand.raised" }
    var tint: Color { self == .restrictions ? .cyan : Color(red: 0.78, green: 0.66, blue: 1) }
}

struct QuickSelectionOptionsView: View {
    @Binding var selection: QuickSelection
    let section: QuickSelectionOptionsSection
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(section.rawValue, systemImage: section.symbol).font(.system(size: 17, weight: .semibold))
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).padding(7) }
                    .buttonStyle(.plain).accessibilityLabel("Close session options")
            }
            Text(section == .restrictions ? "Shape this session." : "A small pause before you begin.")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
            ScrollView {
                VStack(spacing: 9) {
                    if section == .restrictions {
                        ForEach([RestrictionKind.timer, .endTime, .allowBrowserSearches, .coolDown, .dontStartUp], id: \.self) { kind in
                            restrictionCard(kind)
                        }
                    } else {
                        ForEach(QuickFrictionChoice.allCases, id: \.self) { choice in frictionCard(choice) }
                    }
                }.padding(2)
            }.scrollIndicators(.hidden)
            Text(section == .restrictions ? "Included if you save this intention." : "Checks run in the order you add them.")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
        }.padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.18)))
            .shadow(color: .black.opacity(0.2), radius: 18, y: 8)
            .tint(section.tint)
    }

    private func restrictionCard(_ kind: RestrictionKind) -> some View {
        let index = selection.restrictionNodes.firstIndex { $0.kind == kind }
        return VStack(alignment: .leading, spacing: 10) {
            optionButton(title: title(kind), detail: detail(kind), selected: index != nil) {
                if let index { selection.restrictionNodes.remove(at: index) }
                else {
                    selection.restrictionNodes.append(.init(kind: kind,
                        position: .init(x: 240, y: 260 + Double(selection.restrictionNodes.count) * 130),
                        durationMinutes: kind == .coolDown ? 30 : 25,
                        showsRemainingTime: true, locksSessionUntilTimerEnds: false))
                }
            }
            if let index {
                restrictionSettings($selection.restrictionNodes[index])
            }
        }.padding(12).background(cardFill(index != nil), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(index != nil ? section.tint.opacity(0.55) : .white.opacity(0.10)))
    }

    @ViewBuilder private func restrictionSettings(_ node: Binding<RestrictionNode>) -> some View {
        switch node.wrappedValue.kind {
        case .timer, .coolDown:
            Stepper(value: Binding(get: { node.wrappedValue.durationMinutes ?? 25 }, set: { node.wrappedValue.durationMinutes = $0 }), in: 1...240) {
                Text("\(node.wrappedValue.durationMinutes ?? 25) minutes").monospacedDigit()
            }.font(.system(size: 12)).accessibilityLabel("\(node.wrappedValue.kind.displayName) minutes")
            if node.wrappedValue.kind == .timer { lockToggle(node) }
        case .endTime:
            Text("Choose your finish time when you press Start.").font(.system(size: 11)).foregroundStyle(.secondary)
            lockToggle(node)
        case .allowBrowserSearches, .dontStartUp:
            EmptyView()
        }
    }

    private func lockToggle(_ node: Binding<RestrictionNode>) -> some View {
        Toggle("Lock until it ends", isOn: Binding(get: { node.wrappedValue.locksSessionUntilTimerEnds ?? false }, set: { node.wrappedValue.locksSessionUntilTimerEnds = $0 }))
            .toggleStyle(.checkbox).font(.system(size: 12))
            .help("When enabled, the normal Finish action is unavailable until the timer or end time is reached.")
    }

    private func frictionCard(_ choice: QuickFrictionChoice) -> some View {
        let index = selection.frictionNodes.firstIndex { choice.matches($0.friction) }
        return VStack(alignment: .leading, spacing: 10) {
            optionButton(title: choice.title, detail: index.map { "Step \($0 + 1) · \(choice.detail)" } ?? choice.detail, selected: index != nil) {
                if let index { selection.frictionNodes.remove(at: index) }
                else {
                    let nextY = (selection.frictionNodes.map { $0.position.y }.max() ?? 100) + 130
                    selection.frictionNodes.append(.init(friction: choice.defaultValue, position: .init(x: -240, y: nextY)))
                }
            }
            if let index { frictionSettings($selection.frictionNodes[index].friction) }
        }.padding(12).background(cardFill(index != nil), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(index != nil ? section.tint.opacity(0.55) : .white.opacity(0.10)))
    }

    @ViewBuilder private func frictionSettings(_ friction: Binding<Friction>) -> some View {
        switch friction.wrappedValue {
        case .typedPhrase(let phrase):
            TextField("Phrase to type", text: Binding(get: { phrase }, set: { friction.wrappedValue = .typedPhrase($0) }), axis: .vertical)
                .textFieldStyle(.roundedBorder).accessibilityLabel("Commitment phrase")
        case .reasonPrompt(let prompt):
            TextField("Question to answer", text: Binding(get: { prompt }, set: { friction.wrappedValue = .reasonPrompt($0) }), axis: .vertical)
                .textFieldStyle(.roundedBorder).accessibilityLabel("Reason prompt")
        case .countdown(let seconds):
            Stepper(value: Binding(get: { seconds }, set: { friction.wrappedValue = .countdown(seconds: $0) }), in: 1...300) {
                Text("\(seconds) seconds").monospacedDigit()
            }.accessibilityLabel("Countdown seconds")
        case .taskChecklist(let tasks):
            Text("One task per line").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: Binding(get: { tasks.joined(separator: "\n") }, set: { friction.wrappedValue = .taskChecklist($0.components(separatedBy: "\n")) }))
                .frame(height: 76).scrollContentBackground(.hidden)
                .padding(6).background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Checklist tasks")
        case .timeBudget(let minutes):
            Stepper(value: Binding(get: { minutes }, set: { friction.wrappedValue = .timeBudget(minutes: $0) }), in: 1...240) {
                Text("\(minutes) minutes").monospacedDigit()
            }.accessibilityLabel("Time budget minutes")
        case .none: EmptyView()
        }
    }

    private func optionButton(title: String, detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "plus.circle")
                    .foregroundStyle(selected ? section.tint : .white.opacity(0.45))
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("\(title), \(selected ? "selected" : "not selected")")
    }
    private func cardFill(_ selected: Bool) -> Color { selected ? section.tint.opacity(0.10) : .white.opacity(0.04) }
    private func title(_ kind: RestrictionKind) -> String {
        switch kind {
        case .timer: "Timer"
        case .endTime: "End time"
        case .allowBrowserSearches: "Allow browser searches"
        case .coolDown: "Cooldown"
        case .dontStartUp: "Don't start up"
        }
    }
    private func detail(_ kind: RestrictionKind) -> String {
        switch kind {
        case .timer: "Finish automatically after a set duration."
        case .endTime: "Finish at a particular time of day."
        case .allowBrowserSearches: selection.accessMode == .whitelist
            ? "Search Google within selected tabs. New tabs stay unselected."
            : "Allow Google searches while browsing."
        case .coolDown: "Wait before replaying this saved intention."
        case .dontStartUp: "Keep resources from reopening when you replay. Current windows stay open."
        }
    }
}

private enum QuickFrictionChoice: CaseIterable {
    case phrase, countdown, reason, checklist, budget
    var title: String { defaultValue.displayName }
    var detail: String {
        switch self {
        case .phrase: "Type a commitment before starting."
        case .countdown: "Take a breath before the session begins."
        case .reason: "Say what you're here to do."
        case .checklist: "Check off your preparation steps."
        case .budget: "Confirm how much time you plan to spend."
        }
    }
    var defaultValue: Friction {
        switch self {
        case .phrase: .typedPhrase("I want to do this right now")
        case .countdown: .countdown(seconds: 10)
        case .reason: .reasonPrompt("What are you here to do?")
        case .checklist: .taskChecklist(["I'm ready to focus"])
        case .budget: .timeBudget(minutes: 25)
        }
    }
    func matches(_ friction: Friction) -> Bool {
        switch (self, friction) {
        case (.phrase, .typedPhrase), (.countdown, .countdown), (.reason, .reasonPrompt), (.checklist, .taskChecklist), (.budget, .timeBudget): true
        default: false
        }
    }
}
