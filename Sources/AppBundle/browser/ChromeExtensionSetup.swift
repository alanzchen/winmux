import AppKit
import Foundation

/// Settings' **Set Up Chrome Extension…**: registers WinMux's native-messaging host for Google
/// Chrome with the embedded CLI, the same `winmux chrome-extension install` a user can run, and
/// copies the extension's files out of the app to a stable folder to load unpacked. Only when
/// asked: nothing here runs when WinMux starts, and Chrome itself is never touched.
enum ChromeExtensionSetup {
    enum Failure: Error, Equatable {
        /// A development build, or an app without the embedded extension and CLI.
        case notBundled
        case hostInstall(String)
        case copy(String)
    }

    /// The extension's files and the embedded CLI inside `app`, if it has both.
    static func bundled(in app: URL) -> (extension: URL, helper: URL)? {
        let folder = app.appendingPathComponent("Contents/Resources/WinMuxTabs-Chrome")
        let helper = app.appendingPathComponent("Contents/Helpers/winmux")
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path),
              FileManager.default.isExecutableFile(atPath: helper.path) else { return nil }
        return (folder, helper)
    }

    /// Outside the app, so an app update never replaces files beneath a loaded extension.
    static func folder(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/WinMux/WinMuxTabs-Chrome")
    }

    static func run(app: URL = Bundle.main.bundleURL,
                    home: URL = FileManager.default.homeDirectoryForCurrentUser) async throws -> URL {
        guard let bundled = bundled(in: app) else { throw Failure.notBundled }
        try await installHost(helper: bundled.helper)
        let destination = folder(home: home)
        do { try copyExtension(from: bundled.extension, to: destination) }
        catch { throw Failure.copy(error.localizedDescription) }
        return destination
    }

    /// Replaces an earlier copy whole: Chrome reloads the folder as it then is.
    static func copyExtension(from source: URL, to destination: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".WinMuxTabs-Chrome-\(UUID().uuidString)")
        try manager.copyItem(at: source, to: staged)
        do {
            if manager.fileExists(atPath: destination.path) {
                _ = try manager.replaceItemAt(destination, withItemAt: staged)
            } else {
                try manager.moveItem(at: staged, to: destination)
            }
        } catch {
            try? manager.removeItem(at: staged)
            throw error
        }
    }

    /// Runs the embedded CLI's host install, which writes only Chrome's host manifest for this
    /// macOS account, naming that CLI. At most ten seconds.
    static func installHost(helper: URL, timeout: TimeInterval = 10) async throws {
        let process = Process()
        process.executableURL = helper
        process.arguments = ["chrome-extension", "install"]
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: Failure.hostInstall(error.localizedDescription))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
        }
        guard status == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.hostInstall(message.isEmpty ? "The WinMux CLI stopped with status \(status)." : message)
        }
    }

    /// Steps Chrome needs from the user: it only loads an unpacked extension that way.
    static let instructions = """
        1. In Chrome, open chrome://extensions (copied for you).
        2. Turn on Developer mode.
        3. Choose Load unpacked, and select the WinMuxTabs-Chrome folder shown in Finder.
        4. Pin WinMux Tabs from the Extensions menu (the puzzle piece). WinMux switches tabs through the \
        extension only in windows where its button shows; elsewhere it uses Accessibility.

        Repeat steps 3 and 4 in each Chrome profile you use. After WinMux updates, set up again, then \
        click Reload on WinMux Tabs in chrome://extensions.
        """

    /// After a setup: shows the folder in Finder, copies Chrome's extensions address, and says what's left.
    @MainActor
    static func presentNextSteps(folder: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([folder])
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("chrome://extensions", forType: .string)
        let alert = NSAlert()
        alert.messageText = "Load WinMux Tabs in Chrome"
        alert.informativeText = instructions
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @MainActor
    static func presentFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't Set Up the Chrome Extension"
        switch error as? Failure {
            case .notBundled:
                alert.informativeText = "This copy of WinMux doesn't include the Chrome extension and its CLI. Install a Preview release in Applications, then try again."
            case .hostInstall(let message):
                alert.informativeText = "Registering WinMux with Chrome failed: \(message)"
            case .copy(let message):
                alert.informativeText = "Copying the extension's files failed: \(message)"
            case nil:
                alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }
}
