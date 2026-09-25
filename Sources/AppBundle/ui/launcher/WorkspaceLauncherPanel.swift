import AppKit
import Common
import SwiftUI

private let workspaceLauncherPanelId = "WinMux.workspaceLauncher"
let workspaceLauncherWidth: CGFloat = 560
let workspaceLauncherHeight: CGFloat = 440

enum WorkspaceLauncherState: Equatable {
    case choosing
    case opening(appName: String)
    case failed(String)
}

@MainActor
final class WorkspaceLauncherModel: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { selection = 0 } }
    }
    @Published var selection = 0 {
        didSet { if selection != oldValue { notice = nil } }
    }
    /// Why the chosen app can't open a new window, shown until the choice changes.
    @Published var notice: String?
    @Published var state: WorkspaceLauncherState = .choosing
    @Published private(set) var installed: [LauncherApp] = []
    @Published var workspaceTitle = ""
    var running: [LauncherApp] = [] {
        didSet { runningIds = Set(running.map(\.bundleId)) }
    }
    private var runningIds: Set<String> = []
    var menuFallbackEnabled = false
    var onChoose: ((LauncherApp) -> Void)?
    var onDismiss: (() -> Void)?

    var results: [LauncherApp] {
        launcherResults(installed: installed, running: running, query: query) { self.action(for: $0) == .unsupported }
    }

    func action(for app: LauncherApp) -> LauncherAppAction {
        launcherAppAction(bundleId: app.bundleId, isRunning: runningIds.contains(app.bundleId),
            menuFallbackEnabled: menuFallbackEnabled)
    }

    /// Installed apps arrive after the launcher opens; the app already selected stays selected.
    func setInstalled(_ apps: [LauncherApp]) {
        let previous = results
        let selected = previous.indices.contains(selection) ? previous[selection].id : nil
        let keptNotice = notice
        installed = apps
        let updated = results
        if let index = selected.flatMap({ id in updated.firstIndex { $0.id == id } }) {
            selection = index
            notice = keptNotice // Still about the selected app.
        } else {
            selection = min(selection, max(updated.count - 1, 0))
            notice = nil
        }
    }

    func moveSelection(_ delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        selection = min(max(selection + delta, 0), count - 1)
    }

    func chooseCurrent() {
        let results = results
        guard state == .choosing, results.indices.contains(selection) else { return }
        onChoose?(results[selection])
    }
}

/// Opens a new window of the chosen app in one workspace, like a browser's new-tab page.
@MainActor
final class WorkspaceLauncherPanel: NSPanelHud {
    static let shared = WorkspaceLauncherPanel()
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    let model = WorkspaceLauncherModel()
    private(set) var workspace: Workspace?
    /// Each showing is a new session; a request from an earlier one never touches this one.
    private var sessionId = 0
    private var request: NewWindowRequestHandle?
    private var spaceObserver: NSObjectProtocol?

    var isShowing: Bool { workspace != nil }

