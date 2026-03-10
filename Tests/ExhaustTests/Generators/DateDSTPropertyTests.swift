//
//  DateDSTPropertyTests.swift
//  Exhaust
//
//  Demonstrates how boundary analysis catches DST-related date bugs
//  that random testing is unlikely to find.
//

import Foundation
import Testing
@testable import Exhaust

@Suite("Date DST Property Tests")
struct DateDSTPropertyTests {
    /// US Eastern spring forward 2024: March 10 at 2:00 AM EST → 3:00 AM EDT
    /// In UTC: March 10 at 07:00 UTC
    /// Seconds since reference date for 2024-03-10 07:00 UTC:
    ///   2024-01-01 = 725_760_000, + 69 days * 86400 + 7 * 3600 = 731_746_800
    static let springForward2024 = Date(timeIntervalSinceReferenceDate: 731_746_800)

    /// A ±2 week range around the spring forward transition
    static let springRange = springForward2024.addingTimeInterval(-14 * 86400)
        ... springForward2024.addingTimeInterval(14 * 86400)

    /// US Eastern fall back 2024: November 3 at 2:00 AM EDT → 1:00 AM EST
    /// In UTC: November 3 at 06:00 UTC
    static let fallBack2024 = Date(timeIntervalSinceReferenceDate: 752_306_400)

    /// A ±2 week range around the fall back transition
    static let fallBackRange = fallBack2024.addingTimeInterval(-14 * 86400)
        ... fallBack2024.addingTimeInterval(14 * 86400)

    static let usEastern = TimeZone(identifier: "America/New_York")!

    // MARK: - Bug: "Every day has 24 hours"

    @Test("Buggy daysBetween disagrees with Calendar around DST spring forward")
    func daysBetweenDSTBug() {
        let gen = #gen(.date(between: Self.springRange, interval: .hours(1), timeZone: Self.usEastern))

        let counterExample = #exhaust(gen, .suppressIssueReporting) { date in
            let anchor = Self.springRange.lowerBound
            // BUG: dividing elapsed seconds by 86400 assumes every day has exactly 86400 seconds
            let buggyDays = Int(date.timeIntervalSince(anchor)) / 86400
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = Self.usEastern
            let correctDays = calendar.dateComponents([.day], from: anchor, to: date).day!
            return buggyDays == correctDays
        }

