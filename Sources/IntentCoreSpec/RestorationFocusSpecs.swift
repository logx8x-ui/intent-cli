import IntentCore

func runRestorationFocusSpecs() throws {
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
