extension Window {
    @MainActor
    /// `abandonIf`, checked once the classification has answered, gives the relayout up with
    /// `WindowRelayoutAbandoned` before anything moves.
    func relayoutWindow(on workspace: Workspace, forceTile: Bool = false,
                        abandonIf: (@MainActor (Window) -> Bool)? = nil) async throws {
        let data = forceTile
            ? bindingDataForNewTilingWindow(workspace, window: self)
            : try await unbindAndGetBindingDataForNewWindow(self.asMacWindow().windowId, self.asMacWindow().macApp, workspace,
                window: self, abandonIf: abandonIf)
        bind(to: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
    }
}