    override private init() {
        super.init()
        identifier = NSUserInterfaceItemIdentifier(workspaceLauncherPanelId)
        hasShadow = true
        isFloatingPanel = true
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        backgroundColor = .clear
        applyWinMuxLayer(.overlay)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = hostingView
        hostingView.frame = contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    /// Shows the launcher for the workspace named `name`, which must exist and be visible.
    @discardableResult
    func show(forWorkspaceNamed name: String) -> Bool {
        guard let workspace = Workspace.existing(byName: name), workspace.isVisible, !workspace.isArchived else { return false }
        dismiss()
        request?.cancel()
        request = nil
        self.workspace = workspace
        sessionId += 1
        let session = sessionId
        model.query = ""
        model.state = .choosing
        model.workspaceTitle = workspaceDisplayName(name)
        model.menuFallbackEnabled = config.workspaceSidebar.launcherMenuFallback
        model.running = runningLauncherApps()
        model.setInstalled(LauncherAppCatalog.shared.installed)
        // A new session starts at the top, wherever the last one's selection went.
        model.selection = 0
        model.notice = nil
        model.onChoose = { [weak self] app in self?.choose(app) }
        model.onDismiss = { [weak self] in self?.dismiss() }
        setFrame(workspaceLauncherFrame(in: workspace.workspaceMonitor), display: true, animate: false)
        hostingView.rootView = AnyView(WorkspaceLauncherView(model: model))
        orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        makeKey()
        Task { @MainActor in
            let installed = await LauncherAppCatalog.shared.refresh()
            if self.sessionId == session, self.isShowing { self.model.setInstalled(installed) }
        }
        return true
    }

    /// Closing the launcher withdraws its request: a window the app opens later is placed
    /// by the usual rules, not in a workspace the user has left.
    func dismiss() {
        guard workspace != nil else { return }
        workspace = nil
        request?.cancel()
        request = nil
        orderOut(nil)
        hostingView.rootView = AnyView(EmptyView())
    }

    /// Called after each refresh: the launcher belongs to its workspace and leaves with it.
    func revalidate() {
        guard let workspace else { return }
        guard winMuxWorkspaceState.workspaceById[workspace.id] === workspace, workspace.isVisible, !workspace.isArchived else {
            dismiss()
            return
        }
        // Follows the workspace to another monitor or a resized screen.
        let frame = workspaceLauncherFrame(in: workspace.workspaceMonitor)
        if frame != self.frame { setFrame(frame, display: true, animate: false) }
    }

    private func choose(_ app: LauncherApp) {
        guard let workspace, model.state == .choosing else { return }
        switch model.action(for: app) {
            case .unsupported:
                // Only while the menu fallback is off. Switching to the app would show its
                // existing windows, the opposite of what was asked.
                let notice = "\(app.name) can't open a new window from WinMux. Turn on “Use an app's New Window menu” in Settings to try its menu."
                model.notice = notice
                announce(notice)
            case .newWindow, .newWindowFromMenu, .open:
                let session = sessionId
                model.state = .opening(appName: app.name)
                announce("Opening a new \(app.name) window")
                let handle = requestNewWindow(
                    NewWindowRequestTarget(bundleId: app.bundleId, appName: app.name, bundleURL: app.url),
                    targetWorkspace: workspace,
                ) { [weak self] outcome in
                    self?.finishRequest(outcome, appName: app.name, session: session)
                }
                // A request that ended at once has nothing left to cancel.
                if sessionId == session, isShowing, case .opening = model.state { request = handle }
        }
    }

    private func finishRequest(_ outcome: NewWindowRequestOutcome, appName: String, session: Int) {
        // A dismissed or replaced launcher already withdrew this request.
        guard sessionId == session, isShowing else { return }
        request = nil
        let message: String? = switch outcome {
            case .placed, .opened: nil
            case .timedOut: "\(appName) didn't open a new window."
            case .failed(let failure): failure
            case .cancelled: "The workspace closed before \(appName) opened a window."
        }
        guard let message else {
            dismiss()
            return
        }
        guard NSApp.isActive else {
            // The user moved on to another app: don't take focus back to show the error inline.
            dismiss()
            MessageModel.shared.message = Message(description: "App Launcher", body: message)
            return
        }
        model.state = .failed(message)
        announce(message)
        makeKey()
    }

    private func announce(_ text: String) {
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    // Navigation keys are handled before the search field consumes them; typing flows to it.
    // Composing text, such as with a Japanese input method, keeps them for the input method,
    // and shortcuts with modifiers, such as Command-A, reach the field unchanged.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, isShowing,
           (firstResponder as? NSTextView)?.hasMarkedText() != true,
           event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        {
            switch event.keyCode {
                case 53: dismiss(); return // esc
                case 125: model.moveSelection(1); return // down arrow
                case 126: model.moveSelection(-1); return // up arrow
                case 36, 76: // return / keypad enter
                    if case .failed = model.state { dismiss() } else { model.chooseCurrent() }
                    return
                default: break
            }
        }
        super.sendEvent(event)
    }

    /// Clicking elsewhere dismisses the launcher, except while an app opens its window: its
    /// permission prompt or the window itself may take key status first. Cancel covers that.
    override func resignKey() {
        super.resignKey()
        if case .opening = model.state { return }
        dismiss()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Centered in the workspace's usable area, after the menu bar and any reserved sidebar.
@MainActor
func workspaceLauncherFrame(in monitor: Monitor) -> NSRect {
    let area = monitor.visibleRectPaddedByOuterGaps
    let width = max(min(workspaceLauncherWidth, area.width - 24), 0)
    let height = max(min(workspaceLauncherHeight, area.height - 24), 0)
    let appKitMaxY = NSScreen.screens.first?.frame.maxY ?? 0
    return NSRect(
        x: area.topLeftX + (area.width - width) / 2,
        y: appKitMaxY - area.topLeftY - area.height * 0.42 - height / 2,
        width: width,
        height: height,
    )
}

struct WorkspaceLauncherView: View {
    @ObservedObject var model: WorkspaceLauncherModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            switch model.state {
                case .choosing: chooser
                case .opening(let appName): opening(appName)
                case .failed(let message): failure(message)
            }
        }
        .frame(maxWidth: workspaceLauncherWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GlassSurface(
                shape: RoundedRectangle(cornerRadius: RadiusToken.panel, style: .continuous),
                style: config.workspaceSidebar.chromeStyle,
                solidColor: config.workspaceSidebar.resolvedSolidChromeColor,
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: RadiusToken.panel, style: .continuous))
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .onAppear { searchFocused = true }
    }

    private var chooser: some View {
        let results = model.results
        return VStack(spacing: 0) {
            Text("New window in \(model.workspaceTitle)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(GlassToken.textTertiary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 12)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.white.opacity(GlassToken.textTertiary))
                TextField("Search apps…", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.white.opacity(GlassToken.textPrimary))
                    .focused($searchFocused)
                    .accessibilityLabel("Search apps")
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            Rectangle()
                .fill(Color.white.opacity(GlassToken.separatorOpacity))
                .frame(height: StrokeToken.hairline)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, app in
                            WorkspaceLauncherRow(app: app, action: model.action(for: app), isSelected: index == model.selection)
                                .id(app.id)
                                .onTapGesture { model.onChoose?(app) }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: model.selection) { selection in
                    if results.indices.contains(selection) { proxy.scrollTo(results[selection].id, anchor: nil) }
                }
            }
            .frame(maxHeight: workspaceLauncherHeight - 100)
            if let notice = model.notice {
                Text(notice)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(GlassToken.textSecondary))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if results.isEmpty {
                Text(model.installed.isEmpty ? "Finding apps…" : "No matching apps")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(GlassToken.textTertiary))
                    .padding(.vertical, 18)
            }
        }
    }

    private func opening(_ appName: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Opening a new \(appName) window…")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.white.opacity(GlassToken.textPrimary))
            Spacer(minLength: 8)
            // The request can wait on a permission prompt for up to a minute.
            Button("Cancel") { model.onDismiss?() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 22)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(GlassToken.textPrimary))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("OK") { model.onDismiss?() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }
}

private struct WorkspaceLauncherRow: View {
    let app: LauncherApp
    let action: LauncherAppAction
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(bundleIdentifier: app.bundleId, bundlePath: app.url?.path) { icon in
                if let icon {
                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "app").resizable().aspectRatio(contentMode: .fit)
                        .foregroundStyle(Color.white.opacity(GlassToken.textTertiary))
                }
            }
            .frame(width: 22, height: 22)
            Text(app.name)
                .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(Color.white.opacity(isSelected ? GlassToken.textPrimary : GlassToken.textSecondary))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(action.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(GlassToken.textTertiary))
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background {
            RoundedRectangle(cornerRadius: RadiusToken.row, style: .continuous)
                .fill(Color.white.opacity(isSelected ? GlassToken.fillActive : 0))
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(app.name), \(action.label)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
