//
//  RangeDependencyDetectorTests.swift
//  Exhaust
//

import Exhaust
import ExhaustCore
import Testing

@Suite("RangeDependencyDetector")
struct RangeDependencyDetectorTests {
    // MARK: - Edge cases

    @Test("Empty sample returns true (conservative)")
    func emptySample() {
        #expect(RangeDependencyDetector.hasDynamicRanges(in: []) == true)
    }

    @Test("Single sample returns true (conservative)")
    func singleSample() {
        let tree = ChoiceTree.choice(
            .unsigned(42, .uint64),
            ChoiceMetadata(validRange: 0 ... 100, isRangeExplicit: true)
        )
        #expect(RangeDependencyDetector.hasDynamicRanges(in: [tree]) == true)
    }

    // MARK: - Static ranges

    @Test("Identical trees with same explicit ranges returns false")
    func identicalStaticRanges() {
        let tree = ChoiceTree.group([
            .choice(.unsigned(10, .uint64), ChoiceMetadata(validRange: 0 ... 100, isRangeExplicit: true)),
            .choice(.unsigned(20, .uint64), ChoiceMetadata(validRange: 0 ... 50, isRangeExplicit: true)),
        ])
        #expect(RangeDependencyDetector.hasDynamicRanges(in: [tree, tree]) == false)
    }

    @Test("Different values but same explicit ranges returns false")
    func differentValuesSameRanges() {
        let tree1 = ChoiceTree.group([
            .choice(.unsigned(10, .uint64), ChoiceMetadata(validRange: 0 ... 100, isRangeExplicit: true)),
            .choice(.unsigned(20, .uint64), ChoiceMetadata(validRange: 0 ... 50, isRangeExplicit: true)),
        ])
        let tree2 = ChoiceTree.group([
            .choice(.unsigned(77, .uint64), ChoiceMetadata(validRange: 0 ... 100, isRangeExplicit: true)),
            .choice(.unsigned(33, .uint64), ChoiceMetadata(validRange: 0 ... 50, isRangeExplicit: true)),
        ])
        #expect(RangeDependencyDetector.hasDynamicRanges(in: [tree1, tree2]) == false)
    }

    @Test("Only size-scaled ranges (isRangeExplicit=false) returns false")
    func sizeScaledRangesIgnored() {
        let tree1 = ChoiceTree.choice(
            .unsigned(10, .uint64),
            ChoiceMetadata(validRange: 0 ... 50, isRangeExplicit: false)
        )
        let tree2 = ChoiceTree.choice(
            .unsigned(20, .uint64),
            ChoiceMetadata(validRange: 0 ... 200, isRangeExplicit: false)
        )
        // Different ranges, but both non-explicit — should be ignored
        #expect(RangeDependencyDetector.hasDynamicRanges(in: [tree1, tree2]) == false)
    }

    // MARK: - Dynamic ranges

    @Test("Different explicit ranges at same fingerprint returns true")
    func differentExplicitRanges() {
        let tree1 = ChoiceTree.group([
            .choice(.unsigned(10, .uint64), ChoiceMetadata(validRange: 0 ... 100, isRangeExplicit: true)),
            .choice(.unsigned(20, .uint64), ChoiceMetadata(validRange: 10 ... 100, isRangeExplicit: true)),
        ])
        let tree2 = ChoiceTree.group([
            .choice(.unsigned(50, .uint64), ChoiceMetadata(validRange: 0 ... 100, isRangeExplicit: true)),
            .choice(.unsigned(60, .uint64), ChoiceMetadata(validRange: 50 ... 100, isRangeExplicit: true)),
        ])
        #expect(RangeDependencyDetector.hasDynamicRanges(in: [tree1, tree2]) == true)
    }

