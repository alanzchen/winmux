import Common

extension CmdIo {
    /// For WinMux helpers that report through `Bool`, as `err` and `out` did before upstream S3: an error is `false`,
    /// output is `true`. Commands themselves return exit codes.
    @discardableResult func errFalse(_ msg: String) -> Bool { err(msg); return false }
    @discardableResult func outTrue(_ msg: String) -> Bool { out(msg); return true }
    @discardableResult func outTrue(_ msg: [String]) -> Bool { out(msg); return true }
}
