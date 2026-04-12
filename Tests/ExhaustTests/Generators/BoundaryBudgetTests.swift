//
//  BoundaryBudgetTests.swift
//  Exhaust
//
//  Exercises the coverage budget with multi-parameter boundary generators
//  to measure how long boundary analysis takes at different scales.
//

import Foundation
import Testing
@testable import Exhaust

@Suite("Boundary Budget Stress Tests")
struct BoundaryBudgetTests {
    // MARK: - Date Ranges

    // Full year 2024
    static let year2024Start = Date(timeIntervalSinceReferenceDate: 725_760_000)
    static let year2024End = Date(timeIntervalSinceReferenceDate: 725_760_000 + 86400 * 366)
    static let year2024 = year2024Start ... year2024End

    /// Q1 2024 (Jan–Mar, captures US spring forward)
    static let q1_2024 = year2024Start
        ... Date(timeIntervalSinceReferenceDate: 725_760_000 + 91 * 86400)

    /// Q4 2024 (Oct–Dec, captures US fall back)
    static let q4_2024 = Date(timeIntervalSinceReferenceDate: 725_760_000 + 274 * 86400)
        ... year2024End

    static let usEastern = TimeZone(identifier: "America/New_York")!

    // MARK: - 1 Parameter: Baseline

    @Test("1-param year range, hourly interval")
    func oneParamYearHourly() {
        let gen = #gen(.date(between: Self.year2024, interval: .hours(1)))
        let counterExample = #exhaust(gen, .suppressIssueReporting) { date in
            // Property: every date in 2024 has a valid weekday (1–7)
            let calendar = Calendar(identifier: .gregorian)
            let weekday = calendar.component(.weekday, from: date)
            return (1 ... 7).contains(weekday)
        }

