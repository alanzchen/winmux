import AppKit
@testable import AppBundle
import MASShortcut
import SwiftUI
import XCTest

@MainActor
final class ShortcutRecorderViewTest: XCTestCase {
    func testDismantleStopsRecordingAndDetachesTheRecorderCallbacks() {
        let view = RecordingAwareShortcutView(frame: .zero)
        defer { view.isRecording = false }
        var changes: [Bool] = []
        view.onRecordingChanged = { changes.append($0) }
        view.shortcutValueChange = { _ in }
        view.isRecording = true
        XCTAssertEqual(changes, [true])

        // SwiftUI tears the recorder down through the protocol requirement, e.g. when another
        // Settings sidebar row replaces the pane while this recorder is still recording.
        dismantle(ShortcutRecorderView.self, view, ShortcutRecorderView.Coordinator())

        XCTAssertFalse(view.isRecording, "A dismantled recorder must not keep MASShortcut's key monitor installed")
        XCTAssertNil(view.shortcutValueChange, "A dismantled recorder must not write later keystrokes through its binding")
        view.isRecording = true
        view.isRecording = false
        XCTAssertEqual(changes, [true], "A dismantled recorder must not report recording changes")
    }

    private func dismantle<R: NSViewRepresentable>(_: R.Type, _ view: R.NSViewType, _ coordinator: R.Coordinator) {
        R.dismantleNSView(view, coordinator: coordinator)
    }
}
