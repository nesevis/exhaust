//
//  BoundaryDomainAnalysisTests.swift
//  Exhaust
//

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
            Gen.choose(in: 0 ... 10000)
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
            .bind { _ in
                Gen.choose(in: 0 ... 20 as ClosedRange<UInt8>).map { y in y }
            }
            .bind { y in
                Gen.choose(in: 0 ... 10 as ClosedRange<UInt8>).map { x in (x, y) }
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
            Gen.choose(in: 0 ... 10000), Gen.choose(in: 0 ... 10000), Gen.choose(in: 0 ... 10000)
        )
        let result = ChoiceTreeAnalysis.analyze(gen)
        #expect(result == nil)
    }
}

// MARK: - Helpers

private func analyzeBoundary<Output>(_ gen: ReflectiveGenerator<Output>) -> BoundaryDomainProfile? {
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
                    "Character has no scalars"
                )
            }
            return asciiSRS.index(of: scalar)
        },
        Gen.choose(in: 0 ... asciiSRS.scalarCount - 1)
            .map { Character(asciiSRS.scalar(at: $0)) }
    )
    return Gen.arrayOf(charGen, within: UInt64(length.lowerBound) ... UInt64(length.upperBound))
        .map { String($0) }
}
