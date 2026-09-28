import AppKit
import SwiftUI

/// Uses the production shelf materials, workspace tile and lens geometry. It has
/// no window-management actions or native Dock integration: examples stay local.
struct SettingsDockPreview: View {
    @ObservedObject var editor: SettingsEditor
    @State private var expanded = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var sidebar: WorkspaceSidebarConfig { editor.projection.workspaceSidebar }
    var previewConfiguration: WorkspaceSidebarConfiguration { workspaceSidebarConfiguration(editor.projection) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Live preview").font(.headline)
                Spacer()
                if previewConfiguration.showAppIcons {
                    Toggle("Expanded", isOn: $expanded).toggleStyle(.button).controlSize(.small)
                }
            }
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if previewConfiguration.usesTabsList {
                    tabsPreview
                        .frame(width: min(previewConfiguration.expandedWidth, 245), height: 164)
                } else if expanded || !previewConfiguration.showAppIcons || sidebar.alwaysExpanded {
                    expandedPreview
                        .frame(width: min(previewConfiguration.expandedWidth, 245), height: 164)
                } else {
                    SettingsDockPreviewShelf(configuration: previewConfiguration,
                        showsBadge: sidebar.showAppBadges)
                }
            }
            .frame(height: 194)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5) }
            Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("settings.dock-preview")
    }

    private var caption: String {
        switch sidebar.mode {
            case .dock: "Sample workspace. Hover over the icons to try magnification. Preview updates while you adjust a slider; changes save when you release it."
            case .sidebar: "Sample expanded Sidebar. Preview updates while you adjust a slider; changes save when you release it."
            case .tabs: "Sample tabs. The sidebar takes on the current project's color."
        }
    }

    private var tabsPreview: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Search tabs", systemImage: "magnifyingglass").foregroundStyle(.secondary).padding(.bottom, 6)
            tabRow("envelope", "Mail — Inbox", selected: true, badge: sidebar.showAppBadges ? "3" : nil)
            tabRow("safari", "Safari — WinMux")
            if sidebar.browserTabs {
                tabRow("doc.text", "Release notes", indented: true)
                tabRow("doc.text", "Issues", indented: true)
            }
            tabRow("folder", "Finder — Documents")
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            ZStack {
                WorkspaceSidebarSurface(shape: RoundedRectangle(cornerRadius: 12), configuration: previewConfiguration)
                RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.14))
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sample tabs: Mail, Safari\(sidebar.browserTabs ? " with two browser tabs" : ""), and Finder")
    }

    private func tabRow(_ symbol: String, _ title: String, selected: Bool = false, badge: String? = nil, indented: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).frame(width: 16)
            Text(title).lineLimit(1)
            Spacer(minLength: 4)
            if let badge {
                Text(badge).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 17, height: 17).background(.red, in: Circle())
            }
        }
        .padding(.leading, indented ? 22 : 6).padding(.trailing, 6).padding(.vertical, 5)
        .background(selected ? Color.primary.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private var expandedPreview: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Search windows", systemImage: "magnifyingglass").foregroundStyle(.white.opacity(0.6))
            Text("Workspace 1").font(.headline)
            Label("Mail — Inbox", systemImage: "envelope")
            Label("Finder — Documents", systemImage: "folder")
            Spacer(minLength: 0)
        }
        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.white)
        .background {
            WorkspaceSidebarSurface(shape: RoundedRectangle(cornerRadius: 12), configuration: previewConfiguration)
        }
        .allowsHitTesting(false)
    }
}

private struct SettingsDockPreviewShelf: View {
    let configuration: WorkspaceSidebarConfiguration
    let showsBadge: Bool
    @State private var pointer: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private static let mailIcon: NSImage? = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mail")
        .map { NSWorkspace.shared.icon(forFile: $0.path) }

    var body: some View {
        GeometryReader { geometry in
            let horizontal = configuration.dockPosition == .bottom
            let size = configuration.dockIconSize * 0.8
            let thickness = WorkspaceSidebarConfig.dockWidth(forIconSize: size)
            let lens = WorkspaceSidebarDockMagnification(itemSize: size, count: 2,
                enabled: configuration.dockMagnification && !reduceMotion, amount: configuration.dockMagnificationAmount)
            let frames = lens.frames(width: thickness, pointerY: pointer)
            let length = lens.renderedHeight(pointerY: pointer) + 16
            let gap = configuration.compactLeftGap
            let surface = CGRect(x: horizontal ? (geometry.size.width - length) / 2 : configuration.dockPosition == .right ? geometry.size.width - thickness - gap : gap,
                y: horizontal ? geometry.size.height - thickness - gap : (geometry.size.height - length) / 2,
                width: horizontal ? length : thickness, height: horizontal ? thickness : length)
            ZStack(alignment: .topLeading) {
                WorkspaceSidebarDockSurface(shape: RoundedRectangle(cornerRadius: thickness * 0.35), configuration: configuration)
                    .opacity(reduceTransparency ? 1 : configuration.effectiveGlassOpacity)
                    .frame(width: surface.width, height: surface.height)
                    .clipShape(RoundedRectangle(cornerRadius: thickness * 0.35))
                    .position(x: surface.midX, y: surface.midY)
                ForEach(0..<2) { index in
                    let base = frames[index].offsetBy(dx: 0, dy: 8)
                    let frame = workspaceSidebarDockOrientedFrame(base, crossAxis: thickness, position: configuration.dockPosition)
                        .offsetBy(dx: surface.minX, dy: surface.minY)
                    Group {
                        if index == 0 {
                            WorkspaceSidebarWorkspaceIcon(identifier: "1", isActive: true, size: frame.width,
                                railWidth: thickness, showsIndicator: false)
                        } else {
                            ZStack(alignment: .topTrailing) {
                                if let icon = Self.mailIcon { Image(nsImage: icon).resizable().scaledToFit() }
                                else { Image(systemName: "envelope.fill").resizable().scaledToFit().padding(6) }
                                if showsBadge {
                                    Text("3").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                                        .frame(width: 17, height: 17).background(.red, in: Circle())
                                }
                            }
                        }
                    }
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                    case .active(let point):
                        let iconHit = frames.contains { base in
                            workspaceSidebarDockOrientedFrame(base.offsetBy(dx: 0, dy: 8), crossAxis: thickness, position: configuration.dockPosition)
                                .offsetBy(dx: surface.minX, dy: surface.minY).contains(point)
                        }
                        pointer = surface.contains(point) || iconHit
                            ? (horizontal ? point.x - surface.minX : point.y - surface.minY) - 8 : nil
                    case .ended: pointer = nil
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: pointer == nil)
            .onChange(of: configuration.dockPosition) { _ in pointer = nil }
        }
        .padding(16)
        .accessibilityLabel("Sample Dock with workspace 1 and Mail\(showsBadge ? ", three unread messages" : "")")
    }
}
