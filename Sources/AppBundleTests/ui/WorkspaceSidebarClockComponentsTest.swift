@testable import AppBundle
import Foundation
import XCTest

final class WorkspaceSidebarClockComponentsTest: XCTestCase {
    func testMinuteOnlyClockTicksOnMinuteBoundaries() {
        let now = Date(timeIntervalSince1970: 125.25)
        let schedule = workspaceSidebarClockSchedule(showsSeconds: false, now: now)
        let ticks = Array(schedule.entries(from: now, mode: .normal).prefix(3))
        // The schedule includes the current displayed minute, then future boundaries.
        XCTAssertEqual(ticks.map(\.timeIntervalSince1970), [120, 180, 240])
    }

    func testSecondsClockTicksOnSecondBoundaries() {
        let now = Date(timeIntervalSince1970: 125.25)
        let schedule = workspaceSidebarClockSchedule(showsSeconds: true, now: now)
        let ticks = Array(schedule.entries(from: now, mode: .normal).prefix(3))
        XCTAssertEqual(ticks.map(\.timeIntervalSince1970), [125, 126, 127])
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var thursdayJanuary31: Date {
        calendar.date(from: DateComponents(year: 2030, month: 1, day: 31, hour: 12, minute: 34, second: 56))!
    }

    func testExpandedClockUsesSeparateFullEnglishWeekdayAndMonthDayLines() {
        let lines = WorkspaceSidebarExpandedClockDateLines(
            date: thursdayJanuary31,
            locale: Locale(identifier: "en_US"),
            calendar: calendar
        )

        XCTAssertEqual(lines.weekday, "Thursday")
        XCTAssertEqual(lines.monthAndDay, "January 31")
    }

    func testExpandedClockKeepsLongLocalizedDateTextUnabbreviated() {
        let lines = WorkspaceSidebarExpandedClockDateLines(
            date: thursdayJanuary31,
            locale: Locale(identifier: "de_DE"),
            calendar: calendar
        )

        XCTAssertEqual(lines.weekday, "Donnerstag")
        XCTAssertEqual(lines.monthAndDay, "31. Januar")
    }

    func testExpandedClockDateAndWeekdayLinesAreIndependent() {
        XCTAssertEqual(workspaceSidebarExpandedClockDateLineCount(showsDate: false, showsWeekday: false), 0)
        XCTAssertEqual(workspaceSidebarExpandedClockDateLineCount(showsDate: true, showsWeekday: false), 1)
        XCTAssertEqual(workspaceSidebarExpandedClockDateLineCount(showsDate: false, showsWeekday: true), 1)
        XCTAssertEqual(workspaceSidebarExpandedClockDateLineCount(showsDate: true, showsWeekday: true), 2)
    }

    func testExpandedClockGrowsForEachVisibleDateLine() {
        XCTAssertEqual(workspaceSidebarExpandedClockCardHeight(showsDate: false, showsWeekday: false), 68)
        XCTAssertEqual(workspaceSidebarExpandedClockCardHeight(showsDate: true, showsWeekday: false), 87)
        XCTAssertEqual(workspaceSidebarExpandedClockCardHeight(showsDate: true, showsWeekday: true), 106)
    }

    func testExpandedClockAccessibilityKeepsDateAndWeekdayIndependent() {
        let weekdayOnly = workspaceSidebarExpandedClockAccessibilitySummary(
            date: thursdayJanuary31,
            showsSeconds: false,
            showsDate: false,
            showsWeekday: true,
            locale: Locale(identifier: "en_US"),
            calendar: calendar
        )
        let dateOnly = workspaceSidebarExpandedClockAccessibilitySummary(
            date: thursdayJanuary31,
            showsSeconds: false,
            showsDate: true,
            showsWeekday: false,
            locale: Locale(identifier: "en_US"),
            calendar: calendar
        )

        XCTAssertTrue(weekdayOnly.contains("Thursday"))
        XCTAssertFalse(weekdayOnly.contains("January"))
        XCTAssertTrue(dateOnly.contains("January 31"))
        XCTAssertFalse(dateOnly.contains("Thursday"))
    }

    /// The clock reuses its formatters. Each line still reads exactly as a DateFormatter made
    /// afresh for its locale, calendar and time zone writes it.
    func testExpandedClockTextMatchesAFreshFormatterInEveryLocaleAndTimeZone() {
        func reference(_ date: Date, template: String? = nil, timeStyle: DateFormatter.Style = .none,
                       locale: Locale, calendar: Calendar) -> String {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            if let template { formatter.setLocalizedDateFormatFromTemplate(template) } else {
                formatter.dateStyle = .none
                formatter.timeStyle = timeStyle
            }
            return formatter.string(from: date)
        }
        let locales = ["en_US", "en_GB", "de_DE", "fr_FR", "ja_JP", "zh_Hans_CN", "ar_SA", "he_IL", "hi_IN", "ru_RU"]
            .map(Locale.init(identifier:))
        let calendars: [Calendar.Identifier] = [.gregorian, .japanese, .buddhist, .islamicUmmAlQura]
        let zones = ["UTC", "America/Chicago", "Asia/Kolkata", "Pacific/Chatham"].compactMap(TimeZone.init(identifier:))
        // Just before and after midnight UTC, and a leap day afternoon.
        let dates = [1_893_455_999, 1_893_456_000, 1_898_611_200 + 49_320].map { Date(timeIntervalSince1970: TimeInterval($0)) }
        for locale in locales {
            for identifier in calendars {
                for zone in zones {
                    var calendar = Calendar(identifier: identifier)
                    calendar.timeZone = zone
                    for date in dates {
                        let context = "\(locale.identifier) \(identifier) \(zone.identifier) \(date)"
                        let lines = WorkspaceSidebarExpandedClockDateLines(date: date, locale: locale, calendar: calendar)
                        XCTAssertEqual(lines.weekday, reference(date, template: "EEEE", locale: locale, calendar: calendar), context)
                        XCTAssertEqual(lines.monthAndDay, reference(date, template: "MMMMd", locale: locale, calendar: calendar), context)
                        for showsSeconds in [false, true] {
                            let summary = workspaceSidebarExpandedClockAccessibilitySummary(date: date, showsSeconds: showsSeconds,
                                showsDate: true, showsWeekday: true, locale: locale, calendar: calendar)
                            let time = reference(date, timeStyle: showsSeconds ? .medium : .short, locale: locale, calendar: calendar)
                            XCTAssertEqual(summary, [time, lines.weekday, lines.monthAndDay].joined(separator: ", "), context)
                        }
                    }
                }
            }
        }
    }

    /// A change to the user's region settings or time zone drops the reused formatters, so the
    /// next tick formats with the new settings.
    func testRegionOrTimeZoneChangesDropTheReusedFormatters() {
        let center = NotificationCenter()
        let formatters = WorkspaceSidebarClockFormatters(center: center)
        for _ in 0 ..< 3 {
            _ = formatters.string(from: thursdayJanuary31, template: "EEEE", locale: Locale(identifier: "en_US"), calendar: calendar)
        }
        _ = formatters.string(from: thursdayJanuary31, timeStyle: .short, locale: Locale(identifier: "en_US"), calendar: calendar)
        XCTAssertEqual(formatters.count, 2, "One formatter per format, reused")
        center.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        XCTAssertEqual(formatters.count, 0)
        _ = formatters.string(from: thursdayJanuary31, template: "EEEE", locale: Locale(identifier: "en_US"), calendar: calendar)
        center.post(name: .NSSystemTimeZoneDidChange, object: nil)
        XCTAssertEqual(formatters.count, 0)
    }

    func testHorizontalDockClockCornerIsConcentricWithShelf() {
        for railHeight: CGFloat in [48, 56, 64, 80] {
            XCTAssertEqual(workspaceSidebarHorizontalClockCornerRadius(railHeight: railHeight),
                railHeight / 3 - workspaceSidebarHorizontalClockInset, accuracy: 0.001)
        }
        XCTAssertEqual(workspaceSidebarHorizontalClockCornerRadius(railHeight: 24), 4)
    }

    func testHorizontalDockClockHidesDateLineWhenCardIsTooShort() {
        XCTAssertFalse(workspaceSidebarHorizontalClockShowsDateLine(railHeight: 40))
        XCTAssertFalse(workspaceSidebarHorizontalClockShowsDateLine(railHeight: 47))
        XCTAssertTrue(workspaceSidebarHorizontalClockShowsDateLine(railHeight: 48))
        XCTAssertTrue(workspaceSidebarHorizontalClockShowsDateLine(railHeight: 64))
    }
}
