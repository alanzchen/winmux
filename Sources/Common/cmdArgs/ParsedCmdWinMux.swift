extension ParsedCmd {
    /// (command, help, error message): WinMux's server and tests read a parse result this way. Upstream dropped it in S3.
    public func unwrap() -> (T?, String?, String?) {
        switch self {
            case .cmd(let command): (command, nil, nil)
            case .help(let help): (nil, help, nil)
            case .failure(let failure): (nil, nil, failure.msg)
        }
    }
}
