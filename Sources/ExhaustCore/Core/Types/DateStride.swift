//
//  DateStride.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/5/2026.
//

import Foundation

// MARK: - DateStride

/// A step size for date generators, measured in fixed or calendar units.
///
/// `.seconds`, `.minutes`, and `.hours` are fixed-length intervals. `.days`, `.weeks`, `.months`, and `.years` are calendar units: date generators advance them with calendar arithmetic in the generator's time zone, so `.months(1)` from January 15 lands on the 15th of every month, and `.days(1)` keeps the same wall-clock time across daylight-saving transitions.
public enum DateStride: Sendable, Comparable {
    /// Specifies an interval measured in seconds.
    case seconds(Int)
    /// Specifies an interval measured in minutes.
    case minutes(Int)
    /// Specifies an interval measured in hours.
    case hours(Int)
    /// Specifies an interval measured in calendar days.
    case days(Int)
    /// Specifies an interval measured in calendar weeks (seven calendar days).
    case weeks(Int)
    /// Specifies an interval measured in calendar months.
    case months(Int)
    /// Specifies an interval measured in calendar years.
    case years(Int)

    /// The approximate number of seconds represented by this stride, used for ordering.
    ///
    /// Uses fixed conversions: 1 minute = 60 seconds, 1 hour = 3600, 1 day = 86400, 1 week = 604800, 1 month = 2592000 (30 days), 1 year = 31536000 (365 days). Generation does not use this value for calendar units — `.days` through `.years` advance with true calendar arithmetic — so treat it as an ordering key, not a duration.
    public var fixedSeconds: Int {
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

    /// Orders strides by their fixed-second approximation, so `.hours(25) > .days(1)`.
    ///
    /// - Note: Ordering is approximate but equality is structural: `.months(1)` and `.days(30)` compare unequal even though neither is ordered before the other.
    public static func < (lhs: DateStride, rhs: DateStride) -> Bool {
        lhs.fixedSeconds < rhs.fixedSeconds
    }
}

// MARK: - DateGrid

/// The discrete grid of instants a date generator draws from: a lower bound plus `stepCount` strides.
///
/// A grid maps step indices `0 ... stepCount` to instants and back. The `.fixed` form is affine (`lower + step * secondsPerStep`); the `.calendar` form advances the lower bound by whole calendar components, which keeps month grids on the anchor's day-of-month and keeps day grids at the anchor's wall-clock time across daylight-saving transitions.
///
/// ``DateStride`` lowers to a form via ``DateStride/gridForm(in:)``: sub-day strides are always `.fixed`, `.months`/`.years` are always `.calendar`, and `.days`/`.weeks` are `.calendar` exactly when the zone's days can vary in length — under fixed-offset zones (UTC, GMT, `Etc/*`) calendar-day arithmetic is second-for-second identical to the affine map, so the grid lowers to `.fixed` there as a pure optimization.
@usableFromInline
package struct DateGrid: Hashable, Sendable {
    /// Distinguishes affine grids from calendar-arithmetic grids.
    @usableFromInline
    package enum Form: Hashable, Sendable {
        /// Steps are a fixed number of seconds apart.
        case fixed(secondsPerStep: Int64)
        /// Steps advance by `count` calendar components from the lower bound.
        case calendar(component: Calendar.Component, count: Int)

        /// The approximate duration of one step, for consumers that need a coarse scale (for example, deciding whether a grid is fine enough to land inside a one-day gap).
        package var approximateSecondsPerStep: Int64 {
            switch self {
                case let .fixed(secondsPerStep):
                    secondsPerStep
                case let .calendar(component, count):
                    switch component {
                        case .day: Int64(count) * 86400
                        case .month: Int64(count) * 2_592_000
                        case .year: Int64(count) * 31_536_000
                        default: Int64(count) * 86400
                    }
            }
        }
    }

    package let form: Form
    package let lowerSeconds: Int64
    /// The largest valid step index. `secondsAtStep(stepCount)` never exceeds the range's upper bound.
    package let stepCount: Int64
    package let timeZoneID: String

    /// Built once at grid construction. `nil` for `.fixed` grids, which never consult it.
    private let calendar: Calendar?

    /// Creates the grid for a generator's range and stride.
    ///
    /// The stride's count is taken by magnitude, matching the previous affine implementation's `abs`. A `stepCount` of zero is legal here; the generator preconditions on it separately so the failure message names the user-facing parameter.
    package init(
        stride: DateStride,
        lowerSeconds: Int64,
        upperSeconds: Int64,
        timeZone: TimeZone
    ) {
        let form = stride.gridForm(in: timeZone)
        let calendar = Self.makeCalendar(for: form, timeZoneID: timeZone.identifier)
        self.form = form
        self.lowerSeconds = lowerSeconds
        timeZoneID = timeZone.identifier
        self.calendar = calendar
        stepCount = Self.computeStepCount(
            form: form,
            lowerSeconds: lowerSeconds,
            upperSeconds: upperSeconds,
            calendar: calendar
        )
    }

    /// Recreates a grid from its stored parts, for consumers reading a ``TypeTagPayload``.
    package init(form: Form, lowerSeconds: Int64, stepCount: Int64, timeZoneID: String) {
        self.form = form
        self.lowerSeconds = lowerSeconds
        self.stepCount = stepCount
        self.timeZoneID = timeZoneID
        calendar = Self.makeCalendar(for: form, timeZoneID: timeZoneID)
    }

    /// The instant at `step`, in integral seconds since the reference date.
    ///
    /// Calendar grids add `step * count` components in a single operation from the lower bound rather than stepping cumulatively. Cumulative stepping accumulates end-of-month clamping (repeated `+1 month` from January 31 gets stuck on the 28th); a single addition clamps only the final landing month, so the grid stays on the anchor's day-of-month wherever that day exists.
    package func secondsAtStep(_ step: Int64) -> Int64 {
        switch form {
            case let .fixed(secondsPerStep):
                return lowerSeconds + step * secondsPerStep
            case let .calendar(component, count):
                let anchor = Date(timeIntervalSinceReferenceDate: TimeInterval(lowerSeconds))
                guard let calendar,
                      let advanced = calendar.date(byAdding: component, value: Int(step) * count, to: anchor)
                else {
                    preconditionFailure("Could not advance \(anchor) by \(step * Int64(count)) × \(component)")
                }
                return Int64(advanced.timeIntervalSinceReferenceDate.rounded(.down))
        }
    }

    /// The largest step whose instant is at or before `seconds`, clamped to `0 ... stepCount`.
    ///
    /// This is the reflection (backward) map: off-grid instants round down, and out-of-range instants clamp to the nearest grid edge — the same result the interpreter's own range clamping would produce one layer later.
    ///
    /// Calendar grids binary-search the forward map instead of asking `dateComponents(_:from:to:)` for the elapsed component count, because the search guarantees `stepIndex(flooring: secondsAtStep(step)) == step` by construction. Foundation's elapsed-component answer near clamped landings (January 31 + 1 month = February 28) does not carry that guarantee, and reflection round-trips depend on it.
    ///
    /// - Complexity: O(1) for `.fixed` grids, O(log `stepCount`) forward evaluations for `.calendar` grids.
    package func stepIndex(flooring seconds: Int64) -> Int64 {
        switch form {
            case let .fixed(secondsPerStep):
                let offset = seconds - lowerSeconds
                var floored = offset / secondsPerStep
                if offset < 0, offset % secondsPerStep != 0 {
                    floored -= 1
                }
                return min(max(floored, 0), stepCount)
            case .calendar:
                if seconds <= lowerSeconds {
                    return 0
                }
                var lowerStep: Int64 = 0
                var upperStep = stepCount
                while lowerStep < upperStep {
                    let midStep = lowerStep + (upperStep - lowerStep + 1) / 2
                    if secondsAtStep(midStep) <= seconds {
                        lowerStep = midStep
                    } else {
                        upperStep = midStep - 1
                    }
                }
                return lowerStep
        }
    }

    @usableFromInline
    package static func == (lhs: DateGrid, rhs: DateGrid) -> Bool {
        lhs.form == rhs.form
            && lhs.lowerSeconds == rhs.lowerSeconds
            && lhs.stepCount == rhs.stepCount
            && lhs.timeZoneID == rhs.timeZoneID
    }

    @usableFromInline
    package func hash(into hasher: inout Hasher) {
        hasher.combine(form)
        hasher.combine(lowerSeconds)
        hasher.combine(stepCount)
        hasher.combine(timeZoneID)
    }

    private static func makeCalendar(for form: Form, timeZoneID: String) -> Calendar? {
        guard case .calendar = form else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID) ?? TimeZone(identifier: "GMT")!
        return calendar
    }

