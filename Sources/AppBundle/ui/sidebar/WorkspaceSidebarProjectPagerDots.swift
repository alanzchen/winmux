import SwiftUI

let workspaceSidebarCurrentProjectPillMaxWidth: CGFloat = 132
/// Below this, a narrow sidebar shows the current project's emoji or bar without its name.
let workspaceSidebarCurrentProjectPillMinWidthForName: CGFloat = 72

extension WorkspaceSidebarProjectPager {
    /// Every expanded project shows its emoji. The collapsed Sidebar rail keeps its bars.
    func showsProjectEmoji(_ project: WorkspaceSidebarProjectViewModel) -> Bool {
        project.emoji != nil && (layout.showAppIcons || !isCompact)
    }

    /// The pill never outgrows the track, so a narrow sidebar keeps the switcher usable.
    var currentProjectPillMaxWidth: CGFloat {
        min(workspaceSidebarCurrentProjectPillMaxWidth, projectTrackWidth - 8)
    }

    /// The expanded switcher names the current project in place of a separate menu.
    func showsProjectName(isCurrent: Bool) -> Bool {
        isCurrent && usesProjectChips
    }

    /// Where the current project is named, every project is the same chip, so switching widens
    /// one chip into the named pill and narrows the other back instead of fading between two.
    var usesProjectChips: Bool {
        !isCompact && currentProjectPillMaxWidth >= workspaceSidebarCurrentProjectPillMinWidthForName
    }

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
        // Beside the current project's named pill, expanded emoji match its smaller type.
        let emojiSize = isCompact ? min(28, buttonWidth, horizontalCompact ? max(layout.compactRailWidth - 4, 12) : 28) : 24
        let emojiFontSize = isCompact ? emojiSize - 4 : 17
        Button {
            debugWorkspaceSidebarProjectLog(
                "dotButton project=\(project.id.rawValue) selected=\(selectedProjectId.rawValue) currentIndex=\(currentIndex?.description ?? "nil") compact=\(isCompact) projects=\(projects.map(\.id.rawValue))"
            )
            projectTrackScrollTargetId = project.id
            onSelectProject(project.id)
        } label: {
            Group {
                if usesProjectChips {
                    projectChip(project, isCurrent: isCurrent, projectColor: projectColor, isDotHovered: isDotHovered)
                } else if showsProjectEmoji(project), let emoji = project.emoji {
                    Text(emoji)
                        .font(.system(size: emojiFontSize))
                        .frame(width: emojiSize, height: emojiSize)
                        .background {
                            RoundedRectangle(cornerRadius: emojiSize / 4, style: .continuous)
                                .fill(projectColor.opacity(isCurrent ? (isDotHovered ? 0.38 : 0.28) : (isDotHovered ? 0.14 : 0)))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: emojiSize / 4, style: .continuous)
                                .strokeBorder(Color.white.opacity(isCurrent ? 0.65 : 0), lineWidth: 1)
                        }
                        .frame(width: buttonWidth)
                } else {
                    projectBar(projectColor: projectColor, isCurrent: isCurrent, isDotHovered: isDotHovered, scale: scale)
                        .frame(width: buttonWidth)
                }
            }
            .frame(height: horizontalCompact ? compactProjectControlsHeight : workspaceSidebarProjectDotFrameHeight, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(project.displayName)
        .accessibilityValue(showsProjectEmoji(project) ? (project.emoji ?? "") : "")
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

    /// At rest a chip looks like the switcher's emoji or color bar; the current project's chip
    /// is a pill with its name. Every size and color here animates between the two.
    private func projectChip(
        _ project: WorkspaceSidebarProjectViewModel,
        isCurrent: Bool,
        projectColor: Color,
        isDotHovered: Bool,
    ) -> some View {
        let emoji = showsProjectEmoji(project) ? project.emoji : nil
        let resting = emoji == nil ? CGSize(width: 34, height: 22) : CGSize(width: 24, height: 24)
        let cornerRadius: CGFloat = isCurrent ? 11 : (emoji == nil ? 9 : 6)
        let fill = isCurrent ? (isDotHovered ? 0.34 : 0.24) : (isDotHovered ? 0.14 : 0)
        return HStack(spacing: 0) {
            if let emoji {
                Text(emoji)
                    .font(.system(size: 17))
                    .scaleEffect(isCurrent ? 16 / 17 : 1)
            } else {
                // The bar becomes the pill's color dot.
                Capsule(style: .continuous)
                    .fill(isCurrent ? projectColor : projectColor.opacity(isDotHovered ? 0.58 : (isHovered ? 0.44 : 0.32)))
                    .frame(width: isCurrent ? 8 : 13, height: isCurrent ? 8 : 9)
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(projectColor.opacity(isCurrent ? 0 : (isDotHovered ? 0.70 : (isHovered ? 0.54 : 0.36))),
                                lineWidth: isDotHovered ? 0.8 : 0.5)
                    }
            }
            WorkspaceSidebarRevealedWidthLayout(isRevealed: isCurrent, maxWidth: currentProjectPillMaxWidth) {
                Text(project.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 5)
            }
            .clipped()
            .opacity(isCurrent ? 1 : 0)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, isCurrent ? 9 : 0)
        .frame(minWidth: isCurrent ? 36 : resting.width, maxWidth: isCurrent ? currentProjectPillMaxWidth : resting.width,
               minHeight: isCurrent ? 26 : resting.height, maxHeight: isCurrent ? 26 : resting.height)
        .fixedSize(horizontal: true, vertical: false)
        // Slightly under a full capsule: a capsule's hairline stroke leaves ticks at its ends.
        .background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(projectColor.opacity(fill))
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(isCurrent ? (isDotHovered ? 0.5 : 0.36) : 0), lineWidth: 0.8)
        }
        .frame(minWidth: 36)
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

/// Lays its view out at its own width, up to `maxWidth`, but takes no room until revealed. The
/// view keeps its size and leading edge either way, so revealing it uncovers it from the
/// leading edge instead of drawing it centered in a frame that is still growing.
struct WorkspaceSidebarRevealedWidthLayout: SwiftUI.Layout {
    var isRevealed: Bool
    var maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let natural = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: proposal.height))
        return CGSize(width: isRevealed ? min(natural.width, proposal.width ?? natural.width) : 0, height: natural.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        let natural = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: proposal.height))
        // Revealed and short of room, it truncates; hidden, it keeps the width it will have.
        let width = isRevealed ? min(natural.width, bounds.width) : natural.width
        subview.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
            proposal: ProposedViewSize(width: width, height: bounds.height))
    }
}
