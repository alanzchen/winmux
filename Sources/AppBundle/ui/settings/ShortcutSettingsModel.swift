import AppKit
import Foundation

@MainActor
public final class ShortcutSettingsModel: ObservableObject {
    public static let shared = ShortcutSettingsModel()

    @Published var selectedTab: Tab = .shortcuts
    @Published var sections: [Section] = []
    @Published var assignments: [String: String] = [:]
    @Published var tapBindings: [Summary] = []
    @Published var customBindings: [Summary] = []
    @Published var workspaceNumbers: [String] = []
    @Published var workspaceSwitchModifiers: NSEvent.ModifierFlags = defaultWorkspaceSwitchModifiers
    @Published var workspaceMoveModifiers: NSEvent.ModifierFlags = defaultWorkspaceMoveModifiers
    @Published var workspaceOverrides: [WorkspaceOverride] = []
    @Published public var openRequestId: Int = 0
    @Published var requestedSettingsPage: SettingsSidebarItem?
    let settingsDocument = SettingsConfigDocument()
    @Published var settingsRevision: Int = 0
    @Published var errorMessage: String? = nil {
        didSet {
            if let errorMessage { MessageModel.shared.message = Message(description: "Shortcut Settings Error", body: errorMessage) }
        }
    }

    var actionsById: [String: Action] = [:]
    var actionIdByCommand: [String: String] = [:]

    private init() {
        reload()
    }

    /// Opens the Workspace Panel page, which shows the active mode's settings.
    func requestPanelSettings() {
        requestedSettingsPage = .appearance
        requestWindowOpen()
    }
}
