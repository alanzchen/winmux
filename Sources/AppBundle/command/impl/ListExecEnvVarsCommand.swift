import AppKit
import Common

struct ListExecEnvVarsCommand: Command {
    let args: ListExecEnvVarsCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        // WINMUX-HOOK-BEGIN(mcpEnvRefusal)
        // Set only for an MCP request from the tailnet while the server requires no token, however it got here.
        if MCPRequestRestrictions.refusesEnvironmentListing { return .fail(io.err(mcpEnvironmentListingRefusal)) }
        // WINMUX-HOOK-END(mcpEnvRefusal)
        for (key, value) in config.execConfig.envVariables {
            io.out("\(key)=\(value)")
        }
        return .succ
    }
}
