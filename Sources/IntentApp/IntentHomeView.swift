import SwiftUI
import IntentCore

/// The supported home surface. Legacy graph/AI implementations remain available
/// to decode old data, but no longer form part of ordinary navigation.
struct IntentHomeView: View {
    @EnvironmentObject private var model: IntentAppModel
    @EnvironmentObject private var account: IntentAccountManager
    @State private var settings = false
    @State private var guide = false
    @AppStorage("intentDidCompleteOnboarding") private var didCompleteOnboarding = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24).fill(.regularMaterial)
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("intent").font(.system(size: 32, weight: .medium, design: .serif))
                    Spacer()
                    Button { guide = true } label: { Image(systemName: "questionmark.circle") }.help("How Intent works")
                    Button { settings.toggle() } label: { Image(systemName: "gearshape") }.accessibilityLabel("Settings")
                    Button { model.hideOverlay() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close Intent")
                }.buttonStyle(.plain)
                if let name = model.activeSessionName {
                    Label(name, systemImage: "circle.fill").foregroundStyle(.green)
                    Button("Show running controls") { model.toggleSessionControls() }
                } else {
                    Text("What did you come to do?").font(.system(size: 28, weight: .medium))
                    Button("Choose my workspace · `") { IntentRuntime.shared.toggleQuickFocus() }
                        .buttonStyle(.borderedProminent).tint(.green).foregroundStyle(.black)
                }
                Text("Saved intentions").font(.headline).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if model.savedSlots.isEmpty {
                            Text("Your saved intentions will appear here.").foregroundStyle(.secondary).padding(.vertical, 24)
                        }
                        ForEach(model.savedSlots) { intention in
                            Button { IntentRuntime.shared.prepareSavedIntention(intention) } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: intention.icon).frame(width: 26)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(intention.name).font(.headline)
                                        Text(intention.accessMode == .whitelist ? "Allow selected" : "Block selected")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                }.padding(16).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                            }.buttonStyle(.plain).disabled(model.hasActiveSession)
                        }
                    }
                }
            }.padding(32).frame(maxWidth: 680)
            if account.phase == .loading || account.phase == .choosing || account.isPresentingAccount {
                IntentAccountGate().environmentObject(account)
            }
            if guide {
                IntentQuickGuidePresenter(model: model, onFinish: {
                    didCompleteOnboarding = true; guide = false
                }, onDismiss: { guide = false }).allowsHitTesting(false)
            }
        }.padding(18).preferredColorScheme(.dark)
            .onAppear {
                if !didCompleteOnboarding && !UserDefaults.standard.bool(forKey: IntentOnboardingCoordinator.deferredKey) { guide = true }
            }
            .onReceive(model.$settingsPresentationRequest) { if $0 != nil { settings = true; guide = false } }
            .sheet(isPresented: $settings) {
                VStack(alignment: .leading) {
                    HStack { Spacer(); Button("Done") { settings = false } }
                    TabView {
                        ScrollView { OverviewSettingsView(model: model).padding(16) }
                            .tabItem { Text("Workspace") }
                        IntentGeneralSettingsView(model: model)
                            .tabItem { Text("General") }
                    }
                }.padding(20).frame(width: 480, height: 680)
            }
            .sheet(item: $model.pendingFriction) { pending in
                FrictionSheet(pending: pending).id(pending.id).environmentObject(model).interactiveDismissDisabled()
            }
            .sheet(item: $model.pendingEndTimeRequest) { pending in
                EndTimeSheet(pending: pending).environmentObject(model).interactiveDismissDisabled()
            }
            .sheet(item: $model.pendingPurposeSessionSave) { candidate in
                PurposeSessionSaveSheet(candidate: candidate).environmentObject(model).interactiveDismissDisabled()
            }
            .alert("Intent", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK") { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
    }
}

/// Keep ordinary account and shortcut settings reachable after retiring the
/// canvas entry point. Workspace-specific defaults remain in the other tab.
private struct IntentGeneralSettingsView: View {
    @ObservedObject var model: IntentAppModel
    @State private var overlayShortcut = OverlayShortcutStore.load()
    @State private var finishShortcut = FinishShortcutStore.load()
    @State private var launchAtLogin = LaunchAtLoginController.savedPreference
    @State private var error: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Shortcuts").font(.headline)
                Text("Open Intent").font(.caption)
                OverlayShortcutRecorder(shortcut: $overlayShortcut, onUpdate: IntentRuntime.shared.updateOverlayShortcut)
                Text("Finish intention").font(.caption)
                OverlayShortcutRecorder(shortcut: $finishShortcut, onUpdate: IntentRuntime.shared.updateFinishShortcut)
                Button("Reset shortcuts to defaults") {
                    error = IntentRuntime.shared.resetShortcuts()
                    overlayShortcut = OverlayShortcutStore.load(); finishShortcut = FinishShortcutStore.load()
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
