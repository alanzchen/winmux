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
            let shortIdentification = "\(winMuxAppName) v\(winMuxAppVersion) \(gitShortHash)"
            let identification      = "\(winMuxAppName) v\(winMuxAppVersion) \(gitHash)"
        Text(shortIdentification)
        Button("Copy to clipboard") { identification.copyToClipboard() }
            .keyboardShortcut("C", modifiers: .command)
        Divider()
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
        Button("Quit \(winMuxAppName)") {
            _ = Task {
                defer { terminateApp() }
                try await terminationHandler.beforeTermination()
            }
        }.keyboardShortcut("Q", modifiers: .command)
    } label: {
        if viewModel.accessibilityPermissionStatus != .granted {
            Image(systemName: "exclamationmark.triangle.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else if viewModel.isEnabled {
            MenuBarAppIcon().environmentObject(viewModel)
        } else {
            Image(systemName: "pause.circle.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }
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
