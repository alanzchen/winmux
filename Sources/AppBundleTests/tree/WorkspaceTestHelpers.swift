@testable import AppBundle

extension Workspace {
    /// Fixture setup for an automatically named workspace that stays when empty, the state
    /// `getOrCreateFallbackWorkspace` gives the workspaces it creates.
    @MainActor
    func markAsAutomaticDurableForTests() {
        markAsAutomaticallyNamed()
        lifecycle = .durable
    }
}
