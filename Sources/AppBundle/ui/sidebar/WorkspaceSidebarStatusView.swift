import AppKit
import Foundation
import SwiftUI

private struct WorkspaceSidebarClockDateKey: EnvironmentKey {
    static let defaultValue: Date? = nil
}

extension EnvironmentValues {
    var workspaceSidebarClockDate: Date? {
        get { self[WorkspaceSidebarClockDateKey.self] }
        set { self[WorkspaceSidebarClockDateKey.self] = newValue }
    }
}

struct WorkspaceSidebarStatusView: View {
    @Environment(\.workspaceSidebarClockDate) private var clockDate
    let sectionWidth: CGFloat
    let isCompact: Bool
    let showsSeconds: Bool
    let showsDate: Bool
    let showsWeekday: Bool
    var compactScale: CGFloat = 1
    var horizontal = false
    var availableHeight: CGFloat = 64

    var body: some View {
        Group {
            if horizontal {
                TimelineView(workspaceSidebarClockSchedule(showsSeconds: showsSeconds)) { context in
                    let date = clockDate ?? context.date
                    VStack(spacing: 2) {
                        Text(date, format: showsSeconds ? .dateTime.hour().minute().second() : .dateTime.hour().minute())
                            .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                        if workspaceSidebarHorizontalClockShowsDateLine(railHeight: availableHeight), showsDate || showsWeekday {
                            Text(date, format: showsDate && showsWeekday ? .dateTime.weekday().month().day()
                                : showsDate ? .dateTime.month().day() : .dateTime.weekday())
                                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .frame(width: sectionWidth, height: max(availableHeight - workspaceSidebarHorizontalClockInset * 2, 1))
                    .background(RoundedRectangle(
                        cornerRadius: workspaceSidebarHorizontalClockCornerRadius(railHeight: availableHeight),
                        style: .continuous,
                    ).fill(Color.white.opacity(0.06)))
                }
            } else if isCompact {
                TimelineView(workspaceSidebarClockSchedule(showsSeconds: showsSeconds)) { context in
                    WorkspaceSidebarCompactClockCard(
                        date: clockDate ?? context.date,
                        sectionWidth: sectionWidth,
                        showsSeconds: showsSeconds,
                        scale: compactScale,
                    )
                }
            } else {
                TimelineView(workspaceSidebarClockSchedule(showsSeconds: showsSeconds)) { context in
                    WorkspaceSidebarExpandedStatusCard(
                        date: clockDate ?? context.date,
                        sectionWidth: sectionWidth,
                        showsSeconds: showsSeconds,
                        showsDate: showsDate,
                        showsWeekday: showsWeekday,
                    )
                }
            }
        }
        .frame(width: sectionWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.16), value: isCompact)
    }
}

let workspaceSidebarHorizontalClockInset: CGFloat = 6

/// Concentric with the bottom Dock shelf, whose corner radius is railHeight / 3.
func workspaceSidebarHorizontalClockCornerRadius(railHeight: CGFloat) -> CGFloat {
    max(railHeight / 3 - workspaceSidebarHorizontalClockInset, 4)
}

/// The date line needs roughly 34pt beside the 15pt time, so shorter cards show only the time.
func workspaceSidebarHorizontalClockShowsDateLine(railHeight: CGFloat) -> Bool {
    railHeight - workspaceSidebarHorizontalClockInset * 2 >= 36
}
