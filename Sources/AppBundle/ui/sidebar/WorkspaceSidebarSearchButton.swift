import SwiftUI

extension WorkspaceSidebarView {
    func sidebarSearchButton(leadingInset: CGFloat, trailingInset: CGFloat) -> some View {
        Button {
            beginSidebarSearchIfNeeded()
        } label: {
            Label("Search windows and workspaces", systemImage: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.72))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: workspaceSidebarSearchHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Search windows and workspaces")
        .padding(.leading, leadingInset)
        .padding(.trailing, trailingInset)
        .padding(.bottom, workspaceSidebarSectionGap)
    }
}
