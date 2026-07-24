//
//  DateGeneratorTests.swift
//  Exhaust
//

import Exhaust
import Foundation
import Testing

@Suite("Date Generator")
struct DateGeneratorTests {
    // MARK: - Fixed reference dates for deterministic tests

    static let epoch = Date(timeIntervalSinceReferenceDate: 0)
    static let jan1_2025 = Date(timeIntervalSinceReferenceDate: 757_382_400) // 2025-01-01 00:00:00 UTC

    // MARK: - date(between:interval:)

    @Suite("date(between:interval:)")
    struct BetweenStride {
        @Test("Generates dates within the specified range")
        func generatesDatesWithinTheSpecifiedRange() throws {
            let lower = DateGeneratorTests.epoch
            let upper = lower.addingTimeInterval(86400 * 30) // 30 days
            let gen = #gen(.date(between: lower ... upper, interval: .days(1)))
            let dates = try #example(gen, count: 20, seed: 42)

            for date in dates {
                #expect(date >= lower)
                #expect(date <= upper)
            }
        }

        @Test("Dates are quantized to stride intervals")
        func datesAreQuantizedToStrideIntervals() throws {
            let lower = DateGeneratorTests.epoch
            let upper = lower.addingTimeInterval(86400 * 7) // 7 days
            let gen = #gen(.date(between: lower ... upper, interval: .hours(1)))
            let dates = try #example(gen, count: 20, seed: 42)

            for date in dates {
                let offset = date.timeIntervalSinceReferenceDate - lower.timeIntervalSinceReferenceDate
                #expect(offset.truncatingRemainder(dividingBy: 3600) == 0)
            }
        }

        @Test("Stride of seconds produces integral-second dates")
        func strideOfSecondsProducesIntegralSecondDates() throws {
            let lower = DateGeneratorTests.epoch
            let upper = lower.addingTimeInterval(3600) // 1 hour
            let gen = #gen(.date(between: lower ... upper, interval: .seconds(1)))
            let date = try #example(gen, seed: 42)

            let ti = date.timeIntervalSinceReferenceDate
            #expect(ti == ti.rounded(.down))
        }

        @Test("Deterministic: same seed produces same dates")
        func deterministicSameSeedProducesSameDates() throws {
            let lower = DateGeneratorTests.epoch
            let upper = lower.addingTimeInterval(86400 * 365)
            let gen = #gen(.date(between: lower ... upper, interval: .days(1)))

            let dates1 = try #example(gen, count: 10, seed: 99)
            let dates2 = try #example(gen, count: 10, seed: 99)
            #expect(dates1 == dates2)
        }

        @Test("Week stride covers expected range")
        func weekStrideCoversExpectedRange() throws {
            let lower = DateGeneratorTests.jan1_2025
            let upper = lower.addingTimeInterval(86400 * 365) // ~1 year
            let gen = #gen(.date(between: lower ... upper, interval: .weeks(1)))
            let date = try #example(gen, seed: 7)

            let offset = date.timeIntervalSince(lower)
            #expect(offset.truncatingRemainder(dividingBy: 604_800) == 0)
        }
    }

    // MARK: - date(within:of:interval:)

    @Suite("date(within:of:interval:)")
    struct WithinSpan {
        @Test("Generates dates within fixed-length span of anchor")
        func generatesDatesWithinFixedLengthSpanOfAnchor() throws {
            let anchor = DateGeneratorTests.jan1_2025
            let gen = #gen(.date(within: .days(30), of: anchor, interval: .hours(1)))
            let dates = try #example(gen, count: 20, seed: 42)

            let expectedLower = anchor.addingTimeInterval(-86400 * 30)
            let expectedUpper = anchor.addingTimeInterval(86400 * 30)

            for date in dates {
                #expect(date >= expectedLower)
                #expect(date <= expectedUpper)
            }
        }

