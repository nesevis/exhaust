//
//  RecursiveOperationTests.swift
//  Exhaust
//

import Testing
@testable import ExhaustCore

@Suite("Gen.recursive")
struct RecursiveOperationTests {
    // MARK: - Basic Generation

    @Test("Produces BST-like trees at various sizes")
    func basicGeneration() throws {
        let gen = BST.arbitraryRecursive()
        var iterator = ValueInterpreter(gen, seed: 42)

        var generated = 0
        while let tree = try iterator.next() {
            #expect(tree.nodeCount >= 0)
            generated += 1
        }
        #expect(generated > 0)
    }

    @Test("Smaller sizes produce shallower trees")
    func depthScaling() throws {
        let gen = BST.arbitraryRecursive()

        // Small size override
        var smallIterator = ValueInterpreter(gen, seed: 42, maxRuns: 20, sizeOverride: 2)
        var smallHeights: [Int] = []
        while let tree = try smallIterator.next() {
            smallHeights.append(tree.height)
        }

        // Large size override
        var largeIterator = ValueInterpreter(gen, seed: 42, maxRuns: 20, sizeOverride: 100)
        var largeHeights: [Int] = []
        while let tree = try largeIterator.next() {
            largeHeights.append(tree.height)
        }

        let avgSmall = Double(smallHeights.reduce(0, +)) / Double(max(1, smallHeights.count))
        let avgLarge = Double(largeHeights.reduce(0, +)) / Double(max(1, largeHeights.count))

        #expect(avgSmall < avgLarge, "Average small height (\(avgSmall)) should be less than large (\(avgLarge))")
    }

    @Test("Size 0 produces only base cases")
    func sizeZeroProducesBase() throws {
        let gen = BST.arbitraryRecursive()
        var iterator = ValueInterpreter(gen, seed: 42, maxRuns: 10, sizeOverride: 0)

        while let tree = try iterator.next() {
            #expect(tree == .leaf, "At size 0, recursive should produce only base case")
        }
    }

    // MARK: - Reflection Roundtrip

    @Test("Reflection roundtrip: generate, reflect, verify tree")
    func reflectionRoundtrip() throws {
        let gen = BST.arbitraryRecursive()
        var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42, maxRuns: 10)

