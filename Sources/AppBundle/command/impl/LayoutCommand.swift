import AppKit
import Common

struct LayoutCommand: Command {
    let args: LayoutCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        guard let target = args.resolveTargetOrReportError(env, io) else { return false }
        if args.forNextDetectedWindow {
            NewWindowIntentRegistry.shared.setNextWindowLayout(args.toggleBetween.val.first.orDie(), in: target.workspace)
            return true
        }
        let window = args.root ? nil : target.windowOrNil
        let container: TilingContainer?
        if let window {
            guard let parent = window.parent else { return false }
            switch parent.cases {
                case .tilingContainer(let parent): container = parent
                case .workspace: container = nil
                case .macosPopupWindowsContainer: return false
                case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer:
                    return io.err("Can't change layout for macOS minimized, fullscreen windows or windows of hidden apps. This behavior is subject to change")
            }
        } else {
            container = target.workspace.rootTilingContainer
        }
        let targetDescription = args.toggleBetween.val.first(where: { !matches($0, container: container) })
            ?? args.toggleBetween.val.first.orDie()
        // Window modes still require a window, including on an empty workspace.
        if window == nil, targetDescription == .tiling || targetDescription == .floating {
            return io.err(noWindowIsFocused)
        }
        if matches(targetDescription, container: container) { return !args.failIfNoop }
        switch targetDescription {
            case .hTabGroup:
                return changeTilingLayout(io, targetLayout: .tabGroup, targetOrientation: .h, container: container)
            case .vTabGroup:
                return changeTilingLayout(io, targetLayout: .tabGroup, targetOrientation: .v, container: container)
            case .h_tiles:
                return changeTilingLayout(io, targetLayout: .tiles, targetOrientation: .h, container: container)
            case .v_tiles:
                return changeTilingLayout(io, targetLayout: .tiles, targetOrientation: .v, container: container)
            case .tabGroup:
                return changeTilingLayout(io, targetLayout: .tabGroup, targetOrientation: nil, container: container)
            case .tiles:
                return changeTilingLayout(io, targetLayout: .tiles, targetOrientation: nil, container: container)
            case .horizontal:
                return changeTilingLayout(io, targetLayout: nil, targetOrientation: .h, container: container)
            case .vertical:
                return changeTilingLayout(io, targetLayout: nil, targetOrientation: .v, container: container)
            case .tiling:
                guard let window else { return io.err(noWindowIsFocused) }
                window.lastFloatingSize = try await window.getAxSize() ?? window.lastFloatingSize
                try await window.relayoutWindow(on: target.workspace, forceTile: true)
                return true
            case .floating:
                guard let window else { return io.err(noWindowIsFocused) }
                window.bindAsFloatingWindow(to: target.workspace)
                if let size = window.lastFloatingSize { window.setAxFrame(nil, size) }
                return true
        }
    }
}

@MainActor private func changeTilingLayout(_ io: CmdIo, targetLayout: Layout?, targetOrientation: Orientation?, container: TilingContainer?) -> Bool {
    guard let container else { return io.err("The window is non-tiling") }
    let targetOrientation = targetOrientation ?? container.orientation
    let targetLayout = targetLayout ?? container.layout
    if config.usesBrowserTabs, targetLayout == .tabGroup {
        return io.err("Stacks are unavailable in Tabs mode. Use separate sidebar tabs or a split.")
    }
    container.layout = targetLayout
    container.changeOrientation(targetOrientation)
    return true
}

@MainActor private func matches(_ layout: LayoutCmdArgs.LayoutDescription, container: TilingContainer?) -> Bool {
    switch layout {
        case .tabGroup: return container?.layout == .tabGroup
        case .tiles: return container?.layout == .tiles
        case .horizontal: return container?.orientation == .h
        case .vertical: return container?.orientation == .v
        case .hTabGroup: return container.map { $0.layout == .tabGroup && $0.orientation == .h } == true
        case .vTabGroup: return container.map { $0.layout == .tabGroup && $0.orientation == .v } == true
        case .h_tiles: return container.map { $0.layout == .tiles && $0.orientation == .h } == true
        case .v_tiles: return container.map { $0.layout == .tiles && $0.orientation == .v } == true
        case .tiling: return container != nil
        case .floating: return container == nil
    }
}
