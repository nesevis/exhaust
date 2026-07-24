//
//  DaysBetweenTests.swift
//  Exhaust
//

import Exhaust
import Foundation
import Testing

@Suite("Days Between")
struct DaysBetweenTests {
    private let betweenCounter = DaysBetweenFixture()

    @Test("The same date is zero days apart")
    func sameDate() {
        let date = betweenCounter.date(year: 2024, month: 5, day: 10)

        #expect(betweenCounter.daysBetween(date, date) == 0)
    }

    @Test("An ordinary forward span is positive")
    func ordinaryForwardSpan() {
        let first = betweenCounter.date(year: 2024, month: 5, day: 10)
        let second = betweenCounter.date(year: 2024, month: 5, day: 20)

        #expect(betweenCounter.daysBetween(first, second) == 10)
    }

    @Test("An ordinary reverse span is negative")
    func ordinaryReverseSpan() {
        let first = betweenCounter.date(year: 2024, month: 5, day: 20)
        let second = betweenCounter.date(year: 2024, month: 5, day: 10)

        #expect(betweenCounter.daysBetween(first, second) == -10)
    }

    @Test("Adjacent months are one day apart")
    func adjacentMonths() {
        let first = betweenCounter.date(year: 2025, month: 1, day: 31)
        let second = betweenCounter.date(year: 2025, month: 2, day: 1)

        #expect(betweenCounter.daysBetween(first, second) == 1)
    }

    @Test("Adjacent years are one day apart")
    func adjacentYears() {
        let first = betweenCounter.date(year: 2025, month: 12, day: 31)
        let second = betweenCounter.date(year: 2026, month: 1, day: 1)

        #expect(betweenCounter.daysBetween(first, second) == 1)
    }

    @Test("Leap day contributes an additional day")
    func leapDay() {
        let first = betweenCounter.date(year: 2024, month: 2, day: 28)
        let second = betweenCounter.date(year: 2024, month: 3, day: 1)

        #expect(betweenCounter.daysBetween(first, second) == 2)
    }

    @Test("Day differences are reversible")
    func dayDifferencesAreReversible() {
        let dayOffsetGenerator = #gen(.int(in: betweenCounter.dayOffsetRange))
        let dayOffsetPairGenerator = #gen(dayOffsetGenerator, dayOffsetGenerator)
        let points = UnsafeSendableBox([String]())

        #exhaust(
            dayOffsetPairGenerator,
            .budget(.custom(screening: 200, sampling: 200))
        ) { firstDayOffset, secondDayOffset in
            let first = betweenCounter.date(atDayOffset: firstDayOffset)
            let second = betweenCounter.date(atDayOffset: secondDayOffset)
            let days = betweenCounter.daysBetween(first, second)
            let reverseDays = betweenCounter.daysBetween(second, first)
            let reconstructedSecond = betweenCounter.adding(days: days, to: first)

//            #expect(betweenCounter.screenPoint(for: first) == firstDayOffset)
//            #expect(betweenCounter.screenPoint(for: second) == secondDayOffset)
            #expect(days == -reverseDays)
            #expect(reconstructedSecond == second)
//            points.value.append("\(betweenCounter.screenPoint(for: first))x\(betweenCounter.screenPoint(for: second))")
        }
//        print("ø" + points.value.joined(separator: ", "))
    }
}

// MARK: - Fixture

private struct DaysBetweenFixture: Sendable {
    let timeZone: TimeZone
    private let calendar: Calendar

    init() {
        guard let timeZone = TimeZone(identifier: "Australia/Melbourne") else {
            preconditionFailure("Australia/Melbourne must be a known time zone")
        }
        self.timeZone = timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    var dateRange: ClosedRange<Date> {
        date(year: 2024, month: 1, day: 1)
            ... date(year: 2026, month: 12, day: 31)
    }

    var dayOffsetRange: ClosedRange<Int> {
        0 ... daysBetween(dateRange.lowerBound, dateRange.upperBound)
    }

    func date(year: Int, month: Int, day: Int) -> Date {
        let components = DateComponents(
            calendar: calendar,
            timeZone: timeZone,
            year: year,
            month: month,
            day: day
        )

        guard let date = calendar.date(from: components) else {
            preconditionFailure("Invalid fixture date: \(year)-\(month)-\(day)")
        }
        return date
    }

    func daysBetween(_ first: Date, _ second: Date) -> Int {
        guard let days = calendar.dateComponents([.day], from: first, to: second).day else {
            preconditionFailure("Could not calculate the calendar-day difference")
        }
        return days
    }

    func date(atDayOffset dayOffset: Int) -> Date {
        adding(days: dayOffset, to: dateRange.lowerBound)
    }

    func screenPoint(for date: Date) -> Int {
        let point = daysBetween(dateRange.lowerBound, date)
        precondition(dayOffsetRange.contains(point), "Date must be within the fixture's date range")
        return point
    }

    func adding(days: Int, to date: Date) -> Date {
        guard let result = calendar.date(byAdding: .day, value: days, to: date) else {
            preconditionFailure("Could not add \(days) calendar days")
        }
        return result
    }
}
