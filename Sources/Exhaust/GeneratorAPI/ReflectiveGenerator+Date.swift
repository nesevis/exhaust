//
//  ReflectiveGenerator+Date.swift
//  Exhaust
//

import ExhaustCore
import Foundation

public extension ReflectiveGenerator {
    /// Generates dates within the given range, spaced by `interval`.
    ///
    /// Dates are quantized to integral multiples of the interval relative to the range's lower bound.
    /// The `timeZone` is used by problematic-value analysis to include DST transitions for that zone. It defaults to UTC, which has no DST transitions, so the default screening rows are identical on every machine. Pass an explicit zone to include its DST boundary values.
    ///
    /// Reflection rounds off-grid dates down to the nearest interval step. This means `reflecting:` with a date that does not fall exactly on a grid point will start reduction from the closest earlier grid point rather than rejecting the value.
    ///
    /// - Note: ``DateStride`` values are fixed-second approximations that compare by duration: a month is 30 days and a year is 365, so `.months(1) == .days(30)`.
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
    /// ```swift
    /// let gen = #gen(.date(within: .years(1), of: referenceDate, interval: .days(1)))
    /// ```
    static func date(
        within span: DateStride,
        of anchor: Date,
        interval: DateStride,
        timeZone: TimeZone = TimeZone(identifier: "UTC")!
    ) -> ReflectiveGenerator<Date> {
        let offsetSeconds = TimeInterval(span.fixedSeconds)
        let lower = anchor.addingTimeInterval(-offsetSeconds)
        let upper = anchor.addingTimeInterval(offsetSeconds)
        let range = lower ... upper
        return date(between: range, interval: interval, timeZone: timeZone)
    }

    /// Generates dates within an asymmetric span around `anchor`, spaced by `interval`.
    ///
    /// The range bounds are relative to the anchor — negative values go into the past, positive into the future.
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
        let lower = anchor.addingTimeInterval(TimeInterval(span.lowerBound.fixedSeconds))
        let upper = anchor.addingTimeInterval(TimeInterval(span.upperBound.fixedSeconds))
        return date(between: lower ... upper, interval: interval, timeZone: timeZone)
    }
}
