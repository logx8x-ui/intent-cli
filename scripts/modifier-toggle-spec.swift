// Compiled with the actual modifier enum by test-modifier-toggles.sh.
for section in QuickSelectionOptionsSection.allCases {
    var selection = QuickSelection()
    for other in QuickSelectionOptionsSection.allCases { other.enable(in: &selection) }
    section.disable(in: &selection)
    precondition(!section.enabled(in: selection))
    for other in QuickSelectionOptionsSection.allCases where other != section { precondition(other.enabled(in: selection)) }
    section.enable(in: &selection)
    precondition(section.enabled(in: selection))
    section.enable(in: &selection)
    section.disable(in: &selection)
    precondition(!section.enabled(in: selection))
}
var clock = QuickSelection()
clock.restrictionNodes.append(.init(kind: .endTime, position: .init(x: 0, y: 0)))
QuickSelectionOptionsSection.timer.disable(in: &clock)
precondition(!QuickSelectionOptionsSection.timer.enabled(in: clock))
print("All four modifier disable/re-enable, independence, idempotence and end-time removal checks passed")
