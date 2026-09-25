import AppKit
import Common
import SwiftUI

/// Switching projects from the switcher, a shortcut, or a command slides the old project's
/// workspaces out and the new one's in, in the order the switcher shows them. A swipe already
/// moves the pages itself and doesn't use this.
struct WorkspaceSidebarProjectPageTransition: Equatable {
    let id: Int
    let fromProjectId: WorkspaceProjectId
    let toProjectId: WorkspaceProjectId
    /// 1 when the new project is to the right of the old one in the switcher, -1 to the left.
    let direction: Int
    /// Captured once, so toggling Reduce Motion mid-switch can't make the pages jump.
    let reducesMotion: Bool
    /// Where each page starts, in page widths from the visible slot. A switch that interrupts
    /// another starts its pages wherever they had got to.
    var outgoingStart: CGFloat = 0
    var incomingStart: CGFloat
    /// When the slide began; nil while the pages still wait at their starting positions.
    var startedUptime: TimeInterval?

    /// Where each page is now, in page widths.
    func positions(at uptime: TimeInterval) -> (outgoing: CGFloat, incoming: CGFloat) {
        let progress = reducesMotion ? 1 : startedUptime.map {
            workspaceSidebarProjectPageEasing((uptime - $0) / workspaceSidebarProjectPageTransitionDuration)
        } ?? 0
        return (outgoingStart + (CGFloat(-direction) - outgoingStart) * progress, incomingStart * (1 - progress))
    }
}

let workspaceSidebarProjectPageTransitionDuration: TimeInterval = 0.3
let workspaceSidebarProjectPageCrossfadeDuration: TimeInterval = 0.18
/// Quick to leave and gentle to settle, like switching spaces in a browser sidebar.
private let workspaceSidebarProjectPageCurve = (x1: 0.22, y1: 0.9, x2: 0.3, y2: 1.0)

func workspaceSidebarProjectPageAnimation(reduceMotion: Bool) -> Animation {
    let curve = workspaceSidebarProjectPageCurve
    return reduceMotion
        ? .easeInOut(duration: workspaceSidebarProjectPageCrossfadeDuration)
        : .timingCurve(curve.x1, curve.y1, curve.x2, curve.y2, duration: workspaceSidebarProjectPageTransitionDuration)
}

/// How far along the slide is at a share of its duration: the same curve the animation uses,
/// so an interrupting switch can pick the pages up where they are.
func workspaceSidebarProjectPageEasing(_ time: Double) -> CGFloat {
    let t = min(max(time, 0), 1)
    let curve = workspaceSidebarProjectPageCurve
    func bezier(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
        3 * (1 - s) * (1 - s) * s * p1 + 3 * (1 - s) * s * s * p2 + s * s * s
    }
    // Find the curve parameter whose x is `t`; x rises with the parameter, so bisect.
    var low = 0.0
    var high = 1.0
    for _ in 0..<30 {
        let mid = (low + high) / 2
        if bezier(mid, curve.x1, curve.x2) < t { low = mid } else { high = mid }
    }
    return CGFloat(bezier((low + high) / 2, curve.y1, curve.y2))
}

/// Which way the pages move, or nil when there is nothing to animate.
func workspaceSidebarProjectPageDirection(
    from fromProjectId: WorkspaceProjectId,
    to toProjectId: WorkspaceProjectId,
    projects: [WorkspaceSidebarProjectViewModel],
) -> Int? {
    guard fromProjectId != toProjectId,
          let fromIndex = projects.firstIndex(where: { $0.id == fromProjectId }),
          let toIndex = projects.firstIndex(where: { $0.id == toProjectId })
    else { return nil }
    return toIndex > fromIndex ? 1 : -1
}

/// A new switch, starting its pages where an interrupted one had left them: the page that was
/// coming in goes out from where it is. Going straight back brings the other page back from
/// where it is; going on brings the next page in right behind it. (The page the interrupted
/// switch was sending away isn't tracked, so a sliver it still covered goes blank for a moment.)
func workspaceSidebarProjectPageTransition(
    id: Int,
    from fromProjectId: WorkspaceProjectId,
    to toProjectId: WorkspaceProjectId,
    direction: Int,
    reducesMotion: Bool,
    interrupting running: WorkspaceSidebarProjectPageTransition?,
    at uptime: TimeInterval,
) -> WorkspaceSidebarProjectPageTransition {
    var transition = WorkspaceSidebarProjectPageTransition(id: id, fromProjectId: fromProjectId, toProjectId: toProjectId,
        direction: direction, reducesMotion: reducesMotion, incomingStart: CGFloat(direction))
    guard let running, !reducesMotion, !running.reducesMotion, running.toProjectId == fromProjectId else { return transition }
    let positions = running.positions(at: uptime)
    transition.outgoingStart = positions.incoming
    transition.incomingStart = running.fromProjectId == toProjectId
        ? positions.outgoing
        : positions.incoming + CGFloat(direction)
    return transition
}

/// A project a swipe selected, told apart from a later swipe to the same project.
struct WorkspaceSidebarProjectSwipeCommit: Equatable {
    let projectId: WorkspaceProjectId
    let serial: Int
}

struct WorkspaceSidebarProjectPagePlacement: Equatable {
    var offset: CGFloat
    var opacity: Double
}

