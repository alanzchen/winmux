import AppKit
import Common

struct MoveMouseCommand: Command {
    let args: MoveMouseCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        // For a focus change a sidebar action made where the pointer stays: nothing to do.
        if FocusedMonitorChangePointer.isKept { return true }
        let mouse = mouseLocation
        guard let target = args.resolveTargetOrReportError(env, io) else { return false }
        switch args.mouseTarget.val {
            case .windowLazyCenter:
                guard let rect = try await windowSubjectRectOrReportError(target, io) else { return false }
                if rect.contains(mouse) {
                    if !args.failIfNoop {
                        io.err("The mouse already belongs to the window. Tip: use --fail-if-noop to exit with non-zero code")
                    }
                    return !args.failIfNoop
                }
                return moveMouse(io, rect.center)
            case .windowForceCenter:
                guard let rect = try await windowSubjectRectOrReportError(target, io) else { return false }
                return moveMouse(io, rect.center)
            case .monitorLazyCenter:
                let rect = target.workspace.workspaceMonitor.rect
                if rect.contains(mouse) {
                    if !args.failIfNoop {
                        io.err("The mouse already belongs to the monitor. Tip: use --fail-if-noop to exit with non-zero code")
                    }
                    return !args.failIfNoop
                }
                return moveMouse(io, rect.center)
            case .monitorForceCenter:
                return moveMouse(io, target.workspace.workspaceMonitor.rect.center)
        }
    }
}

@MainActor
private func moveMouse(_ io: CmdIo, _ point: CGPoint) -> Bool {
    postMoveMouseEvent(point) ? true : io.err("Failed to move mouse")
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
