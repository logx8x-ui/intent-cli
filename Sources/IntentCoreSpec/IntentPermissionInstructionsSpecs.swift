import Foundation
import IntentCore

func runIntentPermissionInstructionsSpecs() throws {
    for channel in [IntentBuildChannel.development, .launch] {
        let instructions = IntentPermissionInstructions(channel: channel)
        let messages = [instructions.overview, instructions.accessibility, instructions.keyboardLock,
            instructions.screenRecording, instructions.speechRecognition, instructions.microphone,
            instructions.onboardingAccessibility, instructions.onboardingPreviews, instructions.onboardingReturn]
        for message in messages {
            try expect(message.contains(channel.appName), "Every permission and onboarding handoff names its actual installed channel")
            if channel == .development {
                try expect(!message.replacingOccurrences(of: "Test Intent", with: "").contains("Intent"),
                    "Test guidance never directs a user to grant or reopen the other Intent app")
            } else {
                try expect(!message.contains("Test Intent"), "Launch guidance never names the Test app")
            }
        }
        try expect(instructions.overview.contains("choose \(channel.appName).app"),
            "The missing permission entry instructions identify the exact application to add")
    }
    try expect(IntentPermissionInstructions.current.channel == IntentBuildChannel.current,
        "Permission guidance uses the compiled channel, including when the host has no app bundle metadata")
}
