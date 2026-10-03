import IntentCore

func runRestorationFocusSpecs() throws {
    try expect(RestorationFocusPolicy.targetPID(frontmostPID: 10, controllerPID: 10, visiblePID: 2) == 2,
        "Finishing from Intent's controls preserves the visible work app, not the disappearing controls")
    try expect(RestorationFocusPolicy.targetPID(frontmostPID: 1, controllerPID: 10, visiblePID: 2) == 1,
        "A hotkey finish preserves the current app even when another app has an exposed window")
    try expect(RestorationFocusPolicy.targetPID(frontmostPID: 10, controllerPID: 10, visiblePID: nil) == nil,
        "A finish without a visible work app must not guess or reopen a stale application")
    try expect(RestorationFocusPolicy.targetPID(frontmostPID: nil, controllerPID: 10, visiblePID: 2) == nil,
        "An inactive desktop must not activate an exposed application")
    try expect(RestorationFocusPolicy.targetPID(frontmostPID: 10, controllerPID: 10, visiblePID: 10) == nil,
        "Transient Intent panels cannot become their own restoration target")
    do {
        var policy = RestorationFocusPolicy(originalPID: 1, restoringPIDs: [2, 3])
        try expect(policy.shouldPreserve(frontmostPID: 1), "Keep the current window within the same app")
        try expect(policy.shouldPreserve(frontmostPID: 2), "Undo a hidden-app restoration stealing focus")
        try expect(policy.shouldPreserve(frontmostPID: 3), "Undo asynchronous browser restoration stealing focus")
        policy.userInteracted()
        try expect(!policy.shouldPreserve(frontmostPID: 2), "A real click or key cancels focus preservation even for a restored app")
    }
    var policy = RestorationFocusPolicy(originalPID: 1, restoringPIDs: [2])
    try expect(!policy.shouldPreserve(frontmostPID: 9), "Do not fight unrelated app activation")
    try expect(!policy.shouldPreserve(frontmostPID: 2), "Do not return to a stale app after the user moved on")
}