        #expect(counterExample != nil, "Expected boundary analysis to find a DST-related disagreement")
    }

    // MARK: - Bug: "Midnight to midnight is always 86400 seconds"

    @Test("Buggy secondsInDay disagrees with Calendar on DST transition day")
    func secondsInDayDSTBug() {
        let gen = #gen(.date(between: Self.springRange, interval: .hours(1), timeZone: Self.usEastern))

        let counterExample = #exhaust(gen, .suppressIssueReporting) { date in
            // BUG: hardcoded assumption that every day is 86400 seconds
            let buggySeconds = 86400
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = Self.usEastern
            let startOfDay = calendar.startOfDay(for: date)
            guard let startOfNextDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
                return true
            }
            let correctSeconds = Int(startOfNextDay.timeIntervalSince(startOfDay))
            return buggySeconds == correctSeconds
        }

        #expect(counterExample != nil, "Expected boundary analysis to find a day with != 86400 seconds")
    }

    // MARK: - Bug: "Adding N * 3600 seconds advances by N hours"

    @Test("Buggy hourOfDay disagrees with Calendar after spring forward")
    func hourOfDayDSTBug() {
        let gen = #gen(.date(between: Self.springRange, interval: .minutes(30), timeZone: Self.usEastern))

        let counterExample = #exhaust(gen, .suppressIssueReporting) { date in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = Self.usEastern
            let midnight = calendar.startOfDay(for: date)
            // BUG: assumes uniform 3600-second hours from midnight
            let buggyHour = Int(date.timeIntervalSince(midnight)) / 3600
            let correctHour = calendar.component(.hour, from: date)
            return buggyHour == correctHour
        }

        #expect(counterExample != nil, "Expected boundary analysis to find an hour disagreement at DST")
    }

    // MARK: - Google Closure Library: "The 1 Hour Per Year Bug"

    // https://tomeraberba.ch/the-1-hour-per-year-bug
    //
    // The buggy pattern computes relative day labels ("today"/"tomorrow") by:
    //   floor((target - startOfDay(now)) / 86400)
    //
    // On a DST fall-back day the day has 25 hours, so a time late in the evening
    // (>24h from midnight but still the same calendar day) is wrongly labeled
    // "tomorrow". The bug only manifests during the ~1 hour repeated window.

    @Test("Google Closure Library relative day label bug on DST fall-back")
    func closureLibraryDSTBug() {
        let gen = #gen(
            .date(between: Self.fallBackRange, interval: .hours(1), timeZone: Self.usEastern),
            .date(between: Self.fallBackRange, interval: .hours(1), timeZone: Self.usEastern),
        )

        // The specific Closure Library bug: two dates on the SAME calendar day
        // where the buggy formula says "tomorrow" instead of "today".
        let counterExample = #exhaust(gen, .suppressIssueReporting) { now, target in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = Self.usEastern

            let startOfNow = calendar.startOfDay(for: now)
            let startOfTarget = calendar.startOfDay(for: target)
            let correctDayDiff = calendar.dateComponents([.day], from: startOfNow, to: startOfTarget).day!
            guard correctDayDiff == 0 else { return true }

            // BUG: assumes every day is exactly 86400 seconds from midnight
            let buggyDayDiff = Int(floor(target.timeIntervalSince(startOfNow) / 86400))
            return buggyDayDiff == 0
        }

        #expect(counterExample != nil, "Expected boundary analysis to find the 1-hour-per-year DST bug")
    }

    @Test("Random testing alone misses the same-day misclassification")
    func closureLibraryDSTBugRandomOnly() {
        let gen = #gen(
            .date(between: Self.fallBackRange, interval: .hours(1), timeZone: Self.usEastern),
            .date(between: Self.fallBackRange, interval: .hours(1), timeZone: Self.usEastern),
        )

        // The specific Closure Library bug: two dates on the SAME calendar day
        // where the buggy formula says "tomorrow" (dayDiff=1) instead of "today"
        // (dayDiff=0). This only happens on a fall-back day when target is in the
        // 25th hour (>24h from midnight but still the same calendar day).
        //
        // With .randomOnly, hitting this requires BOTH dates to land on the
        // fall-back day's ~1h window — roughly (1/672)^2 ≈ 0.0002% per sample.
        let counterExample = #exhaust(gen, .suppressIssueReporting, .randomOnly, .samplingBudget(200)) { now, target in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = Self.usEastern

            // Only test same-calendar-day pairs
            let startOfNow = calendar.startOfDay(for: now)
            let startOfTarget = calendar.startOfDay(for: target)
            let correctDayDiff = calendar.dateComponents([.day], from: startOfNow, to: startOfTarget).day!
            guard correctDayDiff == 0 else { return true } // skip cross-day pairs

            // BUG: assumes every day is exactly 86400 seconds from midnight
            let buggyDayDiff = Int(floor(target.timeIntervalSince(startOfNow) / 86400))
            return buggyDayDiff == 0
        }

        #expect(counterExample == nil, "Random testing should not find this needle-in-a-haystack bug")
    }

    // MARK: - iOS DST Alarm Bug (2010/2011)

    // In late 2010 and early 2011, a bug in Apple's iOS caused recurring alarms
    // to fire an hour late (or early) when countries transitioned into or out of
    // Daylight Saving Time. The alarm app computed "tomorrow at the same time"
    // by adding 86400 seconds to the current fire date, instead of using Calendar
    // to advance by one day. On a 23-hour spring-forward day, the alarm fires
    // 1 hour late; on a 25-hour fall-back day, it fires 1 hour early.
    //
    // Millions of people in Europe, Australia, and the US were late to work.
    //
    // Fix: use Calendar.date(byAdding: .day, value: 1, to:) instead of + 86400.

    static let auSydney = TimeZone(identifier: "Australia/Sydney")!

    // AU fall back 2024: April 6 at 16:00 UTC (3:00 AM AEDT → 2:00 AM AEST)
    static let auFallBack2024 = Date(timeIntervalSinceReferenceDate: 734_112_000)
    static let auFallBackRange = auFallBack2024.addingTimeInterval(-14 * 86400)
        ... auFallBack2024.addingTimeInterval(14 * 86400)

    // AU spring forward 2024: October 5 at 16:00 UTC (2:00 AM AEST → 3:00 AM AEDT)
    static let auSpringForward2024 = Date(timeIntervalSinceReferenceDate: 749_836_800)
    static let auSpringForwardRange = auSpringForward2024.addingTimeInterval(-14 * 86400)
        ... auSpringForward2024.addingTimeInterval(14 * 86400)

    @Test("iOS recurring alarm fires at wrong hour across AU spring-forward DST")
    func iOSAlarmBugSpringForward() {
        let gen = #gen(.date(between: Self.auSpringForwardRange, interval: .hours(1), timeZone: Self.auSydney))

        let counterExample = #exhaust(gen, .suppressIssueReporting) { alarmTime in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = Self.auSydney

            // BUG: compute next occurrence by adding exactly 86400 seconds
            let buggyNextAlarm = alarmTime.addingTimeInterval(86400)

            // Correct: advance by 1 calendar day
            guard let correctNextAlarm = calendar.date(byAdding: .day, value: 1, to: alarmTime) else {
                return true
            }

            // Property: the alarm should fire at the same wall-clock hour
            let buggyHour = calendar.component(.hour, from: buggyNextAlarm)
            let correctHour = calendar.component(.hour, from: correctNextAlarm)
            return buggyHour == correctHour
        }

        #expect(counterExample != nil, "Expected boundary analysis to find the iOS alarm DST bug (spring forward)")
    }

    @Test("iOS recurring alarm fires at wrong hour across AU fall-back DST")
    func iOSAlarmBugFallBack() {
        let gen = #gen(.date(between: Self.auFallBackRange, interval: .hours(1), timeZone: Self.auSydney))

        let counterExample = #exhaust(gen, .suppressIssueReporting) { alarmTime in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = Self.auSydney

            // BUG: compute next occurrence by adding exactly 86400 seconds
            let buggyNextAlarm = alarmTime.addingTimeInterval(86400)

            // Correct: advance by 1 calendar day
            guard let correctNextAlarm = calendar.date(byAdding: .day, value: 1, to: alarmTime) else {
                return true
            }

            // Property: the alarm should fire at the same wall-clock hour
            let buggyHour = calendar.component(.hour, from: buggyNextAlarm)
            let correctHour = calendar.component(.hour, from: correctNextAlarm)
            return buggyHour == correctHour
        }

        #expect(counterExample != nil, "Expected boundary analysis to find the iOS alarm DST bug (fall back)")
    }

    // MARK: - Bug: "This date doesn't exist"

    // https://www.linkedin.com/posts/activity-7386650870408560640-HGt1
    // DateFormatter defaults to 00:00 when no time is given. In timezones that
    // spring forward at midnight (Cuba, Chile, Egypt), midnight never happens on
    // the transition day — so DateFormatter.date(from:) returns nil for a
    // perfectly valid calendar date.
    //
    // Fix: set formatter.isLenient = true

    /// Timezones that spring forward at midnight — midnight itself doesn't
    /// exist on the transition day.
    static let midnightTransitionZones: [TimeZone] = [
        TimeZone(identifier: "America/Havana")!,
        TimeZone(identifier: "America/Santiago")!,
        TimeZone(identifier: "Africa/Cairo")!,
    ]

    /// Full year 2024 — Cuba's spring forward (March 10) is 1 day out of 366
    static let yearRange2024 = Date(timeIntervalSinceReferenceDate: 725_760_000) // 2024-01-01
        ... Date(timeIntervalSinceReferenceDate: 725_760_000 + 86400 * 366) // 2025-01-01

    @Test("DateFormatter returns nil for valid calendar dates where midnight doesn't exist")
    func dateFormatterMidnightBug() {
        let havana = TimeZone(identifier: "America/Havana")!
        let gen = #gen(.date(between: Self.yearRange2024, interval: .hours(1), timeZone: havana))

        let buggyFormatter = DateFormatter()
        buggyFormatter.dateFormat = "yyyy-MM-dd"
        buggyFormatter.timeZone = TimeZone(identifier: "America/Havana")!
        buggyFormatter.isLenient = false

        let counterExample = #exhaust(gen, .suppressIssueReporting) { date in
            // Format as date-only string, then parse back — the round-trip
            let dateString = buggyFormatter.string(from: date)
            let parsed = buggyFormatter.date(from: dateString)

            // Property: parsing a formatted date should always succeed
            return parsed != nil
        }

        #expect(counterExample != nil, "Expected boundary analysis to find a date where midnight doesn't exist")
    }
}
