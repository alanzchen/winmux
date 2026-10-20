import Foundation

func showDiagnosticMessage(filename: String, title: String, message: String) {
    let titleAndMessage = "##### \(title) #####\n\n" + message
    let cachesDir = URL(filePath: "/tmp/com.zimengxiong.winmux/")
    Result { try FileManager.default.createDirectory(at: cachesDir, withIntermediateDirectories: true) }.getOrDie()
    let file = cachesDir.appending(component: filename)
    Result { try (titleAndMessage + "\n").write(to: file, atomically: true, encoding: .utf8) }.getOrDie()

    file.absoluteURL.open(with: URL(filePath: "/System/Applications/Utilities/Console.app"))
}
