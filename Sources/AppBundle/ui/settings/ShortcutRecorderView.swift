import MASShortcut
import SwiftUI

struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var shortcut: MASShortcut?

    final class Coordinator {
        var isSynchronizingShortcut = false
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> RecordingAwareShortcutView {
        let recorder = RecordingAwareShortcutView(frame: .zero)
        recorder.shortcutValidator = nil
        recorder.onRecordingChanged = { isRecording in
            Task { @MainActor in
                setHotkeysSuspended(isRecording)
            }
        }
        recorder.shortcutValueChange = { sender in
            let newValue = sender.shortcutValue
            guard !context.coordinator.isSynchronizingShortcut else { return }
            shortcut = newValue
        }
        return recorder
    }

    func updateNSView(_ nsView: RecordingAwareShortcutView, context: Context) {
        guard !nsView.isRecording else { return }
        let shouldUpdate: Bool
        if let shortcut, let existing = nsView.shortcutValue {
            shouldUpdate = !existing.isEqual(shortcut)
        } else {
            shouldUpdate = (shortcut != nil) || (nsView.shortcutValue != nil)
        }
        if shouldUpdate {
            context.coordinator.isSynchronizingShortcut = true
            defer { context.coordinator.isSynchronizingShortcut = false }
            nsView.shortcutValue = shortcut
        }
    }

    static func dismantleNSView(_ nsView: RecordingAwareShortcutView, coordinator: Coordinator) {
        // A pane switch can remove a recorder that is still recording. MASShortcut keeps
        // that view alive with its key monitor installed, so stop it and drop its writer.
        let wasRecording = nsView.isRecording
        nsView.onRecordingChanged = { _ in }
        nsView.shortcutValueChange = nil
        guard wasRecording else { return }
        nsView.isRecording = false
        Task { @MainActor in
            setHotkeysSuspended(false)
        }
    }
}

final class RecordingAwareShortcutView: MASShortcutView {
    var onRecordingChanged: (Bool) -> Void = { _ in }

    override var isRecording: Bool {
        didSet {
            guard oldValue != isRecording else { return }
            onRecordingChanged(isRecording)
        }
    }
}
