import SwiftUI
import IntentCore

/// A dialog host only. Workspace selection is the sole home surface.
struct IntentUtilityView: View {
    @EnvironmentObject private var model: IntentAppModel
    @EnvironmentObject private var account: IntentAccountManager
    @AppStorage("intentDidCompleteOnboarding") private var didCompleteOnboarding = false
    @State private var guide = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18).fill(.regularMaterial)
            if model.settingsPresentationRequest != nil {
                VStack {
                    HStack {
                        Text("Settings").font(.headline)
                        Spacer()
                        Button("Done") { model.dismissSettingsPresentation(); model.hideOverlay() }
                    }
                    TabView {
                        ScrollView { OverviewSettingsView(model: model).padding(16) }.tabItem { Text("Workspace") }
                        IntentGeneralSettingsView(model: model).tabItem { Text("General") }
                    }
                }.padding(20)
            }
            if account.phase == .loading || account.phase == .choosing || account.isPresentingAccount {
                IntentAccountGate().environmentObject(account)
            }
            if guide {
                IntentQuickGuidePresenter(model: model, onFinish: {
                    didCompleteOnboarding = true; guide = false; model.hideOverlay()
                }, onDismiss: { guide = false; model.hideOverlay() }).allowsHitTesting(false)
            }
        }.padding(12).preferredColorScheme(.dark)
            .onAppear {
                if !didCompleteOnboarding && !UserDefaults.standard.bool(forKey: IntentOnboardingCoordinator.deferredKey) { guide = true }
            }
            .onChange(of: account.phase) { _ in dismissIfIdle() }
            .onChange(of: account.isPresentingAccount) { _ in dismissIfIdle() }
            .sheet(item: $model.pendingFriction, onDismiss: dismissIfIdle) { pending in
                FrictionSheet(pending: pending).id(pending.id).environmentObject(model).interactiveDismissDisabled()
            }
            .sheet(item: $model.pendingEndTimeRequest, onDismiss: dismissIfIdle) { pending in
                EndTimeSheet(pending: pending).environmentObject(model).interactiveDismissDisabled()
            }
            .alert("Intent", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil; dismissIfIdle() } })) {
                Button("OK") { model.errorMessage = nil; dismissIfIdle() }
            } message: { Text(model.errorMessage ?? "") }
    }

    private func dismissIfIdle() {
        guard model.settingsPresentationRequest == nil, model.pendingFriction == nil,
              model.pendingEndTimeRequest == nil, model.pendingPurposeSessionSave == nil,
              model.errorMessage == nil, !guide, !account.isPresentingAccount,
              account.phase != .loading, account.phase != .choosing else { return }
        model.hideOverlay()
    }
}

private struct IntentGeneralSettingsView: View {
    @ObservedObject var model: IntentAppModel
    @State private var finishShortcut = FinishShortcutStore.load()
    @State private var launchAtLogin = LaunchAtLoginController.savedPreference
    @State private var error: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Shortcuts").font(.headline)
                Text("Workspace: ` · Cmd+G is not used by Intent.").font(.caption)
                Text("Finish intention").font(.caption)
                OverlayShortcutRecorder(shortcut: $finishShortcut, onUpdate: IntentRuntime.shared.updateFinishShortcut)
                Button("Reset shortcuts to defaults") {
                    error = IntentRuntime.shared.resetShortcuts()
                    finishShortcut = FinishShortcutStore.load()
                }
                Text("Safety Stop: ⌃⌥⌘Esc releases all restrictions.").font(.caption).foregroundStyle(.secondary)
                Divider()
                Toggle("Require finish before switching", isOn: $model.requireManualFinishBeforeSwitching)
                Toggle("Open Intent at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in error = IntentRuntime.shared.updateLaunchAtLogin(enabled) }
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
                Divider()
                IntentAccountSettingsSection()
            }.padding(18)
        }
    }
}
