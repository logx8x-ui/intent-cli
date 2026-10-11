import IntentCore

func runIntentBuildPolicySpecs() throws {
    let development = IntentBuildPolicy(channel: .development)
    let launch = IntentBuildPolicy(channel: .launch)
    try expect(development.includesWebsiteAdder && !launch.includesWebsiteAdder,
        "Only the explicit development channel includes the experimental website adder")
    #if INTENT_DEVELOPMENT
    try expect(IntentBuildPolicy.current == development,
        "The development compiler definition selects the personal test policy")
    #else
    try expect(IntentBuildPolicy.current == launch,
        "An unmarked binary defaults to the launch policy, never experimental features")
    #endif

    for policy in [development, launch] {
        var gesture = OverviewSearchGesture(websiteFinderEnabled: policy.includesWebsiteAdder)
        let trigger = gesture.key(code: 17, down: true, modified: false, repeated: false,
            editing: false, browserPickerAvailable: true)
        try expect(trigger.consume == policy.includesWebsiteAdder
            && trigger.action == (policy.includesWebsiteAdder ? .websiteFinder : nil),
            "A resolved browser picker cannot enable T in the launch channel")
        let release = gesture.key(code: 17, down: false, modified: true, repeated: false,
            editing: true, browserPickerAvailable: true)
        try expect(release.consume == policy.includesWebsiteAdder && release.action == nil,
            "Only an enabled T trigger owns its key release")

        for key in [17, 18, 11] {
            let typed = gesture.key(code: key, down: true, modified: false, repeated: false,
                editing: true, browserPickerAvailable: true)
            try expect(!typed.consume && typed.action == nil,
                "Channel policy never consumes ordinary text editing")
        }
        let saved = gesture.key(code: 20, down: true, modified: false, repeated: false,
            editing: false, browserPickerAvailable: true)
        try expect(saved.action == .savedSlot(2), "Both channels retain the saved-intention number shortcuts")
        _ = gesture.key(code: 20, down: false, modified: false, repeated: false, editing: false)
        _ = gesture.key(code: 50, down: true, modified: false, repeated: false, editing: false)
        let modification = gesture.key(code: 22, down: true, modified: false, repeated: false, editing: false)
        try expect(modification.action == .modification(5), "Both channels retain all six modifier shortcuts")
        let run = gesture.key(code: 57, down: true, modified: false, repeated: false, editing: false)
        try expect(run.action == .run, "The feature gate leaves the Caps Lock and backtick Run owner unchanged")
        _ = gesture.key(code: 50, down: false, modified: false, repeated: false, editing: false)
        let escape = gesture.key(code: 53, down: true, modified: false, repeated: false, editing: false)
        try expect(escape.action == .close, "Both channels keep immediate Escape cancellation")
    }
}
