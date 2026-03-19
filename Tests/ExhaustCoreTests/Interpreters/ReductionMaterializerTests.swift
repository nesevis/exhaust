//
//  ReductionMaterializerTests.swift
//  Exhaust
//

import Testing
@testable import ExhaustCore

@Suite("ReductionMaterializer")
struct ReductionMaterializerTests {
    // MARK: - Exact mode: round-trip

    @Test("Exact mode round-trips a simple chooseBits generator")
    func exactRoundTrip() throws {
        let gen = Gen.choose(in: 0 ... 100 as ClosedRange<Int>)

        // Generate a value + tree via VACTI.
        var interpreter = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        let (originalValue, originalTree) = try #require(try interpreter.next())
        let prefix = ChoiceSequence(originalTree)

        // Exact round-trip should reproduce the same value.
        guard case let .success(value, tree) = ReductionMaterializer.materialize(
            gen, prefix: prefix, mode: .exact
        ) else {
            Issue.record("Expected .success, got rejected/failed")
            return
        }

        #expect(value == originalValue)
        // Fresh tree should have valid metadata.
        if case let .choice(_, meta) = tree {
            #expect(meta.validRange == 0.bitPattern64 ... 100.bitPattern64)
        }
    }

    @Test("Exact mode round-trips a zip of two generators")
    func exactRoundTripZip() throws {
        let gen = Gen.zip(
            Gen.choose(in: 0 ... 50 as ClosedRange<Int>),
            Gen.choose(in: 0 ... 50 as ClosedRange<Int>)
        )

        var interpreter = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 99)
        let (originalValue, originalTree) = try #require(try interpreter.next())
        let prefix = ChoiceSequence(originalTree)

        guard case let .success(value, _) = ReductionMaterializer.materialize(
            gen, prefix: prefix, mode: .exact
        ) else {
            Issue.record("Expected .success")
            return
        }

