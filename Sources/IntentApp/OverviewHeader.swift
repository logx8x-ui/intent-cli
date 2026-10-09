import SwiftUI

/// Keep the measured header and its occupied controls shared with layout QA.
/// The space beside these controls remains available to the recent log.
struct OverviewHeader: View {
    @ObservedObject var controller: QuickSelectionController
    @ObservedObject var model: IntentAppModel
    @ObservedObject private var onboarding: IntentOnboardingCoordinator
    let showClock: Bool
    let topSafeInset: CGFloat
    let width: CGFloat

    init(controller: QuickSelectionController, model: IntentAppModel,
         showClock: Bool, topSafeInset: CGFloat, width: CGFloat) {
        self.controller = controller
        self.model = model
        onboarding = controller.onboarding
        self.showClock = showClock
        self.topSafeInset = topSafeInset
        self.width = width
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Spacer()
                if showClock {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(context.date, style: .time).monospacedDigit()
                            .font(.system(size: 14, weight: .medium)).frame(minWidth: 80)
                    }.intentionFrame("overview-clock")
                }
            }.overlay {
                IntentOptionalNameBar(name: $controller.selection.name)
                    .frame(width: min(520, max(180, width - 240)))
                    .intentionFrame("overview-name")
            }.padding(.horizontal, 28).frame(height: 48).padding(.top, topSafeInset)
            if !model.savedSlots.isEmpty {
                IntentSavedSlotsView(controller: controller, model: model)
                    .frame(height: 94).fixedSize(horizontal: true, vertical: false)
                    .intentionFrame("overview-saved")
            }
            if onboarding.isTeaching {
                OnboardingSelectionHint(coordinator: onboarding)
                    .frame(height: 60).padding(.horizontal, 28)
                    .intentionFrame("overview-onboarding")
            }
        }.frame(width: width).fixedSize(horizontal: false, vertical: true)
    }
}
