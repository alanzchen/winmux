import Foundation
import SwiftUI

func workspaceSidebarClockSchedule(showsSeconds: Bool, now: Date = .now) -> PeriodicTimelineSchedule {
    let interval: TimeInterval = showsSeconds ? 1 : 60
    // Align to the displayed unit; a minute-only clock must not lag by the
    // seconds component of the time at which its view was mounted.
    let start = floor(now.timeIntervalSince1970 / interval) * interval
    return .periodic(from: Date(timeIntervalSince1970: start), by: interval)
}

struct WorkspaceSidebarClockComponents {
    let hour: String
    let minute: String
    let second: String

    init(date: Date, calendar: Calendar = .autoupdatingCurrent) {
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        hour = Self.format(components.hour)
        minute = Self.format(components.minute)
        second = Self.format(components.second)
    }

    private static func format(_ value: Int?) -> String {
        String(format: "%02d", value ?? 0)
    }
}

struct WorkspaceSidebarExpandedClockDateLines: Equatable {
    let weekday: String
    let monthAndDay: String

    init(
        date: Date,
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        let formatters = WorkspaceSidebarClockFormatters.shared
        weekday = formatters.string(from: date, template: "EEEE", locale: locale, calendar: calendar)
        monthAndDay = formatters.string(from: date, template: "MMMMd", locale: locale, calendar: calendar)
    }
}

/// The clock redraws every second, and building a DateFormatter and resolving its template cost
/// more than the formatting. Formatters are reused for each format, locale, calendar and time
/// zone, configured exactly as before; a change to the user's region settings or time zone drops
/// them all. Formatting with a formatter no one changes is safe from any thread.
final class WorkspaceSidebarClockFormatters: @unchecked Sendable {
    static let shared = WorkspaceSidebarClockFormatters()

    private struct Key: Hashable {
        let format: String
        let locale: Locale
        let calendar: Calendar
        let timeZone: TimeZone
    }

    private let lock = NSLock()
    private var formatters: [Key: DateFormatter] = [:]
    private var observers: [NSObjectProtocol] = []

    init(center: NotificationCenter = .default) {
        observers = [NSLocale.currentLocaleDidChangeNotification, .NSSystemTimeZoneDidChange].map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.removeAll() }
        }
    }

    var count: Int { lock.withLock { formatters.count } }

    func removeAll() {
        lock.withLock { formatters.removeAll() }
    }

    /// A `template` such as "EEEE", or with none, the time in `timeStyle`.
    func string(from date: Date, template: String? = nil, timeStyle: DateFormatter.Style = .none,
                locale: Locale, calendar: Calendar) -> String {
        let key = Key(format: template ?? "time:\(timeStyle.rawValue)", locale: locale, calendar: calendar,
            timeZone: calendar.timeZone)
        let formatter = lock.withLock { () -> DateFormatter in
            if let formatter = formatters[key] { return formatter }
            // Only a few are ever in use; this just bounds a run of locales.
            if formatters.count >= 64 { formatters.removeAll() }
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            if let template {
                formatter.setLocalizedDateFormatFromTemplate(template)
            } else {
                formatter.dateStyle = .none
                formatter.timeStyle = timeStyle
            }
            formatters[key] = formatter
            return formatter
        }
        return formatter.string(from: date)
    }
}

func workspaceSidebarExpandedClockDateLineCount(showsDate: Bool, showsWeekday: Bool) -> Int {
    (showsDate ? 1 : 0) + (showsWeekday ? 1 : 0)
}

func workspaceSidebarExpandedClockCardHeight(showsDate: Bool, showsWeekday: Bool) -> CGFloat {
    68 + CGFloat(workspaceSidebarExpandedClockDateLineCount(
        showsDate: showsDate,
        showsWeekday: showsWeekday
    )) * 19
}

func workspaceSidebarExpandedClockAccessibilitySummary(
    date: Date,
    showsSeconds: Bool,
    showsDate: Bool,
    showsWeekday: Bool,
    locale: Locale = .autoupdatingCurrent,
    calendar: Calendar = .autoupdatingCurrent,
    dateLines: WorkspaceSidebarExpandedClockDateLines? = nil
) -> String {
    let time = WorkspaceSidebarClockFormatters.shared.string(from: date, timeStyle: showsSeconds ? .medium : .short,
        locale: locale, calendar: calendar)
    let dateLines = dateLines ?? WorkspaceSidebarExpandedClockDateLines(
        date: date,
        locale: locale,
        calendar: calendar
    )
    var parts = [time]
    if showsWeekday {
        parts.append(dateLines.weekday)
    }
    if showsDate {
        parts.append(dateLines.monthAndDay)
    }
    return parts.joined(separator: ", ")
}
