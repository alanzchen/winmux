import AppKit
import ApplicationServices
import SwiftUI

/// Labels are keyed by app URL, never localized display name (which can collide).
struct WorkspaceSidebarDockBadgeSnapshot: Equatable, Sendable {
    var labelsByPath: [String: String] = [:]
    var showsAppBadges = true

    func label(forPath path: String?) -> String? {
        guard let path else { return nil }
        return labelsByPath[URL(fileURLWithPath: path).standardizedFileURL.path]
    }

    mutating func insert(url: URL, label: String?) {
        guard url.isFileURL, url.pathExtension.lowercased() == "app",
              let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty
        else { return }
        labelsByPath[url.standardizedFileURL.path] = label
    }
}

/// AXStatusLabel is a Dock-specific attribute, not a guaranteed cross-app API.
/// Missing attributes/access simply produce no badge. Never prompt for permission.
func readWorkspaceSidebarDockBadges() -> WorkspaceSidebarDockBadgeSnapshot {
    var snapshot = WorkspaceSidebarDockBadgeSnapshot()
    guard AXIsProcessTrusted(),
          let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
    else { return snapshot }
    let root = AXUIElementCreateApplication(dock.processIdentifier)
    AXUIElementSetMessagingTimeout(root, 0.2)
    func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }
    let deadline = Date().addingTimeInterval(1)
    let itemAttributes = [kAXSubroleAttribute, kAXURLAttribute, "AXStatusLabel"] as CFArray
    let lists = (value(root, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(32)
    for list in lists where value(list, kAXRoleAttribute) as? String == kAXListRole {
        for item in (value(list, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(512) {
            guard !Task.isCancelled, Date() < deadline else { return snapshot }
            // Fetch the three fields in one IPC round trip. Unsupported optional
            // attributes appear as error values, which the typed casts ignore.
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(item, itemAttributes, [], &raw) == .success,
                  let fields = raw as? [Any], fields.count == 3,
                  fields[0] as? String == "AXApplicationDockItem",
                  let url = fields[1] as? URL
            else { continue }
            snapshot.insert(url: url, label: fields[2] as? String)
        }
    }
    return snapshot
}

/// Dock geometry only depends on badge presence, not changing unread counts.
@MainActor
final class WorkspaceSidebarDockBadgePresence: ObservableObject {
    @Published private(set) var paths: Set<String> = []

    func update(_ snapshot: WorkspaceSidebarDockBadgeSnapshot) {
        let next = Set(snapshot.labelsByPath.keys)
        if paths != next { paths = next }
    }
}

@MainActor
final class WorkspaceSidebarDockBadgeModel: ObservableObject {
    static let shared = WorkspaceSidebarDockBadgeModel()
    let presence = WorkspaceSidebarDockBadgePresence()
    @Published private(set) var snapshot = WorkspaceSidebarDockBadgeSnapshot() {
        didSet { presence.update(snapshot) }
    }
    private var pollingTask: Task<Void, Never>?
    private var generation = 0
    private let read: @Sendable () async -> WorkspaceSidebarDockBadgeSnapshot

    init(read: @escaping @Sendable () async -> WorkspaceSidebarDockBadgeSnapshot = {
        await Task.detached(priority: .utility) { readWorkspaceSidebarDockBadges() }.value
    }) {
        self.read = read
    }

    func setEnabled(_ enabled: Bool, showsAppBadges: Bool? = nil) {
        let showsAppBadges = showsAppBadges ?? snapshot.showsAppBadges
        if !enabled {
            generation += 1
            pollingTask?.cancel()
            pollingTask = nil
            let cleared = WorkspaceSidebarDockBadgeSnapshot(showsAppBadges: showsAppBadges)
            if snapshot != cleared { snapshot = cleared }
            return
        }
        if snapshot.showsAppBadges != showsAppBadges { snapshot.showsAppBadges = showsAppBadges }
        guard pollingTask == nil else { return }
        let currentGeneration = generation
        let read = read
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                var next = await read()
                guard !Task.isCancelled, let self, self.generation == currentGeneration else { return }
                next.showsAppBadges = self.snapshot.showsAppBadges
                if self.snapshot != next { self.snapshot = next }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
}

struct WorkspaceSidebarDockBadge: View {
    let app: WorkspaceSidebarAppViewModel
    var isReminder = false
    @ObservedObject var model = WorkspaceSidebarDockBadgeModel.shared

    var body: some View {
        if model.snapshot.showsAppBadges || isReminder, let label = model.snapshot.label(forPath: app.bundlePath) {
            GeometryReader { geometry in
                let diameter = max(12, geometry.size.width * 0.38)
                Text(label.count > 4 ? String(label.prefix(3)) + "…" : label)
                    .font(.system(size: diameter * 0.65, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, diameter * 0.22)
                    .frame(minWidth: diameter, minHeight: diameter)
                    .background(Color(red: 0.96, green: 0.20, blue: 0.23), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .accessibilityLabel("\(app.name) badge: \(label)")
            }
            .allowsHitTesting(false)
        }
    }
}
