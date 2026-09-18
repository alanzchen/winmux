import AppKit
import Common
import QuartzCore
import SwiftUI

struct DockPerformanceWork: Codable, Sendable {
    let start: Double
    let end: Double
}

struct DockPerformanceReport: Codable, Sendable {
    let schemaVersion: Int
    let startedUTC: Date
    let hostTimeAnchor: Double
    let endedHostTime: Double
    let version: String
    let gitHash: String
    let operatingSystem: String
    let hardwareModel: String
    let processorCount: Int
    let lowPowerMode: Bool
    let thermalState: Int
    let settings: [String: String]
    let panels: [DockPerformancePanelReport]
    let refreshSpans: [DockPerformanceWork]
    let overwrittenRefreshSpans: Int
    let omittedPanels: Int
    let overwrittenRetiredPanels: Int
}

@MainActor
final class DockPerformanceRecorder: ObservableObject {
    static let shared = DockPerformanceRecorder()
    @Published private(set) var isRecording = false
    @Published private(set) var isSaving = false
    @Published private(set) var status = "Capture timing while reproducing a stutter."
    @Published private(set) var lastReport: URL?
    private let views = NSHashTable<WorkspaceSidebarDockDisplayLinkView>.weakObjects()
    private let omittedViews = NSHashTable<WorkspaceSidebarDockDisplayLinkView>.weakObjects()
    private var entries: [Entry] = []
    private var retired = DockPerformanceRing<DockPerformancePanelReport>(capacity: 8)
    private var nextPanelID = 0
    private var omittedPanels = 0
    private var refreshSpans = DockPerformanceRing<DockPerformanceWork>(capacity: 128)
    private var startedUTC = Date()
    private var startedHostTime = 0.0
    private var captureID = UUID()
    private var timeout: Task<Void, Never>?
    private var runLoopObserver: CFRunLoopObserver?
    private var wakeObserver: NSObjectProtocol?
    private let outputDirectory: URL
    private let captureDuration: Duration

    init(outputDirectory: URL = DockPerformanceRecorder.reportsDirectory, captureDuration: Duration = .seconds(120)) {
        self.outputDirectory = outputDirectory
        self.captureDuration = captureDuration
    }

    private struct Entry {
        let id: Int
        weak var view: WorkspaceSidebarDockDisplayLinkView?
        let trace: DockPerformanceTrace
        let maximumFPS: Int
        let scale: Double
    }

