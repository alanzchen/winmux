import SwiftUI

extension WorkspaceSidebarProjectPager {
    @ViewBuilder
    func projectDot(
        _ project: WorkspaceSidebarProjectViewModel,
        index: Int,
    ) -> some View {
        let isCurrent = index == currentIndex
        let isDotHovered = hoveredProjectDotId == project.id
        let projectColor = workspaceSidebarProjectColor(projectId: project.id, configuredHex: project.colorHex)
        // The scrolling track follows the fitted Dock width. Keep its pills and
        // hover outlines inside that track while retaining the vertical click target.
        let scale = isCompact && layout.showAppIcons ? layout.compactDockScale : 1
        let buttonWidth = isCompact && layout.showAppIcons ? min(36, sectionWidth) : 36
        let emojiSize = min(28, buttonWidth, horizontalCompact ? max(layout.compactRailWidth - 4, 12) : 28)
        Button {
            debugWorkspaceSidebarProjectLog(
                "dotButton project=\(project.id.rawValue) selected=\(selectedProjectId.rawValue) currentIndex=\(currentIndex?.description ?? "nil") compact=\(isCompact) projects=\(projects.map(\.id.rawValue))"
            )
            projectTrackScrollTargetId = project.id
            onSelectProject(project.id)
        } label: {
            Group {
                if layout.showAppIcons, let emoji = project.emoji {
                    Text(emoji)
                        .font(.system(size: emojiSize - 4))
                        .frame(width: emojiSize, height: emojiSize)
                        .background {
                            RoundedRectangle(cornerRadius: emojiSize / 4, style: .continuous)
                                .fill(projectColor.opacity(isCurrent ? (isDotHovered ? 0.38 : 0.28) : (isDotHovered ? 0.14 : 0)))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: emojiSize / 4, style: .continuous)
                                .strokeBorder(Color.white.opacity(isCurrent ? 0.65 : 0), lineWidth: 1)
                        }
                } else {
                    projectBar(projectColor: projectColor, isCurrent: isCurrent, isDotHovered: isDotHovered, scale: scale)
                }
            }
            .frame(width: buttonWidth, height: horizontalCompact ? compactProjectControlsHeight : workspaceSidebarProjectDotFrameHeight, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(project.displayName)
        .accessibilityValue(layout.showAppIcons ? (project.emoji ?? "") : "")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .help(project.displayName)
        .onHover { hovering in
            hoveredProjectDotId = hovering ? project.id : (hoveredProjectDotId == project.id ? nil : hoveredProjectDotId)
        }
        .contextMenu {
            projectContextMenuItems(for: project)
        }
        .animation(.easeOut(duration: 0.14), value: isDotHovered)
    }

    private func projectBar(projectColor: Color, isCurrent: Bool, isDotHovered: Bool, scale: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9 * scale, style: .continuous)
                .fill(isDotHovered ? projectColor.opacity(0.14) : Color.clear)
                .frame(width: 34 * scale, height: 22 * scale)
            Capsule(style: .continuous)
                .fill(isCurrent ? Color.white.opacity(0.17) : projectColor.opacity(isDotHovered ? 0.58 : (isHovered ? 0.44 : 0.32)))
                .frame(width: (isCurrent ? 28 : 13) * scale, height: (isCompact ? 10 : 9) * scale)
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(
                            isCurrent ? Color.white.opacity(0.42) : projectColor.opacity(isDotHovered ? 0.70 : (isHovered ? 0.54 : 0.36)),
                            lineWidth: max(0.5, (isDotHovered || isCurrent ? 0.8 : 0.5) * scale),
                        )
                }
                .overlay {
                    if isCurrent {
                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.18), .clear],
                                    startPoint: .top,
                                    endPoint: .bottom,
                                )
                            )
                            .padding(0.8 * scale)
                    }
                }
        }
    }
}
