import SwiftUI

struct IntentAccountGate: View {
    @EnvironmentObject private var accountManager: IntentAccountManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var emailMode: EmailMode?
    @State private var email = ""
    @State private var password = ""
    @State private var confirmation = ""
    @FocusState private var focusedField: Field?

    private enum EmailMode: String {
        case signIn = "Sign in"
        case create = "Create account"
    }

    private enum Field {
        case email
        case password
        case confirmation
        case newPassword
        case newPasswordConfirmation
    }

    var body: some View {
        ZStack {
            Color.black.opacity(colorScheme == .dark ? 0.58 : 0.32)
                .ignoresSafeArea()

            if accountManager.phase == .loading {
                loadingView
            } else {
                accountCard
            }
        }
        .transition(.opacity)
        .animation(.easeOut(duration: 0.2), value: emailMode)
        .onExitCommand {
            if accountManager.isResettingPassword {
                accountManager.dismissAccount()
            } else if emailMode != nil {
                emailMode = nil
            } else {
                accountManager.dismissAccount()
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.regular)
            Text("Opening your Intent workspace")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(GraphTheme.muted(colorScheme))
        }
        .padding(28)
        .adaptiveGlassPanel(colorScheme: colorScheme, cornerRadius: 18)
    }

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15)
                        .fill(GraphTheme.elevatedSurface(colorScheme))
                    Image(systemName: "scope")
                        .font(.system(size: 27, weight: .medium))
                }
                .frame(width: 58, height: 58)
                .overlay(RoundedRectangle(cornerRadius: 15).stroke(GraphTheme.stroke(colorScheme)))

                VStack(alignment: .leading, spacing: 5) {
                    Text(accountTitle)
                        .font(.system(size: 25, weight: .semibold, design: .rounded))
                    Text(accountSubtitle)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(GraphTheme.muted(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                if !accountManager.requiresFirstRunChoice {
                    Button {
                        accountManager.dismissAccount()
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Close")
                }
            }

            if accountManager.isResettingPassword {
                resetPasswordView
            } else if emailMode == nil {
                choiceView
            } else {
                emailView
            }

            if let message = accountManager.errorMessage {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let message = accountManager.noticeMessage {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(red: 0.35, green: 0.82, blue: 0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(28)
        .frame(width: 480)
        .adaptiveGlassPanel(colorScheme: colorScheme, cornerRadius: 22)
        .shadow(color: .black.opacity(0.3), radius: 30, y: 18)
    }

    private var accountTitle: String {
        if accountManager.isResettingPassword { return "Choose a new password" }
        return emailMode == nil ? "Your Intent workspace" : emailMode!.rawValue
    }

    private var accountSubtitle: String {
        if accountManager.isResettingPassword {
            return "Finish recovering your account, then your synced workspace will be ready."
        }
        return emailMode == nil
            ? "Focus on one thing. Keep it with you."
            : "Your intentions and settings stay in sync across your Macs."
    }

    private var choiceView: some View {
        VStack(spacing: 11) {
            Button {
                Task { await accountManager.signInWithGoogle() }
            } label: {
                HStack(spacing: 11) {
                    GoogleMark()
                    Text("Continue with Google")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Image(systemName: "arrow.right")
                        .foregroundStyle(GraphTheme.muted(colorScheme))
                }
                .padding(.horizontal, 15)
                .frame(height: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accountChoiceStyle(colorScheme: colorScheme)
            .disabled(accountManager.isBusy || !accountManager.isConfigured)

            Button {
                emailMode = .signIn
                DispatchQueue.main.async { focusedField = .email }
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: "envelope.fill")
                        .frame(width: 20)
                    Text("Continue with email")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Image(systemName: "arrow.right")
                        .foregroundStyle(GraphTheme.muted(colorScheme))
                }
                .padding(.horizontal, 15)
                .frame(height: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accountChoiceStyle(colorScheme: colorScheme)
            .disabled(accountManager.isBusy || !accountManager.isConfigured)

            HStack(spacing: 14) {
                Rectangle().fill(GraphTheme.stroke(colorScheme)).frame(height: 1)
                Text("OR")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(GraphTheme.muted(colorScheme))
                Rectangle().fill(GraphTheme.stroke(colorScheme)).frame(height: 1)
            }
            .padding(.vertical, 2)

            Button {
                accountManager.continueAsGuest()
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: "person.crop.circle")
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Continue as guest")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Everything works; your workspace stays on this Mac.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(GraphTheme.muted(colorScheme))
                    }
                    Spacer()
                    Image(systemName: "arrow.right")
                        .foregroundStyle(GraphTheme.muted(colorScheme))
                }
                .padding(.horizontal, 15)
                .frame(height: 54)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accountChoiceStyle(colorScheme: colorScheme)
            .disabled(accountManager.isBusy)

            if let message = accountManager.configurationMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(GraphTheme.muted(colorScheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var emailView: some View {
        VStack(alignment: .leading, spacing: 13) {
            Picker("Email action", selection: Binding(
                get: { emailMode ?? .signIn },
                set: { emailMode = $0 }
            )) {
                Text("Sign in").tag(EmailMode.signIn)
                Text("Create account").tag(EmailMode.create)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(spacing: 10) {
                TextField("Email", text: $email)
                    .focused($focusedField, equals: .email)
                    .onSubmit { focusedField = .password }

                SecureField("Password", text: $password)
                    .focused($focusedField, equals: .password)
                    .onSubmit {
                        if emailMode == .create {
                            focusedField = .confirmation
                        } else {
                            submitEmail()
                        }
                    }

                if emailMode == .create {
                    SecureField("Confirm password", text: $confirmation)
                        .focused($focusedField, equals: .confirmation)
                        .onSubmit { submitEmail() }
                }
            }
            .textFieldStyle(.plain)
            .padding(13)
            .background(GraphTheme.surface(colorScheme))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(GraphTheme.stroke(colorScheme)))
            .clipShape(RoundedRectangle(cornerRadius: 11))

            HStack {
                Button("Back") {
                    emailMode = nil
                    password = ""
                    confirmation = ""
                }
                .buttonStyle(.plain)
                .foregroundStyle(GraphTheme.muted(colorScheme))

                if emailMode == .signIn {
                    Button("Forgot password?") {
                        Task { await accountManager.sendPasswordReset(email: email) }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(GraphTheme.muted(colorScheme))
                }

                Spacer()

                Button(accountManager.isBusy ? "Please wait" : emailMode!.rawValue) {
                    submitEmail()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.28, green: 0.76, blue: 0.44))
                .disabled(accountManager.isBusy)
            }

            if emailMode == .create {
                Text("Use at least 8 characters. A new account begins with a clean, empty Intent canvas.")
                    .font(.caption2)
                    .foregroundStyle(GraphTheme.muted(colorScheme))
            }
        }
    }

    private var resetPasswordView: some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(spacing: 10) {
                SecureField("New password", text: $password)
                    .focused($focusedField, equals: .newPassword)
                    .onSubmit { focusedField = .newPasswordConfirmation }

                SecureField("Confirm new password", text: $confirmation)
                    .focused($focusedField, equals: .newPasswordConfirmation)
                    .onSubmit { submitNewPassword() }
            }
            .textFieldStyle(.plain)
            .padding(13)
            .background(GraphTheme.surface(colorScheme))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(GraphTheme.stroke(colorScheme)))
            .clipShape(RoundedRectangle(cornerRadius: 11))

            HStack {
                Text("Use at least 8 characters.")
                    .font(.caption2)
                    .foregroundStyle(GraphTheme.muted(colorScheme))

                Spacer()

                Button(accountManager.isBusy ? "Please wait" : "Update password") {
                    submitNewPassword()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.28, green: 0.76, blue: 0.44))
                .disabled(accountManager.isBusy)
            }
        }
        .onAppear {
            password = ""
            confirmation = ""
            DispatchQueue.main.async { focusedField = .newPassword }
        }
    }

    private func submitEmail() {
        guard let emailMode else { return }
        Task {
            switch emailMode {
            case .signIn:
                await accountManager.signIn(email: email, password: password)
            case .create:
                await accountManager.signUp(
                    email: email,
                    password: password,
                    confirmation: confirmation
                )
            }
        }
    }

    private func submitNewPassword() {
        Task {
            await accountManager.updatePassword(password, confirmation: confirmation)
        }
    }
}

struct IntentAccountSettingsSection: View {
    @EnvironmentObject private var accountManager: IntentAccountManager
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("ACCOUNT")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(GraphTheme.muted(colorScheme))

            HStack(spacing: 11) {
                Image(systemName: accountManager.isSignedIn ? "person.crop.circle.fill.badge.checkmark" : "person.crop.circle")
                    .font(.system(size: 22))

                VStack(alignment: .leading, spacing: 2) {
                    Text(accountManager.accountEmail ?? "Guest")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(accountManager.syncStatusText)
                        .font(.caption2)
                        .foregroundStyle(GraphTheme.muted(colorScheme))
                }

                Spacer()

                if accountManager.isSignedIn {
                    Button {
                        Task { await accountManager.refreshCloudWorkspace() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(accountManager.isBusy)
                    .help("Sync now")
                }
            }
            .padding(12)
            .background(GraphTheme.surface(colorScheme))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(GraphTheme.stroke(colorScheme)))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            if accountManager.isSignedIn {
                Button("Sign out") {
                    Task { await accountManager.signOut() }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .disabled(accountManager.isBusy)
            } else {
                Button("Sign in or create account") {
                    accountManager.presentAccount()
                }
                .buttonStyle(.plain)
            }

            if let message = accountManager.errorMessage {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let message = accountManager.noticeMessage {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(Color(red: 0.35, green: 0.82, blue: 0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct GoogleMark: View {
    var body: some View {
        ZStack {
            Circle().fill(.white)
            Text("G")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.25, green: 0.49, blue: 0.91))
        }
        .frame(width: 21, height: 21)
        .overlay(Circle().stroke(Color.black.opacity(0.1)))
    }
}

private extension View {
    func accountChoiceStyle(colorScheme: ColorScheme) -> some View {
        background(GraphTheme.surface(colorScheme))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(GraphTheme.stroke(colorScheme)))
            .clipShape(RoundedRectangle(cornerRadius: 11))
    }
}
