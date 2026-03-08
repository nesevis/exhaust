//
//  DateSequenceBudgetTests.swift
//  Exhaust
//
//  Measures boundary analysis performance for date sequences —
//  verifying that the capped element model keeps things tractable.
//

import Foundation
import Testing
@testable import Exhaust

@Suite("Date Sequence Budget Tests")
struct DateSequenceBudgetTests {
    static let year2024Start = Date(timeIntervalSinceReferenceDate: 725_760_000)
    static let year2024End = Date(timeIntervalSinceReferenceDate: 725_760_000 + 86400 * 366)
    static let year2024 = year2024Start ... year2024End

    // ±2 weeks around US spring forward 2024
    static let springForward2024 = Date(timeIntervalSinceReferenceDate: 731_746_800)
    static let springRange = springForward2024.addingTimeInterval(-14 * 86400)
        ... springForward2024.addingTimeInterval(14 * 86400)

    static let usEastern = TimeZone(identifier: "America/New_York")!

    // MARK: - Single Date Array

    @Test("Array of dates: hourly over a year")
    func dateArrayYearHourly() {
        let gen = #gen(
            .date(between: Self.year2024, interval: .hours(1))
                .array(length: 1 ... 10),
        )

        // Property: dates in the array are all within the year range
        let counterExample = #exhaust(gen, .suppressIssueReporting) { dates in
            dates.allSatisfy { $0 >= Self.year2024Start && $0 <= Self.year2024End }
        }

        #expect(counterExample == nil)
    }

    @Test("Array of dates: 30-min intervals around DST")
    func dateArrayDSTFineGrain() {
        let gen = #gen(
            .date(between: Self.springRange, interval: .minutes(30))
                .array(length: 1 ... 5),
        )

        // Property: array is generated with valid dates
        let counterExample = #exhaust(gen, .suppressIssueReporting) { dates in
            !dates.isEmpty
        }

        #expect(counterExample == nil)
    }

    // MARK: - Date Array + Scalar Date

    @Test("Date array + scalar date: sorted check across DST")
    func dateArrayPlusScalar() {
        let gen = #gen(
            .date(between: Self.springRange, interval: .hours(1))
                .array(length: 1 ... 5),
            .date(between: Self.springRange, interval: .hours(1)),
        )

        // Property: sorting is idempotent
        let counterExample = #exhaust(gen, .suppressIssueReporting) { dates, pivot in
            let withPivot = dates + [pivot]
            let sorted = withPivot.sorted()
            return sorted == sorted.sorted()
        }

        #expect(counterExample == nil)
    }

    // MARK: - Two Date Arrays

    @Test("Two date arrays: merge preserves count")
    func twoDateArrays() {
        let gen = #gen(
            .date(between: Self.springRange, interval: .hours(1))
                .array(length: 0 ... 5),
            .date(between: Self.springRange, interval: .hours(1))
                .array(length: 0 ... 5),
        )

        // Property: merging two sorted arrays preserves total count
        let counterExample = #exhaust(gen, .suppressIssueReporting) { a, b in
            let merged = (a + b).sorted()
            return merged.count == a.count + b.count
        }

        #expect(counterExample == nil)
    }

    // MARK: - Date Array + Integer

    @Test("Date array + offset: shifting preserves order")
    func dateArrayPlusOffset() {
        let gen = #gen(
            .date(between: Self.year2024, interval: .hours(1))
                .array(length: 1 ... 5),
            .int(in: -168 ... 168), // ±1 week in hours
        )

        // Property: shifting all dates by the same offset preserves relative order
        let counterExample = #exhaust(gen, .suppressIssueReporting) { dates, hours in
            let sorted = dates.sorted()
            let shifted = sorted.map { $0.addingTimeInterval(Double(hours) * 3600) }
            return shifted == shifted.sorted()
        }

        #expect(counterExample == nil)
    }

    // MARK: - Worst Case: Date Array + Date Array + Scalar

    @Test("Two date arrays + scalar: worst-case parameter count")
    func worstCaseParameterCount() {
        let gen = #gen(
            .date(between: Self.springRange, interval: .hours(1))
                .array(length: 0 ... 5),
            .date(between: Self.springRange, interval: .hours(1))
                .array(length: 0 ... 5),
            .date(between: Self.springRange, interval: .hours(1)),
        )

        // Property: total element count is consistent
        let counterExample = #exhaust(gen, .suppressIssueReporting) { a, b, extra in
            let all = a + b + [extra]
            return all.count == a.count + b.count + 1
        }

        #expect(counterExample == nil)
    }
}
