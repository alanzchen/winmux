import AppKit
import ApplicationServices
import SwiftUI

/// Labels are keyed by app URL, never localized display name (which can collide).
struct WorkspaceSidebarDockBadgeSnapshot: Equatable, Sendable {
    var labelsByPath: [String: String] = [:]

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
    let lists = (value(root, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(32)
    for list in lists where value(list, kAXRoleAttribute) as? String == kAXListRole {
        for item in (value(list, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(512) {
            guard !Task.isCancelled, Date() < deadline else { return snapshot }
            guard value(item, kAXSubroleAttribute) as? String == "AXApplicationDockItem",
                  let url = value(item, kAXURLAttribute) as? URL
            else { continue }
            snapshot.insert(url: url, label: value(item, "AXStatusLabel") as? String)
        }
    }
    return snapshot
}

@MainActor
final class WorkspaceSidebarDockBadgeModel: ObservableObject {
    static let shared = WorkspaceSidebarDockBadgeModel()
    @Published private(set) var snapshot = WorkspaceSidebarDockBadgeSnapshot()
    private var pollingTask: Task<Void, Never>?
    private var generation = 0
    private let read: @Sendable () async -> WorkspaceSidebarDockBadgeSnapshot

    init(read: @escaping @Sendable () async -> WorkspaceSidebarDockBadgeSnapshot = {
        await Task.detached(priority: .utility) { readWorkspaceSidebarDockBadges() }.value
    }) {
        self.read = read
    }

    func setEnabled(_ enabled: Bool) {
        if !enabled {
            generation += 1
            pollingTask?.cancel()
            pollingTask = nil
            if !snapshot.labelsByPath.isEmpty { snapshot = .init() }
            return
        }
        guard pollingTask == nil else { return }
        let currentGeneration = generation
        let read = read
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                let next = await read()
                guard !Task.isCancelled, let self, self.generation == currentGeneration else { return }
                if self.snapshot != next { self.snapshot = next }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
}

struct WorkspaceSidebarDockBadge: View {
    let app: WorkspaceSidebarAppViewModel
    @ObservedObject private var model = WorkspaceSidebarDockBadgeModel.shared

    var body: some View {
        if let label = model.snapshot.label(forPath: app.bundlePath) {
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
