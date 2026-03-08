//
//  BoundaryDomainAnalysisTests.swift
//  Exhaust
//

import Foundation
import Testing
@testable import ExhaustCore

// MARK: - Boundary Domain Analysis

@Suite("Boundary Domain Analysis")
struct BoundaryDomainAnalysisTests {
    @Test("Int explicit full range produces boundary profile with boundary values")
    func intExplicitFullRange() {
        let gen = Gen.choose(in: Int.min ... Int.max)
        let profile = analyzeBoundary(gen)
        #expect(profile != nil)
        #expect(profile?.parameters.count == 1)
        let values = profile?.parameters[0].values ?? []
        #expect(values.count >= 4)
        #expect(values.count <= 6)
    }

    @Test("Size-scaled rangeless int returns nil (getSize rejected)")
    func rangelessIntReturnsNil() {
        let gen = Gen.choose(in: Int.min ... Int.max, scaling: Int.defaultScaling)
        let result = ChoiceTreeAnalysis.analyze(gen)
        #expect(result == nil)
    }

    @Test("Int in 0...1000 produces boundary profile with 5 values")
    func intBoundedRange() {
        let gen = Gen.choose(in: 0 ... 1000)
        let profile = analyzeBoundary(gen)
        #expect(profile != nil)
        #expect(profile?.parameters.count == 1)

        let values = profile?.parameters[0].values ?? []
        let zeroBP = Int(0).bitPattern64
        let oneBP = Int(1).bitPattern64
        let fiveHundredBP = Int(500).bitPattern64
        let nineNineNineBP = Int(999).bitPattern64
        let thousandBP = Int(1000).bitPattern64

        #expect(values.contains(zeroBP))
        #expect(values.contains(oneBP))
        #expect(values.contains(fiveHundredBP))
        #expect(values.contains(nineNineNineBP))
        #expect(values.contains(thousandBP))
    }

    @Test("Small int range falls back to finite")
    func smallRangeIsFinite() {
        let gen = Gen.choose(in: 0 ... 4)
        // Small range should be classified as finite, not boundary
        guard case let .finite(profile) = ChoiceTreeAnalysis.analyze(gen) else {
            Issue.record("Expected .finite result for small range")
            return
        }
        #expect(profile.parameters.count == 1)
        #expect(profile.parameters[0].domainSize == 5)
    }

    @Test("Zip of boundary-analyzable generators produces concatenated parameters")
    func zipAnalysis() {
        let gen = Gen.zip(Gen.choose(in: 0 ... 10000), Gen.choose(in: 0 ... 10000))
        let profile = analyzeBoundary(gen)
        #expect(profile != nil)
        #expect(profile?.parameters.count == 2)
    }

    @Test("Int array with constant-scaling length produces boundary profile")
    func intArrayWithLength() {
        let gen = Gen.arrayOf(Gen.choose(in: 0 ... 1000), within: 0 ... 10, scaling: .constant)
        let profile = analyzeBoundary(gen)
        #expect(profile != nil)
        // length param + up to 2 element params
        #expect(profile!.parameters.count >= 2)
        #expect(profile!.parameters.count <= 3)

        // Check length parameter
        if let lengthParam = profile?.parameters[0] {
            if case .sequenceLength = lengthParam.kind {
                #expect(lengthParam.values.contains(0))
                #expect(lengthParam.values.contains(1))
                #expect(lengthParam.values.contains(2))
            } else {
                Issue.record("Expected sequenceLength parameter")
            }
        }
    }

    @Test("Int array with size-scaled length returns nil (getSize rejected)")
    func sizeScaledArrayReturnsNil() {
        let gen = Gen.arrayOf(Gen.choose(in: 0 ... 1000), within: 0 ... 10)
        let result = ChoiceTreeAnalysis.analyze(gen)
        #expect(result == nil)
    }