        @Test("Month span produces valid calendar-month range")
        func monthSpanProducesValidCalendarMonthRange() throws {
            let anchor = DateGeneratorTests.jan1_2025
            let gen = #gen(.date(within: .months(6), of: anchor, interval: .days(1)))
            let dates = try #example(gen, count: 20, seed: 42)

            let expectedLower = utcGregorianCalendar.date(byAdding: .month, value: -6, to: anchor)!
            let expectedUpper = utcGregorianCalendar.date(byAdding: .month, value: 6, to: anchor)!

            for date in dates {
                #expect(date >= expectedLower)
                #expect(date <= expectedUpper)
            }
        }

        @Test("Year span produces valid calendar-year range")
        func yearSpanProducesValidCalendarYearRange() throws {
            let anchor = DateGeneratorTests.jan1_2025
            let gen = #gen(.date(within: .years(1), of: anchor, interval: .days(1)))
            let dates = try #example(gen, count: 20, seed: 42)

            let expectedLower = utcGregorianCalendar.date(byAdding: .year, value: -1, to: anchor)!
            let expectedUpper = utcGregorianCalendar.date(byAdding: .year, value: 1, to: anchor)!

            for date in dates {
                #expect(date >= expectedLower)
                #expect(date <= expectedUpper)
            }
        }
    }

    // MARK: - date(within: ClosedRange<DateStride>, of:interval:)

    @Suite("date(within: ClosedRange<DateStride>, of:interval:)")
    struct WithinSpanRange {
        @Test("Asymmetric span produces correct bounds")
        func asymmetricSpanProducesCorrectBounds() throws {
            let anchor = DateGeneratorTests.jan1_2025
            let gen = #gen(.date(within: .days(-7) ... .days(30), of: anchor, interval: .hours(1)))
            let dates = try #example(gen, count: 20, seed: 42)

            let expectedLower = anchor.addingTimeInterval(-86400 * 7)
            let expectedUpper = anchor.addingTimeInterval(86400 * 30)

            for date in dates {
                #expect(date >= expectedLower)
                #expect(date <= expectedUpper)
            }
        }

        @Test("Past-only range (both bounds negative)")
        func pastOnlyRangeBothBoundsNegative() throws {
            let anchor = DateGeneratorTests.jan1_2025
            let gen = #gen(.date(within: .days(-30) ... .days(-1), of: anchor, interval: .hours(1)))
            let dates = try #example(gen, count: 20, seed: 42)

            let expectedLower = anchor.addingTimeInterval(-86400 * 30)
            let expectedUpper = anchor.addingTimeInterval(-86400)

            for date in dates {
                #expect(date >= expectedLower)
                #expect(date <= expectedUpper)
            }
        }

        @Test("Mixed units in range bounds")
        func mixedUnitsInRangeBounds() throws {
            let anchor = DateGeneratorTests.jan1_2025
            let gen = #gen(.date(within: .hours(-12) ... .weeks(2), of: anchor, interval: .minutes(30)))
            let dates = try #example(gen, count: 20, seed: 42)

            let expectedLower = anchor.addingTimeInterval(-12 * 3600)
            let expectedUpper = anchor.addingTimeInterval(2 * 604_800)

            for date in dates {
                #expect(date >= expectedLower)
                #expect(date <= expectedUpper)
            }
        }

        @Test("Dates are quantized to interval")
        func datesAreQuantizedToInterval() throws {
            let anchor = DateGeneratorTests.epoch
            let gen = #gen(.date(within: .days(-10) ... .days(10), of: anchor, interval: .hours(6)))
            let dates = try #example(gen, count: 20, seed: 42)

            let lowerSeconds = anchor.addingTimeInterval(-86400 * 10).timeIntervalSinceReferenceDate

            for date in dates {
                let offset = date.timeIntervalSinceReferenceDate - lowerSeconds
                #expect(offset.truncatingRemainder(dividingBy: 6 * 3600) == 0)
            }
        }
    }

    // MARK: - Shrinking

    @Suite("Shrinking")
    struct ShrinkingTests {
        @Test("Shrinks to boundary: date before noon")
        func shrinksToBoundaryDateBeforeNoon() throws {
            // Range: Jan 1 – Jan 31 2025, hourly intervals
            let lower = DateGeneratorTests.jan1_2025
            let upper = lower.addingTimeInterval(86400 * 30)
            let gen = #gen(.date(between: lower ... upper, interval: .hours(1)))

            // Cutoff: noon on Jan 15
            let cutoff = lower.addingTimeInterval(86400 * 14 + 3600 * 12)

            let output = try #require(
                #exhaust(gen, .suppress(.issueReporting)) { date in date < cutoff }
            )