        #expect(value.0 == originalValue.0)
        #expect(value.1 == originalValue.1)
    }

    // MARK: - Exact mode: out-of-range rejection

    @Test("Exact mode rejects inner value outside valid range")
    func exactRejectsOutOfRange() {
        let gen = Gen.choose(in: 0 ... 10 as ClosedRange<UInt64>)

        // Construct a prefix with value 50, which is outside 0...10.
        let prefix: ChoiceSequence = [
            .value(.init(choice: .unsigned(50, .uint64), validRange: 0 ... 100)),
        ]

        let result = ReductionMaterializer.materialize(gen, prefix: prefix, mode: .exact)
        guard case .rejected = result else {
            Issue.record("Expected .rejected for out-of-range inner value, got \(result)")
            return
        }
    }

    @Test("Exact mode rejects when prefix is exhausted")
    func exactRejectsExhaustedPrefix() {
        let gen = Gen.zip(
            Gen.choose(in: 0 ... 10 as ClosedRange<UInt64>),
            Gen.choose(in: 0 ... 10 as ClosedRange<UInt64>)
        )

        // Prefix only has one value, but generator needs two.
        let prefix: ChoiceSequence = [
            .value(.init(choice: .unsigned(5, .uint64), validRange: 0 ... 10)),
        ]

        let result = ReductionMaterializer.materialize(gen, prefix: prefix, mode: .exact)
        guard case .rejected = result else {
            Issue.record("Expected .rejected for exhausted prefix")
            return
        }
    }

    // MARK: - Exact mode: bind replay without cursor suspension

    @Test("Exact mode replays bound values from prefix without suspension")
    func exactBindReplayWithoutSuspension() throws {
        // bind { n in Gen.choose(in: 0 ... n) } where inner generates n
        let gen: ReflectiveGenerator<Int> = Gen.choose(in: 1 ... 10 as ClosedRange<Int>)._bind { n in
            Gen.choose(in: 0 ... max(0, n) as ClosedRange<Int>)
        }

        // Generate a value via VACTI.
        var interpreter = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        let (originalValue, originalTree) = try #require(try interpreter.next())
        let prefix = ChoiceSequence(originalTree)

        // Exact mode should replay both inner AND bound values from prefix.
        guard case let .success(value, tree) = ReductionMaterializer.materialize(
            gen, prefix: prefix, mode: .exact
        ) else {
            Issue.record("Expected .success for bind replay")
            return
        }

        #expect(value == originalValue)
        // Tree should contain a .bind node.
        #expect(tree.containsBind)
    }

    @Test("Exact mode clamps bound values when inner value changes range")
    func exactClampsBoundValues() {
        // bind { n in Gen.choose(in: 0 ... n) } using UInt64 to avoid bit-pattern offset.
        // If inner was 10 (bound value was 8), then inner drops to 5,
        // the bound value 8 should clamp to 5.
        let gen: ReflectiveGenerator<UInt64> = Gen.choose(in: 0 ... 10 as ClosedRange<UInt64>)._bind { n in
            Gen.choose(in: 0 ... max(1, n) as ClosedRange<UInt64>)
        }

        // Construct a prefix where inner = 5, bound = 8 (out of 0...5 but was valid for 0...10).
        let prefix: ChoiceSequence = [
            .bind(true),
            .value(.init(choice: .unsigned(5, .uint64), validRange: 0 ... 10, isRangeExplicit: true)),
            .value(.init(choice: .unsigned(8, .uint64), validRange: 0 ... 10, isRangeExplicit: true)),
            .bind(false),
        ]

        guard case let .success(value, _) = ReductionMaterializer.materialize(
            gen, prefix: prefix, mode: .exact
        ) else {
            Issue.record("Expected .success — bound value should be clamped, not rejected")
            return
        }

        // Bound value 8 should be clamped to max(0...5) = 5.
        #expect(value <= 5)
    }

    // MARK: - Guided mode: clamping

    @Test("Guided mode clamps prefix values to valid range")
    func guidedClamps() {
        let gen = Gen.choose(in: 0 ... 10 as ClosedRange<UInt64>)

        // Prefix with value 50, outside 0...10.
        let prefix: ChoiceSequence = [
            .value(.init(choice: .unsigned(50, .uint64), validRange: 0 ... 100)),
        ]

        guard case let .success(value, tree) = ReductionMaterializer.materialize(
            gen, prefix: prefix,
            mode: .guided(seed: 42, fallbackTree: nil)
        ) else {
            Issue.record("Expected .success — guided should clamp, not reject")
            return
        }

        // Value should be clamped to max of range: 10.
        #expect(value == 10)
        // Fresh tree metadata should have the generator's range.
        if case let .choice(_, meta) = tree {
            #expect(meta.validRange == 0 ... 10)
        }
    }

    @Test("Guided mode falls back to PRNG when prefix exhausted")
    func guidedFallsToPRNG() {
        let gen = Gen.choose(in: 0 ... 100 as ClosedRange<UInt64>)

        // Empty prefix — guided should fall back to PRNG.
        let prefix: ChoiceSequence = []

        guard case let .success(value, _) = ReductionMaterializer.materialize(
            gen, prefix: prefix,
            mode: .guided(seed: 42, fallbackTree: nil)
        ) else {
            Issue.record("Expected .success — guided should fall back to PRNG")
            return
        }

        #expect(value >= 0 && value <= 100)
    }

    // MARK: - Guided mode: cursor suspension at bind sites

    @Test("Guided mode suspends cursor for bind bound region")
    func guidedCursorSuspension() throws {
        let gen: ReflectiveGenerator<Int> = Gen.choose(in: 1 ... 10 as ClosedRange<Int>)._bind { n in
            Gen.choose(in: 0 ... max(0, n) as ClosedRange<Int>)
        }

        // Generate via VACTI to get a well-formed prefix.
        var interpreter = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        let (_, originalTree) = try #require(try interpreter.next())
        let prefix = ChoiceSequence(originalTree)

        // Guided mode with fallback tree should succeed.
        guard case let .success(_, tree) = ReductionMaterializer.materialize(
            gen, prefix: prefix,
            mode: .guided(seed: ZobristHash.hash(of: prefix), fallbackTree: originalTree)
        ) else {
            Issue.record("Expected .success for guided bind materialization")
            return
        }

        // Tree should contain bind structure.
        #expect(tree.containsBind)
    }

    // MARK: - Materialized picks at pick sites

    @Test("Pick sites produce all branch alternatives in result tree")
    func materializedPicks() throws {
        let gen: ReflectiveGenerator<String> = Gen.pick(choices: [
            (weight: 1, generator: Gen.just("a")),
            (weight: 1, generator: Gen.just("b")),
            (weight: 1, generator: Gen.just("c")),
        ])

        // Generate a value via VACTI with materialized picks.
        var interpreter = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        let (originalValue, originalTree) = try #require(try interpreter.next())
        let prefix = ChoiceSequence(originalTree)

        // ReductionMaterializer should produce all branches.
        guard case let .success(value, tree) = ReductionMaterializer.materialize(
            gen, prefix: prefix, mode: .exact, materializePicks: true
        ) else {
            Issue.record("Expected .success for pick materialization")
            return
        }

        #expect(value == originalValue)

        // The tree should be a group with 3 branch children (one selected).
        if case let .group(branches, _) = tree {
            #expect(branches.count == 3, "Expected 3 branches (1 selected + 2 alternatives)")
            let selectedCount = branches.filter(\.isSelected).count
            #expect(selectedCount == 1)
        } else {
            Issue.record("Expected .group at top level of pick tree")
        }
    }

    @Test("Non-selected branches are generated via jumped PRNG")
    func nonSelectedBranchesAreConsistent() throws {
        let gen: ReflectiveGenerator<Int> = Gen.pick(choices: [
            (weight: 1, generator: Gen.choose(in: 0 ... 100 as ClosedRange<Int>)),
            (weight: 1, generator: Gen.choose(in: 0 ... 100 as ClosedRange<Int>)),
        ])

        var interpreter = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 77)
        let (_, originalTree) = try #require(try interpreter.next())
        let prefix = ChoiceSequence(originalTree)

        // Run twice with same prefix — should produce deterministic results.
        guard case let .success(value1, tree1) = ReductionMaterializer.materialize(
            gen, prefix: prefix, mode: .exact, materializePicks: true
        ) else {
            Issue.record("First materialization failed")
            return
        }
        guard case let .success(value2, tree2) = ReductionMaterializer.materialize(
            gen, prefix: prefix, mode: .exact, materializePicks: true
        ) else {
            Issue.record("Second materialization failed")
            return
        }

        #expect(value1 == value2)
        #expect(tree1 == tree2)
    }

    // MARK: - Fresh validRange metadata

    @Test("Result tree has fresh validRange from generator, not stale prefix")
    func freshValidRange() {
        let gen = Gen.choose(in: 10 ... 20 as ClosedRange<UInt64>)

        // Construct prefix with a STALE validRange (0...100).
        let prefix: ChoiceSequence = [
            .value(.init(choice: .unsigned(15, .uint64), validRange: 0 ... 100)),
        ]

        guard case let .success(_, tree) = ReductionMaterializer.materialize(
            gen, prefix: prefix, mode: .exact
        ) else {
            Issue.record("Expected .success")
            return
        }

        // The tree's metadata should reflect the generator's range (10...20),
        // not the prefix's stale range (0...100).
        if case let .choice(_, meta) = tree {
            #expect(meta.validRange == 10 ... 20,
                    "Expected fresh validRange 10...20 from generator, got \(String(describing: meta.validRange))")
        } else {
            Issue.record("Expected .choice tree node")
        }
    }

    @Test("Sequence flattened from fresh tree has fresh validRange")
    func flattenedSequenceHasFreshMetadata() {
        let gen = Gen.choose(in: 5 ... 15 as ClosedRange<UInt64>)

        // Prefix with stale range.
        let prefix: ChoiceSequence = [
            .value(.init(choice: .unsigned(10, .uint64), validRange: 0 ... 1000)),
        ]

        guard case let .success(_, tree) = ReductionMaterializer.materialize(
            gen, prefix: prefix, mode: .exact
        ) else {
            Issue.record("Expected .success")
            return
        }

        let freshSequence = ChoiceSequence(tree)
        if case let .value(v) = freshSequence[0] {
            #expect(v.validRange == 5 ... 15,
                    "Expected fresh range 5...15, got \(String(describing: v.validRange))")
        }
    }

    @Test("Bind-dependent generator produces fresh validRange after inner value change")
    func freshValidRangeForBindDependent() throws {
        // bind { n in Gen.choose(in: 0 ... n) } using UInt64.
        let gen: ReflectiveGenerator<UInt64> = Gen.choose(in: 1 ... 100 as ClosedRange<UInt64>)._bind { n in
            Gen.choose(in: 0 ... max(1, n) as ClosedRange<UInt64>)
        }

        // Generate a value via VACTI.
        var interpreter = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        let (_, originalTree) = try #require(try interpreter.next())

        // Now materialize with a MODIFIED prefix where inner = 10.
        var prefix = ChoiceSequence(originalTree)
        // Find and replace the first value entry (inner value) with 10.
        for idx in prefix.indices {
            if case .value = prefix[idx] {
                prefix[idx] = .value(.init(
                    choice: .unsigned(10, .uint64),
                    validRange: 1 ... 100,
                    isRangeExplicit: true
                ))
                break
            }
        }

        guard case let .success(_, tree) = ReductionMaterializer.materialize(
            gen, prefix: prefix, mode: .exact
        ) else {
            Issue.record("Expected .success")
            return
        }

        // The bound subtree's validRange should reflect 0...10, not the original 0...50.
        if case let .bind(_, bound) = tree {
            if case let .choice(_, meta) = bound {
                #expect(meta.validRange?.upperBound == 10,
                        "Bound range upper bound should be 10 (from inner), got \(String(describing: meta.validRange))")
            }
        }
    }

    // MARK: - Compatibility with VACTI

    @Test("Exact mode produces same output as Interpreters.materialize for simple generators")
    func compatibilityWithLegacyMaterialize() throws {
        let gen = Gen.choose(in: 0 ... 1000 as ClosedRange<Int>)

        var interpreter = ValueAndChoiceTreeInterpreter(gen, materializePicks: false, seed: 42, maxRuns: 20)
        while let (_, originalTree) = try interpreter.next() {
            let sequence = ChoiceSequence(originalTree)
            let legacyOutput = try #require(
                try Interpreters.materialize(gen, with: originalTree, using: sequence)
            )

            guard case let .success(freshOutput, _) = ReductionMaterializer.materialize(
                gen, prefix: sequence, mode: .exact
            ) else {
                Issue.record("ReductionMaterializer rejected valid sequence")
                return
            }

            #expect(freshOutput == legacyOutput,
                    "Expected same output: legacy=\(legacyOutput), fresh=\(freshOutput)")
        }
    }

    @Test("Exact mode produces same output as legacy for sequence generators")
    func compatibilityWithLegacySequence() throws {
        let gen = Gen.arrayOf(
            Gen.choose(in: 0 ... 50 as ClosedRange<Int>),
            exactly: 3
        )

        var interpreter = ValueAndChoiceTreeInterpreter(gen, materializePicks: false, seed: 42, maxRuns: 10)
        while let (_, originalTree) = try interpreter.next() {
            let sequence = ChoiceSequence(originalTree)
            let legacyOutput = try #require(
                try Interpreters.materialize(gen, with: originalTree, using: sequence)
            )

            guard case let .success(freshOutput, _) = ReductionMaterializer.materialize(
                gen, prefix: sequence, mode: .exact
            ) else {
                Issue.record("ReductionMaterializer rejected valid sequence")
                return
            }

            #expect(freshOutput == legacyOutput)
        }
    }

    // MARK: - Guided mode: fallback tree

    @Test("Guided mode uses fallback tree when prefix exhausted")
    func guidedUsesFallbackTree() throws {
        let gen = Gen.choose(in: 0 ... 100 as ClosedRange<UInt64>)

        // Generate a value to use as fallback tree.
        var interpreter = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        let (fallbackValue, fallbackTree) = try #require(try interpreter.next())

        // Empty prefix, with fallback tree — should use fallback value.
        guard case let .success(value, _) = ReductionMaterializer.materialize(
            gen, prefix: [],
            mode: .guided(seed: 42, fallbackTree: fallbackTree)
        ) else {
            Issue.record("Expected .success")
            return
        }

        #expect(value == fallbackValue,
                "Expected fallback value \(fallbackValue), got \(value)")
    }

    // MARK: - Sequence handling

    @Test("Exact mode handles variable-length sequences")
    func exactSequenceVariableLength() throws {
        let gen = Gen.arrayOf(
            Gen.choose(in: 0 ... 10 as ClosedRange<Int>),
            within: 1 ... 5,
            scaling: .constant
        )

        var interpreter = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        let (originalValue, originalTree) = try #require(try interpreter.next())
        let prefix = ChoiceSequence(originalTree)

        guard case let .success(value, _) = ReductionMaterializer.materialize(
            gen, prefix: prefix, mode: .exact
        ) else {
            Issue.record("Expected .success")
            return
        }

        #expect(value == originalValue)
    }
}