    @Test("Generator with too many parameters returns nil")
    func tooManyParametersReturnsNil() {
        let gen = Gen.zip(
            Gen.choose(in: 0 ... 10000),
            Gen.choose(in: 0 ... 10000),
            Gen.choose(in: 0 ... 10000),
            Gen.choose(in: 0 ... 10000),
            Gen.choose(in: 0 ... 10000),
            Gen.choose(in: 0 ... 10000),
            Gen.choose(in: 0 ... 10000),
            Gen.choose(in: 0 ... 10000),
            Gen.choose(in: 0 ... 10000),
            Gen.choose(in: 0 ... 10000),
            Gen.choose(in: 0 ... 10000),
            Gen.choose(in: 0 ... 10000),
            Gen.choose(in: 0 ... 10000),
            Gen.choose(in: 0 ... 10000),
            Gen.choose(in: 0 ... 10000),
            Gen.choose(in: 0 ... 10000),
            Gen.choose(in: 0 ... 10000),
            Gen.choose(in: 0 ... 10000),
            Gen.choose(in: 0 ... 10000),
            Gen.choose(in: 0 ... 10000),
            Gen.choose(in: 0 ... 10000),
        )
        let result = ChoiceTreeAnalysis.analyze(gen)
        #expect(result == nil)
    }

    @Test("Finite-domain generator returns finite result")
    func finiteReturnsFinite() {
        let gen = Gen.zip(Gen.choose(from: [true, false]), Gen.choose(from: [true, false]))
        guard case let .finite(profile) = ChoiceTreeAnalysis.analyze(gen) else {
            Issue.record("Expected .finite result")
            return
        }
        #expect(profile.parameters.count == 2)
        #expect(profile.parameters[0].domainSize == 2)
        #expect(profile.parameters[1].domainSize == 2)
    }

    @Test("Non-analyzable generator returns nil")
    func nonAnalyzableReturnsNil() {
        let gen = asciiStringGen(length: 1 ... 5)
        let result = ChoiceTreeAnalysis.analyze(gen)
        #expect(result == nil)
    }
}

// MARK: - Boundary Covering Array Replay

@Suite("Boundary Covering Array Replay")
struct BoundaryCoveringArrayReplayTests {
    @Test("Replay of boundary row produces valid value for large int range")
    func replayLargeIntRange() throws {
        let gen = Gen.zip(Gen.choose(in: 0 ... 10000), Gen.choose(in: 0 ... 10000))
        let profile = try #require(analyzeBoundary(gen))
        let covering = try #require(CoveringArray.bestFitting(budget: 100, boundaryProfile: profile))

        var replayedCount = 0
        for row in covering.rows {
            guard let tree = BoundaryCoveringArrayReplay.buildTree(row: row, profile: profile) else {
                continue
            }
            let value: (Int, Int)? = try Interpreters.replay(gen, using: tree)
            if value != nil {
                replayedCount += 1
            }
        }
        #expect(replayedCount > 0)
    }

    @Test("Boundary replay includes actual boundary values")
    func boundaryValuesAppear() throws {
        let gen = Gen.zip(Gen.choose(in: 0 ... 10000), Gen.choose(in: 0 ... 10000))
        let profile = try #require(analyzeBoundary(gen))
        let covering = try #require(CoveringArray.bestFitting(budget: 100, boundaryProfile: profile))

        var seenValues: Set<Int> = []
        for row in covering.rows {
            guard let tree = BoundaryCoveringArrayReplay.buildTree(row: row, profile: profile) else {
                continue
            }
            if let (a, b): (Int, Int) = try Interpreters.replay(gen, using: tree) {
                seenValues.insert(a)
                seenValues.insert(b)
            }
        }

        // Should have boundary values 0, 1, 5000, 9999, 10000
        #expect(seenValues.contains(0))
        #expect(seenValues.contains(10000))
    }
}

// MARK: - ChoiceTree Analysis

@Suite("ChoiceTree Analysis")
struct ChoiceTreeAnalysisTests {
    @Test("Finite generators return .finite result")
    func finiteResult() {
        let gen = Gen.zip(Gen.choose(from: [true, false]), Gen.choose(from: [true, false]))
        let result = ChoiceTreeAnalysis.analyze(gen)
        guard case let .finite(profile) = result else {
            Issue.record("Expected .finite result")
            return
        }
        #expect(profile.parameters.count == 2)
        #expect(profile.parameters[0].domainSize == 2)
        #expect(profile.parameters[1].domainSize == 2)
        #expect(profile.totalSpace == 4)
    }

    @Test("Large-range generators return .boundary result")
    func boundaryResult() {
        let gen = Gen.choose(in: 0 ... 10000)
        let result = ChoiceTreeAnalysis.analyze(gen)
        guard case let .boundary(profile) = result else {
            Issue.record("Expected .boundary result")
            return
        }
        #expect(profile.parameters.count == 1)
        #expect(profile.parameters[0].values.count >= 4)
    }