            // Should shrink to exactly the cutoff (first failing hour)
            #expect(output == cutoff)
            // Verify it's still on an hourly boundary
            let offset = output.timeIntervalSince(lower)
            #expect(offset.truncatingRemainder(dividingBy: 3600) == 0)
        }

        @Test("Shrinks to boundary: date after a threshold")
        func shrinksToBoundaryDateAfterAThreshold() throws {
            // Range: full year 2025, daily intervals
            let lower = DateGeneratorTests.jan1_2025
            let upper = lower.addingTimeInterval(86400 * 365)
            let gen = #gen(.date(between: lower ... upper, interval: .days(1)))

            // Property: date must be in the first 100 days
            let threshold = lower.addingTimeInterval(86400 * 100)

            let output = try #require(
                #exhaust(gen, .suppress(.issueReporting)) { date in date < threshold }
            )

            // Should shrink to exactly the threshold (first failing day)
            #expect(output == threshold)
        }
    }

    // MARK: - Calendar Grids

    @Suite("Calendar Grids")
    struct CalendarGridTests {
        @Test("Monthly grid stays on the anchor's day-of-month")
        func monthlyGridStaysOnAnchorDayOfMonth() throws {
            let lower = date(year: 2024, month: 1, day: 15)
            let upper = date(year: 2026, month: 1, day: 15)
            let gen = #gen(.date(between: lower ... upper, interval: .months(1)))
            let dates = try #example(gen, count: 30, seed: 42)

            for generated in dates {
                let components = utcGregorianCalendar.dateComponents([.day, .hour, .minute, .second], from: generated)
                #expect(components.day == 15)
                #expect(components.hour == 0)
                #expect(components.minute == 0)
                #expect(components.second == 0)
            }
        }

        @Test("Yearly grid stays on the anchor's calendar date across leap years")
        func yearlyGridStaysOnAnchorCalendarDateAcrossLeapYears() throws {
            let lower = date(year: 2020, month: 1, day: 1)
            let upper = date(year: 2030, month: 1, day: 1)
            let gen = #gen(.date(between: lower ... upper, interval: .years(1)))
            let dates = try #example(gen, count: 30, seed: 42)

            for generated in dates {
                let components = utcGregorianCalendar.dateComponents([.month, .day, .hour], from: generated)
                #expect(components.month == 1)
                #expect(components.day == 1)
                #expect(components.hour == 0)
            }
        }

        @Test("Daily grid keeps wall-clock time across a DST transition")
        func dailyGridKeepsWallClockTimeAcrossDSTTransition() throws {
            let newYork = TimeZone(identifier: "America/New_York")!
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = newYork

            // March 2024 contains the US spring-forward on March 10.
            let lower = calendar.date(from: DateComponents(year: 2024, month: 3, day: 1, hour: 9))!
            let upper = calendar.date(from: DateComponents(year: 2024, month: 3, day: 31, hour: 9))!
            let gen = #gen(.date(between: lower ... upper, interval: .days(1), timeZone: newYork))
            let dates = try #example(gen, count: 30, seed: 42)

            for generated in dates {
                let components = calendar.dateComponents([.hour, .minute], from: generated)
                #expect(components.hour == 9)
                #expect(components.minute == 0)
            }
        }

        @Test("Monthly grid from a month-end anchor clamps to short months")
        func monthlyGridFromMonthEndAnchorClampsToShortMonths() throws {
            let lower = date(year: 2025, month: 1, day: 31)
            let upper = date(year: 2025, month: 12, day: 31)
            let gen = #gen(.date(between: lower ... upper, interval: .months(1)))
            let dates = try #example(gen, count: 30, seed: 42)

            for generated in dates {
                let components = utcGregorianCalendar.dateComponents([.day], from: generated)
                let lastDayOfMonth = utcGregorianCalendar.range(of: .day, in: .month, for: generated)!.upperBound - 1
                let day = components.day!
                #expect(day == 31 || day == lastDayOfMonth)
            }
        }

        @Test("Calendar grid reflection round-trips through forward")
        func calendarGridReflectionRoundTripsThroughForward() {
            let lower = date(year: 2024, month: 1, day: 31)
            let upper = date(year: 2026, month: 12, day: 31)
            let gen = #gen(.date(between: lower ... upper, interval: .months(1)))
            #expect(#examine(gen, .samples(20), .replay(42)).passed)
        }

        @Test("Off-grid date reflection snaps to the previous month step")
        func offGridDateReflectionSnapsToThePreviousMonthStep() throws {
            let lower = date(year: 2025, month: 1, day: 15)
            let upper = date(year: 2026, month: 1, day: 15)
            let gen = #gen(.date(between: lower ... upper, interval: .months(1)))

            let offGrid = date(year: 2025, month: 2, day: 20)
            let expectedSnap = date(year: 2025, month: 2, day: 15)

            let tree = try #require(try Interpreters.reflect(gen.gen, with: offGrid))
            let replayed = try #require(try Interpreters.replay(gen.gen, using: tree))
            #expect(replayed == expectedSnap)
        }

        private func date(year: Int, month: Int, day: Int) -> Date {
            utcGregorianCalendar.date(from: DateComponents(year: year, month: month, day: day))!
        }
    }

    // MARK: - DateStride

    @Suite("DateStride")
    struct DateStrideTests {
        @Test("Fixed spans convert to correct seconds", arguments: [
            (DateStride.seconds(1), 1),
            (DateStride.minutes(1), 60),
            (DateStride.hours(1), 3600),
            (DateStride.days(1), 86400),
            (DateStride.weeks(1), 604_800),
            (DateStride.minutes(5), 300),
            (DateStride.hours(24), 86400),
            (DateStride.days(7), 604_800),
            (DateStride.months(1), 2_592_000),
            (DateStride.years(1), 31_536_000),
        ])
        func fixedSpansConvertToCorrectSeconds(span: DateStride, expectedSeconds: Int) {
            #expect(span.fixedSeconds == expectedSeconds)
        }
    }

    // MARK: - Reflection (backward mapping)

    @Suite("Reflection")
    struct ReflectionTests {
        @Test("Backward mapping round-trips through forward")
        func backwardMappingRoundTripsThroughForward() {
            let lower = DateGeneratorTests.epoch
            let upper = lower.addingTimeInterval(86400 * 365)
            let gen = #gen(.date(between: lower ... upper, interval: .hours(1)))
            #expect(#examine(gen, .samples(20), .replay(42)).passed)
        }

        @Test("Off-grid date reflection snaps to nearest earlier grid point")
        func offGridDateReflectionSnapsToNearestEarlierGridPoint() throws {
            let lower = DateGeneratorTests.epoch
            let upper = lower.addingTimeInterval(86400)
            let gen = #gen(.date(between: lower ... upper, interval: .hours(1)))

            let offGrid = lower.addingTimeInterval(10.5 * 3600)
            let expectedSnap = lower.addingTimeInterval(10 * 3600)

            let tree = try #require(try Interpreters.reflect(gen.gen, with: offGrid))
            let replayed = try #require(try Interpreters.replay(gen.gen, using: tree))
            #expect(replayed == expectedSnap)
        }

        @Test("On-grid date reflection round-trips correctly")
        func onGridDateReflectionRoundTripsCorrectly() throws {
            let lower = DateGeneratorTests.epoch
            let upper = lower.addingTimeInterval(86400)
            let gen = #gen(.date(between: lower ... upper, interval: .hours(1)))

            let onGrid = lower.addingTimeInterval(10 * 3600)

            let tree = try #require(try Interpreters.reflect(gen.gen, with: onGrid))
            let replayed = try #require(try Interpreters.replay(gen.gen, using: tree))
            #expect(replayed == onGrid)
        }
    }
}

// MARK: - Helpers

/// Gregorian calendar pinned to UTC, matching the date generator's default zone.
private let utcGregorianCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()
