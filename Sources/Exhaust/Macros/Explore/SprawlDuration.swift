// The wall-clock time type for `#explore(time:)` budgets and report durations.

/// A span of wall-clock time, used for `#explore(time:)` budgets and for the elapsed and per-cluster times a ``SprawlReport`` reports.
///
/// This exists instead of the standard library's `Duration` so the `time:` mode carries no availability floor: `Duration` requires macOS 13 / iOS 16, while a fuzz run is otherwise deployable to the package's own minimum. Construct one with the unit factories, which keep the call site self-documenting (`.minutes(15)`, `.seconds(8)`) and admit no bare, unit-ambiguous number.
///
/// ```swift
/// #explore(messageGen, time: .minutes(15)) { message in
///     try Decoder.decode(message)
/// }
/// ```
public struct SprawlDuration: Sendable, Hashable, Comparable {
    /// The span in whole nanoseconds. The runtime works in nanoseconds throughout, so this is the native unit rather than a derived accessor.
    public let nanoseconds: UInt64

    /// Creates a duration from a raw nanosecond count.
    public init(nanoseconds: UInt64) {
        self.nanoseconds = nanoseconds
    }

    /// A zero-length span.
    public static let zero = SprawlDuration(nanoseconds: 0)

    /// Creates a duration from a raw nanosecond count.
    public static func nanoseconds(_ value: UInt64) -> SprawlDuration {
        SprawlDuration(nanoseconds: value)
    }

    /// Creates a duration from a whole number of milliseconds. Negative values become zero.
    public static func milliseconds(_ value: Int) -> SprawlDuration {
        scaled(value, byNanoseconds: 1_000_000)
    }

    /// Creates a duration from a whole number of seconds. Negative values become zero.
    public static func seconds(_ value: Int) -> SprawlDuration {
        scaled(value, byNanoseconds: 1_000_000_000)
    }

    /// Creates a duration from a whole number of minutes. Negative values become zero.
    public static func minutes(_ value: Int) -> SprawlDuration {
        scaled(value, byNanoseconds: 60_000_000_000)
    }

    /// Creates a duration from a whole number of hours. Negative values become zero.
    public static func hours(_ value: Int) -> SprawlDuration {
        scaled(value, byNanoseconds: 3_600_000_000_000)
    }

    /// The span in fractional seconds, for throughput math and rendering.
    public var seconds: Double {
        Double(nanoseconds) / 1_000_000_000
    }

    public static func < (lhs: SprawlDuration, rhs: SprawlDuration) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }

    /// Scales the span by a non-negative integer factor, saturating rather than overflowing.
    public static func * (duration: SprawlDuration, factor: Int) -> SprawlDuration {
        guard factor > 0 else {
            return .zero
        }
        let (product, overflow) = duration.nanoseconds.multipliedReportingOverflow(by: UInt64(factor))
        return SprawlDuration(nanoseconds: overflow ? .max : product)
    }

    /// Divides the span by a positive integer divisor. A nonpositive divisor yields zero.
    public static func / (duration: SprawlDuration, divisor: Int) -> SprawlDuration {
        guard divisor > 0 else {
            return .zero
        }
        return SprawlDuration(nanoseconds: duration.nanoseconds / UInt64(divisor))
    }

    /// Multiplies a positive integer unit count by nanoseconds-per-unit, clamping negatives to zero and saturating overflow at the maximum span (585 years) rather than trapping on an absurd budget.
    private static func scaled(_ value: Int, byNanoseconds nanosecondsPerUnit: UInt64) -> SprawlDuration {
        guard value > 0 else {
            return .zero
        }
        let (product, overflow) = UInt64(value).multipliedReportingOverflow(by: nanosecondsPerUnit)
        return SprawlDuration(nanoseconds: overflow ? .max : product)
    }
}
