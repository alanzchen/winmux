@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class ConfigTest: XCTestCase {
    func testParseI3Config() {
        let toml =
            """
            config-version = 2
            persistent-workspaces = []
            enable-normalization-flatten-containers = false
            enable-normalization-opposite-orientation-for-nested-containers = false
            on-focused-monitor-changed = ['move-mouse monitor-lazy-center']

            [mode.main.binding]
                alt-enter = '''exec-and-forget osascript -e '
                tell application "Terminal"
                    do script
                    activate
                end tell'
                '''
                alt-j = 'focus --boundaries-action wrap-around-the-workspace left'
                alt-k = 'focus --boundaries-action wrap-around-the-workspace down'
                alt-l = 'focus --boundaries-action wrap-around-the-workspace up'
                alt-semicolon = 'focus --boundaries-action wrap-around-the-workspace right'
            """
        let (i3Config, errors) = parseConfigForTests(toml)
        assertEquals(errors, [])
        assertEquals(i3Config.execConfig, defaultConfig.execConfig)
        assertEquals(i3Config.enableNormalizationFlattenContainers, false)
        assertEquals(i3Config.enableNormalizationOppositeOrientationForNestedContainers, false)
    }

    func testParseDefaultConfig() throws {
        let toml = try String(contentsOf: projectRoot.appending(component: "resources/default-config.toml"), encoding: .utf8)
        let (config, errors) = parseConfigForTests(toml)
        assertEquals(errors, [])
        XCTAssertTrue(config.automaticallyTileNewWindows)
        XCTAssertFalse(config.workspaceSidebar.showClock)
        XCTAssertTrue(config.workspaceSidebar.showSeconds)
        XCTAssertFalse(config.workspaceSidebar.showDate)
        XCTAssertTrue(config.workspaceSidebar.showWeekday)
        XCTAssertTrue(config.workspaceSidebar.saveNamedWorkspaces)
        XCTAssertFalse(config.workspaceSidebar.openSavedWorkspaceAppsAtStartup)
        XCTAssertTrue(config.enableShakeToToggleTiling)
    }

    func testParseAutomaticallyTileNewWindows() {
        let (config, errors) = parseConfigForTests("automatically-tile-new-windows = false")

        assertEquals(errors, [])
        XCTAssertFalse(config.automaticallyTileNewWindows)
    }

    func testParseShakeToToggleTiling() {
        let (config, errors) = parseConfigForTests("enable-shake-to-toggle-tiling = false")

        assertEquals(errors, [])
        XCTAssertFalse(config.enableShakeToToggleTiling)
    }

    func testConfigVersionOutOfBounds() {
        let result = parseConfig(
            """
            config-version = 0
            """,
        )
        assertTrue(result.allowReloadConfig)
        assertEquals(result.strErrors, ["[ERROR] config-version: config-version must be in [1, 2] range"])
    }

    func testConfigVersionOutdatedWarning() {
        let result = parseConfig(
            """
            config-version = 1
            """,
        )
        assertTrue(result.allowReloadConfig)
        assertEquals(result.errors, [])
        assertEquals(result.strWarnings, [
            "[WARNING] The current 'config-version = 1' is outdated. " +
                "Please consider migrating to 'config-version = \(maxConfigVersion)'. " +
                "See https://nikitabobko.github.io/AeroSpace/guide#config-version for the migration guide.",
        ])
    }

    func testLatestConfigVersionNoWarning() {
        let result = parseConfig(
            """
            config-version = \(maxConfigVersion)
            """,
        )
        assertEquals(result.errors, [])
        assertEquals(result.warnings, [])
    }

    func testExecOnWorkspaceChangeDifferentTypesError() {
        let errors = parseConfig(
            """
            exec-on-workspace-change = ['', 1]
            """,
        ).strErrors
        assertEquals(errors, ["[ERROR] exec-on-workspace-change[1]: Expected type is \'String\'. But actual type is \'Int\'"])
    }

    func testDuplicatedPersistentWorkspaces() {
        let errors = parseConfig(
            """
            config-version = 2
            persistent-workspaces = ['a', 'a']
            """,
        ).strErrors
        assertEquals(errors, ["[ERROR] persistent-workspaces: Contains duplicated workspace names"])
    }

    func testPersistentWorkspacesAreAvailableOnlySinceVersion2() {
        let errors = parseConfig(
            """
            persistent-workspaces = ['a']
            """,
        ).strErrors
        assertEquals(errors, ["[ERROR] persistent-workspaces: This config option is only available since \'config-version = 2\'"])
    }

    func testQueryCantBeUsedInConfig() {
        let errors = parseConfig(
            """
            [mode.main.binding]
                alt-a = 'list-apps'
            """,
        ).strErrors
        XCTAssertTrue(errors.singleOrNil()?.contains("cannot be used in config") == true)
    }

    func testDropBindings() {
        let result = parseConfig(
            """
            mode.main = {}
            """,
        )
        assertTrue(result.allowReloadConfig)
        assertEquals(result.errors, [])
        assertTrue(result.config.modes[mainModeId]?.bindings.isEmpty == true)
    }

    func testParseMode() {
        let result = parseConfig(
            """
            [mode.main.binding]
                alt-h = 'focus left'
            """,
        )
        assertEquals(result.errors, [])
        let binding = HotkeyBinding(.option, .h, [FocusCommand.new(direction: .left)])
        assertEquals(
            result.config.modes[mainModeId],
            Mode(bindings: [binding.descriptionWithKeyCode: binding], tapBindings: [:]),
        )
    }

    func testParseTapBindings() {
        let (config, errors) = parseConfigForTests(
            """
            [mode.main.binding-tap]
                left-alt = 'focus left'
                right-cmd = 'workspace 2'
            """,
        )
        assertEquals(errors, [])
        assertEquals(
            config.modes[mainModeId],
            Mode(
                bindings: [:],
                tapBindings: [
                    "left-alt": TapBinding(.leftAlt, [FocusCommand.new(direction: .left)]),
                    "right-cmd": TapBinding(.rightCmd, [WorkspaceCommand(args: WorkspaceCmdArgs(target: .direct(.parse("2").getOrDie())))]),
                ],
            ),
        )
    }

    func testTapModifierStateClearsAfterMissedRelease() async throws {
        resetHotKeys()
        config.modes = [
            mainModeId: Mode(
                bindings: [:],
                tapBindings: [
                    "left-alt": TapBinding(.leftAlt, [FocusCommand.new(direction: .left)]),
                    "right-cmd": TapBinding(.rightCmd, [FocusCommand.new(direction: .right)]),
                ],
            ),
        ]
        try await activateMode(mainModeId)

        let leftAltDown: NSEvent.ModifierFlags = [.option, TapModifierKey.leftAlt.deviceSpecificModifierFlag]
        let rightCmdDown: NSEvent.ModifierFlags = [.command, TapModifierKey.rightCmd.deviceSpecificModifierFlag]
        noteTapBindingFlagsChanged(keyCode: 58, modifierFlags: leftAltDown)
        XCTAssertEqual(tapBindingPressedModifiersForTests(), [.leftAlt])

        noteTapBindingFlagsChanged(keyCode: 58, modifierFlags: leftAltDown)
        XCTAssertEqual(tapBindingPressedModifiersForTests(), [.leftAlt])

        noteTapBindingFlagsChanged(keyCode: 58, modifierFlags: [])
        XCTAssertTrue(tapBindingPressedModifiersForTests().isEmpty)

        noteTapBindingFlagsChanged(keyCode: 54, modifierFlags: rightCmdDown)
        XCTAssertEqual(tapBindingPressedModifiersForTests(), [.rightCmd])

        // Simulate macOS missing the right-cmd release event. The next modifier
        // event snapshot says only left-alt is down, so stale right-cmd state
        // must be cleared; otherwise tap bindings stop launching after a while.
        noteTapBindingFlagsChanged(keyCode: 58, modifierFlags: leftAltDown)
        XCTAssertEqual(tapBindingPressedModifiersForTests(), [.leftAlt])
    }

    func testFlipEventTapCancelsOptionLauncherButPreservesSingleTap() async throws {
        resetHotKeys()
        defer { resetHotKeys() }
        let saved = UserDefaults.standard.object(forKey: "doubleSidedWindows")
        defer { UserDefaults.standard.set(saved, forKey: "doubleSidedWindows") }
        UserDefaults.standard.set(false, forKey: "doubleSidedWindows")
        config.modes = [mainModeId: Mode(bindings: [:], tapBindings: [
            "left-alt": TapBinding(.leftAlt, [FocusCommand.new(direction: .left)]),
        ])]
        try await activateMode(mainModeId)
        let optionDown: NSEvent.ModifierFlags = [.option, TapModifierKey.leftAlt.deviceSpecificModifierFlag]
        let gesture = DoubleSidedWindowGesture()
        // These key and mouse paths do not post events through the proxy.
        let proxy = OpaquePointer(bitPattern: 1)!
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: true)!
        event.flags = .maskAlternate
        for type: CGEventType in [.keyDown, .leftMouseDown] {
            noteTapBindingFlagsChanged(keyCode: 58, modifierFlags: optionDown)
            XCTAssertTrue(hasPendingTapBindingForTests())
            // Bypass NSEvent monitors, as happens when the flip tap consumes input.
            _ = gesture.handle(proxy: proxy, type: type, event: event)
            noteTapBindingFlagsChanged(keyCode: 58, modifierFlags: [])
            XCTAssertFalse(hasPendingTapBindingForTests())
        }
        noteTapBindingFlagsChanged(keyCode: 58, modifierFlags: optionDown)
        noteTapBindingFlagsChanged(keyCode: 58, modifierFlags: [])
        XCTAssertTrue(hasPendingTapBindingForTests())
    }

    func testBindingEqualityChecksCommandCount() {
        let focusLeft = FocusCommand.new(direction: .left)
        let focusRight = FocusCommand.new(direction: .right)
        let shortHotkey = HotkeyBinding(.option, .h, [focusLeft])
        let longHotkey = HotkeyBinding(.option, .h, [focusLeft, focusRight])
        let shortTap = TapBinding(.leftAlt, [focusLeft])
        let longTap = TapBinding(.leftAlt, [focusLeft, focusRight])

        XCTAssertNotEqual(shortHotkey, longHotkey)
        XCTAssertNotEqual(shortTap, longTap)
    }

    func testWindowDetectedCallbackEqualityChecksCommandCount() {
        let matcher = WindowDetectedCallbackMatcher.legacy(LegacyWindowDetectedCallbackMatcher(appId: "com.example.app"))
        let short = WindowDetectedCallback(
            matcher: matcher,
            rawRun: [FocusCommand.new(direction: .left)],
        )
        let long = WindowDetectedCallback(
            matcher: matcher,
            rawRun: [FocusCommand.new(direction: .left), FocusCommand.new(direction: .right)],
        )

        XCTAssertNotEqual(short, long)
    }

    func testModesMustContainDefaultModeError() {
        let result = parseConfig(
            """
            [mode.foo.binding]
                alt-h = 'focus left'
            """,
        )
        assertEquals(
            result.strErrors,
            ["[ERROR] mode: Please specify \'main\' mode"],
        )
        assertEquals(result.config.modes[mainModeId], nil)
    }

    func testHotkeyParseError() {
        let result = parseConfig(
            """
            [mode.main.binding]
                alt-hh = 'focus left'
                aalt-j = 'focus down'
                alt-k = 'focus up'
            """,
        )
        assertEquals(
            result.strErrors,
            [
                "[ERROR] mode.main.binding.aalt-j: Can\'t parse modifiers in \'aalt-j\' binding",
                "[ERROR] mode.main.binding.alt-hh: Can\'t parse the key in \'alt-hh\' binding",
            ],
        )
        let binding = HotkeyBinding(.option, .k, [FocusCommand.new(direction: .up)])
        assertEquals(
            result.config.modes[mainModeId],
            Mode(bindings: [binding.descriptionWithKeyCode: binding], tapBindings: [:]),
        )
    }

    func testTapBindingParseError() {
        let (config, errors) = parseConfigForTests(
            """
            [mode.main.binding-tap]
                unicorn = 'focus left'
            """,
        )
        assertEquals(
            errors,
            [
                "mode.main.binding-tap.unicorn: Unsupported tap binding key 'unicorn'. Supported keys: left-alt, right-alt, left-cmd, right-cmd, left-ctrl, right-ctrl, left-shift, right-shift",
            ],
        )
        assertEquals(config.modes[mainModeId], Mode(bindings: [:], tapBindings: [:]))
    }

    func testTapModifierKeyUsesSideSpecificModifierFlags() {
        let leftAltFlags: NSEvent.ModifierFlags = [
            .option,
            NSEvent.ModifierFlags(rawValue: UInt(NX_DEVICELALTKEYMASK)),
        ]
        let rightCmdFlags: NSEvent.ModifierFlags = [
            .command,
            NSEvent.ModifierFlags(rawValue: UInt(NX_DEVICERCMDKEYMASK)),
        ]

        XCTAssertTrue(TapModifierKey.leftAlt.isPressed(in: leftAltFlags))
        XCTAssertFalse(TapModifierKey.rightAlt.isPressed(in: leftAltFlags))
        XCTAssertTrue(TapModifierKey.rightCmd.isPressed(in: rightCmdFlags))
        XCTAssertFalse(TapModifierKey.leftCmd.isPressed(in: rightCmdFlags))
        XCTAssertTrue(TapModifierKey.leftAlt.isPressed(in: .option))
    }

    func testPermanentWorkspaceNames() {
        let result = parseConfig(
            """
            [mode.main.binding]
                alt-1 = 'workspace 1'
                alt-2 = 'workspace 2'
                alt-3 = ['workspace 3']
                alt-4 = ['workspace 4', 'focus left']
            """,
        )
        assertEquals(result.errors, [])
        assertEquals(result.config.persistentWorkspaces.sorted(), ["1", "2", "3", "4"])
    }

    func testUnknownTopLevelKeyParseError() {
        let result = parseConfig(
            """
            unknownKey = true
            enable-normalization-flatten-containers = false
            """,
        )
        assertEquals(
            result.strErrors,
            ["[ERROR] unknownKey: Unknown top-level key"],
        )
        assertEquals(result.config.enableNormalizationFlattenContainers, false)
    }

    func testUnknownKeyParseError() {
        let result = parseConfig(
            """
            enable-normalization-flatten-containers = false
            [gaps]
                unknownKey = true
            """,
        )
        assertEquals(
            result.strErrors,
            ["[ERROR] gaps.unknownKey: Unknown key"],
        )
        assertEquals(result.config.enableNormalizationFlattenContainers, false)
    }

    func testTypeMismatch() {
        let errors = parseConfig(
            """
            enable-normalization-flatten-containers = 'true'
            """,
        ).strErrors
        assertEquals(
            errors,
            ["[ERROR] enable-normalization-flatten-containers: Expected type is \'Bool\'. But actual type is \'String\'"],
        )
    }

    func testConfigParseError() {
        assertFalse(parseConfig("true").allowReloadConfig)
        assertEquals(
            parseConfig("true").strErrors,
            ["[ERROR] (Line 1) Syntax error: missing =."],
        )

        assertEquals(
            parseConfig("\n1").strErrors,
            ["[ERROR] (Line 2) Syntax error: missing =."],
        )

        assertEquals(
            parseConfig("foo: 1").strErrors,
            ["[ERROR] (Line 1) Syntax error: missing =."],
        )

        // Upstream reports "foo: Unsupported TOML type: Double". WinMux reads floats (hook jsonDouble), so the value
        // passes conversion and the key is reported instead.
        assertEquals(
            parseConfigForTests("foo = 1.0").errors,
            ["foo: Unknown top-level key"],
        )

        assertEquals(
            parseConfig("foo.bar = 1979-05-27").strErrors,
            ["[ERROR] foo.bar: Unsupported TOML type: LocalDate", "[ERROR] foo: Unknown top-level key"],
        )
    }

    func testMoveWorkspaceToMonitorCommandParsing() {
        XCTAssertTrue(parseCommand("move-workspace-to-monitor --wrap-around next").cmdOrNil is MoveWorkspaceToMonitorCommand)
        XCTAssertTrue(parseCommand("move-workspace-to-display --wrap-around next").cmdOrNil is MoveWorkspaceToMonitorCommand)
    }

    func testParseTiles() {
        let command = parseCommand("layout tiles h_tiles v_tiles tab-group h_tab_group v_tab_group").cmdOrNil
        guard let command = command as? LayoutCommand else {
            XCTFail("Expected layout command")
            return
        }
        assertEquals(command.args.toggleBetween.val, [.tiles, .h_tiles, .v_tiles, .tabGroup, .hTabGroup, .vTabGroup])

        guard case .help = parseCommand("layout tiles -h") else {
            XCTFail()
            return
        }
    }

    func testSplitCommandAndFlattenContainersNormalization() {
        let (_, errors) = parseConfigForTests(
            """
            enable-normalization-flatten-containers = true
            [mode.main.binding]
            [mode.foo.binding]
                alt-s = 'split horizontal'
            """,
        )
        assertEquals(
            errors,
            ["""
                The config contains:
                1. usage of 'split' command
                2. enable-normalization-flatten-containers = true
                These two settings don't play nicely together. 'split' command has no effect when enable-normalization-flatten-containers is enabled.

                My recommendation: keep the normalizations enabled, and prefer 'join-with' over 'split'.
                """],
        )
    }

    func testParseWorkspaceToMonitorAssignment() {
        let result = parseConfig(
            """
            [workspace-to-monitor-force-assignment]
                workspace_name_1 = 1                            # Sequence number of the monitor (from left to right, 1-based indexing)
                workspace_name_2 = 'main'                       # main monitor
                workspace_name_3 = 'secondary'                  # non-main monitor (in case when there are only two monitors)
                workspace_name_4 = 'built-in'                   # case insensitive regex substring
                workspace_name_5 = '^built-in retina display$'  # case insensitive regex match
                workspace_name_6 = ['secondary', 1]             # you can specify multiple patterns. The first matching pattern will be used
                7 = "foo"
                w7 = ['', 'main']
                w8 = 0
                workspace_name_x = '2'                          # Sequence number of the monitor (from left to right, 1-based indexing)
            """,
        )
        assertEquals(
            result.config.workspaceToMonitorForceAssignment,
            [
                "workspace_name_1": [.sequenceNumber(1)],
                "workspace_name_2": [.main],
                "workspace_name_3": [.secondary],
                "workspace_name_4": [.pattern("built-in")!],
                "workspace_name_5": [.pattern("^built-in retina display$")!],
                "workspace_name_6": [.secondary, .sequenceNumber(1)],
                "workspace_name_x": [.sequenceNumber(2)],
                "7": [.pattern("foo")!],
                "w7": [.main],
                "w8": [],
            ],
        )
        assertEquals([
            "[ERROR] workspace-to-monitor-force-assignment.w7[0]: Empty string is an illegal monitor description",
            "[ERROR] workspace-to-monitor-force-assignment.w8: Monitor sequence numbers uses 1-based indexing. Values less than 1 are illegal",
        ], result.strErrors)
        assertEquals([:], defaultConfig.workspaceToMonitorForceAssignment)
    }

    func testParseOnWindowDetected() {
        let result = parseConfig(
            """
            on-window-detected = [
                { # 0
                    check-further-callbacks = true,
                    run = ['layout floating', 'move-node-to-workspace W'],
                },
                { # 1
                    if.app-id = 'com.apple.systempreferences',
                    run = [],
                },
                {}, # 2
                { # 3
                    run = ['move-node-to-workspace S', 'layout tiling'],
                },
                { # 4
                    run = ['move-node-to-workspace S', 'move-node-to-workspace W'],
                },
                { # 5
                    run = ['move-node-to-workspace S', 'layout h_tiles'],
                },
                { # 6
                    if = 'test %{app-bundle-id} = org.alacritty',
                    run = ['move-node-to-workspace T'],
                },
            ]
            """,
        )
        let matcher6Args = TestCmdArgs(rawArgs: [])
            .copy(\.lhs, .initialized(.app(.appBundleId)))
            .copy(\.infixOperator, .initialized(.equals))
            .copy(\.rhs, .initialized("org.alacritty"))
        assertEquals(result.config.onWindowDetected, [
            WindowDetectedCallback( // 0
                checkFurtherCallbacks: true,
                rawRun: [
                    LayoutCommand(args: LayoutCmdArgs(rawArgs: [], toggleBetween: [.floating])),
                    MoveNodeToWorkspaceCommand(args: MoveNodeToWorkspaceCmdArgs(workspace: "W")),
                ],
            ),
            WindowDetectedCallback( // 1
                matcher: .legacy(LegacyWindowDetectedCallbackMatcher(
                    appId: "com.apple.systempreferences",
                )),
                rawRun: [],
            ),
            WindowDetectedCallback( // 3
                rawRun: [
                    MoveNodeToWorkspaceCommand(args: MoveNodeToWorkspaceCmdArgs(workspace: "S")),
                    LayoutCommand(args: LayoutCmdArgs(rawArgs: [], toggleBetween: [.tiling])),
                ],
            ),
            WindowDetectedCallback( // 4
                rawRun: [
                    MoveNodeToWorkspaceCommand(args: MoveNodeToWorkspaceCmdArgs(workspace: "S")),
                    MoveNodeToWorkspaceCommand(args: MoveNodeToWorkspaceCmdArgs(workspace: "W")),
                ],
            ),
            WindowDetectedCallback( // 5
                rawRun: [
                    MoveNodeToWorkspaceCommand(args: MoveNodeToWorkspaceCmdArgs(workspace: "S")),
                    LayoutCommand(args: LayoutCmdArgs(rawArgs: [], toggleBetween: [.h_tiles])),
                ],
            ),
            WindowDetectedCallback( // 6
                matcher: .command(TestCommand(args: matcher6Args)),
                rawRun: [
                    MoveNodeToWorkspaceCommand(args: MoveNodeToWorkspaceCmdArgs(workspace: "T")),
                ],
            ),
        ])

        assertEquals(result.strErrors, [
            "[ERROR] on-window-detected[2]: \'run\' is mandatory key",
        ])
    }

    func testParseInlineTables() {
        let errors = parseConfigForTests(
            """
            on-window-detected = [
                {
                    check-further-callbacks = true,
                    run = ['layout floating', 'move-node-to-workspace W'],
                },
                {
                    if.app-id = 'com.apple.systempreferences',
                    run = [],
                }
            ]
            """,
        ).errors
        assertEquals(errors, [])
    }

    func testTomlParser() {
        // https://github.com/nikitabobko/AeroSpace/issues/1064
        let errors = parseConfig(
            """
            [[[on-window-detected]]
            if.app-id = 'com.apple.findmy'
            run = 'layout floating'

            [on-window-detected]]
            if.app-id = 'com.openai.chat'
            run = 'layout floating'
            """,
        ).strErrors
        assertEquals(errors, ["[ERROR] (Line 1) Syntax error: invalid or missing key."])
    }
}
