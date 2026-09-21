import AppKit

/// A layer is not an accessible control. Keep real accessibility elements alive
/// and answer frame queries from the same geometry used to draw and hit-test it.
@MainActor
final class WorkspaceSidebarNativeDockButton: NSAccessibilityElement {
    weak var owner: WorkspaceSidebarNativeDockView?
    let workspaceName: String?
    let appId: String?

    init(owner: WorkspaceSidebarNativeDockView, workspaceName: String?, appId: String?, label: String) {
        self.owner = owner
        self.workspaceName = workspaceName
        self.appId = appId
        super.init()
        setAccessibilityParent(owner)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        setAccessibilityElement(true)
    }

    nonisolated override func accessibilityFrame() -> NSRect {
        nonisolated(unsafe) let element = self
        return MainActor.assumeIsolated {
            guard let owner = element.owner, let window = owner.window,
                  let frame = owner.buttonFrame(workspaceName: element.workspaceName, appId: element.appId)
            else { return .zero }
            return window.convertToScreen(owner.convert(frame, to: nil))
        }
    }

    nonisolated override func isAccessibilityEnabled() -> Bool {
        nonisolated(unsafe) let element = self
        return MainActor.assumeIsolated { element.owner?.buttonIsEnabled(workspaceName: element.workspaceName) == true }
    }

    nonisolated override func accessibilityPerformPress() -> Bool {
        nonisolated(unsafe) let element = self
        return MainActor.assumeIsolated { element.owner?.pressButton(workspaceName: element.workspaceName, appId: element.appId) == true }
    }
}

@MainActor
final class WorkspaceSidebarNativeDockMenuItem: NSMenuItem {
    private let perform: () -> Void

    init(_ title: String, perform: @escaping () -> Void) {
        self.perform = perform
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { perform() }
}
