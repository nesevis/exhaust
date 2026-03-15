//
//  ReflectiveGenerator+Date.swift
//  Exhaust
//

import ExhaustCore
import Foundation

/// A calendar-meaningful duration for date generation.
///
/// All cases resolve to a fixed number of seconds. Months are treated as 30 days and years as 365 days.
public enum DateSpan: Sendable, Comparable, Equatable {
    case seconds(Int)
    case minutes(Int)
    case hours(Int)
    case days(Int)
    case weeks(Int)
    case months(Int)
    case years(Int)

    /// The number of seconds represented by this span.
    var fixedSeconds: Int {
        switch self {
        case let .seconds(n): n
        case let .minutes(n): n * 60
        case let .hours(n): n * 3600
        case let .days(n): n * 86400
        case let .weeks(n): n * 604_800
        case let .months(n): n * 2_592_000 // 30 days
        case let .years(n): n * 31_536_000 // 365 days
        }
    }

    public static func == (lhs: DateSpan, rhs: DateSpan) -> Bool {
        lhs.fixedSeconds == rhs.fixedSeconds
    }

    public static func < (lhs: DateSpan, rhs: DateSpan) -> Bool {
        lhs.fixedSeconds < rhs.fixedSeconds
    }
}

public extension ReflectiveGenerator {
    /// Generates dates within the given range, spaced by `interval`.
    ///
    /// Dates are quantized to integral multiples of the interval relative to the range's lower bound.
    /// The `timeZone` is used by boundary analysis to include DST transitions for that zone.
    /// Defaults to `TimeZone.current` when not specified.
    ///
    /// ```swift
    /// let gen: ReflectiveGenerator<Date> = .date(
    ///     between: startDate ... endDate,
    ///     interval: .hours(1),
    ///     timeZone: .init(identifier: "America/New_York")!
    /// )
    /// ```
    static func date(
        between range: ClosedRange<Date>,
        interval: DateSpan,
        timeZone: TimeZone = .current
    ) -> ReflectiveGenerator<Date> {
        let lowerSeconds = Int64(range.lowerBound.timeIntervalSinceReferenceDate)
        let upperSeconds = Int64(range.upperBound.timeIntervalSinceReferenceDate)
        // Uses the absolute value of the interval, so .hours(-1) is treated as .hours(1)
        let intervalSeconds = Int64(abs(interval.fixedSeconds))

        precondition(intervalSeconds > 0, "Interval must be non-zero")
        precondition(intervalSeconds <= upperSeconds - lowerSeconds, "Interval must not exceed the date range")

        let numSteps = (upperSeconds - lowerSeconds) / intervalSeconds

        let inner: ReflectiveGenerator<Int64> = .impure(
            operation: .chooseBits(
                min: Int64(0).bitPattern64,
                max: numSteps.bitPattern64,
                tag: .date(lowerSeconds: lowerSeconds, intervalSeconds: intervalSeconds, timeZoneID: timeZone.identifier),
                isRangeExplicit: true
            )
        ) { .pure(Int64(bitPattern64: ($0 as! any BitPatternConvertible).bitPattern64)) }

        return inner.mapped(
            forward: { step in
                Date(timeIntervalSinceReferenceDate: Double(lowerSeconds + step * intervalSeconds))
            },
            backward: { date in
                Int64(floor((date.timeIntervalSinceReferenceDate - Double(lowerSeconds)) / Double(intervalSeconds)))
            }
        )
    }

    /// Generates dates within `span` on either side of `anchor`, spaced by `interval`.
    ///
    /// ```swift
    /// let gen = #gen(.date(within: .years(1), of: referenceDate, interval: .days(1)))
    /// ```
    static func date(
        within span: DateSpan,
        of anchor: Date,
        interval: DateSpan,
        timeZone: TimeZone = .current
    ) -> ReflectiveGenerator<Date> {
        let offsetSeconds = TimeInterval(span.fixedSeconds)
        let range = anchor.addingTimeInterval(-offsetSeconds) ... anchor.addingTimeInterval(offsetSeconds)
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
        within span: ClosedRange<DateSpan>,
        of anchor: Date,
        interval: DateSpan,
        timeZone: TimeZone = .current
    ) -> ReflectiveGenerator<Date> {
        let lower = anchor.addingTimeInterval(TimeInterval(span.lowerBound.fixedSeconds))
        let upper = anchor.addingTimeInterval(TimeInterval(span.upperBound.fixedSeconds))
        return date(between: lower ... upper, interval: interval, timeZone: timeZone)
    }
}
