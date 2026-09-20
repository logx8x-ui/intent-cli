import Foundation
import IntentCore

func runOnboardingPresentationSpecs() throws {
    var policy = OnboardingPresentationPolicy()
    let firstRequest = UUID()
    try expect(policy.update(isPresented: true, selectionVisible: false, request: nil, initialEntryFocus: false) == .show,
               "Resuming a later guide step shows its coach without taking focus")
    try expect(policy.update(isPresented: true, selectionVisible: false, request: firstRequest, initialEntryFocus: false) == .showAndFocus,
               "Explicit Show quick guide raises and focuses an already retained coach at any step")
    for _ in 0..<10 {
        try expect(policy.update(isPresented: true, selectionVisible: false, request: firstRequest, initialEntryFocus: true) == .none,
                   "Content refreshes do not repeatedly raise or focus the coach, including purpose entry")
    }
    try expect(policy.update(isPresented: true, selectionVisible: false, request: UUID(), initialEntryFocus: false) == .showAndFocus,
               "A second explicit request restores a hidden retained coach without recreating its tutorial")

    let secondRequest = UUID()
    try expect(policy.update(isPresented: true, selectionVisible: true, request: secondRequest, initialEntryFocus: true) == .hide,
               "An explicit request cannot cover the real picker or steal its keyboard focus")
    try expect(policy.update(isPresented: true, selectionVisible: false, request: secondRequest, initialEntryFocus: false) == .showAndFocus,
               "The explicit request is fulfilled once the actual picker closes")
    try expect(policy.update(isPresented: true, selectionVisible: true, request: secondRequest, initialEntryFocus: false) == .hide,
               "Opening the picker hides the existing coach")
    try expect(policy.update(isPresented: true, selectionVisible: false, request: secondRequest, initialEntryFocus: false) == .show,
               "Ordinary picker closure restores the coach without taking focus from the selected work")

    try expect(policy.update(isPresented: true, selectionVisible: true, request: UUID(), initialEntryFocus: false) == .hide,
               "A pending explicit request stays hidden while the picker is open")
    try expect(policy.update(isPresented: false, selectionVisible: true, request: nil, initialEntryFocus: false) == .hide,
               "Closing the guide cancels any pending focus request")
    try expect(policy.update(isPresented: false, selectionVisible: false, request: nil, initialEntryFocus: false) == .hide,
               "The picker closing after guide exit cannot resurrect the guide")

    var fresh = OnboardingPresentationPolicy()
    try expect(fresh.update(isPresented: true, selectionVisible: false, request: nil, initialEntryFocus: true) == .showAndFocus,
               "First welcome and purpose presentation can accept keyboard input")
    var resumed = OnboardingPresentationPolicy()
    try expect(resumed.update(isPresented: true, selectionVisible: false, request: UUID(), initialEntryFocus: false) == .showAndFocus,
               "A request made before the presenter exists is consumed when its panel is created")

    var handoff = OnboardingPermissionHandoffPolicy()
    handoff.begin()
    try expect(handoff.isSuspended, "Permission handoff hides Intent before macOS opens its permission prompt")
    handoff.activatedApplication("dev.loganmondi.intent.qa", intentBundleIdentifier: "dev.loganmondi.intent.qa")
    try expect(handoff.isSuspended, "An Intent activation before Settings opens cannot cancel the pending handoff")
    handoff.activatedApplication("com.apple.systempreferences", intentBundleIdentifier: "dev.loganmondi.intent.qa")
    handoff.activatedApplication("com.apple.SecurityAgent", intentBundleIdentifier: "dev.loganmondi.intent.qa")
    try expect(handoff.isSuspended, "Authentication helpers retain the permission handoff instead of reopening the coach")
    handoff.activatedApplication("com.google.Chrome", intentBundleIdentifier: "dev.loganmondi.intent.qa")
    try expect(handoff.isSuspended, "Leaving Settings for another task does not put the coach back above it")
    handoff.activatedApplication("dev.loganmondi.intent.qa", intentBundleIdentifier: "dev.loganmondi.intent.qa")
    try expect(!handoff.isSuspended, "Returning to the actual QA app resumes its existing coach")
    handoff.activatedApplication("com.apple.systempreferences", intentBundleIdentifier: "dev.loganmondi.intent.qa")
    try expect(handoff.isSuspended, "Opening Settings manually also gives the permission UI priority")
    handoff.resume()
    try expect(!handoff.isSuspended, "An explicit Intent request or guide exit clears the window handoff")

    var windows = OnboardingPresentationPolicy()
    let request = UUID()
    _ = windows.update(isPresented: true, selectionVisible: false, request: request, initialEntryFocus: false)
    try expect(windows.update(isPresented: true, selectionVisible: false, request: request,
                              initialEntryFocus: false, permissionHandoffActive: true) == .hide,
               "A previously raised coach hides while the permission UI owns the screen")
    try expect(windows.update(isPresented: true, selectionVisible: false, request: request,
                              initialEntryFocus: false, permissionHandoffActive: false) == .show,
               "Finishing permission handoff restores the coach without taking keyboard focus")
    try expect(windows.update(isPresented: true, selectionVisible: false, request: request,
                              initialEntryFocus: false) == .none,
               "Permission status polling cannot repeatedly order or focus the restored coach")
    try expect(windows.update(isPresented: false, selectionVisible: false, request: nil,
                              initialEntryFocus: false, permissionHandoffActive: true) == .hide,
               "Exiting during setup keeps the coach hidden")
    try expect(windows.update(isPresented: false, selectionVisible: false, request: nil,
                              initialEntryFocus: false) == .hide,
               "Clearing setup after exit cannot reopen the dismissed guide")
    print("Onboarding presentation specs passed")
}