    /// The largest step whose instant does not exceed `upperSeconds`.
    ///
    /// Calendar grids start from Foundation's elapsed-component estimate and then nudge it against the forward map, because the estimate can be off by one near clamped landings. The nudge loops run at most a step or two.
    private static func computeStepCount(
        form: Form,
        lowerSeconds: Int64,
        upperSeconds: Int64,
        calendar: Calendar?
    ) -> Int64 {
        switch form {
            case let .fixed(secondsPerStep):
                return (upperSeconds - lowerSeconds) / secondsPerStep
            case let .calendar(component, count):
                guard let calendar else {
                    preconditionFailure("Calendar grids always carry a calendar")
                }
                let lowerDate = Date(timeIntervalSinceReferenceDate: TimeInterval(lowerSeconds))
                let upperDate = Date(timeIntervalSinceReferenceDate: TimeInterval(upperSeconds))
                let elapsed = calendar.dateComponents([component], from: lowerDate, to: upperDate)
                    .value(for: component) ?? 0

                func seconds(atStep step: Int64) -> Int64 {
                    guard let advanced = calendar.date(byAdding: component, value: Int(step) * count, to: lowerDate) else {
                        preconditionFailure("Could not advance \(lowerDate) by \(step * Int64(count)) × \(component)")
                    }
                    return Int64(advanced.timeIntervalSinceReferenceDate.rounded(.down))
                }

                var stepCount = max(0, Int64(elapsed) / Int64(count))
                while seconds(atStep: stepCount + 1) <= upperSeconds {
                    stepCount += 1
                }
                while stepCount > 0, seconds(atStep: stepCount) > upperSeconds {
                    stepCount -= 1
                }
                return stepCount
        }
    }
}

