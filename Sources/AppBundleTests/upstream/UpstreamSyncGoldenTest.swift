@testable import AppBundle
import Common
import Foundation
import XCTest

/// What users and scripts see must not change in the behavior-neutral phases of docs/upstream-sync.md:
/// command help, parse errors, query output, the effective configuration, and the persisted frozen world.
/// After an intended change, rewrite the fixtures with `WINMUX_UPDATE_GOLDEN=1 swift test --filter UpstreamSyncGoldenTest`
/// and review the fixture diff.
@MainActor
final class UpstreamSyncGoldenTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testCommandHelp() {
        var out = ""
        for kind in CmdKind.allCases where kind != .execAndForget {
            out += "## \(kind.rawValue)\n"
            switch parseCommand("\(kind.rawValue) --help") {
                case .help(let text): out += text + "\n"
                case .failure(let error): out += "failure: \(error)\n"
                case .cmd: out += "cmd\n"
            }
        }
        assertGolden("cli-help.txt", out)
    }

    func testParseErrors() {
        let commands = [
            "", "unknown-command", "focus", "focus nowhere", "focus left --boundaries nowhere", "move", "move up down",
            "layout", "layout accordion", "layout tab-group tiles", "layout --fail-if-noop", "workspace", "workspace --wrap-around",
            "workspace next --auto-back-and-forth", "move-node-to-workspace", "move-node-to-workspace --focus-follows-window",
            "list-windows", "list-windows --all --focused", "list-windows --all --format", "list-workspaces", "list-workspaces --monitor",
            "list-monitors --format '%{nonexistent}'", "list-apps --format '%{window-id}'", "resize", "resize width", "resize width +x",
            "split", "split sideways", "join-with", "swap", "summon-workspace", "move-workspace-to-monitor", "mode", "config --get",
            "trigger-binding", "volume", "volume up 5", "close --quit-if-last-window extra",
            "fullscreen on off", "macos-native-fullscreen sometimes", "enable maybe", "agent", "agent apply", "project", "create-project",
            "rename-project", "set-project-color", "move-node-to-project", "stack-with", "save-workspace --name", "palette extra",
            "open-sidebar extra", "doctor --verbose", "exec-and-forget", "subscribe", "subscribe nothing",
        ]
        let out = commands.map { "$ \($0)\n" + describe(parseCommand($0)) }.joined(separator: "\n")
        assertGolden("cli-parse-errors.txt", out + "\n")
    }

    func testQueryOutput() async throws {
        buildWorld()
        let commands = [
            "list-workspaces --all", "list-workspaces --all --json", "list-workspaces --focused",
            "list-workspaces --all --format '%{workspace}|%{workspace-is-focused}|%{workspace-is-visible}|%{monitor-name}'",
            "list-windows --all", "list-windows --all --json", "list-windows --workspace focused --count",
            "list-windows --all --format '%{window-id}|%{app-name}|%{app-bundle-id}|%{workspace}|%{window-layout}'",
            "list-monitors", "list-monitors --json", "list-apps", "list-apps --json", "list-modes", "list-modes --json",
            "list-projects", "list-projects --json", "list-exec-env-vars", "config --major-keys",
            "focus left", "focus-monitor next", "workspace-back-and-forth", "move-node-to-workspace 2", "focus right",
        ]
        var out = ""
        for command in commands {
            out += "$ \(command)\n" + (try await run(command)) + "\n"
        }
        assertGolden("cli-query-output.txt", out)
    }

    func testEffectiveDefaultConfig() async throws {
        let toml = try String(contentsOf: projectRoot.appending(path: "resources/default-config.toml"), encoding: .utf8)
        assertGolden("config-default.txt", try await dumpConfig(toml))
    }

    func testEffectiveWinMuxConfig() async throws {
        let toml = """
            config-version = 2
            automatically-tile-new-windows = false
            open-new-windows-in-new-workspace = true
            middle-click-closes-windows = false
            tab-group-padding = 12
            auto-add-new-windows-to-tab-group = true
            default-root-container-layout = 'tab-group'
            exec-on-workspace-change = ['/bin/echo', 'changed']
            on-focus-changed = ['move-mouse window-lazy-center']
            [gaps]
            inner.horizontal = 4
            outer.left = [{ monitor.main = 16 }, 8]
            [workspace-sidebar]
            enabled = true
            mode = 'tabs'
            width = 300
            [window-tabs]
            [mode.main.binding]
            alt-h = 'focus left'
            alt-shift-t = 'layout tab-group tiles'
            [mode.main.binding-tap]
            [[on-window-detected]]
            if.app-id = 'com.apple.finder'
            if.during-winmux-startup = false
            run = 'layout floating'
            """
        assertGolden("config-winmux.txt", try await dumpConfig(toml))
    }

    func testConfigErrors() {
        let cases = [
            "unknown-key = 1",
            "accordion-padding = 10",
            "tab-group-padding = 'wide'",
            "default-root-container-layout = 'accordion'",
            "[workspace-sidebar]\nmode = 'nowhere'",
            "[workspace-sidebar]\nunknown = true",
            "[mode.main.binding]\nalt-h = 'focus nowhere'",
            "[[on-window-detected]]\nif.during-aerospace-startup = true\nrun = 'layout floating'",
            "[gaps]\ninner.horizontal = -1",
            "config-version = 99",
            "not toml at all = = =",
        ]
        let out = cases.map { toml in
            "### \(toml.replacingOccurrences(of: "\n", with: " ⏎ "))\n"
                + parseConfig(toml).errors.map { "- \($0.description)" }.joined(separator: "\n")
        }.joined(separator: "\n")
        assertGolden("config-errors.txt", out + "\n")
    }

    func testDefaultWindowRules() throws {
        let text = try String(contentsOf: projectRoot.appending(path: "resources/default-window-rules.toml"), encoding: .utf8)
        let file = parseWindowRulesFile(text, source: "default-window-rules.toml")
        let out = "rules: \(file.rules.count)\ndisabled: \(file.disabledIds.sorted())\nproblems:\n"
            + file.problems.map { "- \($0)" }.joined(separator: "\n")
            + "\n" + file.rules.map { String(describing: $0) }.joined(separator: "\n")
        assertGolden("window-rules-default.txt", out + "\n")
    }

    func testPersistedFrozenWorld() throws {
        buildWorld()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshotCurrentFrozenWorld())
        let normalized = try JSONSerialization.data(
            withJSONObject: sortUnorderedIds(try JSONSerialization.jsonObject(with: data)),
            options: [.prettyPrinted, .sortedKeys])
        assertGolden("frozen-world.json", String(decoding: normalized, as: UTF8.self) + "\n")
    }

    // MARK: helpers

    private func buildWorld() {
        let first = Workspace.get(byName: "1")
        first.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0)
            }
        }
        let second = Workspace.get(byName: "2")
        TilingContainer(parent: second.rootTilingContainer, adaptiveWeight: 1, .v, .tabGroup, index: 0).apply {
            TestWindow.new(id: 4, parent: $0)
            TestWindow.new(id: 5, parent: $0)
        }
        check(first.focusWorkspace())
        Workspace.reconcileWorkspaceState()
    }

    private func run(_ command: String) async throws -> String {
        switch parseCommand(command) {
            case .cmd(let cmd):
                let result = try await cmd.run(.defaultEnv, .emptyStdin)
                // The environment prints in dictionary order, which isn't stable across processes.
                let stdout = command == "list-exec-env-vars" ? result.stdout.sorted() : result.stdout
                return "exit: \(result.exitCode)\n" + stdout.map { "out: \($0)\n" }.joined()
                    + result.stderr.map { "err: \($0)\n" }.joined()
            case let other:
                return describe(other)
        }
    }

    /// Every parsed value, flattened by property path. A `winmux` path segment is dropped, so moving WinMux fields
    /// into one nested struct (docs/upstream-sync.md phase 1) keeps the fixture.
    private func dumpConfig(_ toml: String) async throws -> String {
        let (parsed, errors) = parseConfig(toml)
        var lines: [String] = []
        flatten(parsed, path: "", depth: 0, into: &lines)
        return "errors:\n" + errors.map { "- \($0.description)\n" }.joined() + lines.sorted().joined(separator: "\n") + "\n"
    }
}