    @Test("Size-scaled generator returns nil")
    func sizeScaledReturnsNil() {
        let gen = Gen.choose(in: Int.min ... Int.max, scaling: Int.defaultScaling)
        let result = ChoiceTreeAnalysis.analyze(gen)
        #expect(result == nil)
    }

    @Test("Mixed finite and boundary returns .boundary")
    func mixedReturnsBoundary() {
        let gen = Gen.zip(Gen.choose(from: [true, false]), Gen.choose(in: 0 ... 10000))
        let result = ChoiceTreeAnalysis.analyze(gen)
        guard case let .boundary(profile) = result else {
            Issue.record("Expected .boundary result")
            return
        }
        #expect(profile.parameters.count == 2)
    }

    @Test("Bind chain is analyzed correctly")
    func bindChainAnalysis() {
        // This bind chain is NOT analyzable by the recursive walker because
        // analyzeContinuation rejects .impure continuations. But the ChoiceTree
        // walker sees through it because VACTI evaluates the full chain.
        let gen: ReflectiveGenerator<(UInt8, UInt8)> = Gen.choose(in: 0 ... 10 as ClosedRange<UInt8>)
            ._bind { _ in
                Gen.choose(in: 0 ... 20 as ClosedRange<UInt8>)._map { y in y }
            }
            ._bind { y in
                Gen.choose(in: 0 ... 10 as ClosedRange<UInt8>)._map { x in (x, y) }
            }

        let newResult = ChoiceTreeAnalysis.analyze(gen)
        guard case let .finite(profile) = newResult else {
            Issue.record("Expected .finite result for bind chain")
            return
        }
        // Should find 3 parameters: the three chooseBits operations
        #expect(profile.parameters.count == 3)
    }

    @Test("Sequence with constant scaling is analyzed")
    func sequenceAnalysis() {
        let gen = Gen.arrayOf(Gen.choose(in: 0 ... 1000), within: 0 ... 10, scaling: .constant)
        let result = ChoiceTreeAnalysis.analyze(gen)
        guard case .boundary = result else {
            Issue.record("Expected .boundary result for sequence with large elements")
            return
        }
    }

    @Test("Sequence with size-scaled length returns nil")
    func sizeScaledSequenceReturnsNil() {
        let gen = Gen.arrayOf(Gen.choose(in: 0 ... 1000), within: 0 ... 10)
        let result = ChoiceTreeAnalysis.analyze(gen)
        #expect(result == nil)
    }

    @Test("Too many parameters returns nil")
    func tooManyParametersReturnsNil() {
        let gen = Gen.zip(
            Gen.choose(in: 0 ... 10000), Gen.choose(in: 0 ... 10000), Gen.choose(in: 0 ... 10000),
            Gen.choose(in: 0 ... 10000), Gen.choose(in: 0 ... 10000), Gen.choose(in: 0 ... 10000),
            Gen.choose(in: 0 ... 10000), Gen.choose(in: 0 ... 10000), Gen.choose(in: 0 ... 10000),
            Gen.choose(in: 0 ... 10000), Gen.choose(in: 0 ... 10000), Gen.choose(in: 0 ... 10000),
            Gen.choose(in: 0 ... 10000), Gen.choose(in: 0 ... 10000), Gen.choose(in: 0 ... 10000),
            Gen.choose(in: 0 ... 10000), Gen.choose(in: 0 ... 10000), Gen.choose(in: 0 ... 10000),
            Gen.choose(in: 0 ... 10000), Gen.choose(in: 0 ... 10000), Gen.choose(in: 0 ... 10000),
        )
        let result = ChoiceTreeAnalysis.analyze(gen)
        #expect(result == nil)
    }
}

// MARK: - Date Boundary Values

