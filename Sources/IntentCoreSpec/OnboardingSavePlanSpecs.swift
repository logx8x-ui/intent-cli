import Foundation
import IntentCore

func runOnboardingSavePlanSpecs() throws {
    let currentApp = AllowedApp(name: "Notes", bundleIdentifier: "com.apple.Notes")
    var draft = Intention(id: "tutorial-draft", name: "Original purpose", icon: "square", colorHex: "#34C759", folder: "",
        allowedApps: [currentApp], allowedWebsites: [], startupActions: [], restrictions: .init(),
        graphPosition: .init(x: 20, y: 30),
        restrictionNodes: [
            .init(id: "timer", kind: .timer, position: .init(x: 40, y: 50), durationMinutes: 10),
            .init(id: QuickSelection.startupSuppressionID, kind: .dontStartUp, position: .init(x: 20, y: 10))
        ], frictionNodes: [.init(id: "tasks", friction: .taskChecklist(["Write something"]), position: .init(x: 10, y: -10))])
    draft.selectionOnly = true
    let purpose = "  한글 🎧  listen to music\n"
    let insertion = OnboardingSavePlan(candidate: draft, latestPurpose: purpose, existing: nil,
        replaceExisting: false, insertionPosition: .init(x: 100, y: 200))
    try expect(insertion.action == .insert && insertion.intention.id == draft.id, "First tutorial save inserts the actual completed draft with its identity")
    try expect(insertion.intention.name == "한글 🎧  listen to music", "Editing purpose after running supplies the latest saved name, preserving Unicode and internal whitespace")
    try expect(insertion.intention.graphPosition == .init(x: 100, y: 200), "A first save uses its free canvas position")
    try expect(insertion.intention.restrictionNodes.map(\.id) == ["timer"], "Saving removes only the automatic current-session startup suppression")
    try expect(insertion.intention.restrictionNodes.first?.position == .init(x: 120, y: 220)
        && insertion.intention.frictionNodes.first?.position == .init(x: 90, y: 160), "Connected modifier positions move with the saved card")

    var existing = Intention(id: "saved-on-canvas", name: "My existing setup", icon: "book", colorHex: "#000000", folder: "Personal",
        allowedApps: [AllowedApp(name: "Old app", bundleIdentifier: "example.old")], allowedWebsites: [], startupActions: [], restrictions: .init(),
        graphPosition: .init(x: 400, y: 500))
    existing.usesCustomIcon = true
    let kept = OnboardingSavePlan(candidate: draft, latestPurpose: purpose, existing: existing,
        replaceExisting: false, insertionPosition: .zero)
    try expect(kept.action == .keepExisting && kept.intention == existing, "Replay or the ordinary save shortcut cannot silently rename, replace, reposition, or duplicate an existing saved setup")

    let updated = OnboardingSavePlan(candidate: draft, latestPurpose: purpose, existing: existing,
        replaceExisting: true, insertionPosition: .zero)
    try expect(updated.action == .replaceExisting && updated.intention.id == existing.id, "Explicit Update saved setup replaces one stable identity instead of creating a duplicate")
    try expect(updated.intention.graphPosition == existing.graphPosition && updated.intention.folder == existing.folder, "An explicit update keeps the user's canvas placement and folder")
    try expect(updated.intention.allowedApps == draft.allowedApps && updated.intention.name == "한글 🎧  listen to music", "Explicit replacement saves the new real workspace and latest purpose")
    try expect(updated.intention.restrictionNodes.first?.position == .init(x: 420, y: 520)
        && updated.intention.frictionNodes.first?.position == .init(x: 390, y: 460), "Replacement modifier nodes remain connected around the existing card")
    let repeated = OnboardingSavePlan(candidate: draft, latestPurpose: "Another purpose", existing: updated.intention,
        replaceExisting: false, insertionPosition: .zero)
    try expect(repeated.intention == updated.intention, "The next ordinary save after an explicit update remains non-destructive")
    let noLongerExisting = OnboardingSavePlan(candidate: draft, latestPurpose: " \n ", existing: nil,
        replaceExisting: true, insertionPosition: .zero)
    try expect(noLongerExisting.action == .insert && noLongerExisting.intention.name == draft.name, "A removed saved entry can be saved again and empty transient input does not erase a valid name")
}
