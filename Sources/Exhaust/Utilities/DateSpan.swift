//
//  DateSpan.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/5/2026.
//

// MARK: - DateStride

/// A fixed-second approximation of a calendar interval, for specifying date generator step sizes.
///
/// Each case converts to a fixed number of seconds: `.months` uses 30 days and `.years` uses 365 days. ``Comparable`` and ``Equatable`` conformances compare by this fixed-second value, so `.months(1)` is less than `.days(31)`.
public enum DateStride: Sendable, Comparable, Equatable {
    /// Specifies an interval measured in seconds.
    case seconds(Int)
    /// Specifies an interval measured in minutes.
    case minutes(Int)
    /// Specifies an interval measured in hours.
    case hours(Int)
    /// Specifies an interval measured in days.
    case days(Int)
    /// Specifies an interval measured in weeks.
    case weeks(Int)
    /// Specifies an interval measured in calendar months.
    case months(Int)
    /// Specifies an interval measured in calendar years.
    case years(Int)

    /// The number of seconds represented by this span.
    ///
    /// Uses fixed conversions: 1 minute = 60 seconds, 1 hour = 3600, 1 day = 86400, 1 week = 604800, 1 month = 2592000 (30 days), 1 year = 31536000 (365 days). This is the value that ``Comparable`` and ``Equatable`` conformances compare.
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

    public static func == (lhs: DateStride, rhs: DateStride) -> Bool {
        lhs.fixedSeconds == rhs.fixedSeconds
    }

    public static func < (lhs: DateStride, rhs: DateStride) -> Bool {
        lhs.fixedSeconds < rhs.fixedSeconds
    }
}