/// Stored properties renamed back to upstream's names (docs/upstream-sync.md phase 1), printed under the names the
/// fixtures were recorded with. Internal only: no config key, CLI output or persisted field uses them.
private let internalRenames = [
    "duringAeroSpaceStartup": "duringWinMuxStartup",
]

private func flatten(_ value: Any, path: String, depth: Int, into lines: inout [String]) {
    let mirror = Mirror(reflecting: value)
    func leaf() {
        let text = String(describing: value).replacing(/0x[0-9a-f]+/, with: "0x…")
        lines.append("\(path) = \(text)")
    }
    if depth > 8 { return leaf() }
    switch mirror.displayStyle {
        case .optional:
            if let child = mirror.children.first {
                flatten(child.value, path: path, depth: depth + 1, into: &lines)
            } else {
                lines.append("\(path) = nil")
            }
        case .struct, .class:
            if mirror.children.isEmpty { return leaf() }
            for child in mirror.children {
                let label = internalRenames[child.label ?? "?"] ?? child.label ?? "?"
                let childPath = label == "winmux" ? path : (path.isEmpty ? label : "\(path).\(label)")
                flatten(child.value, path: childPath, depth: depth + 1, into: &lines)
            }
        case .dictionary, .set:
            let items = mirror.children.map { child -> (String, Any) in
                let pair = Mirror(reflecting: child.value).children.map(\.value)
                return pair.count == 2 ? (String(describing: pair[0]), pair[1]) : (String(describing: child.value), child.value)
            }.sorted { $0.0 < $1.0 }
            if items.isEmpty { lines.append("\(path) = [:]") }
            for (key, item) in items {
                if mirror.displayStyle == .set {
                    lines.append("\(path)[] = \(key)")
                } else {
                    flatten(item, path: "\(path)[\(key)]", depth: depth + 1, into: &lines)
                }
            }
        case .collection, .tuple:
            if mirror.children.isEmpty { lines.append("\(path) = []") }
            for (index, child) in mirror.children.enumerated() {
                flatten(child.value, path: "\(path)[\(child.label.map { $0.hasPrefix(".") ? String(index) : $0 } ?? String(index))]", depth: depth + 1, into: &lines)
            }
        default:
            leaf()
    }
}