@Suite("Date Boundary Values")
struct DateBoundaryValueTests {
    @Test("Step-domain edges and midpoint are present")
    func stepDomainBoundaries() {
        // Range: 1000 seconds, interval: 100 seconds → 10 steps
        let lower: Int64 = 725_760_000 // 2024-01-01
        let upper: Int64 = lower + 1000
        let interval: Int64 = 100

        let values = BoundaryDomainAnalysis.computeBoundaryValues(
            min: lower.bitPattern64,
            max: upper.bitPattern64,
            tag: .date(intervalSeconds: interval, timeZoneID: "GMT"),
        )

        // First step
        #expect(values.contains(lower.bitPattern64))
        // Last aligned step (1000 / 100 * 100 = 1000)
        #expect(values.contains(upper.bitPattern64))
        // Second step
        #expect(values.contains((lower + interval).bitPattern64))
        // Second-to-last step
        #expect(values.contains((upper - interval).bitPattern64))
        // Midpoint step (step 5 → lower + 500)
        #expect(values.contains((lower + 500).bitPattern64))
    }

    @Test("Values are snapped to interval (no off-grid values)")
    func valuesAreSnapped() {
        let lower: Int64 = 0
        let upper: Int64 = 86400 * 365 // 1 year
        let interval: Int64 = 3600 // 1 hour

        let values = BoundaryDomainAnalysis.computeBoundaryValues(
            min: lower.bitPattern64,
            max: upper.bitPattern64,
            tag: .date(intervalSeconds: interval, timeZoneID: "GMT"),
        )

        for bp in values {
            let seconds = Int64(bitPattern64: bp)
            let offset = seconds - lower
            #expect(
                offset >= 0 && offset % interval == 0,
                "Value \(seconds) is not aligned to interval \(interval) from lower \(lower)",
            )
        }
    }

    @Test("Reference date epoch appears when in range")
    func referenceDate() {
        // Range spanning the reference date (0 seconds since ref)
        let lower: Int64 = -86400
        let upper: Int64 = 86400
        let interval: Int64 = 1

        let values = BoundaryDomainAnalysis.computeBoundaryValues(
            min: lower.bitPattern64,
            max: upper.bitPattern64,
            tag: .date(intervalSeconds: interval, timeZoneID: "GMT"),
        )

        #expect(values.contains(Int64(0).bitPattern64))
    }

    @Test("Unix epoch appears when in range")
    func unixEpoch() {
        let unixEpoch: Int64 = -978_307_200
        let lower = unixEpoch - 86400
        let upper = unixEpoch + 86400

        let values = BoundaryDomainAnalysis.computeBoundaryValues(
            min: lower.bitPattern64,
            max: upper.bitPattern64,
            tag: .date(intervalSeconds: 1, timeZoneID: "GMT"),
        )

        #expect(values.contains(unixEpoch.bitPattern64))
    }

    @Test("Epochs outside range are excluded")
    func epochsOutsideRange() {
        // Range entirely in 2024 — Unix epoch (1970) and Y2038 should not appear
        let lower: Int64 = 725_760_000 // ~2024-01-01
        let upper: Int64 = lower + 86400 * 30

        let values = BoundaryDomainAnalysis.computeBoundaryValues(
            min: lower.bitPattern64,
            max: upper.bitPattern64,
            tag: .date(intervalSeconds: 1, timeZoneID: "GMT"),
        )

        let unixEpoch: Int64 = -978_307_200
        let y2038: Int64 = 1_169_176_447
        #expect(!values.contains(unixEpoch.bitPattern64))
        #expect(!values.contains(y2038.bitPattern64))
    }
}

// MARK: - DST Boundary Values

@Suite("Date Boundary Values — DST Transitions")
struct DateDSTBoundaryTests {
    struct DSTCase: Sendable, CustomTestStringConvertible {
        let label: String
        let timeZoneID: String
        let year: Int
        let month: Int
        let day: Int
        let hour: Int
        var testDescription: String {
            label
        }
    }

