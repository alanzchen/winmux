import AppKit
import SwiftUI

/// Tabs mode: Suggest Topic Groups… from a project's menu, or from several chosen tabs. Opens
/// the preview beside the sidebar that asked; nothing is read before this.
@MainActor
func openWorkspaceTopicSuggestions(projectId: WorkspaceProjectId, tabs: [String]?, panelScopeId: String) {
    guard config.suggestsTopicGroups, let model = workspaceTopicPanelModel(panelScopeId) else { return }
    let snapshot = workspaceSidebarSnapshot(from: model)
    // Only the project this sidebar shows: suggestions never reach into another.
    guard snapshot.activeProjectId == projectId else { return }
    let scope = WorkspaceTopicScope(projectId: projectId, panelScopeId: panelScopeId,
        listedScopeId: snapshot.selectedMonitorScopeId, selection: tabs)
    WorkspaceTopicCoordinator.shared.suggest(scope, snapshot: snapshot)
    if let panel = WorkspaceSidebarPanel.panel(for: panelScopeId) { WorkspaceTopicSuggestionPanel.shared.show(beside: panel) }
}

/// Whether a sidebar's menu offers Suggest Topic Groups… for `projectId`.
@MainActor
func workspaceTopicSuggestionsOffered(projectId: WorkspaceProjectId, panelScopeId: String?) -> Bool {
    guard config.suggestsTopicGroups, let panelScopeId, let model = workspaceTopicPanelModel(panelScopeId) else { return false }
    return model.workspaceSidebarActiveProjectId == projectId
}

let workspaceTopicSuggestMenuTitle = "Suggest Topic Groups…"

/// The preview: a key-able panel beside the sidebar, as wide as it. It takes key once, when it
/// opens from the menu, and never again; outside clicks leave it open so a slow suggestion
/// survives switching windows. Esc, Cancel and Apply close it.
@MainActor
final class WorkspaceTopicSuggestionPanel: NSObject, NSWindowDelegate {
    static let shared = WorkspaceTopicSuggestionPanel()
    private var panel: WorkspaceTopicSuggestionWindow?
    private var previousKeyWindow: NSWindow?
    private var anchor: CGRect = .zero
    private var localMonitor: Any?
    private var width: CGFloat = 240

    var isVisible: Bool { panel?.isVisible == true }

    static func width(forSidebarWidth width: CGFloat) -> CGFloat { min(max(width, 160), 400) }

    func show(beside sidebar: WorkspaceSidebarPanel) {
        let surface = sidebar.visibleSurfaceFrameOnScreen
        show(anchor: surface.isEmpty ? sidebar.frame : surface, sidebarWidth: CGFloat(sidebar.sidebarSettings.width))
    }

    func show(anchor: CGRect, sidebarWidth: CGFloat) {
        self.anchor = anchor
        width = Self.width(forSidebarWidth: sidebarWidth)
        if let panel {
            panel.contentView = hostingView()
            resizeNow()
            return
        }
        previousKeyWindow = NSApp.keyWindow
        let panel = WorkspaceTopicSuggestionWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        panel.contentView = hostingView()
        self.panel = panel
        resizeNow()
        panel.makeKeyAndOrderFront(nil)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, let panel = self.panel, event.window === panel, event.keyCode == 53 else { return false }
                self.dismiss()
                return true
            }
            return consumed ? nil : event
        }
    }

    private func hostingView() -> NSView {
        let view = NSHostingView(rootView: WorkspaceTopicSuggestionView(coordinator: .shared, width: width,
            maximumHeight: maximumHeight, resized: { [weak self] in self?.resize() }, dismiss: { [weak self] in self?.dismiss() }))
        return view
    }

    private var screenBounds: CGRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        return screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 800)
    }

    private var maximumHeight: CGFloat { max(200, screenBounds.height - 16) }

    func resize() {
        DispatchQueue.main.async { [weak self] in self?.resizeNow() }
    }

    private func resizeNow() {
        guard let panel, let view = panel.contentView else { return }
        view.layoutSubtreeIfNeeded()
        let bounds = screenBounds
        let size = CGSize(width: width, height: min(view.fittingSize.height, maximumHeight))
        // Beside the sidebar, on the side with room; never off the screen.
        let rightX = anchor.maxX + 8
        let x = rightX + size.width <= bounds.maxX - 8 ? rightX : max(bounds.minX + 8, anchor.minX - 8 - size.width)
        let y = min(max(anchor.maxY - size.height, bounds.minY + 8), bounds.maxY - size.height - 8)
        panel.setFrame(CGRect(origin: CGPoint(x: min(x, bounds.maxX - size.width - 8), y: y), size: size), display: true)
    }

    /// Esc or Cancel: stop, keep nothing.
    func dismiss() {
        WorkspaceTopicCoordinator.existing?.cancel()
        close()
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        // Hand key back only if the preview still has it: after the user has moved on, closing
        // it, say because the setting was turned off, must not take their focus back.
        let ownsKey = panel.isKeyWindow
        panel.orderOut(nil)
        if ownsKey, previousKeyWindow?.isVisible == true { previousKeyWindow?.makeKey() }
        previousKeyWindow = nil
        WorkspaceSidebarPanel.scheduleHoverRecheckForVisiblePanels()
    }
}

private final class WorkspaceTopicSuggestionWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The preview's content: the request, its state, the groups to edit, and what was left out.
struct WorkspaceTopicSuggestionView: View {
    @ObservedObject var coordinator: WorkspaceTopicCoordinator
    let width: CGFloat
    let maximumHeight: CGFloat
    let reduceMotionOverride: Bool?
    let resized: () -> Void
    let dismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var showsSkipped: Bool
    @State private var showsAnalyzed: Bool

    init(coordinator: WorkspaceTopicCoordinator, width: CGFloat, maximumHeight: CGFloat = 640, reduceMotionOverride: Bool? = nil,
         showsSkipped: Bool = false, showsAnalyzed: Bool = false, resized: @escaping () -> Void = {}, dismiss: @escaping () -> Void = {}) {
        self.coordinator = coordinator
        self.width = width
        self.maximumHeight = maximumHeight
        self.reduceMotionOverride = reduceMotionOverride
        self.resized = resized
        self.dismiss = dismiss
        _showsSkipped = State(initialValue: showsSkipped)
        _showsAnalyzed = State(initialValue: showsAnalyzed)
    }

    private var reducesMotion: Bool { reduceMotionOverride ?? systemReduceMotion }
    private var isNarrow: Bool { width < 200 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(12)
            Divider()
            ScrollView(.vertical) {
                content.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: max(120, maximumHeight - 120))
            Divider()
            footer.padding(12)
        }
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        .background(WorkspaceTopicSuggestionBackground())
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .transaction { if reducesMotion { $0.animation = nil } }
        .onChange(of: coordinator.phase) { phase in
            // Nothing to group, but a browser tab could be included: show how.
            if phase == .ready, coordinator.groups.isEmpty,
               coordinator.request?.prepared.skipped.contains(where: { if case .browser = $0.reason { true } else { false } }) == true {
                showsSkipped = true
            }
            resized()
        }
        .onChange(of: coordinator.groups.count) { _ in resized() }
        .onChange(of: showsSkipped) { _ in resized() }
        .onChange(of: showsAnalyzed) { _ in resized() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggested topic groups")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Suggested Groups").font(.headline)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            }
        }
    }

    private var subtitle: String? {
        guard let scope = coordinator.request?.scope else { return nil }
        let project = TrayMenuModel.shared.workspaceSidebarProjects.first { $0.id == scope.projectId }?.displayName
        let range: String = if let selection = scope.selection { "\(selection.count) chosen tabs" }
            else if scope.listedScopeId == workspaceSidebarDefaultScopeId { "All displays" }
            else if scope.listedScopeId == workspaceSidebarFocusedScopeId { "Focused tab" }
            else { "This display" }
        return [project, range].compactMap(\.self).joined(separator: " · ")
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch coordinator.phase {
                case .idle:
                    EmptyView()
                case .checking:
                    progress("Checking Apple Intelligence…", fraction: nil)
                case .analyzing(let done, let total):
                    progress(total == 0 ? "Reading tabs…" : "Analyzing \(min(done + 1, total)) of \(total) tabs on this Mac…",
                        fraction: total == 0 ? nil : Double(done) / Double(total))
                case .unavailable(let reason):
                    notice(reason.message, systemImage: "exclamationmark.circle")
                case .failed(let failure):
                    notice(failure.message, systemImage: "exclamationmark.triangle")
                    Button("Try Again") { coordinator.suggestAgain() }
                case .notApplied(let message):
                    notice(message, systemImage: "exclamationmark.triangle")
                    Button("Suggest Again") { coordinator.suggestAgain() }
                case .ready, .applying:
                    if coordinator.groups.isEmpty {
                        notice(emptyMessage, systemImage: "rectangle.stack")
                    } else {
                        ForEach($coordinator.groups) { $group in
                            WorkspaceTopicGroupEditor(group: $group, displays: coordinator.request?.prepared.displays ?? [:],
                                isNarrow: isNarrow)
                        }
                    }
            }
            if coordinator.request != nil { summary }
        }
    }

    private var emptyMessage: String {
        let candidates = coordinator.request?.prepared.candidates.count ?? 0
        return candidates < 2 ? "There aren't enough tabs here to group. Tabs WinMux didn't read are listed below."
            : "No clear topics. WinMux only suggests groups when tabs plainly share one."
    }

    private func progress(_ text: String, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let fraction { ProgressView(value: fraction) } else { ProgressView().controlSize(.small) }
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Text("Titles are analyzed on this Mac and never sent anywhere.").font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func notice(_ text: String, systemImage: String) -> some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: systemImage) }
            .font(.callout)
            .accessibilityElement(children: .combine)
    }

    /// Tabs left as they are, and tabs WinMux didn't read, with the browser opt-in.
    @ViewBuilder private var summary: some View {
        if let request = coordinator.request {
            let grouped = Set(coordinator.groups.flatMap(\.includedMembers))
            let analyzedLeft = request.analyzed.filter { !grouped.contains($0.token) && !request.untagged.contains($0.token) }.count
            let unchanged = request.prepared.unchangedCount + (coordinator.phase == .ready ? analyzedLeft : 0)
            let skipped = request.prepared.skipped
            VStack(alignment: .leading, spacing: 8) {
                if unchanged > 0 {
                    Text("Left as they are: \(unchanged) \(unchanged == 1 ? "tab" : "tabs")").font(.caption).foregroundStyle(.secondary)
                }
                if !skipped.isEmpty || !request.thin.isEmpty || !request.untagged.isEmpty {
                    let count = skipped.count + request.thin.count + request.untagged.count
                    DisclosureGroup(isExpanded: $showsSkipped) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(skipped) { tab in skippedRow(tab, request: request) }
                            ForEach(request.thin, id: \.rawValue) { token in
                                skippedText(request.prepared.displays[token]?.title ?? "Tab",
                                    reason: WorkspaceTopicSkipReason.notEnoughToGoOn.description)
                            }
                            ForEach(request.untagged, id: \.rawValue) { token in
                                skippedText(request.prepared.displays[token]?.title ?? "Tab",
                                    reason: WorkspaceTopicSkipReason.untagged.description)
                            }
                        }
                        .padding(.top, 4)
                    } label: {
                        Text("Left out: \(count) \(count == 1 ? "tab" : "tabs")").font(.caption)
                    }
                }
                if !request.analyzed.isEmpty {
                    DisclosureGroup(isExpanded: $showsAnalyzed) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(request.analyzed, id: \.token.rawValue) { evidence in
                                Text(evidence.promptText).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            }
                        }
                        .padding(.top, 4)
                    } label: {
                        Text("What was analyzed").font(.caption)
                    }
                }
            }
        }
    }

    private func skippedText(_ title: String, reason: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).lineLimit(2).truncationMode(.middle)
            Text(reason).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func skippedRow(_ tab: WorkspaceTopicSkippedTab, request: WorkspaceTopicRequestState) -> some View {
        let title = request.prepared.displays[tab.token]?.title ?? "Tab"
        if case .browser = tab.reason, let preview = tab.preview {
            let name = request.prepared.bindings[tab.token]?.name ?? ""
            let revoked = request.prepared.revokedConsents.contains(tab.token)
            VStack(alignment: .leading, spacing: 4) {
                skippedText(title, reason: revoked ? "Its titles changed since you included it. Check them again." : tab.reason.description)
                Text(preview.isEmpty ? "(No titles)" : preview).font(.caption2.monospaced())
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .padding(6).background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                Toggle("Include these titles in this suggestion", isOn: Binding(
                    get: { coordinator.includedBrowserTabs.contains(name) },
                    set: { coordinator.setBrowserTab(tab.token, included: $0) }))
                    .toggleStyle(.checkbox).font(.caption)
                    .disabled(preview.isEmpty || coordinator.phase == .applying)
                Text("WinMux can't tell whether a browser window is private.").font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            skippedText(title, reason: tab.reason.description)
        }
    }

    private var applyTitle: String {
        let count = coordinator.groups.filter { $0.isIncluded && $0.problem == nil }.count
        return count == 0 ? "Apply" : count == 1 ? "Apply 1 Group" : "Apply \(count) Groups"
    }

    private var canApply: Bool {
        coordinator.phase == .ready && coordinator.groups.contains(where: \.isIncluded) &&
            coordinator.groups.allSatisfy { $0.problem == nil } && workspaceTopicReadOnlyReason() == nil
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if coordinator.phase == .ready, !coordinator.groups.isEmpty, let reason = workspaceTopicReadOnlyReason() {
                Text(reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if offersApply {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        cancelButton
                        Spacer(minLength: 8)
                        applyButton
                    }
                    VStack(alignment: .trailing, spacing: 6) {
                        applyButton.frame(maxWidth: .infinity, alignment: .trailing)
                        cancelButton.frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            } else {
                cancelButton.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// Apply shows only with groups to apply; otherwise there's only a way out.
    private var offersApply: Bool {
        (coordinator.phase == .ready || coordinator.phase == .applying) && !coordinator.groups.isEmpty
    }

    private var isWorking: Bool {
        switch coordinator.phase {
            case .checking, .analyzing, .applying: true
            default: false
        }
    }

    private var cancelButton: some View {
        Button(offersApply || isWorking ? "Cancel" : "Close") { dismiss() }.keyboardShortcut(.cancelAction).fixedSize()
    }

    private var applyButton: some View {
        Button(applyTitle) { coordinator.apply() }
            .keyboardShortcut(.defaultAction)
            .disabled(!canApply)
            .fixedSize()
    }
}

/// One suggested group: whether to make it, its name, and which tabs go in it.
struct WorkspaceTopicGroupEditor: View {
    @Binding var group: WorkspaceTopicDraftGroup
    let displays: [WorkspaceTopicToken: WorkspaceTopicTabDisplay]
    let isNarrow: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Toggle("", isOn: $group.isIncluded).toggleStyle(.checkbox).labelsHidden()
                    .accessibilityLabel("Make the group \(group.name)")
                TextField("Group name", text: $group.name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Group name")
                    .disabled(!group.isIncluded)
            }
            if !group.sharedEvidence.isEmpty {
                Text("Shared: " + group.sharedEvidence.map { "“\($0)”" }.joined(separator: ", "))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2).truncationMode(.tail)
            }
            ForEach($group.members) { $member in
                let display = displays[member.token]
                Toggle(isOn: $member.isIncluded) {
                    HStack(spacing: 6) {
                        if !isNarrow {
                            AppIconView(bundleIdentifier: display?.bundleId, bundlePath: display?.bundlePath) { icon in
                                if let icon { Image(nsImage: icon).resizable().frame(width: 14, height: 14) }
                                else { Image(systemName: "macwindow").frame(width: 14, height: 14) }
                            }
                            .accessibilityHidden(true)
                        }
                        Text(display?.title ?? "Tab").lineLimit(2).truncationMode(.middle)
                    }
                }
                .toggleStyle(.checkbox)
                .font(.callout)
                .disabled(!group.isIncluded)
                .accessibilityLabel("Include \(display?.title ?? "tab") in \(group.name)")
            }
            if let problem = group.problem {
                Text(problem).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct WorkspaceTopicSuggestionBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
