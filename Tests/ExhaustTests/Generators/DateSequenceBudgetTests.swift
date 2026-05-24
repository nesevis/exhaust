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
                .array(length: 1 ... 10)
        )

        // Property: dates in the array are all within the year range
        let counterExample = #exhaust(gen, .suppress(.issueReporting)) { dates in
            dates.allSatisfy { $0 >= Self.year2024Start && $0 <= Self.year2024End }
        }

        #expect(counterExample == nil)
    }

    // MARK: - DST Fine-Grain Array

    @Test("Array of dates: 30-min intervals around DST obey range and quantization")
    func dateArrayDSTFineGrain() {
        let intervalSeconds: TimeInterval = 1800
        let rangeStart = Self.springRange.lowerBound
        let gen = #gen(
            .date(between: Self.springRange, interval: .minutes(30))
                .array(length: 1 ... 5)
        )

        let counterExample = #exhaust(gen, .suppress(.issueReporting)) { dates in
            dates.allSatisfy { date in
                date >= Self.springRange.lowerBound
                    && date <= Self.springRange.upperBound
                    && date.timeIntervalSince(rangeStart).remainder(dividingBy: intervalSeconds).magnitude < 0.001
            }
        }

        #expect(counterExample == nil)
    }

    // MARK: - Date Array + Scalar Date

    @Test("Date array + scalar date: all values within range across DST")
    func dateArrayPlusScalar() {
        let gen = #gen(
            .date(between: Self.springRange, interval: .hours(1))
                .array(length: 1 ... 5),
            .date(between: Self.springRange, interval: .hours(1))
        )

        let counterExample = #exhaust(gen, .suppress(.issueReporting)) { dates, pivot in
            let allDates = dates + [pivot]
            return allDates.allSatisfy { $0 >= Self.springRange.lowerBound && $0 <= Self.springRange.upperBound }
        }

        #expect(counterExample == nil)
    }

    // MARK: - Two Date Arrays

    @Test("Two date arrays: all elements within range")
    func twoDateArrays() {
        let gen = #gen(
            .date(between: Self.springRange, interval: .hours(1))
                .array(length: 0 ... 5),
            .date(between: Self.springRange, interval: .hours(1))
                .array(length: 0 ... 5)
        )

        let counterExample = #exhaust(gen, .suppress(.issueReporting)) { a, b in
            (a + b).allSatisfy { $0 >= Self.springRange.lowerBound && $0 <= Self.springRange.upperBound }
        }

        #expect(counterExample == nil)
    }

    // MARK: - Date Array + Integer

    @Test("Date array + offset: dates within range and offset within bounds")
    func dateArrayPlusOffset() {
        let gen = #gen(
            .date(between: Self.year2024, interval: .hours(1))
                .array(length: 1 ... 5),
            .int(in: -168 ... 168)
        )

        let counterExample = #exhaust(gen, .suppress(.issueReporting)) { dates, hours in
            let datesValid = dates.allSatisfy { $0 >= Self.year2024Start && $0 <= Self.year2024End }
            let offsetValid = hours >= -168 && hours <= 168
            return datesValid && offsetValid
        }

        #expect(counterExample == nil)
    }

    // MARK: - Worst Case: Date Array + Date Array + Scalar

    @Test("Two date arrays + scalar: all three parameters within range")
    func worstCaseParameterCount() {
        let gen = #gen(
            .date(between: Self.springRange, interval: .hours(1))
                .array(length: 0 ... 5),
            .date(between: Self.springRange, interval: .hours(1))
                .array(length: 0 ... 5),
            .date(between: Self.springRange, interval: .hours(1))
        )

        let counterExample = #exhaust(gen, .suppress(.issueReporting)) { a, b, extra in
            (a + b + [extra]).allSatisfy { $0 >= Self.springRange.lowerBound && $0 <= Self.springRange.upperBound }
        }

        #expect(counterExample == nil)
    }
}