    // Known DST transitions verified against Foundation Calendar below.
    // US: 2nd Sunday of March (spring), 1st Sunday of November (fall) — post-2007
    // EU: Last Sunday of March (spring), last Sunday of October (fall)
    // AU: 1st Sunday of October (spring), 1st Sunday of April (fall) — Southern Hemisphere
    static let knownTransitions: [DSTCase] = [
        // US Eastern (UTC-5) 2024
        DSTCase(label: "US Eastern spring 2024 (Mar 10, 07:00 UTC)", timeZoneID: "America/New_York", year: 2024, month: 3, day: 10, hour: 7),
        DSTCase(label: "US Eastern fall 2024 (Nov 3, 06:00 UTC)", timeZoneID: "America/New_York", year: 2024, month: 11, day: 3, hour: 6),
        // US Pacific (UTC-8) 2024
        DSTCase(label: "US Pacific spring 2024 (Mar 10, 10:00 UTC)", timeZoneID: "America/Los_Angeles", year: 2024, month: 3, day: 10, hour: 10),
        DSTCase(label: "US Pacific fall 2024 (Nov 3, 09:00 UTC)", timeZoneID: "America/Los_Angeles", year: 2024, month: 11, day: 3, hour: 9),
        // EU 2024
        DSTCase(label: "EU spring 2024 (Mar 31, 01:00 UTC)", timeZoneID: "Europe/London", year: 2024, month: 3, day: 31, hour: 1),
        DSTCase(label: "EU fall 2024 (Oct 27, 01:00 UTC)", timeZoneID: "Europe/London", year: 2024, month: 10, day: 27, hour: 1),
        // AU 2024 — 2:00 AM AEST (UTC+10) = previous day 16:00 UTC
        DSTCase(label: "AU spring 2024 (Oct 5, 16:00 UTC)", timeZoneID: "Australia/Sydney", year: 2024, month: 10, day: 5, hour: 16),
        DSTCase(label: "AU fall 2024 (Apr 6, 16:00 UTC)", timeZoneID: "Australia/Sydney", year: 2024, month: 4, day: 6, hour: 16),
        // US pre-2007: 1st Sunday of April, last Sunday of October
        DSTCase(label: "US Eastern spring 2006 (Apr 2, 07:00 UTC)", timeZoneID: "America/New_York", year: 2006, month: 4, day: 2, hour: 7),
        DSTCase(label: "US Eastern fall 2006 (Oct 29, 06:00 UTC)", timeZoneID: "America/New_York", year: 2006, month: 10, day: 29, hour: 6),
        // Different year to test rule consistency
        DSTCase(label: "EU spring 2025 (Mar 30, 01:00 UTC)", timeZoneID: "Europe/London", year: 2025, month: 3, day: 30, hour: 1),
        DSTCase(label: "EU fall 2025 (Oct 26, 01:00 UTC)", timeZoneID: "Europe/London", year: 2025, month: 10, day: 26, hour: 1),
    ]

    @Test("DST transition appears in boundary values", arguments: knownTransitions)
    func dstTransitionPresent(transition: DSTCase) {
        let calendar = Calendar(identifier: .gregorian)
        let components = DateComponents(
            timeZone: .gmt,
            year: transition.year,
            month: transition.month,
            day: transition.day,
            hour: transition.hour,
        )
        let expectedDate = calendar.date(from: components)!
        let expectedSeconds = Int64(expectedDate.timeIntervalSinceReferenceDate)

        // Range spanning ±7 days around the transition, 1-second interval
        let lower = expectedSeconds - 7 * 86400
        let upper = expectedSeconds + 7 * 86400

        let values = BoundaryDomainAnalysis.computeBoundaryValues(
            min: lower.bitPattern64,
            max: upper.bitPattern64,
            tag: .date(intervalSeconds: 1, timeZoneID: transition.timeZoneID),
        )

        #expect(
            values.contains(expectedSeconds.bitPattern64),
            "\(transition.label): expected \(expectedSeconds) in boundary values",
        )
    }

    @Test("DST neighbors (±1 step) are included", arguments: knownTransitions)
    func dstNeighborsPresent(transition: DSTCase) {
        let calendar = Calendar(identifier: .gregorian)
        let components = DateComponents(
            timeZone: .gmt,
            year: transition.year,
            month: transition.month,
            day: transition.day,
            hour: transition.hour,
        )
        let expectedDate = calendar.date(from: components)!
        let expectedSeconds = Int64(expectedDate.timeIntervalSinceReferenceDate)

        let interval: Int64 = 3600 // 1 hour
        let lower = expectedSeconds - 7 * 86400
        let upper = expectedSeconds + 7 * 86400

        let values = BoundaryDomainAnalysis.computeBoundaryValues(
            min: lower.bitPattern64,
            max: upper.bitPattern64,
            tag: .date(intervalSeconds: interval, timeZoneID: transition.timeZoneID),
        )

        // The snapped transition and at least one neighbor should be present
        let snappedOffset = ((expectedSeconds - lower) / interval) * interval
        let snapped = lower + snappedOffset
        #expect(values.contains(snapped.bitPattern64), "Snapped transition value missing")
        #expect(
            values.contains((snapped + interval).bitPattern64)
                || values.contains((snapped - interval).bitPattern64),
            "At least one neighbor of snapped transition should be present",
        )
    }
}

