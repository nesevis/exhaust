//
//  ReducerReduceValuesTests.swift
//  ExhaustTests
//
//  Tests for Pass 5 of Interpreters.reduce: reduce individual values via binary search.
//  Pass 5 binary searches between the current value and its reduction target to find
//  the minimum failing value when Pass 3's all-or-nothing simplification fails.
//

import ExhaustCore
import ExhaustTestSupport
import Foundation
import Testing

@Suite("ChoiceValue.reductionTarget")
struct ReductionTargetTests {
    @Test("Unsigned target is 0 when 0 is in range")
    func unsignedTargetIsZero() {
        let value = ChoiceValue(247 as UInt64, tag: .uint64)
        let target = value.reductionTarget(in: 0 ... 1000)
        #expect(target == 0)
    }

    @Test("Unsigned target is range lower bound when 0 is not in range")
    func unsignedTargetIsLowerBound() {
        let value = ChoiceValue(500 as UInt64, tag: .uint64)
        let target = value.reductionTarget(in: 10 ... 1000)
        #expect(target == 10)
    }

    @Test("Signed target is 0's bit pattern when 0 is in range")
    func signedTargetIsZero() {
        let value = ChoiceValue(Int64(-50), tag: .int64)
        let zeroBP = Int64(0).bitPattern64
        let range = Int64(-100).bitPattern64 ... Int64(100).bitPattern64
        let target = value.reductionTarget(in: range)
        #expect(target == zeroBP)
    }

    @Test("Signed target is closest bound when 0 is not in range")
    func signedTargetIsClosestBound() {
        let value = ChoiceValue(Int64(-50), tag: .int64)
        let range = Int64(-100).bitPattern64 ... Int64(-10).bitPattern64
        let zeroBP = Int64(0).bitPattern64
        let target = value.reductionTarget(in: range)
        // -10 is closest to 0
        let minus10BP = Int64(-10).bitPattern64
        #expect(target == minus10BP)
        #expect(target != zeroBP)
    }
}

@Suite("Reducer Pass 5: reduce values")
struct ReducerReduceValuesTests {
    @Test("Unsigned value reduced to minimum failing value")
    func unsignedReducedToMinimum() throws {
        let gen = Gen.choose(in: UInt64(0) ... 1000)

        let (value, tree) = try generate(gen)
        try #require(value > 5)

        // Property fails for values >= 5
        let property: (UInt64) -> Bool = { $0 < 5 }

        let (_, output) = try #require(
            try Interpreters.choiceGraphReduce(gen: gen, tree: tree, config: reducerConfig, property: property).counterexample
        )

