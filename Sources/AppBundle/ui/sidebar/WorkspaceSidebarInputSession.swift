import AppKit

enum WorkspaceSidebarExpansionReason {
    case passive
    case hover

    func startsSearch(alwaysExpanded: Bool, isDragging: Bool, isTrackingMenu: Bool) -> Bool {
        self == .hover && !alwaysExpanded && !isDragging && !isTrackingMenu
    }
}

enum WorkspaceSidebarInputPurpose {
    case textEditing, projectCreation

    var activatesPanel: Bool { self == .textEditing }

    func acceptsNavigationKey(modifiers: CGEventFlags) -> Bool {
        self == .textEditing || modifiers.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty
    }
}

@MainActor
protocol WorkspaceSidebarInputOwner: AnyObject {
    var canCaptureSidebarInput: Bool { get }
    var sidebarInputPurpose: WorkspaceSidebarInputPurpose { get }
    func cancelInlineTextEditing()
    func handleInlineTextEditingKey(_ key: WorkspaceSidebarInlineTextKey) -> Bool
}

extension WorkspaceSidebarInputOwner {
    var sidebarInputPurpose: WorkspaceSidebarInputPurpose { .textEditing }
}

/// A session event tap must have exactly one live owner, even with multiple sidebars.
@MainActor
final class WorkspaceSidebarInputSession {
    weak var owner: (any WorkspaceSidebarInputOwner)?

    func acquire(_ next: any WorkspaceSidebarInputOwner) {
        if let previous = owner, previous !== next {
            owner = nil
            previous.cancelInlineTextEditing()
        }
        owner = next
    }

    func release(_ previous: any WorkspaceSidebarInputOwner) {
        if owner === previous { owner = nil }
    }

    func handle(_ key: WorkspaceSidebarInlineTextKey) -> Bool {
        guard let owner else { return false }
        if owner.sidebarInputPurpose == .projectCreation, !owner.canCaptureSidebarInput {
            // Even when the pointer has left without a mouse event, keyboard work disarms the page.
            return owner.handleInlineTextEditingKey(.ignored)
        }
        guard owner.canCaptureSidebarInput else { return false }
        if case .ignored = key, owner.sidebarInputPurpose != .projectCreation { return false }
        return owner.handleInlineTextEditingKey(key)
    }
}

func shouldCancelWorkspaceSidebarInputForPointer(
    isInside: Bool,
    isMouseDown: Bool,
    cancelsOnPointerExit: Bool,
    pointerHasEntered: Bool,
) -> Bool {
    !isInside && (isMouseDown || (cancelsOnPointerExit && pointerHasEntered))
}

/// Another app's activation normally ends inline editing. Just after editing starts, it is the
/// double-click's first click switching workspace or project, not the user leaving the edit.
let workspaceSidebarInlineTextActivationGrace: TimeInterval = 0.6

func workspaceSidebarInlineTextEditingCancelsForActivation(startedAt: Date, now: Date = .now) -> Bool {
    now.timeIntervalSince(startedAt) >= workspaceSidebarInlineTextActivationGrace
}