// MARK: - Stride Lowering

package extension DateStride {
    /// Lowers this stride to the grid form date generators execute, taking the count by magnitude.
    ///
    /// `.days`/`.weeks` are calendar units semantically, but under a fixed-offset zone every calendar day is exactly 86400 seconds, so they lower to the affine form there and generation skips calendar arithmetic entirely. `.months`/`.years` never lower to `.fixed`: their drift (a 30-day month, a 365-day year) is wrong in every zone, UTC included.
    func gridForm(in timeZone: TimeZone) -> DateGrid.Form {
        switch self {
            case let .seconds(n):
                return .fixed(secondsPerStep: Int64(abs(n)))
            case let .minutes(n):
                return .fixed(secondsPerStep: Int64(abs(n)) * 60)
            case let .hours(n):
                return .fixed(secondsPerStep: Int64(abs(n)) * 3600)
            case let .days(n):
                if timeZone.hasFixedLengthDays {
                    return .fixed(secondsPerStep: Int64(abs(n)) * 86400)
                }
                return .calendar(component: .day, count: abs(n))
            case let .weeks(n):
                if timeZone.hasFixedLengthDays {
                    return .fixed(secondsPerStep: Int64(abs(n)) * 604_800)
                }
                return .calendar(component: .day, count: abs(n) * 7)
            case let .months(n):
                return .calendar(component: .month, count: abs(n))
            case let .years(n):
                return .calendar(component: .year, count: abs(n))
        }
    }
}

private extension TimeZone {
    /// Whether every calendar day in this zone is exactly 86400 seconds, making calendar-day arithmetic identical to fixed-second arithmetic.
    ///
    /// True only for the fixed-offset families (`UTC`, `GMT`-prefixed, `Etc/*`). Zones that merely lack DST today (for example `America/Phoenix`) stay calendar-lowered: their historic offset changes can still produce short or long days, and the cost of calendar arithmetic is preferable to an incorrect grid.
    var hasFixedLengthDays: Bool {
        identifier == "UTC" || identifier.hasPrefix("GMT") || identifier.hasPrefix("Etc/")
    }
}
