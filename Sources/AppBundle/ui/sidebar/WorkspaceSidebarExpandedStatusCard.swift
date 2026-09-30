import AppKit
import Foundation
import SwiftUI

struct WorkspaceSidebarExpandedStatusCard: View {
    let date: Date
    let sectionWidth: CGFloat
    let showsSeconds: Bool
    let showsDate: Bool
    let showsWeekday: Bool
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar

    private var dateLines: WorkspaceSidebarExpandedClockDateLines {
        WorkspaceSidebarExpandedClockDateLines(date: date, locale: locale, calendar: calendar)
    }

    private var accessibilitySummary: String {
        workspaceSidebarExpandedClockAccessibilitySummary(
            date: date,
            showsSeconds: showsSeconds,
            showsDate: showsDate,
            showsWeekday: showsWeekday,
            locale: locale,
            calendar: calendar
        )
    }

    var body: some View {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let time = date.formatted(style.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        let seconds = showsSeconds ? date.formatted(style.second(.twoDigits)) : nil
        // A narrow sidebar shrinks the time and its seconds together instead of cutting them short.
        let scale = workspaceSidebarExpandedClockScale(time: time, seconds: seconds,
            availableWidth: sectionWidth - workspaceSidebarExpandedClockHorizontalPadding * 2)
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .top, spacing: 4 * scale) {
                Text(time)
                    .font(.system(size: 42 * scale, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.90))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let seconds {
                    Text(seconds)
                        .font(.system(size: 16 * scale, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.white.opacity(0.34))
                        .lineLimit(1)
                        .padding(.top, 9 * scale)
                }
            }
            .layoutPriority(1)

            if showsWeekday {
                dateLine(dateLines.weekday)
            }
            if showsDate {
                dateLine(dateLines.monthAndDay)
            }
        }
        .padding(.horizontal, workspaceSidebarExpandedClockHorizontalPadding)
        .padding(.vertical, 8)
        .frame(
            width: sectionWidth,
            height: workspaceSidebarExpandedClockCardHeight(showsDate: showsDate, showsWeekday: showsWeekday),
            alignment: .leading,
        )
        .background(
            RoundedRectangle(cornerRadius: workspaceSidebarStatusCornerRadius, style: .continuous)
                .fill(Color.white.opacity(GlassToken.fillResting))
                .overlay {
                    RoundedRectangle(cornerRadius: workspaceSidebarStatusCornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(GlassToken.cardStroke), lineWidth: StrokeToken.hairline)
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilitySummary))
    }

    private func dateLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.48))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .allowsTightening(true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

let workspaceSidebarExpandedClockHorizontalPadding: CGFloat = 14

/// How much the expanded clock's time shrinks to fit its card: 1 while it fits.
func workspaceSidebarExpandedClockScale(time: String, seconds: String?, availableWidth: CGFloat) -> CGFloat {
    func width(_ text: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
    let natural = width(time, size: 42, weight: .bold) + (seconds.map { 4 + width($0, size: 16, weight: .semibold) } ?? 0)
    guard natural > 0, availableWidth.isFinite else { return 1 }
    return min(1, max(availableWidth, 1) / natural)
}