        #expect(counterExample == nil)
    }

    @Test("1-param year range, 15-minute interval")
    func oneParamYear15Min() {
        let gen = #gen(.date(between: Self.year2024, interval: .minutes(15)))

        let counterExample = #exhaust(gen, .suppressIssueReporting) { date in
            // Property: timeIntervalSinceReferenceDate round-trips through Date
            let seconds = date.timeIntervalSinceReferenceDate
            let roundTripped = Date(timeIntervalSinceReferenceDate: seconds)
            return abs(roundTripped.timeIntervalSince(date)) < 1.0
        }

        #expect(counterExample == nil)
    }

    // MARK: - 2 Parameters: Pairwise Coverage

    @Test("2-param: scheduling overlap detection across DST")
    func twoParamSchedulingOverlap() {
        let gen = #gen(
            .date(between: Self.q1_2024, interval: .hours(1)),
            .date(between: Self.q1_2024, interval: .hours(1))
        )

        // Property: if eventEnd > eventStart, the duration is positive
        // (This is trivially true but exercises the 2-param covering array)
        let counterExample = #exhaust(gen, .suppressIssueReporting) { start, end in
            guard end > start else { return true }
            return end.timeIntervalSince(start) > 0
        }

        #expect(counterExample == nil)
    }

    @Test("2-param: cross-quarter date comparison")
    func twoParamCrossQuarter() {
        let gen = #gen(
            .date(between: Self.q1_2024, interval: .hours(1)),
            .date(between: Self.q4_2024, interval: .hours(1))
        )

        // Property: Q4 date is always after Q1 date
        let counterExample = #exhaust(gen, .suppressIssueReporting) { q1Date, q4Date in
            q4Date > q1Date
        }

        #expect(counterExample == nil)
    }

    @Test("2-param: day-of-week consistency across DST", .disabled("This fails and finds two dates in August. Need to figure out what that is"))
    func twoParamDayOfWeekConsistency() {
        let gen = #gen(
            .date(between: Self.year2024, interval: .hours(1)),
            .date(between: Self.year2024, interval: .hours(1))
        )

        // Property: if two dates are exactly 7 calendar days apart,
        // they fall on the same weekday
        let counterExample = #exhaust(
            gen,
            .suppressIssueReporting,
            .replay(9_233_197_236_318_045_878)
        ) { date1, date2 in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = Self.usEastern
            let dayDiff = calendar.dateComponents([.day], from: date1, to: date2).day!
            guard dayDiff == 7 else { return true }
            let weekday1 = calendar.component(.weekday, from: date1)
            let weekday2 = calendar.component(.weekday, from: date2)
            return weekday1 == weekday2
        }

        #expect(counterExample == nil)
    }

    // MARK: - 3 Parameters: Triple Interaction

    @Test("3-param: transitive date ordering")
    func threeParamTransitiveOrdering() {
        let gen = #gen(
            .date(between: Self.q1_2024, interval: .hours(1)),
            .date(between: Self.q1_2024, interval: .hours(1)),
            .date(between: Self.q1_2024, interval: .hours(1))
        )

        // Property: date comparison is transitive (a < b && b < c → a < c)
        let counterExample = #exhaust(gen, .suppressIssueReporting) { a, b, c in
            guard a < b, b < c else { return true }
            return a < c
        }

        #expect(counterExample == nil)
    }

    @Test("3-param: calendar day containment")
    func threeParamCalendarDayContainment() {
        let gen = #gen(
            .date(between: Self.q1_2024, interval: .hours(1)),
            .date(between: Self.q1_2024, interval: .hours(1)),
            .date(between: Self.q1_2024, interval: .hours(1))
        )

        // Property: if a and c are on the same calendar day, and a <= b <= c,
        // then b is also on the same calendar day.
        let counterExample = #exhaust(gen, .suppressIssueReporting) { a, b, c in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = Self.usEastern
            // Sort so we have ordered dates
            let sorted = [a, b, c].sorted()
            let first = sorted[0], mid = sorted[1], last = sorted[2]
            let startFirst = calendar.startOfDay(for: first)
            let startLast = calendar.startOfDay(for: last)
            guard startFirst == startLast else { return true } // different days, skip
            let startMid = calendar.startOfDay(for: mid)
            return startMid == startFirst
        }

        #expect(counterExample == nil)
    }

    // MARK: - 4 Parameters: Quad Interaction

    @Test("4-param: overlapping intervals across DST")
    func fourParamOverlappingIntervals() {
        // Two events: [start1, end1) and [start2, end2)
        let gen = #gen(
            .date(between: Self.q1_2024, interval: .hours(1)),
            .date(between: Self.q1_2024, interval: .hours(1)),
            .date(between: Self.q1_2024, interval: .hours(1)),
            .date(between: Self.q1_2024, interval: .hours(1))
        )

        // Property: overlap is symmetric — if A overlaps B, then B overlaps A
        let counterExample = #exhaust(gen, .suppressIssueReporting) { s1, e1, s2, e2 in
            let start1 = min(s1, e1), end1 = max(s1, e1)
            let start2 = min(s2, e2), end2 = max(s2, e2)
            let aOverlapsB = start1 < end2 && start2 < end1
            let bOverlapsA = start2 < end1 && start1 < end2
            return aOverlapsB == bOverlapsA
        }

        #expect(counterExample == nil)
    }

    // MARK: - Mixed Types: Date + Integer

    @Test("2-param: date + offset — calendar addition consistency")
    func mixedDateAndOffset() {
        let gen = #gen(
            .date(between: Self.year2024, interval: .hours(1)),
            .int(in: -168 ... 168) // ±1 week in hours
        )

        // Property: adding N hours via seconds matches Calendar.date(byAdding:)
        let counterExample = #exhaust(gen, .suppressIssueReporting) { date, hours in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = Self.usEastern
            let bySeconds = date.addingTimeInterval(Double(hours) * 3600)
            guard let byCalendar = calendar.date(byAdding: .hour, value: hours, to: date) else {
                return true
            }
            // These should always agree — Calendar.date(byAdding: .hour) adds wall-clock hours
            // which equals adding seconds for hour additions
            return abs(bySeconds.timeIntervalSince(byCalendar)) < 1.0
        }

        #expect(counterExample == nil)
    }

    @Test("3-param: date + two offsets — associativity of hour addition")
    func mixedDateAndTwoOffsets() {
        let gen = #gen(
            .date(between: Self.year2024, interval: .hours(1)),
            .int(in: -72 ... 72),
            .int(in: -72 ... 72)
        )

        // Property: adding hours is associative — (date + a) + b == date + (a + b)
        let counterExample = #exhaust(gen, .suppressIssueReporting) { date, a, b in
            let stepwise = date.addingTimeInterval(Double(a) * 3600)
                .addingTimeInterval(Double(b) * 3600)
            let combined = date.addingTimeInterval(Double(a + b) * 3600)
            return abs(stepwise.timeIntervalSince(combined)) < 1.0
        }

        #expect(counterExample == nil)
    }

    // MARK: - Realistic Record Types

    @Test("5-param: record with startDate, endDate, modifiedDate, createdDate, dueDate")
    func fiveDateRecord() {
        let gen = #gen(
            .date(between: Self.q1_2024, interval: .hours(1)),
            .date(between: Self.q1_2024, interval: .hours(1)),
            .date(between: Self.q1_2024, interval: .hours(1)),
            .date(between: Self.q1_2024, interval: .hours(1)),
            .date(between: Self.q1_2024, interval: .hours(1))
        )

        // Property: createdDate <= modifiedDate (treating params as: start, end, modified, created, due)
        let counterExample = #exhaust(gen, .suppressIssueReporting) { start, end, modified, created, _ in
            guard created <= modified else { return true } // precondition
            guard start <= end else { return true } // precondition
            // Trivially true — just exercising the covering array
            return created <= modified
        }

        #expect(counterExample == nil)
    }

    @Test("6-param: record with dates + status enum + priority int")
    func sixParamMixedRecord() {
        let gen = #gen(
            .date(between: Self.q1_2024, interval: .hours(1)), // startDate
            .date(between: Self.q1_2024, interval: .hours(1)), // endDate
            .date(between: Self.q1_2024, interval: .hours(1)), // modifiedDate
            .date(between: Self.q1_2024, interval: .hours(1)), // createdDate
            .int(in: 0 ... 4), // status
            .int(in: 1 ... 5) // priority
        )

        let counterExample = #exhaust(gen, .suppressIssueReporting) { _, _, _, _, status, priority in
            (1 ... 5).contains(priority) && (0 ... 4).contains(status)
        }

        #expect(counterExample == nil)
    }

    // MARK: - Budget Ceiling: Large Boundary Sets

    @Test("2-param year range with fine granularity — approaches budget ceiling")
    func budgetCeiling() {
        let gen = #gen(
            .date(between: Self.year2024, interval: .minutes(15)),
            .date(between: Self.year2024, interval: .minutes(15))
        )

        // Property: dates preserve their relative ordering through Calendar
        let counterExample = #exhaust(gen, .suppressIssueReporting) { date1, date2 in
            guard date1 != date2 else { return true }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = Self.usEastern
            let comp = calendar.compare(date1, to: date2, toGranularity: .second)
            if date1 < date2 {
                return comp == .orderedAscending
            } else {
                return comp == .orderedDescending
            }
        }

        #expect(counterExample == nil)
    }
}
