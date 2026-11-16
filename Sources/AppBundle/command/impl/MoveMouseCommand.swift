import AppKit
import Common

struct MoveMouseCommand: Command {
    let args: MoveMouseCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> BinaryExitCode {
        // For a focus change a sidebar action made where the pointer stays: nothing to do.
        if FocusedMonitorChangePointer.isKept { return .succ}
        let mouse = mouseLocation
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        switch args.mouseTarget.val {
            case .windowLazyCenter:
                guard let rect = try await windowSubjectRectOrReportError(target, io) else { return .fail }
                if rect.contains(mouse) {
                    return switch args.failIfNoop {
                        case true: .fail
                        case false:
                            .succ(io.err("The mouse already belongs to the window. Tip: use --fail-if-noop to exit with non-zero code"))
                    }
                }
                return .from(bool: moveMouse(io, rect.center))
            case .windowForceCenter:
                guard let rect = try await windowSubjectRectOrReportError(target, io) else { return .fail }
                return .from(bool: moveMouse(io, rect.center))
            case .monitorLazyCenter:
                let rect = target.workspace.workspaceMonitor.rect
                if rect.contains(mouse) {
                    return switch args.failIfNoop {
                        case true: .fail
                        case false:
                            .succ(io.err("The mouse already belongs to the monitor. Tip: use --fail-if-noop to exit with non-zero code"))
                    }
                }
                return .from(bool: moveMouse(io, rect.center))
            case .monitorForceCenter:
                return .from(bool: moveMouse(io, target.workspace.workspaceMonitor.rect.center))
        }
    }
}

@MainActor
private func moveMouse(_ io: CmdIo, _ point: CGPoint) -> Bool {
    postMoveMouseEvent(point) ? true : io.errFalse("Failed to move mouse")
}

/// Moves the pointer to `point`. Tests replace it, so no real mouse event is posted.
@MainActor var postMoveMouseEvent: @MainActor (CGPoint) -> Bool = { point in
    guard let event = CGEvent(
        mouseEventSource: nil,
        mouseType: CGEventType.mouseMoved,
        mouseCursorPosition: point,
        mouseButton: CGMouseButton.left,
    ) else { return false }
    event.post(tap: CGEventTapLocation.cghidEventTap)
    return true
}

@MainActor
private func windowSubjectRectOrReportError(_ target: LiveFocus, _ io: CmdIo) async throws -> Rect? {
    // todo bug it's bad that we operate on the "ax physical" state directly. command seq won't work correctly
    //      focus <direction> command has the similar problem
    if let window: Window = target.windowOrNil {
        if let rect = window.lastAppliedLayoutPhysicalRect {
            return rect
        } else if let rect = try await window.getAxRect() {
            return rect
        } else {
            io.err("Failed to get rect of window '\(window.windowId)'")
            return nil
        }
    } else {
        io.err(noWindowIsFocused)
        return nil
    }
}
