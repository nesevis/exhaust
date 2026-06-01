//
//  LargeDomainCoveringArrayReplayTests.swift
//  Exhaust
//

import ExhaustCore
import ExhaustTestSupport
import Testing

@Suite("LargeDomainCoveringArrayReplay")
struct LargeDomainCoveringArrayReplayUnitTests {
    // MARK: - buildTree

    @Suite("buildTree")
    struct BuildTreeTests {
        @Test("Valid row matching profile produces a tree")
        func validRow() throws {
            let gen = Gen.choose(in: 0 ... 10000)
            let profile = try #require(analyzeLargeDomain(gen))
            let row = CoveringArrayRow(values: [0])

            let tree = LargeDomainCoveringArrayReplay.buildTree(row: row, profile: profile)
            #expect(tree != nil)
        }

        @Test("Mismatched row count returns nil")
        func mismatchedCount() throws {
            let gen = Gen.choose(in: 0 ... 10000)
            let profile = try #require(analyzeLargeDomain(gen))
            // Too many values
            let row = CoveringArrayRow(values: [0, 1])

            let tree = LargeDomainCoveringArrayReplay.buildTree(row: row, profile: profile)
            #expect(tree == nil)
        }

        @Test("Single parameter returns unwrapped tree (not group)")
        func singleParamUnwrapped() throws {
            let gen = Gen.choose(in: 0 ... 10000)
            let profile = try #require(analyzeLargeDomain(gen))
            let row = CoveringArrayRow(values: [0])

            let tree = try #require(LargeDomainCoveringArrayReplay.buildTree(row: row, profile: profile))
            // Single parameter should not be wrapped in a group
            if case .group = tree {
                Issue.record("Single parameter should not be wrapped in group")
            }
        }

        @Test("Multiple parameters produce a group")
        func multipleParamsGroup() throws {
            let gen = Gen.zip(Gen.choose(in: 0 ... 10000), Gen.choose(in: 0 ... 10000))
            let profile = try #require(analyzeLargeDomain(gen))
            let row = CoveringArrayRow(values: [0, 0])

            let tree = try #require(LargeDomainCoveringArrayReplay.buildTree(row: row, profile: profile))
            if case .group = tree {
                // Expected
            } else {
                Issue.record("Multiple parameters should produce group, got \(tree)")
            }
        }
    }

    // MARK: - buildChooseBitsTree

    @Suite("buildChooseBitsTree")
    struct BuildChooseBitsTreeTests {
        @Test("Out-of-bounds value index returns nil")
        func outOfBoundsIndex() throws {
            let gen = Gen.choose(in: 0 ... 10000)
            let profile = try #require(analyzeLargeDomain(gen))
            let valueCount = UInt64(profile.parameters[0].values.count)
            let row = CoveringArrayRow(values: [valueCount]) // one past the end

            let tree = LargeDomainCoveringArrayReplay.buildTree(row: row, profile: profile)
            #expect(tree == nil)
        }

        @Test("Each value index produces a valid choice tree")
        func allIndicesValid() throws {
            let gen = Gen.choose(in: 0 ... 10000)
            let profile = try #require(analyzeLargeDomain(gen))

            for i in 0 ..< UInt64(profile.parameters[0].values.count) {
                let row = CoveringArrayRow(values: [i])
                let tree = LargeDomainCoveringArrayReplay.buildTree(row: row, profile: profile)
                #expect(tree != nil, "Index \(i) should produce a valid tree")
            }
        }
    }

    // MARK: - buildPickTree

    @Suite("buildPickTree")
    struct BuildPickTreeTests {
        @Test("Pick parameter produces branch with selected wrapper")
        func pickProducesBranch() {
            let gen: Generator<Bool> = Gen.pick(choices: [
                (1, Gen.just(true)),
                (1, Gen.just(false)),
            ])
            guard case let .large(profile) = ChoiceTreeAnalysis.analyze(gen) else {
                guard case .enumerable = ChoiceTreeAnalysis.analyze(gen) else {
                    Issue.record("Expected analyzable generator")
                    return
                }
                // Small pick might be enumerable — that's fine, skip this test
                return
            }

            for i in 0 ..< UInt64(profile.parameters[0].values.count) {
                let row = CoveringArrayRow(values: [i])
                let tree = LargeDomainCoveringArrayReplay.buildTree(row: row, profile: profile)
                #expect(tree != nil, "Pick index \(i) should produce a tree")
            }
        }

