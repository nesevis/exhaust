//
//  ReflectiveGenerator+Date.swift
//  Exhaust
//

import ExhaustCore
import Foundation

public extension ReflectiveGenerator {
    /// Generates dates within the given range, spaced by `interval`.
    ///
    /// Sub-day intervals (`.seconds`, `.minutes`, `.hours`) space dates a fixed number of seconds apart from the range's lower bound. Calendar intervals (`.days` through `.years`) advance with calendar arithmetic in `timeZone`: `.months(1)` from January 15 produces the 15th of every month, `.years(1)` lands on the same calendar date each year, and `.days(1)` keeps the lower bound's wall-clock time across the zone's DST transitions (so one step is 23 or 25 hours of absolute time on transition days).
    ///
    /// The `timeZone` defaults to UTC, where every day is exactly 86400 seconds and there are no DST transitions, so the default grid and screening rows are identical on every machine. Pass an explicit zone to anchor day-based grids to that zone's wall clock and to include its DST transitions in problematic-value analysis.
    ///
    /// Reflection rounds off-grid dates down to the nearest grid point. This means `reflecting:` with a date that does not fall exactly on the grid will start reduction from the closest earlier grid point rather than rejecting the value.
    ///
    /// - Note: When the lower bound's day-of-month does not exist in a landing month, `.months` grids clamp to that month's last day: a grid starting January 31 visits February 28 (or 29), March 31, April 30, and so on.
    /// - Note: `DateStride` orders by fixed-second approximation (a month counts as 30 days), so `.months(1) < .days(31)`; equality is structural, so `.months(1) != .days(30)`.
    ///
    /// ```swift
    /// let gen = #gen(.date(
    ///     between: startDate ... endDate,
    ///     interval: .hours(1),
    ///     timeZone: .init(identifier: "America/New_York")!
    /// ))
    /// ```
    static func date(
        between range: ClosedRange<Date>,
        interval: DateStride,
        timeZone: TimeZone = TimeZone(identifier: "UTC")!
    ) -> ReflectiveGenerator<Date> {
        Gen.date(between: range, interval: interval, timeZone: timeZone)
    }

    /// Generates dates within `span` on either side of `anchor`, spaced by `interval`.
    ///
    /// Calendar spans measure calendar distance from the anchor: `.years(1)` reaches the same calendar date one year back and one year forward, including across leap years.
    ///
    /// ```swift
    /// let gen = #gen(.date(within: .years(1), of: referenceDate, interval: .days(1)))
    /// ```
    static func date(
        within span: DateStride,
        of anchor: Date,
        interval: DateStride,
        timeZone: TimeZone = TimeZone(identifier: "UTC")!
    ) -> ReflectiveGenerator<Date> {
        let lower = anchor.advanced(by: span.negated, in: timeZone)
        let upper = anchor.advanced(by: span, in: timeZone)
        return date(between: lower ... upper, interval: interval, timeZone: timeZone)
    }

    /// Generates dates within an asymmetric span around `anchor`, spaced by `interval`.
    ///
    /// The range bounds are relative to the anchor — negative values go into the past, positive into the future. Calendar spans measure calendar distance from the anchor, so `.months(-1)` reaches the same day-of-month in the previous month rather than 30 days back.
    ///
    /// ```swift
    /// let gen = #gen(.date(within: .days(-7) ... .days(30), of: anchor, interval: .hours(1)))
    /// ```
    static func date(
        within span: ClosedRange<DateStride>,
        of anchor: Date,
        interval: DateStride,
        timeZone: TimeZone = TimeZone(identifier: "UTC")!
    ) -> ReflectiveGenerator<Date> {
        let lower = anchor.advanced(by: span.lowerBound, in: timeZone)
        let upper = anchor.advanced(by: span.upperBound, in: timeZone)
        return date(between: lower ... upper, interval: interval, timeZone: timeZone)
    }
}

// MARK: - Span Arithmetic

private extension Date {
    /// The date reached by moving `span` away from this date, using calendar arithmetic for calendar units.
    func advanced(by span: DateStride, in timeZone: TimeZone) -> Date {
        switch span {
            case .seconds, .minutes, .hours:
                return addingTimeInterval(TimeInterval(span.fixedSeconds))
            case let .days(count):
                return adding(.day, value: count, in: timeZone)
            case let .weeks(count):
                return adding(.day, value: count * 7, in: timeZone)
            case let .months(count):
                return adding(.month, value: count, in: timeZone)
            case let .years(count):
                return adding(.year, value: count, in: timeZone)
        }
    }

    private func adding(_ component: Calendar.Component, value: Int, in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let advanced = calendar.date(byAdding: component, value: value, to: self) else {
            preconditionFailure("Could not offset \(self) by \(value) × \(component)")
        }
        return advanced
    }
}

private extension DateStride {
    /// The stride pointing the same distance in the opposite direction.
    var negated: DateStride {
        switch self {
            case let .seconds(count): .seconds(-count)
            case let .minutes(count): .minutes(-count)
            case let .hours(count): .hours(-count)
            case let .days(count): .days(-count)
            case let .weeks(count): .weeks(-count)
            case let .months(count): .months(-count)
            case let .years(count): .years(-count)
        }
    }
}