        #expect(output == 5)
    }

    @Test("Unsigned value in range not containing 0")
    func unsignedInRestrictedRange() throws {
        let gen = Gen.choose(in: UInt64(10) ... 1000)

        let (value, tree) = try generate(gen)
        try #require(value >= 50)

        // Property fails for values >= 50
        let property: (UInt64) -> Bool = { $0 < 50 }

        let (_, output) = try #require(
            try Interpreters.choiceGraphReduce(gen: gen, tree: tree, config: reducerConfig, property: property).counterexample
        )

        #expect(output == 50)
    }

    @Test("Signed value reduced toward 0")
    func signedReducedTowardZero() throws {
        let gen = Gen.choose(in: Int64(-1000) ... -1)

        let (value, tree) = try generate(gen)
        try #require(value < -5)

        // Property fails for values <= -5
        let property: (Int64) -> Bool = { $0 > -5 }

        let (_, output) = try #require(
            try Interpreters.choiceGraphReduce(gen: gen, tree: tree, config: reducerConfig, property: property).counterexample
        )

        #expect(output == -5)
    }

    @Test("Value already at target is unchanged")
    func alreadyAtTarget() throws {
        let gen = Gen.choose(in: UInt64(0) ... 100)

        let (_, tree) = try generate(gen)

        // Property always passes — no reduction possible
        let property: (UInt64) -> Bool = { _ in true }

        let result = try Interpreters.choiceGraphReduce(gen: gen, tree: tree, config: reducerConfig, property: property)
        if case .reduced = result {
            Issue.record("Property always passes — reduction should not find an improvement")
        }
    }

    @Test("Reduction preserves property failure")
    func reductionPreservesFailure() throws {
        let gen = Gen.choose(in: UInt64(0) ... 1000)

        let (value, tree) = try generate(gen)
        try #require(value > 10)

        // Property fails for values >= 10
        let property: (UInt64) -> Bool = { $0 < 10 }

        let (_, output) = try #require(
            try Interpreters.choiceGraphReduce(gen: gen, tree: tree, config: reducerConfig, property: property).counterexample
        )

        #expect(property(output) == false)
        #expect(output >= 10)
    }

    @Test("Character value reduced within its range")
    func characterReduced() throws {
        let gen = charGen(from: CharacterSet(charactersIn: Unicode.Scalar("a") ... Unicode.Scalar("z")))

        // Try multiple seeds to find one that generates a character > "e"
        var foundTree: ChoiceTree?
        for seed: UInt64 in 0 ... 100 {
            let (value, tree) = try generate(gen, seed: seed)
            if value > "e" {
                foundTree = tree
                break
            }
        }
        let tree = try #require(foundTree)

        // Property fails for characters > "e"
        let property: (Character) -> Bool = { $0 <= "e" }

        let (_, output) = try #require(
            try Interpreters.choiceGraphReduce(gen: gen, tree: tree, config: reducerConfig, property: property).counterexample
        )

        #expect(output == "f")
    }

    @Test("Float value reduced naively via bit pattern search")
    func floatReducedNaively() throws {
        let gen = Gen.choose(in: 0.0 ... 1000.0 as ClosedRange<Double>)

        // Try multiple seeds/runs to find one that generates a value > 1.0
        var foundTree: ChoiceTree?
        outer: for seed: UInt64 in 0 ... 20 {
            var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: seed)
            for _ in 0 ..< 50 {
                guard let (value, tree) = try iterator.next() else { break }
                if value > 1.0 {
                    foundTree = tree
                    break outer
                }
            }
        }
        let tree = try #require(foundTree)

        // Property always fails — should reduce toward 0.0
        let property: (Double) -> Bool = { _ in false }

        let (_, output) = try #require(
            try Interpreters.choiceGraphReduce(gen: gen, tree: tree, config: reducerConfig, property: property).counterexample
        )

        // Value should be reduced toward 0 (Pass 3 sets it to 0.0 directly since property always fails)
        #expect(output == 0.0)
    }

    @Test("Pass 3 + Pass 5 work together")
    func passThreeAndFiveIntegration() throws {
        let gen = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 1000), exactly: 3)

        let (_, tree) = try generate(gen)

        // Property fails when the array has 3 elements and at least one >= 100.
        // Pass 3 will zero what it can. Pass 5 will minimise the load-bearing value.
        let property: ([UInt64]) -> Bool = { arr in
            guard arr.count == 3 else { return true }
            return arr.allSatisfy { $0 < 100 }
        }

        let (_, output) = try #require(
            try Interpreters.choiceGraphReduce(gen: gen, tree: tree, config: reducerConfig, property: property).counterexample
        )

        #expect(output.count == 3)
        // At least one value should be exactly 100 (minimum failing)
        #expect(output.contains(100))
        // The other values should be 0 (simplified by Pass 3)
        let nonLoadBearing = output.filter { $0 != 100 }
        #expect(nonLoadBearing.allSatisfy { $0 == 0 })
    }

    @Test("Dynamic child ranges from bind do not block value shrinking")
    func dynamicRangesDoNotBlockValueShrinking() throws {
        // Child values are constrained by the chosen parent value.
        let gen = Gen.choose(in: UInt64(0) ... 100)
            .bind { parent in
                Gen.zip(Gen.just(parent), Gen.choose(in: parent ... 100), Gen.choose(in: parent ... 100))
            }

        // Fails when left child is strictly less than right child.
        let property: ((UInt64, UInt64, UInt64)) -> Bool = { triple in
            triple.1 >= triple.2
        }

        // Ensure we start from a non-trivial parent so stale validRange would matter.
        var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: false, seed: 1337, maxRuns: 500)
        var found: ((UInt64, UInt64, UInt64), ChoiceTree)?
        while let pair = try iterator.next() {
            let value = pair.0
            if value.0 > 0, property(value) == false {
                found = pair
                break
            }
        }
        let (_, tree) = try #require(found)

        let (_, output) = try #require(
            try Interpreters.choiceGraphReduce(gen: gen, tree: tree, config: reducerConfig, property: property).counterexample
        )

        // Minimal failing tuple under constraints:
        // p <= left, p <= right, and left < right  ==>  (0, 0, 1)
        #expect(output == (0, 0, 1))
    }
}

// MARK: - Helpers

private let reducerConfig = Interpreters.ReducerConfiguration(maxStalls: 2)