/// Where the outgoing and incoming pages sit partway through a switch, from the visible slot.
/// With Reduce Motion the pages stay put and crossfade. Only the two pages involved move,
/// however far apart the projects are, so the switch never flashes past the ones in between.
func workspaceSidebarProjectPagePlacements(
    direction: Int,
    progress: CGFloat,
    pageWidth: CGFloat,
    reduceMotion: Bool,
    outgoingStart: CGFloat = 0,
    incomingStart: CGFloat? = nil,
) -> (outgoing: WorkspaceSidebarProjectPagePlacement, incoming: WorkspaceSidebarProjectPagePlacement) {
    let progress = min(max(progress, 0), 1)
    if reduceMotion {
        return (.init(offset: 0, opacity: Double(1 - progress)), .init(offset: 0, opacity: Double(progress)))
    }
    let incomingStart = incomingStart ?? CGFloat(direction)
    return (
        .init(offset: (outgoingStart + (CGFloat(-direction) - outgoingStart) * progress) * pageWidth, opacity: 1),
        .init(offset: incomingStart * (1 - progress) * pageWidth, opacity: 1),
    )
}

/// How far a page is moved from its own slot in the pager, and how visible it is, during a
/// switch; nil for pages not involved. The pager already sits at the new project, so the old
/// page is brought in from its slot, however far away. Both pages keep their identity, so
/// nothing reloads when the switch ends.
func workspaceSidebarProjectPageSlotPlacement(
    projectId: WorkspaceProjectId,
    index: Int,
    displayIndex: Int,
    displayedProjectId: WorkspaceProjectId?,
    transition: WorkspaceSidebarProjectPageTransition?,
    progress: CGFloat,
    pageWidth: CGFloat,
) -> WorkspaceSidebarProjectPagePlacement? {
    guard let transition, displayedProjectId == transition.toProjectId,
          projectId == transition.fromProjectId || projectId == transition.toProjectId
    else { return nil }
    let placements = workspaceSidebarProjectPagePlacements(direction: transition.direction, progress: progress,
        pageWidth: pageWidth, reduceMotion: transition.reducesMotion,
        outgoingStart: transition.outgoingStart, incomingStart: transition.incomingStart)
    if projectId == transition.toProjectId { return placements.incoming }
    let slotOffset = CGFloat(index - displayIndex) * pageWidth
    return .init(offset: placements.outgoing.offset - slotOffset, opacity: placements.outgoing.opacity)
}

extension WorkspaceSidebarView {
    /// Called when the active project changes. Only the expanded Sidebar pages between
    /// projects; the collapsed rail, the all-projects list, and the floating columns don't.
    /// Nor does a drag: its drop targets must stay where the pages are.
    func startProjectPageTransitionIfNeeded(from fromProjectId: WorkspaceProjectId?, to toProjectId: WorkspaceProjectId) {
        let collapsedWidth = snapshot.configuration.expansionStartWidth
        let expandedWidth = snapshot.configuration.expandedWidth
        let expansionProgress = (snapshot.visibleWidth - collapsedWidth) / max(expandedWidth - collapsedWidth, 1)
        guard let fromProjectId, !showsAllProjects, !isWorkspaceSidebarDragInProgress(),
              expansionProgress >= workspaceSidebarRowsRevealProgress,
              let direction = workspaceSidebarProjectPageDirection(from: fromProjectId, to: toProjectId,
                  projects: snapshot.projects)
        else {
            endProjectPageTransition()
            return
        }
        projectPageTransitionSerial += 1
        let reduceMotion = reduceDockMotion
        let transition = workspaceSidebarProjectPageTransition(id: projectPageTransitionSerial, from: fromProjectId,
            to: toProjectId, direction: direction, reducesMotion: reduceMotion,
            interrupting: projectPageTransition, at: ProcessInfo.processInfo.systemUptime)
        var start = Transaction()
        start.disablesAnimations = true
        withTransaction(start) {
            projectPageTransition = transition
            projectPageTransitionProgress = 0
        }
        // The first frame shows the pages where they were; the slide starts on the next one.
        DispatchQueue.main.async {
            guard projectPageTransition?.id == transition.id else { return }
            projectPageTransition?.startedUptime = ProcessInfo.processInfo.systemUptime
            withAnimation(workspaceSidebarProjectPageAnimation(reduceMotion: reduceMotion)) {
                projectPageTransitionProgress = 1
            }
            let duration = reduceMotion ? workspaceSidebarProjectPageCrossfadeDuration : workspaceSidebarProjectPageTransitionDuration
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.02) {
                guard projectPageTransition?.id == transition.id else { return }
                endProjectPageTransition()
            }
        }
    }

    func endProjectPageTransition() {
        guard projectPageTransition != nil else { return }
        var end = Transaction()
        end.disablesAnimations = true
        withTransaction(end) {
            projectPageTransition = nil
            projectPageTransitionProgress = 1
        }
    }

    func projectPageTransitionPlacement(
        index: Int,
        projectId: WorkspaceProjectId,
        displayIndex: Int,
        pageWidth: CGFloat,
    ) -> WorkspaceSidebarProjectPagePlacement? {
        workspaceSidebarProjectPageSlotPlacement(projectId: projectId, index: index, displayIndex: displayIndex,
            displayedProjectId: snapshot.projects.indices.contains(displayIndex) ? snapshot.projects[displayIndex].id : nil,
            transition: projectPageTransition, progress: projectPageTransitionProgress, pageWidth: pageWidth)
    }
}
