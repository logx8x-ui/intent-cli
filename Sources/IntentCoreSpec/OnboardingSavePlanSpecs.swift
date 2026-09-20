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

    // Exercise the real picker constructor: synthetic drafts with an explicit
    // graph origin previously hid its UUID-derived origin mismatch.
    var selection = QuickSelection()
    selection.apps = [currentApp.bundleIdentifier]
    selection.restrictionNodes = [.init(kind: .timer, position: .init(x: 240, y: 260), durationMinutes: 1)]
    selection.frictionNodes = [.init(friction: .taskChecklist(["Finish the task"]), position: .init(x: -240, y: 260))]
    for _ in 0..<3 {
        let actualDraft = try selection.makeIntention(apps: [currentApp], snapshots: [])
        try expect(actualDraft.graphPosition == .zero, "Every quick-selection draft uses the same local origin as its modifier coordinates, regardless of its generated identity")
        let firstSave = OnboardingSavePlan(candidate: actualDraft, latestPurpose: "QA first run", existing: nil,
            replaceExisting: false, insertionPosition: .init(x: 340, y: 0)).intention
        let replay = OnboardingSavePlan(candidate: actualDraft, latestPurpose: "QA replay", existing: firstSave,
            replaceExisting: true, insertionPosition: .init(x: -999, y: -999)).intention
        for saved in [firstSave, replay] {
            try expect(saved.graphPosition == .init(x: 340, y: 0)
                && saved.restrictionNodes.first?.position == .init(x: 580, y: 260)
                && saved.frictionNodes.first?.position == .init(x: 100, y: 260),
                "First save and explicit replay replacement keep the real picker modifiers beside their card, without random displacement")
        }
        try expect(replay.id == firstSave.id, "Fitting a replay preserves the existing saved identity")

        for viewport in [(900.0, 560.0), (640.0, 440.0)] {
            let focus = OnboardingCanvasFocus(intention: replay, viewportWidth: viewport.0, viewportHeight: viewport.1)
            let renderedNodes: [(GraphPoint, Double, Double)] = [
                (replay.graphPosition, 200, 190),
                (replay.restrictionNodes[0].position, 116, 116),
                (replay.frictionNodes[0].position, 126, 112)
            ]
            for (point, width, height) in renderedNodes {
                let centerX = viewport.0 / 2 + focus.offset.x + point.x * focus.scale
                let centerY = viewport.1 / 2 + focus.offset.y + point.y * focus.scale
                try expect(centerX - width * focus.scale / 2 >= 40
                    && centerX + width * focus.scale / 2 <= viewport.0 - 40
                    && centerY - height * focus.scale / 2 >= 72
                    && centerY + height * focus.scale / 2 <= viewport.1 - 100,
                    "Show on canvas fits the whole saved group above the bottom controls, including the lower checklist and timer")
            }
        }
    }

    let keptFocus = OnboardingCanvasFocus(intention: existing, viewportWidth: 900, viewportHeight: 560)
    try expect(keptFocus.scale == 1 && existing.graphPosition == .init(x: 400, y: 500),
        "Focusing an existing unmodified card keeps normal scale and never rewrites user graph coordinates")
}
