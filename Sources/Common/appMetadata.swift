public let stableAeroSpaceAppId: String = "com.zimengxiong.winmux"
#if DEBUG
    public let aeroSpaceAppId: String = "com.zimengxiong.winmux.debug"
    public let aeroSpaceAppName: String = "WinMux-Debug"
#else
    public let aeroSpaceAppId: String = stableAeroSpaceAppId
    public let aeroSpaceAppName: String = "WinMux"
#endif

/// The fork's issue tracker, where users report bugs and runtime errors.
public let winMuxNewIssueURL = "https://github.com/alanzchen/winmux/issues/new"
