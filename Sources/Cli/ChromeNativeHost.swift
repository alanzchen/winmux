import Common
import Darwin
import Foundation

/// Invoked only by Chrome (the allowed origin is argv[1]), or by an explicit install command.
enum ChromeNativeHost {
    static func install(helper: URL, home: URL) throws -> URL {
        let directory = home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts")
        let file = directory.appendingPathComponent(BrowserPushIdentity.host + ".json")
        let data = try JSONSerialization.data(withJSONObject: [
            "name": BrowserPushIdentity.host, "description": "WinMux browser event bridge", "type": "stdio",
            "path": helper.resolvingSymlinksInPath().path, "allowed_origins": [BrowserPushIdentity.origin],
        ], options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        return file
    }

    static func handle(_ args: [String]) -> Bool {
        let helper = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        if args == ["chrome-extension", "install"] {
            // A host registered against a temporary SwiftPM binary would break on the next build.
            guard helper.path.hasSuffix(".app/Contents/Helpers/winmux") else {
                fputs("Run chrome-extension install with the CLI inside your installed WinMux.app.\n", stderr)
                Darwin.exit(1)
            }
            do { print(try install(helper: helper, home: FileManager.default.homeDirectoryForCurrentUser).path) }
            catch { fputs("Chrome host installation failed: \(error)\n", stderr); Darwin.exit(1) }
            return true
        }
        guard args.first?.hasPrefix("chrome-extension://") == true else { return false }
        guard args.first == BrowserPushIdentity.origin else { Darwin.exit(1) }
        signal(SIGPIPE, SIG_IGN)
        let app = helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let requirement = BrowserPushIO.requirement(for: app),
              let fd = BrowserPushIO.connect(BrowserPushIdentity.socket), BrowserPushIO.peer(fd, meets: requirement)
        else { Darwin.exit(1) }
        // One reader in each direction. There are no logs on stdout, polling processes or login items.
        DispatchQueue.global(qos: .utility).async {
            while let data = BrowserPushIO.read(STDIN_FILENO), BrowserPushIO.write(data, to: fd) {}
            shutdown(fd, SHUT_RDWR)
        }
        while let data = BrowserPushIO.read(fd), BrowserPushIO.write(data, to: STDOUT_FILENO) {}
        shutdown(fd, SHUT_RDWR)
        close(fd)
        Darwin.exit(0)
    }
}