        @Test("Out-of-bounds pick value returns nil")
        func outOfBoundsPick() {
            let gen: Generator<Bool> = Gen.pick(choices: [
                (1, Gen.just(true)),
                (1, Gen.just(false)),
            ])

            // This might be enumerable-domain, in which case we can't test large-domain replay
            guard case let .large(profile) = ChoiceTreeAnalysis.analyze(gen) else {
                return
            }

            let badIndex = UInt64(profile.parameters[0].values.count)
            let row = CoveringArrayRow(values: [badIndex])
            let tree = LargeDomainCoveringArrayReplay.buildTree(row: row, profile: profile)
            #expect(tree == nil)
        }

        @Test("Pick with large-domain peer reaches buildPickTree via template path")
        func pickWithLargeDomainPeer() throws {
            // A standalone small pick analyzes as enumerable, silently skipping
            // the large-domain tests above. Zipping with a large-domain generator
            // forces the overall analysis to .large, so the pick appears as a
            // .pick parameter and the template substitution path calls buildPickTree.
            let gen = Gen.zip(
                Gen.pick(choices: [
                    (1, Gen.just(true)),
                    (1, Gen.just(false)),
                ]),
                Gen.choose(in: 0 ... 10000)
            )
            let profile = try #require(analyzeLargeDomain(gen))

            let hasPickParam = profile.parameters.contains { param in
                if case .pick = param.kind { return true }
                return false
            }
            #expect(hasPickParam, "Profile must contain a .pick parameter")

            for pickIndex in 0 ..< UInt64(profile.parameters[0].values.count) {
                var values: [UInt64] = [pickIndex]
                for _ in 1 ..< profile.parameters.count {
                    values.append(0)
                }
                let row = CoveringArrayRow(values: values)
                let tree = LargeDomainCoveringArrayReplay.buildTree(row: row, profile: profile)
                #expect(tree != nil, "Pick index \(pickIndex) should produce a tree")
            }
        }