    @Test("Bind-dependent ranges detected across samples")
    func bindDependentRanges() {
        // Simulates a bind where child range depends on parent value
        let tree1 = ChoiceTree.bind(
            inner: .choice(.unsigned(20, .uint64), ChoiceMetadata(validRange: 0 ... 100, isRangeExplicit: true)),
            bound: .choice(.unsigned(30, .uint64), ChoiceMetadata(validRange: 20 ... 100, isRangeExplicit: true))
        )
        let tree2 = ChoiceTree.bind(
            inner: .choice(.unsigned(50, .uint64), ChoiceMetadata(validRange: 0 ... 100, isRangeExplicit: true)),
            bound: .choice(.unsigned(70, .uint64), ChoiceMetadata(validRange: 50 ... 100, isRangeExplicit: true))
        )
        // Inner range is static (0...100), bound range varies (20...100 vs 50...100)
        #expect(RangeDependencyDetector.hasDynamicRanges(in: [tree1, tree2]) == true)
    }

    // MARK: - Structural divergence

    @Test("Different tree structures returns true")
    func structuralDivergence() {
        let tree1 = ChoiceTree.group([
            .choice(.unsigned(10, .uint64), ChoiceMetadata(validRange: 0 ... 100, isRangeExplicit: true)),
            .choice(.unsigned(20, .uint64), ChoiceMetadata(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        // Second tree has only one choice node — different fingerprint set
        let tree2 = ChoiceTree.group([
            .choice(.unsigned(10, .uint64), ChoiceMetadata(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        #expect(RangeDependencyDetector.hasDynamicRanges(in: [tree1, tree2]) == true)
    }

    // MARK: - Sequence nodes

    @Test("Sequence node explicit ranges compared correctly")
    func sequenceNodeRanges() {
        let tree1 = ChoiceTree.sequence(
            length: 3,
            elements: [
                .choice(.unsigned(1, .uint64), ChoiceMetadata(validRange: 0 ... 10, isRangeExplicit: true)),
            ],
            ChoiceMetadata(validRange: 1 ... 5, isRangeExplicit: true)
        )
        let tree2 = ChoiceTree.sequence(
            length: 3,
            elements: [
                .choice(.unsigned(1, .uint64), ChoiceMetadata(validRange: 0 ... 10, isRangeExplicit: true)),
            ],
            ChoiceMetadata(validRange: 2 ... 8, isRangeExplicit: true)
        )
        // Sequence-level range differs
        #expect(RangeDependencyDetector.hasDynamicRanges(in: [tree1, tree2]) == true)
    }

    // MARK: - Multiple samples

    @Test("Three samples, third diverges")
    func thirdSampleDiverges() {
        let staticTree = ChoiceTree.choice(
            .unsigned(10, .uint64),
            ChoiceMetadata(validRange: 0 ... 100, isRangeExplicit: true)
        )
        let dynamicTree = ChoiceTree.choice(
            .unsigned(50, .uint64),
            ChoiceMetadata(validRange: 10 ... 100, isRangeExplicit: true)
        )
        #expect(RangeDependencyDetector.hasDynamicRanges(in: [staticTree, staticTree, dynamicTree]) == true)
    }

    @Test("Five identical samples returns false")
    func fiveIdenticalSamples() {
        let tree = ChoiceTree.group([
            .choice(.unsigned(42, .uint64), ChoiceMetadata(validRange: 0 ... 100, isRangeExplicit: true)),
            .choice(.unsigned(7, .uint64), ChoiceMetadata(validRange: 0 ... 50, isRangeExplicit: true)),
        ])
        let trees = Array(repeating: tree, count: 5)
        #expect(RangeDependencyDetector.hasDynamicRanges(in: trees) == false)
    }

    // MARK: - Mixed explicit and non-explicit

    @Test("Only non-explicit range differs, explicit matches — returns false")
    func mixedExplicitNonExplicit() {
        let tree1 = ChoiceTree.group([
            .choice(.unsigned(10, .uint64), ChoiceMetadata(validRange: 0 ... 100, isRangeExplicit: true)),
            .choice(.unsigned(20, .uint64), ChoiceMetadata(validRange: 0 ... 50, isRangeExplicit: false)),
        ])
        let tree2 = ChoiceTree.group([
            .choice(.unsigned(10, .uint64), ChoiceMetadata(validRange: 0 ... 100, isRangeExplicit: true)),
            .choice(.unsigned(20, .uint64), ChoiceMetadata(validRange: 0 ... 200, isRangeExplicit: false)),
        ])
        // Non-explicit range differs but should be ignored
        #expect(RangeDependencyDetector.hasDynamicRanges(in: [tree1, tree2]) == false)
    }
}
