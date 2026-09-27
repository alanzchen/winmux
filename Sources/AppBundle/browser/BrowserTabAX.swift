import AppKit

func browserTabSelectedValue(value: NSNumber?, selected: NSNumber?) -> Bool? {
    // Safari exposes the radio value. Chromium aliases value to selected, including
    // multi-selection; the scanner requires exactly one selected control there.
    value?.boolValue ?? selected?.boolValue
}

struct NativeBrowserTabNode: BrowserTabAXNode {
    let element: AXUIElement

    static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }

    private func values(_ names: [String]) -> [Any]? {
        AXUIElementSetMessagingTimeout(element, 0.05)
        var result: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &result) == .success else { return nil }
        return result as? [Any]
    }

    func structure() -> BrowserTabAXStructure? {
        guard let values = values([kAXRoleAttribute, kAXSubroleAttribute]), values.count == 2,
              let role = values[0] as? String else { return nil }
        return .init(role: role, subrole: values[1] as? String ?? "")
    }

    func children() -> [Self]? {
        AXUIElementSetMessagingTimeout(element, 0.05)
        var count: CFIndex = 0
        let error = AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count)
        if error == .noValue || error == .attributeUnsupported { return [] }
        guard error == .success, count <= 256 else { return nil }
        if count == 0 { return [] }
        var result: CFArray?
        guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, count, &result) == .success,
              let elements = result as? [AXUIElement] else { return nil }
        return elements.map { .init(element: $0) }
    }

    private func reference(_ attribute: String) -> Self? {
        guard let raw = values([attribute])?.first else { return nil }
        let value = raw as CFTypeRef
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return .init(element: unsafeDowncast(value, to: AXUIElement.self))
    }

    func parent() -> Self? { reference(kAXParentAttribute) }
    func window() -> Self? { reference(kAXWindowAttribute) }

    func tabInfo() -> BrowserTabAXInfo? {
        guard let values = values([kAXTitleAttribute, kAXSelectedAttribute, kAXValueAttribute]), values.count == 3,
              let title = values[0] as? String,
              let selected = browserTabSelectedValue(value: values[2] as? NSNumber, selected: values[1] as? NSNumber) else { return nil }
        return .init(title: title, selected: selected)
    }

    func tabRecord() -> BrowserTabAXRecord<Self>? {
        guard let values = values([kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute,
                                   kAXSelectedAttribute, kAXValueAttribute, kAXParentAttribute]), values.count == 6,
              let role = values[0] as? String, let subrole = values[1] as? String, let title = values[2] as? String,
              let selected = browserTabSelectedValue(value: values[4] as? NSNumber, selected: values[3] as? NSNumber),
              CFGetTypeID(values[5] as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
        return .init(structure: .init(role: role, subrole: subrole), info: .init(title: title, selected: selected),
            parent: .init(element: unsafeDowncast(values[5] as CFTypeRef, to: AXUIElement.self)))
    }

    func press() -> Bool {
        var actions: CFArray?
        guard AXUIElementCopyActionNames(element, &actions) == .success,
              (actions as? [String])?.contains(kAXPressAction) == true else { return false }
        // A user action can require compositing a heavy page. Keep passive reads
        // short while allowing a bounded, more generous action round trip.
        AXUIElementSetMessagingTimeout(element, 0.2)
        defer { AXUIElementSetMessagingTimeout(element, 0.05) }
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    func iconCandidate(for snapshot: BrowserWindowTabs) -> BrowserTabIconCandidate? {
        guard snapshot.tabs.filter(\.isSelected).count == 1, let selected = snapshot.tabs.first(where: \.isSelected),
              let values = values([kAXDocumentAttribute, kAXTitleAttribute]), values.count == 2,
              let address = values[0] as? String, let title = values[1] as? String,
              title == selected.title || title.hasPrefix(selected.title + " - ") else { return nil }
        return .init(target: selected.target, origin: browserTabIconOrigin(address))
    }
}

/// Best-effort subscriptions, isolated from WinMux's window/layout refresh callback.
/// Registration failures are expected; periodic reconciliation remains authoritative.
final class BrowserTabAXObservation {
    private let runLoop = CFRunLoopGetCurrent()
    private var observer: AXObserver?
    private var registrations: [(element: AXUIElement, name: String, subscribed: Bool)] = []
    private let changed: () -> Void
    private var lastNotification: TimeInterval = -.infinity

    private func notifyChange() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastNotification >= 0.75 else { return }
        lastNotification = now
        changed()
    }

    init(pid: Int32, changed: @escaping () -> Void) {
        self.changed = changed
        if AXObserverCreate(pid, { _, _, _, context in
            guard let context else { return }
            Unmanaged<BrowserTabAXObservation>.fromOpaque(context).takeUnretainedValue().notifyChange()
        }, &observer) == .success, let observer {
            CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
        }
    }

    func update(_ nodes: [NativeBrowserTabNode]) {
        guard let observer else { return }
        for (element, name, subscribed) in registrations where !nodes.contains(where: { CFEqual($0.element, element) }) {
            if subscribed { AXObserverRemoveNotification(observer, element, name as CFString) }
        }
        registrations.removeAll { entry in !nodes.contains(where: { CFEqual($0.element, entry.0) }) }
        for node in nodes {
            for name in [kAXSelectedChildrenChangedNotification, kAXValueChangedNotification,
                         kAXTitleChangedNotification, kAXUIElementDestroyedNotification] {
                if registrations.contains(where: { CFEqual($0.0, node.element) && $0.1 == name }) { continue }
                let subscribed = AXObserverAddNotification(observer, node.element, name as CFString,
                    Unmanaged.passUnretained(self).toOpaque()) == .success
                registrations.append((node.element, name, subscribed))
            }
        }
    }

    deinit {
        guard let observer else { return }
        for (element, name, subscribed) in registrations where subscribed { AXObserverRemoveNotification(observer, element, name as CFString) }
        CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
    }
}