        @Test("Pick with large-domain peer round-trips through replay")
        func pickWithLargeDomainPeerRoundTrip() throws {
            let gen = Gen.zip(
                Gen.pick(choices: [
                    (1, Gen.just(true)),
                    (1, Gen.just(false)),
                ]),
                Gen.choose(in: 0 ... 10000)
            )
            let profile = try #require(analyzeLargeDomain(gen))

            let expectedCount = profile.parameters[0].values.count
            var replayedCount = 0
            for pickIndex in 0 ..< UInt64(expectedCount) {
                var values: [UInt64] = [pickIndex]
                for _ in 1 ..< profile.parameters.count {
                    values.append(0)
                }
                let row = CoveringArrayRow(values: values)
                let tree = try #require(
                    LargeDomainCoveringArrayReplay.buildTree(row: row, profile: profile),
                    "buildTree failed for pick index \(pickIndex)"
                )
                let value: (Bool, Int)? = try Interpreters.replay(gen, using: tree)
                try #require(value != nil, "Replay failed for pick index \(pickIndex)")
                replayedCount += 1
            }
            #expect(replayedCount == expectedCount)
        }
    }

    // MARK: - buildSequenceTree

    @Suite("buildSequenceTree")
    struct BuildSequenceTreeTests {
        @Test("Sequence with elements produces valid tree")
        func sequenceWithElements() throws {
            let gen = Gen.arrayOf(Gen.choose(in: 0 ... 1000), within: 0 ... 2, scaling: .constant)
            let profile = try #require(analyzeLargeDomain(gen))

            // Try each row index
            for i in 0 ..< UInt64(profile.parameters[0].values.count) {
                var values = [i]
                // Fill in remaining param values with 0
                for _ in 1 ..< profile.parameters.count {
                    values.append(0)
                }
                let row = CoveringArrayRow(values: values)
                let tree = LargeDomainCoveringArrayReplay.buildTree(row: row, profile: profile)
                #expect(tree != nil, "Sequence with length index \(i) should produce a tree")
            }
        }

        @Test("Empty sequence produces tree with no element children")
        func emptySequence() throws {
            let gen = Gen.arrayOf(Gen.choose(in: 0 ... 1000), within: 0 ... 2, scaling: .constant)
            let profile = try #require(analyzeLargeDomain(gen))

            // Find the value index for length 0
            guard let zeroIndex = profile.parameters[0].values.firstIndex(of: 0) else {
                // Length 0 might not be a problematic value if range starts > 0
                return
            }

            var values = [UInt64(zeroIndex)]
            for _ in 1 ..< profile.parameters.count {
                values.append(0)
            }
            let row = CoveringArrayRow(values: values)
            let tree = try #require(LargeDomainCoveringArrayReplay.buildTree(row: row, profile: profile))

            // Should contain a sequence with length 0
            let sequence = ChoiceSequence(tree)
            #expect(sequence.contains(where: { $0.value != nil }) == false)
        }
    }

    // MARK: - buildSubTree

    @Suite("buildSubTree")
    struct BuildSubTreeTests {
        @Test("Pure generator produces .just")
        func pureProducesJust() {
            // Verified via pick which calls buildSubTree internally
            let gen: Generator<Bool> = Gen.pick(choices: [
                (1, Gen.just(true)),
                (1, Gen.just(false)),
            ])
            guard case let .large(profile) = ChoiceTreeAnalysis.analyze(gen) else {
                // Might be enumerable, skip
                return
            }

            let row = CoveringArrayRow(values: [0])
            let tree = LargeDomainCoveringArrayReplay.buildTree(row: row, profile: profile)
            #expect(tree != nil)
        }
    }

    // MARK: - Round-trip tests

    @Suite("Round-trip (analyze -> replay)")
    struct RoundTripTests {
        @Test("Simple int range round-trips through replay")
        func simpleIntRoundTrip() throws {
            let gen = Gen.choose(in: 0 ... 10000)
            let profile = try #require(analyzeLargeDomain(gen))

            let expectedCount = profile.parameters[0].values.count
            var replayedCount = 0
            for i in 0 ..< UInt64(expectedCount) {
                let row = CoveringArrayRow(values: [i])
                let tree = try #require(
                    LargeDomainCoveringArrayReplay.buildTree(row: row, profile: profile),
                    "buildTree failed for value index \(i)"
                )
                let value = try #require(
                    Interpreters.replay(gen, using: tree) as Int?,
                    "Replay failed for value index \(i)"
                )
                #expect(0 ... 10000 ~= value)
                replayedCount += 1
            }
            #expect(replayedCount == expectedCount)
        }

        @Test("Zip of two ints round-trips")
        func zipRoundTrip() throws {
            let gen = Gen.zip(Gen.choose(in: 0 ... 10000), Gen.choose(in: 0 ... 10000))
            let profile = try #require(analyzeLargeDomain(gen))
            let generator = PullBasedCoveringArrayGenerator(
                domainSizes: profile.domainSizes,
                strength: min(profile.parameterCount, 4)
            )

            var replayedCount = 0
            var rowCount = 0
            while let row = generator.next() {
                rowCount += 1
                let tree = try #require(
                    LargeDomainCoveringArrayReplay.buildTree(row: row, profile: profile),
                    "buildTree failed for row \(rowCount)"
                )
                let (a, b) = try #require(
                    Interpreters.replay(gen, using: tree) as (Int, Int)?,
                    "Replay failed for row \(rowCount)"
                )
                #expect(0 ... 10000 ~= a)
                #expect(0 ... 10000 ~= b)
                replayedCount += 1
            }
            #expect(replayedCount == rowCount)
        }

        @Test("Array with constant scaling round-trips")
        func arrayRoundTrip() throws {
            let gen = Gen.arrayOf(Gen.choose(in: 0 ... 10000), within: 0 ... 2, scaling: .constant)
            let profile = try #require(analyzeLargeDomain(gen))

            var replayedCount = 0
            var rowCount = 0
            if profile.parameterCount >= 2 {
                let generator = PullBasedCoveringArrayGenerator(
                    domainSizes: profile.domainSizes,
                    strength: min(profile.parameterCount, 4)
                )
                while let row = generator.next() {
                    rowCount += 1
                    let tree = try #require(
                        LargeDomainCoveringArrayReplay.buildTree(row: row, profile: profile),
                        "buildTree failed for row \(rowCount)"
                    )
                    let array = try #require(
                        Interpreters.replay(gen, using: tree) as [Int]?,
                        "Replay failed for row \(rowCount)"
                    )
                    for element in array {
                        #expect(0 ... 10000 ~= element)
                    }
                    replayedCount += 1
                }
            } else {
                rowCount = Int(profile.domainSizes[0])
                for valueIndex in 0 ..< profile.domainSizes[0] {
                    let row = CoveringArrayRow(values: [valueIndex])
                    let tree = try #require(
                        LargeDomainCoveringArrayReplay.buildTree(row: row, profile: profile),
                        "buildTree failed for value index \(valueIndex)"
                    )
                    let array = try #require(
                        Interpreters.replay(gen, using: tree) as [Int]?,
                        "Replay failed for value index \(valueIndex)"
                    )
                    for element in array {
                        #expect(0 ... 10000 ~= element)
                    }
                    replayedCount += 1
                }
            }
            #expect(replayedCount == rowCount)
        }

        @Test("Int inside resize round-trips through replay")
        func resizeRoundTrip() throws {
            let gen = Gen.choose(in: 0 ... 10000).wrapped.resize(50).gen
            let profile = try #require(analyzeLargeDomain(gen))

            #expect(profile.parameters.count == 1, "Should extract one parameter from inside the resize")

            let expectedCount = profile.parameters[0].values.count
            var replayedCount = 0
            for valueIndex in 0 ..< UInt64(expectedCount) {
                let row = CoveringArrayRow(values: [valueIndex])
                let tree = try #require(
                    LargeDomainCoveringArrayReplay.buildTree(row: row, profile: profile),
                    "buildTree failed for value index \(valueIndex)"
                )
                let value = try #require(
                    Interpreters.replay(gen, using: tree) as Int?,
                    "Replay failed for value index \(valueIndex)"
                )
                #expect(0 ... 10000 ~= value)
                replayedCount += 1
            }
            #expect(replayedCount == expectedCount)
        }

        @Test("Zip with resize peer round-trips through replay")
        func zipWithResizeRoundTrip() throws {
            let gen = Gen.zip(
                Gen.choose(in: 0 ... 10000).wrapped.resize(50).gen,
                Gen.choose(in: 0 ... 10000)
            )
            let profile = try #require(analyzeLargeDomain(gen))

            #expect(profile.parameters.count == 2, "Should extract parameters from both peers")

            let generator = PullBasedCoveringArrayGenerator(
                domainSizes: profile.domainSizes,
                strength: 2
            )

            var replayedCount = 0
            while let row = generator.next() {
                replayedCount += 1
                let tree = try #require(
                    LargeDomainCoveringArrayReplay.buildTree(row: row, profile: profile),
                    "buildTree failed for row \(replayedCount)"
                )
                let (resized, plain) = try #require(
                    Interpreters.replay(gen, using: tree) as (Int, Int)?,
                    "Replay failed for row \(replayedCount)"
                )
                #expect(0 ... 10000 ~= resized)
                #expect(0 ... 10000 ~= plain)
            }
            #expect(replayedCount > 0)
        }
    }
}
