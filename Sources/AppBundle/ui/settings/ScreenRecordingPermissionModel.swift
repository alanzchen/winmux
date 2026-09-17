import AppKit
import Combine

/// Observing permission must never ask for it. Only a deliberate Settings action may prompt.
@MainActor
final class ScreenRecordingPermissionModel: ObservableObject {
    @Published private(set) var isGranted = false
    @Published private(set) var didRequest = false
    private let preflight: () -> Bool
    private let request: () -> Bool

    init(
        preflight: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
        request: @escaping () -> Bool = { CGRequestScreenCaptureAccess() }
    ) {
        self.preflight = preflight
        self.request = request
        refresh()
    }

    func refresh() {
        isGranted = preflight()
    }

    func requestFromSettings() {
        refresh()
        guard !isGranted, !didRequest else { return }
        didRequest = true
        isGranted = request()
    }
}