// MARK: - Opaque Group

@Suite("Opaque Group Coverage Skipping")
struct OpaqueGroupTests {
    @Test("Opaque zip hides its parameters from coverage analysis")
    func opaqueZipHidesParameters() {
        // An opaque zip of 4 floats paired with a non-opaque int parameter.
        // Coverage analysis should see only the int, not the 4 floats.
        let opaqueFloats = Gen.zip(
            Gen.choose(in: Float(0) ... Float(1)),
            Gen.choose(in: Float(0) ... Float(1)),
            Gen.choose(in: Float(0) ... Float(1)),
            Gen.choose(in: Float(0) ... Float(1)),
            isOpaque: true,
        )
        let gen = Gen.zip(
            opaqueFloats._map { $0.0 },
            Gen.choose(in: 0 ... 100),
        )
        guard let result = ChoiceTreeAnalysis.analyze(gen) else {
            Issue.record("Expected analyzable generator")
            return
        }
        switch result {
        case let .finite(profile):
            // Only the int 0...100 should appear
            #expect(profile.parameters.count == 1)
        case let .boundary(profile):
            #expect(profile.parameters.count == 1)
        }
    }

    @Test("getSize inside opaque group does not poison other parameters")
    func getSizeInsideOpaqueDoesNotPoison() {
        // A size-scaled float (uses getSize internally) inside an opaque zip.
        // Without opaque, this would make the whole property unanalyzable.
        let opaqueScaled = Gen.zip(
            Gen.choose() as ReflectiveGenerator<Float>,
            Gen.choose() as ReflectiveGenerator<Float>,
            isOpaque: true,
        )
        let gen = Gen.zip(
            opaqueScaled._map { $0.0 },
            Gen.choose(in: 0 ... 10),
        )
        guard let result = ChoiceTreeAnalysis.analyze(gen) else {
            Issue.record("Expected analyzable generator — opaque should isolate getSize")
            return
        }
        switch result {
        case let .finite(profile):
            // Only the int 0...10 should appear (11 values, finite domain)
            #expect(profile.parameters.count == 1)
            #expect(profile.parameters[0].domainSize == 11)
        case let .boundary(profile):
            #expect(profile.parameters.count == 1)
        }
    }

    @Test("Non-opaque zip still exposes all parameters")
    func nonOpaqueZipExposesAll() {
        let gen = Gen.zip(
            Gen.choose(in: 0 ... 1),
            Gen.choose(in: 0 ... 1),
            Gen.choose(in: 0 ... 1),
        )
        guard case let .finite(profile) = ChoiceTreeAnalysis.analyze(gen) else {
            Issue.record("Expected finite profile")
            return
        }
        #expect(profile.parameters.count == 3)
    }
}

// MARK: - Helpers

private func analyzeBoundary(_ gen: ReflectiveGenerator<some Any>) -> BoundaryDomainProfile? {
    guard case let .boundary(profile) = ChoiceTreeAnalysis.analyze(gen) else { return nil }
    return profile
}

private func asciiStringGen(length: ClosedRange<Int>) -> ReflectiveGenerator<String> {
    var rangeSet = RangeSet<UInt32>()
    rangeSet.insert(contentsOf: 0x0020 ..< 0x007F)
    let asciiSRS = ScalarRangeSet(rangeSet)
    let charGen = Gen.contramap(
        { (char: Character) throws -> Int in
            guard let scalar = char.unicodeScalars.first else {
                throw Interpreters.ReflectionError.couldNotReflectOnSequenceElement(
                    "Character has no scalars",
                )
            }
            return asciiSRS.index(of: scalar)
        },
        Gen.choose(in: 0 ... asciiSRS.scalarCount - 1)
            ._map { Character(asciiSRS.scalar(at: $0)) },
    )
    return Gen.arrayOf(charGen, within: UInt64(length.lowerBound) ... UInt64(length.upperBound))
        ._map { String($0) }
}
