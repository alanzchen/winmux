    import Common
    import Foundation
    import SwiftUI
    
private let winmuxRepositoryURL = "https://github.com/alanzchen/winmux"

    @MainActor
    public func menuBar(
        viewModel: TrayMenuModel,
        checkForUpdates: (() -> Void)? = nil,
    ) -> some Scene { // todo should it be converted to "SwiftUI struct"?
        MenuBarExtra {
            let shortIdentification = "\(aeroSpaceAppName) v\(aeroSpaceAppVersion) \(gitShortHash)"
            let identification      = "\(aeroSpaceAppName) v\(aeroSpaceAppVersion) \(gitHash)"
        Text(shortIdentification)
        Button("Copy to clipboard") { identification.copyToClipboard() }
            .keyboardShortcut("C", modifiers: .command)
        Divider()
        if viewModel.debugRecording != nil {
            Button("Debug recording… Stop") {
                _ = DebugRecorder.shared.stop(reason: "it was stopped from the menu bar")
            }
            Divider()
        }
        // D-S3-1: until a reload without errors, whether or not the config was applied.
        if let details = viewModel.configErrorDetails {
            Button {
                MessageModel.shared.openDetails(details)
            } label: {
                Label("\(configHasErrorsMenuTitle) — Show Error Details", systemImage: "exclamationmark.octagon.fill")
            }
            Divider()
        } else if viewModel.lastReloadConfigContainedWarnings, let token: RunSessionGuard = .isServerEnabled {
            // Upstream 890ec336: a config that loaded with warnings; the button shows them.
            Button {
                Task.startUnstructured {
                    try await runLightSession(.menuBarButton, token) {
                        let args = ReloadConfigCmdArgs(rawArgs: []).copy(\.warningsAsErrors, true)
                        _ = try await reloadConfig(args: args)
                    }
                }
            } label: {
                Label("Config contains warnings…", systemImage: "exclamationmark.triangle.fill")
            }
            Divider()
        }
        if let details = viewModel.persistenceFailureDetails {
            Button {
                MessageModel.shared.openDetails(details)
            } label: {
                Label("\(persistenceFailedMenuTitle) — Show Details", systemImage: "externaldrive.badge.exclamationmark")
            }
            if viewModel.canRetryPersistenceNow {
                Button(persistenceRetryNowMenuTitle) { PersistenceHealth.shared.retryNow() }
            }
            Divider()
        }
        if viewModel.accessibilityPermissionStatus == .granted {
            Button(viewModel.isEnabled ? "Disable" : "Enable") {
                _ = Task {
                    try await runLightSession(.menuBarButton, .forceRun) { () throws in
                        _ = try await EnableCommand(args: EnableCmdArgs(rawArgs: [], targetState: .toggle))
                            .run(.defaultEnv, .emptyStdin)
                    }
                }
            }.keyboardShortcut("E", modifiers: .command)
            OpenShortcutSettingsButton()
        } else {
            Text("Waiting for Accessibility permission")
            Button("Open Accessibility Settings…") {
                viewModel.accessibilityPermissionStatus = .waitingWithPrompt
                openURLString("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            }
        }
        WinMuxErrorDetailsMenuButton()
        if let checkForUpdates {
            Button("Check for Updates…") {
                checkForUpdates()
            }
        }
        Button("GitHub Repository") {
            openURLString(winmuxRepositoryURL)
        }
        Button("File an issue...") {
            openURLString(winMuxNewIssueURL)
        }
        Button("Quit \(aeroSpaceAppName)") {
            terminationHandler?.beforeTermination()
            terminateApp()
        }.keyboardShortcut("Q", modifiers: .command)
    } label: {
        switch menuBarIconKind(viewModel) {
            case .debugRecording:
                Image(systemName: "record.circle.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .accessibilityLabel("WinMux: debug recording")
            case .accessibilityMissing:
                Image(systemName: "exclamationmark.triangle.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            case .appIcon:
                MenuBarAppIcon().environmentObject(viewModel)
            case .disabled:
                Image(systemName: "pause.circle.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
        }
    }
}

enum MenuBarIconKind: Equatable {
    /// A debug recording is running: shown over anything else.
    case debugRecording
    case accessibilityMissing
    case appIcon
    case disabled
}

@MainActor
func menuBarIconKind(_ model: TrayMenuModel) -> MenuBarIconKind {
    if model.debugRecording != nil { return .debugRecording }
    if model.accessibilityPermissionStatus != .granted { return .accessibilityMissing }
    return model.isEnabled ? .appIcon : .disabled
}

@MainActor @ViewBuilder
func openConfigButton() -> some View {
    let button = Button("Open config") {
        switch findCustomConfigUrl() {
            case .file(let url):
                NSWorkspace.shared.open(url)
            case .noCustomConfigExists:
                let createdUrl = try? ensureBootstrapConfigExistsIfNeeded()
                NSWorkspace.shared.open(createdUrl ?? preferredEditableConfigUrl())
            case .ambiguousConfigError:
                NSWorkspace.shared.open(preferredEditableConfigUrl())
        }
    }.keyboardShortcut(",", modifiers: .command)
    shortcutGroup(label: Text("⌘ ,"), content: button)
}

@MainActor @ViewBuilder
func reloadConfigButton() -> some View {
    if let token: RunSessionGuard = .isServerEnabled {
        let button = Button("Reload config") {
            _ = Task {
                try await runLightSession(.menuBarButton, token) { _ = try await reloadConfig() }
            }
        }.keyboardShortcut("R", modifiers: .command)
        shortcutGroup(label: Text("⌘ R"), content: button)
    }
}

@MainActor
private func openURLString(_ urlString: String) {
    guard let url = URL(string: urlString) else { return }
    NSWorkspace.shared.open(url)
}

func shortcutGroup(label: some View, content: some View) -> some View {
    GroupBox {
        VStack(alignment: .trailing, spacing: 6) {
            label
                .foregroundStyle(Color.secondary)
            content
        }
    }
}
