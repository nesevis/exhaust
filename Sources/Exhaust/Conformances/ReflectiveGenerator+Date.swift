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
    /// The `timeZone` is used by boundary analysis to include DST transitions for that zone.
    /// Defaults to `TimeZone.current` when not specified.
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
        interval: DateSpan,
        timeZone: TimeZone = .current
    ) -> ReflectiveGenerator<Date> {
        let lowerSeconds = Int64(range.lowerBound.timeIntervalSinceReferenceDate)
        let upperSeconds = Int64(range.upperBound.timeIntervalSinceReferenceDate)
        let intervalSeconds = Int64(abs(interval.fixedSeconds))

        precondition(intervalSeconds > 0, "Interval must be non-zero")
        precondition(
            intervalSeconds <= upperSeconds - lowerSeconds,
            "Interval must not exceed the date range"
        )

        let numSteps = (upperSeconds - lowerSeconds) / intervalSeconds

        return Generator<Int64>.impure(
            operation: .chooseBits(
                min: Int64(0).bitPattern64,
                max: numSteps.bitPattern64,
                tag: .date(
                    lowerSeconds: lowerSeconds,
                    intervalSeconds: intervalSeconds,
                    timeZoneID: timeZone.identifier
                ),
                isRangeExplicit: true
            )
        ) { .pure(Int64(bitPattern64: ($0 as! any BitPatternConvertible).bitPattern64)) }
        .wrapped.mapped(
            forward: { step in
                Date(timeIntervalSinceReferenceDate: Double(lowerSeconds + step * intervalSeconds))
            },
            backward: { date in
                let offset = date.timeIntervalSinceReferenceDate - Double(lowerSeconds)
                return Int64(floor(offset / Double(intervalSeconds)))
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
