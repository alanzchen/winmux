import AppKit
@testable import AppBundle
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarAppearanceTest: XCTestCase {
    func testAppearanceSectionsOverrideOnlyTheirOwnValues() {
        let (parsed, errors) = parseConfig("""
        [workspace-sidebar]
        mode = 'dock'
        chrome-style = 'solid'
        glass-opacity = 0.3
        solid-chrome-color = 'blue'
        solid-chrome-custom-color = '#123456'
        [workspace-sidebar.sidebar-appearance]
        blur = false
        background-opacity = 0.8
        [workspace-sidebar.dock-appearance]
        style = 'liquid-glass'
        glass-opacity = 0.7
        """)
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        let settings = parsed.workspaceSidebar
        XCTAssertEqual(settings.sidebarAppearance.backgroundOpacity, 0.8)
        XCTAssertFalse(settings.sidebarAppearance.blur)
        XCTAssertEqual(settings.dockChromeStyle, .liquidGlass)
        XCTAssertEqual(settings.dockGlassOpacity, 0.7)
        XCTAssertEqual(settings.dockSolidColor, .blue)
        XCTAssertEqual(settings.dockCustomColor, "#123456")
        XCTAssertEqual(settings.chromeStyle, .solid, "Tab groups and switcher retain their own style")
        XCTAssertEqual(settings.glassOpacity, 0.3, "Legacy values are preserved")
    }

    func testLegacyDockSettingsAndNewSidebarDefaults() {
        let (parsed, errors) = parseConfig("""
        [workspace-sidebar]
        show-app-icons = true
        use-liquid-glass = false
        glass-opacity = 0.2
        solid-chrome-color = 'custom'
        solid-chrome-custom-color = '#abcdef'
        """)
        XCTAssertTrue(errors.isEmpty)
        let settings = parsed.workspaceSidebar
        XCTAssertEqual(settings.dockChromeStyle, .solid)
        XCTAssertEqual(settings.dockGlassOpacity, 0.2)
        XCTAssertEqual(settings.dockSolidColor, .custom)
        XCTAssertEqual(settings.dockCustomColor, "#ABCDEF")
        XCTAssertTrue(settings.sidebarAppearance.blur)
        XCTAssertEqual(settings.sidebarAppearance.backgroundOpacity, 0.70)
    }

    func testInvalidAppearanceValuesAreRejected() {
        for section in ["sidebar-appearance", "dock-appearance"] {
            let key = section == "sidebar-appearance" ? "background-opacity" : "glass-opacity"
            for value in ["-0.1", "1.1", "nan", "inf", "true", "'dark'"] {
                XCTAssertFalse(parseConfig("[workspace-sidebar.\(section)]\n\(key) = \(value)").errors.isEmpty)
            }
            XCTAssertFalse(parseConfig("[workspace-sidebar.\(section)]\nunknown = true").errors.isEmpty)
        }
        XCTAssertFalse(parseConfig("[workspace-sidebar.sidebar-appearance]\nblur = 1").errors.isEmpty)
        XCTAssertFalse(parseConfig("[workspace-sidebar.dock-appearance]\nstyle = 'frosted'").errors.isEmpty)
        XCTAssertFalse(parseConfig("[workspace-sidebar.dock-appearance]\ncustom-color = 'bad'").errors.isEmpty)
    }

    func testLiveAppearanceChangesAndModeSwitchRetainIndependentPreferences() {
        let previous = config
        defer { config = previous }
        let model = TrayMenuModel()
        config.workspaceSidebar.sidebarAppearance.backgroundOpacity = 0.85
        config.workspaceSidebar.sidebarAppearance.blur = false
        config.workspaceSidebar.dockAppearance.glassOpacity = 0.25
        config.workspaceSidebar.dockAppearance.style = .solid
        for mode in [WorkspaceSidebarMode.dock, .sidebar, .dock] {
            config.workspaceSidebar.mode = mode
            model.refreshWorkspaceSidebarAppearance()
            let appearance = model.workspaceSidebarAppearance
            XCTAssertEqual(appearance.sidebarBackgroundOpacity, 0.85)
            XCTAssertFalse(appearance.sidebarBlur)
            XCTAssertEqual(appearance.glassOpacity, 0.25)
            XCTAssertEqual(appearance.chromeStyle, .solid)
        }
        config.workspaceSidebar.sidebarAppearance.backgroundOpacity = 0.65
        config.workspaceSidebar.sidebarAppearance.blur = true
        model.refreshWorkspaceSidebarAppearance()
        XCTAssertEqual(model.workspaceSidebarAppearance.sidebarBackgroundOpacity, 0.65)
        XCTAssertTrue(model.workspaceSidebarAppearance.sidebarBlur)
        XCTAssertEqual(model.workspaceSidebarAppearance.glassOpacity, 0.25)
    }

    func testSettingsEditsKeepAppearanceSectionsSeparate() {
        var text = """
        [workspace-sidebar]
        chrome-style = 'solid'
        glass-opacity = 0.25
        [workspace-sidebar.sidebar-appearance]
        blur = true
        background-opacity = 0.55
        [workspace-sidebar.dock-appearance]
        style = 'liquid-glass'
        glass-opacity = 0.7
        """
        text = updateSettingsScalarConfig(in: text, section: "workspace-sidebar.sidebar-appearance", key: "background-opacity", renderedValue: "0.9")
        text = updateSettingsScalarConfig(in: text, section: "workspace-sidebar.dock-appearance", key: "style", renderedValue: "'solid'")
        let (parsed, errors) = parseConfig(text)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(parsed.workspaceSidebar.sidebarAppearance.backgroundOpacity, 0.9)
        XCTAssertEqual(parsed.workspaceSidebar.dockGlassOpacity, 0.7)
        XCTAssertEqual(parsed.workspaceSidebar.dockChromeStyle, .solid)
        XCTAssertEqual(parsed.workspaceSidebar.glassOpacity, 0.25)
    }

    func testSidebarUsesStableBehindWindowBlurAndOpaqueAccessibilityFallback() {
        for (blur, reduceTransparency, expectedCount) in [(true, false, 1), (false, false, 0), (true, true, 0)] {
            var appearance = WorkspaceSidebarConfiguration.empty
            appearance.sidebarBlur = blur
            let host = NSHostingView(rootView: WorkspaceSidebarSurface(shape: Rectangle(), configuration: appearance,
                reduceTransparencyOverride: reduceTransparency))
            host.frame = CGRect(x: 0, y: 0, width: 200, height: 300)
            host.layoutSubtreeIfNeeded()
            let effects = descendants(host).compactMap { $0 as? NSVisualEffectView }
            XCTAssertEqual(effects.count, expectedCount)
            for effect in effects {
                XCTAssertEqual(effect.blendingMode, NSVisualEffectView.BlendingMode.behindWindow)
                XCTAssertEqual(effect.state, NSVisualEffectView.State.active, "Search focus must not change the backdrop")
                XCTAssertEqual(effect.material, NSVisualEffectView.Material.hudWindow)
                XCTAssertEqual(effect.appearance?.name, .darkAqua)
            }
        }
    }

    func testEditingOtherChromePreservesLegacyDockAppearanceAtomically() {
        let text = """
        [workspace-sidebar]
        chrome-style = 'solid'
        glass-opacity = 0.4
        solid-chrome-color = 'blue'
        """
        let updated = updateSettingsAppearanceConfig(in: text, section: "workspace-sidebar", values: ["chrome-style": "'liquid-glass'"],
            preservingDockAppearance: true)
        let (parsed, errors) = parseConfig(updated)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(parsed.workspaceSidebar.chromeStyle, .liquidGlass)
        XCTAssertEqual(parsed.workspaceSidebar.dockChromeStyle, .solid)
        XCTAssertEqual(parsed.workspaceSidebar.dockGlassOpacity, 0.4)
        XCTAssertEqual(parsed.workspaceSidebar.dockSolidColor, .blue)
    }

    func testSettingsSavesPreserveExistingDockValuesAndFreezeOnlyInheritedFields() {
        let text = """
        [workspace-sidebar]
        chrome-style = 'solid'
        solid-chrome-color = 'blue'
        [workspace-sidebar.dock-appearance]
        glass-opacity = 0.23 # Saved by another editor while Settings was open
        """
        let chromeEdit = updateSettingsAppearanceConfig(in: text, section: "workspace-sidebar",
            values: ["solid-chrome-color": "'midnight'"], preservingDockAppearance: true)
        XCTAssertTrue(chromeEdit.contains("glass-opacity = 0.23 # Saved by another editor"))
        let dockEdit = updateSettingsAppearanceConfig(in: chromeEdit, section: "workspace-sidebar.dock-appearance", values: ["style": "'liquid-glass'"])
        let (parsed, errors) = parseConfig(dockEdit)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(parsed.workspaceSidebar.solidChromeColor, .midnight)
        XCTAssertEqual(parsed.workspaceSidebar.dockSolidColor, .blue)
        XCTAssertEqual(parsed.workspaceSidebar.dockGlassOpacity, 0.23)
        XCTAssertEqual(parsed.workspaceSidebar.dockChromeStyle, .liquidGlass)
    }

    func testSidebarSettingsCanBeAddedWithoutAnExistingParentSection() {
        let text = "[window-tabs]\nenabled = false\n"
        let updated = updateSettingsAppearanceConfig(in: text, section: "workspace-sidebar.sidebar-appearance",
            values: ["blur": "true", "background-opacity": "0.75"])
        let (parsed, errors) = parseConfig(updated)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertFalse(parsed.windowTabs.enabled)
        XCTAssertTrue(parsed.workspaceSidebar.sidebarAppearance.blur)
        XCTAssertEqual(parsed.workspaceSidebar.sidebarAppearance.backgroundOpacity, 0.75)
    }

    func testAppearanceSettingsPreserveCommentedAndPaddedHeadersWithCRLF() {
        let text = "[ workspace-sidebar ] # Other chrome\r\nchrome-style = 'solid'\r\n"
            + "[workspace-sidebar. 'dock-appearance' ] # Dock overrides\r\nglass-opacity = 0.4\r\n"
        let updated = updateSettingsAppearanceConfig(in: text, section: "workspace-sidebar.dock-appearance",
            values: ["glass-opacity": "0.6"])
        let chromeEdit = updateSettingsAppearanceConfig(in: updated, section: "workspace-sidebar",
            values: ["chrome-style": "'liquid-glass'"], preservingDockAppearance: true)
        let (parsed, errors) = parseConfig(chromeEdit)
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        XCTAssertEqual(parsed.workspaceSidebar.chromeStyle, .liquidGlass)
        XCTAssertEqual(parsed.workspaceSidebar.dockChromeStyle, .solid)
        XCTAssertEqual(parsed.workspaceSidebar.dockGlassOpacity, 0.6)
        XCTAssertTrue(chromeEdit.contains("# Dock overrides"))
    }

    /// Run on the isolated Tart desktop; the external screenshot captures WindowServer blur.
    func testNativeAppearancePreview() async throws {
        guard let directory = ProcessInfo.processInfo.environment["WINMUX_SIDEBAR_PREVIEW_DIRECTORY"] else {
            throw XCTSkip("Opt-in native Sidebar appearance preview")
        }
        let application = NSApplication.shared
        let oldPolicy = application.activationPolicy()
        application.setActivationPolicy(.accessory)
        let screen = try XCTUnwrap(NSScreen.main)
        let viewport = screen.visibleFrame
        let backing = NSWindow(contentRect: screen.frame,
            styleMask: [.borderless], backing: .buffered, defer: false)
        backing.isReleasedWhenClosed = false
        backing.contentView = NSHostingView(rootView: VStack(spacing: 0) {
            ForEach(0..<20) { index in
                HStack(spacing: 0) {
                    ForEach(0..<16) { column in
                        Rectangle().fill([Color.blue, .white, .orange, .purple][(index + column) % 4])
                            .overlay(Text("Window content").font(.system(size: 12)).foregroundStyle(.black))
                    }
                }
            }
        })
        backing.orderFrontRegardless()
        var panels: [NSPanel] = []
        defer {
            for panel in panels { panel.close() }
            backing.close()
            application.setActivationPolicy(oldPolicy)
        }
        let panelWidth = (viewport.width - 80) / 3
        // Keep the comparison below first-boot notification banners in the test VM.
        let panelHeight = min(420, viewport.height - 80)
        for (index, title) in ["Previous Sidebar", "Darker Sidebar", "Expanded Dock"].enumerated() {
            var snapshot = WorkspaceSidebarSnapshot.empty
            snapshot.configuration = workspaceSidebarConfiguration()
            snapshot.configuration.showAppIcons = index == 2
            snapshot.visibleWidth = snapshot.configuration.expandedWidth
            let shape = RoundedRectangle(cornerRadius: 24)
            let panel = NSPanel(contentRect: CGRect(x: viewport.minX + 20 + CGFloat(index) * (panelWidth + 20),
                y: viewport.minY + 20, width: panelWidth, height: panelHeight),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .floating
            panel.contentView = NSHostingView(rootView: ZStack {
                if index == 0 {
                    GlassSurface(shape: shape, hasBorder: false)
                } else {
                    WorkspaceSidebarView(snapshot: snapshot).sidebarSurface(in: shape)
                }
                VStack(alignment: .leading, spacing: 20) {
                    Text(title).font(.system(size: 18, weight: .bold))
                    Label("Search windows", systemImage: "magnifyingglass").font(.callout)
                    ForEach(1..<9) { row in
                        Label("Window \(row) — Workspace", systemImage: "app.fill")
                            .font(.system(size: 14))
                    }
                    Spacer()
                }
                .padding(24)
                .foregroundStyle(.white)
            }.environment(\.colorScheme, .dark))
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        try await Task.sleep(for: .seconds(1))
        try "ready".write(toFile: directory + "/sidebar-preview-ready.txt", atomically: true, encoding: .utf8)
        try await Task.sleep(for: .seconds(20))
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
