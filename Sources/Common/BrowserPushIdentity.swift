import Foundation

public enum BrowserPushIdentity {
    public static let extensionId = "hnanakkjaimkfkpgmcoaglbgiiaohgbj"
    public static let host = "com.zimengxiong.winmux.tabs"
    public static var origin: String { "chrome-extension://\(extensionId)/" }
    public static var socket: String { "\(socketPath).browser" }
}
