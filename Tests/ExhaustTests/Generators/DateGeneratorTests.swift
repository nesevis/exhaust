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

        @Test("Month span produces valid range (30-day months)")
        func monthSpanProducesValidRange30DayMonths() throws {
            let anchor = DateGeneratorTests.jan1_2025
            let gen = #gen(.date(within: .months(6), of: anchor, interval: .days(1)))
            let dates = try #example(gen, count: 20, seed: 42)

            let offsetSeconds: TimeInterval = 6 * 2_592_000 // 6 * 30 days
            let expectedLower = anchor.addingTimeInterval(-offsetSeconds)
            let expectedUpper = anchor.addingTimeInterval(offsetSeconds)

            for date in dates {
                #expect(date >= expectedLower)
                #expect(date <= expectedUpper)
            }
        }

        @Test("Year span produces valid range (365-day years)")
        func yearSpanProducesValidRange365DayYears() throws {
            let anchor = DateGeneratorTests.jan1_2025
            let gen = #gen(.date(within: .years(1), of: anchor, interval: .days(1)))
            let dates = try #example(gen, count: 20, seed: 42)

            let offsetSeconds: TimeInterval = 31_536_000 // 365 days
            let expectedLower = anchor.addingTimeInterval(-offsetSeconds)
            let expectedUpper = anchor.addingTimeInterval(offsetSeconds)

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
