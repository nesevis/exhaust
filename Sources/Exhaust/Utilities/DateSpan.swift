//
//  DateSpan.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/5/2026.
//

// MARK: - DateSpan

public enum DateSpan: Sendable, Comparable, Equatable {
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
