import AppKit
import Sparkle

/// Keeps update decisions and permissions in Sparkle's standard UI. Passive failures are
/// handed to WinMux; opening the unchanged Sparkle diagnostic requires Details.
@MainActor
public enum AutomaticUpdates {
    public typealias ErrorPresenter = (_ title: String, _ body: String, _ details: @escaping @MainActor () -> Void) -> Void
    private static var updater: SPUUpdater?

    public static func start(reportError: @escaping ErrorPresenter) {
        guard updater == nil else { return }
        let driver = WinMuxUpdateUserDriver(hostBundle: .main, delegate: nil)
        driver.reportError = reportError
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: nil)
        self.updater = updater
        do { try updater.start() }
        catch {
            NSLog("Fatal updater error: %@", error as NSError)
            let title = "Unable to Check For Updates"
            let body = "The updater failed to start. Please verify you have the latest version of WinMux and contact the app developer if the issue still persists. Check the Console logs for more information."
            reportError(title, body) {
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = body
                alert.runModal()
            }
        }
    }

    public static func checkForUpdates() { updater?.checkForUpdates() }
}

@MainActor
final class WinMuxUpdateUserDriver: SPUStandardUserDriver {
    var reportError: AutomaticUpdates.ErrorPresenter?

    override func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        // This text is part of an existing Install/Skip decision, and stops its spinner. Keep
        // that context (and Sparkle's logging), while also reporting the failure as a toast.
        super.showUpdateReleaseNotesFailedToDownloadWithError(error)
        let diagnostic = error as NSError
        let original = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
        reportError?("Release Notes Error", diagnostic.localizedDescription) {
            original.showUpdaterError(diagnostic, acknowledgement: {})
        }
    }

    override func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        guard let reportError else {
            super.showUpdaterError(error, acknowledgement: acknowledgement)
            return
        }
        let diagnostic = error as NSError
        // Finish the failed session now. A diagnostic opened later must never dismiss or
        // acknowledge a newer update session, hence the independent standard detail driver.
        dismissUpdateInstallation()
        let original = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
        let title = diagnostic.localizedRecoverySuggestion == nil ? "Update Error!" : diagnostic.localizedDescription
        let body = diagnostic.localizedRecoverySuggestion ?? diagnostic.localizedDescription
        reportError(title, body) { original.showUpdaterError(diagnostic, acknowledgement: {}) }
        acknowledgement()
    }
}