    static var reportsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/WinMux/DockPerformance", isDirectory: true)
    }

    func register(_ view: WorkspaceSidebarDockDisplayLinkView) {
        views.add(view)
        if isRecording { attach(view) }
    }

    private func attach(_ view: WorkspaceSidebarDockDisplayLinkView) {
        guard view.performanceTrace == nil else { return }
        retireDetachedPanels()
        guard entries.count < 8 else {
            if !omittedViews.contains(view) {
                omittedViews.add(view)
                omittedPanels += 1
            }
            return
        }
        let trace = DockPerformanceTrace()
        view.performanceTrace = trace
        view.recordInputState(.capture)
        nextPanelID += 1
        entries.append(Entry(id: nextPanelID, view: view, trace: trace,
            maximumFPS: view.window?.screen?.maximumFramesPerSecond ?? 0,
            scale: Double(view.window?.backingScaleFactor ?? 0)))
    }

    private func retireDetachedPanels() {
        // Retain a small tail from closed/replaced panels, leaving all eight full
        // trace slots available to current panels during monitor reconfiguration.
        entries.removeAll { entry in
            guard entry.view == nil || entry.view?.window == nil else { return false }
            entry.view?.performanceTrace = nil
            retired.append(entry.trace.snapshot(panel: entry.id, maximumFPS: entry.maximumFPS,
                scale: entry.scale, retired: true))
            return true
        }
    }

    func start() {
        guard !isRecording, !isSaving else { return }
        startedUTC = Date()
        startedHostTime = CACurrentMediaTime()
        captureID = UUID()
        lastReport = nil
        entries = []
        retired = .init(capacity: 8)
        nextPanelID = 0
        omittedPanels = 0
        omittedViews.removeAllObjects()
        refreshSpans = .init(capacity: 128)
        isRecording = true
        status = "Recording for up to 2 minutes. Move over the Dock to reproduce the stutter."
        for view in views.allObjects where view.window != nil { attach(view) }
        runLoopObserver = CFRunLoopObserverCreateWithHandler(nil,
            CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, self.isRecording else { return }
                    let now = CACurrentMediaTime()
                    for entry in self.entries where entry.view?.window != nil { entry.trace.beforeWaiting(at: now) }
                }
            }
        CFRunLoopAddObserver(CFRunLoopGetMain(), runLoopObserver, .commonModes)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    for entry in self?.entries ?? [] { entry.trace.resetBaseline() }
                }
            }
        let duration = captureDuration
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            self?.stop()
        }
    }

    func stop() {
        guard isRecording else { return }
        timeout?.cancel()
        timeout = nil
        if let runLoopObserver { CFRunLoopRemoveObserver(CFRunLoopGetMain(), runLoopObserver, .commonModes) }
        runLoopObserver = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        retireDetachedPanels()
        for view in views.allObjects { view.performanceTrace = nil }
        isRecording = false
        let sidebar = config.workspaceSidebar
        let report = DockPerformanceReport(schemaVersion: 2, startedUTC: startedUTC,
            hostTimeAnchor: startedHostTime, endedHostTime: CACurrentMediaTime(),
            version: winMuxAppVersion, gitHash: gitHash,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            hardwareModel: dockPerformanceHardwareModel(),
            processorCount: ProcessInfo.processInfo.processorCount,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState.rawValue,
            settings: ["mode": sidebar.mode.rawValue, "chrome": sidebar.chromeStyle.rawValue,
                "magnification": String(sidebar.dockMagnificationAmount), "iconSize": String(sidebar.dockIconSize),
                "glassOpacity": String(sidebar.glassOpacity),
                "reduceMotion": String(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion),
                "reduceTransparency": String(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)],
            panels: retired.elements + entries.map { entry in
                entry.trace.snapshot(panel: entry.id,
                    maximumFPS: entry.view?.window?.screen?.maximumFramesPerSecond ?? entry.maximumFPS,
                    scale: entry.view?.window.map { Double($0.backingScaleFactor) } ?? entry.scale)
            }, refreshSpans: refreshSpans.elements, overwrittenRefreshSpans: refreshSpans.overwritten,
            omittedPanels: omittedPanels, overwrittenRetiredPanels: retired.overwritten)
        entries = []
        isSaving = true
        status = "Saving performance report…"
        let directory = outputDirectory
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { try writeDockPerformanceReport(report, to: directory) }
            }.value
            guard let self else { return }
            self.isSaving = false
            switch result {
                case .success(let url):
                    self.lastReport = url
                    let suspects = report.panels.reduce(0) { $0 + $1.summary.suspectedFrames }
                    self.status = "Saved report: \(suspects) possible timing issues. These are not measured GPU frame drops."
                case .failure(let error): self.status = "Could not save report: \(error.localizedDescription)"
            }
        }
    }

    func hoverRecheck(in window: NSWindow) {
        guard isRecording else { return }
        for entry in entries where entry.view?.window === window { entry.trace.hoverRecheck() }
    }

    /// Refresh spans include suspension/AX wait time, not just CPU time.
    func beginRefresh() -> (UUID, Double)? {
        isRecording ? (captureID, CACurrentMediaTime()) : nil
    }

    func endRefresh(_ token: (UUID, Double)?) {
        guard isRecording, let token, token.0 == captureID else { return }
        refreshSpans.append(.init(start: token.1, end: CACurrentMediaTime()))
    }
}

private func dockPerformanceHardwareModel() -> String {
    var length = 0
    guard sysctlbyname("hw.model", nil, &length, nil, 0) == 0, length > 0 else { return "unknown" }
    var bytes = [CChar](repeating: 0, count: length)
    guard sysctlbyname("hw.model", &bytes, &length, nil, 0) == 0 else { return "unknown" }
    return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

enum DockPerformanceWriteError: LocalizedError {
    case reportTooLarge
    var errorDescription: String? { "Performance report exceeds the 5 MB capture limit." }
}

/// Serialization and rotation run off the main actor, once per capture.
func writeDockPerformanceReport(_ report: DockPerformanceReport, to directory: URL) throws -> URL {
    let manager = FileManager.default
    try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(report)
    guard data.count <= 5 * 1_024 * 1_024 else {
        throw DockPerformanceWriteError.reportTooLarge
    }
    let reports = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        .filter { $0.lastPathComponent.hasPrefix("dock-performance-") && $0.pathExtension == "json" }
        .sorted {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast >
            (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast
        }
    // Rotate before writing: a purge failure cannot hide an already-saved report
    // or allow disk usage to grow without a bound. Always retain the new capture.
    for old in reports.dropFirst(2) { try manager.removeItem(at: old) }
    let url = directory.appendingPathComponent("dock-performance-\(UUID().uuidString).json")
    try data.write(to: url, options: .atomic)
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return url
}

struct DockPerformanceSettingsView: View {
    @ObservedObject private var recorder = DockPerformanceRecorder.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Record Dock performance (debug mode)", isOn: Binding(
                get: { recorder.isRecording },
                set: { $0 ? recorder.start() : recorder.stop() }
            ))
            .disabled(recorder.isSaving)
            Text(recorder.status).font(.caption).foregroundStyle(.secondary)
            Text("Stops and saves automatically after 2 minutes. Reports contain timing, settings and counts; no app names, window titles or cursor positions. Keeps the latest 3 reports.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let report = recorder.lastReport {
                Button("Show performance report in Finder") { NSWorkspace.shared.activateFileViewerSelecting([report]) }
            }
        }
        .padding(14)
    }
}
