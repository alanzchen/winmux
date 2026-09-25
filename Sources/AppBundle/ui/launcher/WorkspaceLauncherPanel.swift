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
    @Published var selection = 0
    @Published var state: WorkspaceLauncherState = .choosing
    @Published var installed: [LauncherApp] = []
    @Published var workspaceTitle = ""
    var running: [LauncherApp] = []
    var menuFallbackEnabled = false
    var onChoose: ((LauncherApp) -> Void)?
    var onDismiss: (() -> Void)?

    var results: [LauncherApp] {
        launcherResults(installed: installed, running: running, query: query) { self.action(for: $0) == .switchTo }
    }

    func action(for app: LauncherApp) -> LauncherAppAction {
        launcherAppAction(bundleId: app.bundleId, isRunning: running.contains { $0.bundleId == app.bundleId },
            menuFallbackEnabled: menuFallbackEnabled)
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
    private(set) var workspaceName: String?
    private var spaceObserver: NSObjectProtocol?

    var isShowing: Bool { workspaceName != nil }

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

    /// Shows the launcher for `workspaceName`, which must exist and be visible.
    func show(forWorkspaceNamed name: String) {
        guard let workspace = Workspace.existing(byName: name), workspace.isVisible, !workspace.isArchived else { return }
        workspaceName = name
        model.query = ""
        model.selection = 0
        model.state = .choosing
        model.workspaceTitle = workspaceDisplayName(name)
        model.running = runningLauncherApps()
        model.installed = LauncherAppCatalog.shared.installed
        model.menuFallbackEnabled = config.workspaceSidebar.launcherMenuFallback
        model.onChoose = { [weak self] app in self?.choose(app) }
        model.onDismiss = { [weak self] in self?.dismiss() }
        setFrame(workspaceLauncherFrame(in: workspace.workspaceMonitor), display: true, animate: false)
        hostingView.rootView = AnyView(WorkspaceLauncherView(model: model))
        orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        makeKey()
        Task { @MainActor in
            let installed = await LauncherAppCatalog.shared.refresh()
            if self.workspaceName == name { self.model.installed = installed }
        }
    }

    func dismiss() {
        guard workspaceName != nil else { return }
        workspaceName = nil
        orderOut(nil)
        hostingView.rootView = AnyView(EmptyView())
    }

    /// Called after each refresh: the launcher belongs to its workspace and leaves with it.
    func revalidate() {
        guard let workspaceName else { return }
        guard let workspace = Workspace.existing(byName: workspaceName), workspace.isVisible, !workspace.isArchived else {
            dismiss()
            return
        }
    }

    private func choose(_ app: LauncherApp) {
        guard let workspaceName else { return }
        switch model.action(for: app) {
            case .switchTo:
                // Labeled in the list: this app can't make a new window from WinMux.
                dismiss()
                NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleId).first?.activate()
            case .newWindow, .newWindowFromMenu, .open:
                model.state = .opening(appName: app.name)
                requestNewWindow(
                    NewWindowRequestTarget(bundleId: app.bundleId, appName: app.name, bundleURL: app.url),
                    targetWorkspaceName: workspaceName,
                ) { [weak self] outcome in
                    self?.finishRequest(outcome, appName: app.name, workspaceName: workspaceName)
                }
        }
    }

    private func finishRequest(_ outcome: NewWindowRequestOutcome, appName: String, workspaceName: String) {
        let message: String? = switch outcome {
            case .placed: nil
            case .timedOut: "\(appName) didn't open a new window."
            case .failed(let failure): failure
            case .cancelled: "The workspace closed before \(appName) opened a window."
        }
        guard self.workspaceName == workspaceName else {
            // The launcher has gone; still say why nothing appeared.
            if let message { MessageModel.shared.message = Message(description: "App Launcher", body: message) }
            return
        }
        if let message {
            model.state = .failed(message)
            makeKey()
        } else {
            dismiss()
        }
    }

    // Navigation keys are handled before the search field consumes them; typing flows to it.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, isShowing {
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

    /// Clicking elsewhere dismisses the launcher while choosing; an app opening its window
    /// takes key status without dismissing it.
    override func resignKey() {
        super.resignKey()
        if model.state == .choosing { dismiss() }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Centered in the workspace's usable area, after the menu bar and any reserved sidebar.
@MainActor
func workspaceLauncherFrame(in monitor: Monitor) -> NSRect {
    let area = monitor.visibleRectPaddedByOuterGaps
    let width = min(workspaceLauncherWidth, area.width - 24)
    let height = min(workspaceLauncherHeight, area.height - 24)
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
                case .opening(let appName): status(systemImage: nil, text: "Opening a new \(appName) window…")
                case .failed(let message): failure(message)
            }
        }
        .frame(width: workspaceLauncherWidth)
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
            if results.isEmpty {
                Text(model.installed.isEmpty ? "Finding apps…" : "No matching apps")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(GlassToken.textTertiary))
                    .padding(.vertical, 18)
            }
        }
    }

    private func status(systemImage: String?, text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.white.opacity(GlassToken.textPrimary))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .accessibilityElement(children: .combine)
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
                .foregroundStyle(Color.white.opacity(action == .switchTo ? GlassToken.textQuaternary : GlassToken.textTertiary))
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