private func describe<T>(_ parsed: ParsedCmd<T>) -> String {
    switch parsed {
        case .cmd: "parsed\n"
        case .failure(let error): "failure: \(error)\n"
        case .help(let text): "help: \(text.split(separator: "\n").first ?? "")\n"
    }
}

/// Sets encode in hash order; sort id arrays so the fixture is stable.
private func sortUnorderedIds(_ value: Any, key: String? = nil) -> Any {
    if let dict = value as? [String: Any] {
        return dict.mapValuesWithKey { k, v in sortUnorderedIds(v, key: k) }
    }
    if let array = value as? [Any] {
        let mapped = array.map { sortUnorderedIds($0) }
        if let key, key.hasSuffix("Ids"), let numbers = mapped as? [NSNumber] {
            return numbers.sorted { $0.int64Value < $1.int64Value }
        }
        return mapped
    }
    return value
}

private extension Dictionary {
    func mapValuesWithKey<T>(_ transform: (Key, Value) -> T) -> [Key: T] {
        Dictionary<Key, T>(uniqueKeysWithValues: map { ($0.key, transform($0.key, $0.value)) })
    }
}

@MainActor
private func assertGolden(_ name: String, _ actual: String, file: StaticString = #filePath, line: UInt = #line) {
    let url = projectRoot.appending(path: "test-fixtures/upstream-sync/\(name)")
    if ProcessInfo.processInfo.environment["WINMUX_UPDATE_GOLDEN"] == "1" {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertNoThrow(try actual.write(to: url, atomically: true, encoding: .utf8), file: file, line: line)
        return
    }
    guard let expected = try? String(contentsOf: url, encoding: .utf8) else {
        XCTFail("Missing golden fixture \(name); run with WINMUX_UPDATE_GOLDEN=1", file: file, line: line)
        return
    }
    if expected == actual { return }
    let expectedLines = expected.split(separator: "\n", omittingEmptySubsequences: false)
    let actualLines = actual.split(separator: "\n", omittingEmptySubsequences: false)
    let index = zip(expectedLines, actualLines).enumerated().first { $0.element.0 != $0.element.1 }?.offset
        ?? min(expectedLines.count, actualLines.count)
    let expectedLine = index < expectedLines.count ? String(expectedLines[index]) : "<end>"
    let actualLine = index < actualLines.count ? String(actualLines[index]) : "<end>"
    XCTFail("\(name) differs at line \(index + 1):\n  expected: \(expectedLine)\n  actual:   \(actualLine)", file: file, line: line)
}
