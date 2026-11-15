import Common

extension WinMuxHooks {
    /// `debug-windows` keeps WinMux's key names. Hook `axDumpKeys` in dumpAxRecursive.swift answers the recursion limit
    /// with these keys and renames upstream's bookkeeping keys before the dump is returned.
    static var axDumpRecursionLimit: [String: Json] {
        ["dumpAxRecursive infinite recursion": .bool(true), kAXWinMuxSynthetic: .bool(true)]
    }

    static let axDumpKeyRenames: [(upstream: String, winMux: String)] = [
        ("Aero.AxWritable", "WinMux.AxWritable"),
        ("Aero.AxFailed", "WinMux.AxFailed"),
        ("Aero.AxIgnored", "WinMux.AxIgnored"),
    ]

    static func renameAxDumpKeys(_ result: inout [String: Json]) {
        for (upstream, winMux) in axDumpKeyRenames {
            if let value = result.removeValue(forKey: upstream) { result[winMux] = value }
        }
    }
}
