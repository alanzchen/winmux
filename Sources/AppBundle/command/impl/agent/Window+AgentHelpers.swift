extension WorkspaceTabMember {
    var agentLayoutDescription: String {
        switch state {
            case .laidOut:
                guard let tilingLayout else { preconditionFailure("A tiled member must capture its container layout") }
                return "\(tilingLayout.orientation.rawValue)_\(tilingLayout.layout.rawValue)"
            case .floating: return "floating"
            case .nativeFullscreen: return "macos_native_fullscreen"
            case .hiddenWithApp: return "macos_native_hidden_app"
            case .minimized, .notPresentable: return "macos_native_minimized"
        }
    }
}