        while let (value, tree) = try iterator.next() {
            // Reflect the generated value back
            let reflectedTree = try Interpreters.reflect(gen, with: value)
            #expect(reflectedTree != nil, "Reflection should succeed for generated value: \(value)")
        }
    }

    // MARK: - Replay Roundtrip

    @Test("Replay roundtrip: generate with VACTI, replay from tree, verify same value")
    func replayRoundtrip() throws {
        let gen = BST.arbitraryRecursive()
        var iterator = ValueAndChoiceTreeInterpreter(gen, seed: 42, maxRuns: 20)

        while let (value, tree) = try iterator.next() {
            let replayed = try Interpreters.replay(gen, using: tree)
            #expect(replayed == value, "Replayed value should match original. Original: \(value), replayed: \(String(describing: replayed))")
        }
    }

    // MARK: - Base-as-Generator Overload

    @Test("Base-as-generator overload works")
    func baseAsGenerator() throws {
        // Use a generator for the base case (random leaf values)
        let baseGen = Gen.choose(in: UInt(0) ... 9).map { BST.node(left: .leaf, value: $0, right: .leaf) }
        let gen = Gen.recursive(base: baseGen) { recurse, remaining in
            let nodeBranch = Gen.zip(recurse(), Gen.choose(in: UInt(0) ... 9), recurse()).map { left, value, right in
                BST.node(left: left, value: value, right: right)
            }
            return Gen.pick(choices: [
                (weight: 1, generator: baseGen),
                (weight: Int(remaining), generator: nodeBranch),
            ])
        }

        var iterator = ValueInterpreter(gen, seed: 42, maxRuns: 10)
        var generated = 0
        while let tree = try iterator.next() {
            #expect(tree.nodeCount >= 1, "Base-as-generator should produce at least one node")
            generated += 1
        }
        #expect(generated > 0)
    }

    // MARK: - Determinism

    @Test("Same seed produces same sequence")
    func deterministic() throws {
        let gen = BST.arbitraryRecursive()

        var iter1 = ValueInterpreter(gen, seed: 123, maxRuns: 20)
        var iter2 = ValueInterpreter(gen, seed: 123, maxRuns: 20)

        while let v1 = try iter1.next() {
            let v2 = try iter2.next()
            #expect(v1 == v2)
        }
    }

    // MARK: - Materialize Roundtrip

    @Test("Materialize roundtrip: VACTI → flatten → materialize")
    func materializeRoundtrip() throws {
        let gen = BST.arbitraryRecursive()
        var iterator = ValueAndChoiceTreeInterpreter(gen, seed: 42, maxRuns: 20)

        while let (value, tree) = try iterator.next() {
            let sequence = ChoiceSequence(tree)
            let materialized = try Interpreters.materialize(gen, with: tree, using: sequence)
            #expect(materialized == value, "Materialized value should match original. Original: \(value), materialized: \(String(describing: materialized))")
        }
    }

    // MARK: - JSONValue (recursion through collections)

    @Suite("JSONValue")
    struct JSONValueTests {
        @Test("Produces JSON values at various sizes")
        func basicGeneration() throws {
            let gen = JSONValue.arbitraryRecursive()
            var iterator = ValueInterpreter(gen, seed: 42)

            var generated = 0
            var sawNull = false
            var sawInt = false
            var sawArray = false
            while let value = try iterator.next() {
                switch value {
                case .null: sawNull = true
                case .int: sawInt = true
                case .array: sawArray = true
                }
                generated += 1
            }
            #expect(generated > 0)
            #expect(sawNull, "Should produce at least one null")
            #expect(sawInt, "Should produce at least one int")
            #expect(sawArray, "Should produce at least one array")
        }

        @Test("Size 0 produces only base case (null)")
        func sizeZeroProducesBase() throws {
            let gen = JSONValue.arbitraryRecursive()
            var iterator = ValueInterpreter(gen, seed: 42, maxRuns: 10, sizeOverride: 0)

            while let value = try iterator.next() {
                #expect(value == .null, "At size 0, recursive should produce only base case, got: \(value)")
            }
        }

        @Test("Depth scales with size")
        func depthScaling() throws {
            let gen = JSONValue.arbitraryRecursive()

            var smallIterator = ValueInterpreter(gen, seed: 42, maxRuns: 30, sizeOverride: 2)
            var smallDepths: [Int] = []
            while let value = try smallIterator.next() {
                smallDepths.append(value.depth)
            }

            var largeIterator = ValueInterpreter(gen, seed: 42, maxRuns: 30, sizeOverride: 100)
            var largeDepths: [Int] = []
            while let value = try largeIterator.next() {
                largeDepths.append(value.depth)
            }

            let avgSmall = Double(smallDepths.reduce(0, +)) / Double(max(1, smallDepths.count))
            let avgLarge = Double(largeDepths.reduce(0, +)) / Double(max(1, largeDepths.count))

            #expect(avgSmall < avgLarge, "Average small depth (\(avgSmall)) should be less than large (\(avgLarge))")
        }

        @Test("Replay roundtrip")
        func replayRoundtrip() throws {
            let gen = JSONValue.arbitraryRecursive()
            var iterator = ValueAndChoiceTreeInterpreter(gen, seed: 42, maxRuns: 20)

            while let (value, tree) = try iterator.next() {
                let replayed = try Interpreters.replay(gen, using: tree)
                #expect(replayed == value, "Replayed value should match original. Original: \(value), replayed: \(String(describing: replayed))")
            }
        }

        @Test("Materialize roundtrip")
        func materializeRoundtrip() throws {
            let gen = JSONValue.arbitraryRecursive()
            var iterator = ValueAndChoiceTreeInterpreter(gen, seed: 42, maxRuns: 20)

            while let (value, tree) = try iterator.next() {
                let sequence = ChoiceSequence(tree)
                let materialized = try Interpreters.materialize(gen, with: tree, using: sequence)
                #expect(materialized == value, "Materialized value should match original. Original: \(value), materialized: \(String(describing: materialized))")
            }
        }

        @Test("Deterministic across runs")
        func deterministic() throws {
            let gen = JSONValue.arbitraryRecursive()

            var iter1 = ValueInterpreter(gen, seed: 99, maxRuns: 20)
            var iter2 = ValueInterpreter(gen, seed: 99, maxRuns: 20)

            while let v1 = try iter1.next() {
                let v2 = try iter2.next()
                #expect(v1 == v2)
            }
        }

        @Test("Nested arrays contain varied elements")
        func nestedArrayContent() throws {
            let gen = JSONValue.arbitraryRecursive()
            var iterator = ValueInterpreter(gen, seed: 42, maxRuns: 50, sizeOverride: 50)

            var maxDepth = 0
            var maxNodeCount = 0
            while let value = try iterator.next() {
                maxDepth = max(maxDepth, value.depth)
                maxNodeCount = max(maxNodeCount, value.nodeCount)
            }

            #expect(maxDepth >= 2, "Should produce values with nesting depth >= 2, got \(maxDepth)")
            #expect(maxNodeCount >= 3, "Should produce values with node count >= 3, got \(maxNodeCount)")
        }
    }
}
