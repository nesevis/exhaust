//
//  RecursiveOperationTests.swift
//  Exhaust
//

import ExhaustCore
import Testing

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

    @Test("Smaller maxDepth produces shallower trees")
    func depthScaling() throws {
        // Small maxDepth
        let smallGen = BST.arbitraryRecursive(maxDepth: 2)
        var smallIterator = ValueInterpreter(smallGen, seed: 42, maxRuns: 20)
        var smallHeights: [Int] = []
        while let tree = try smallIterator.next() {
            smallHeights.append(tree.height)
        }

        // Large maxDepth
        let largeGen = BST.arbitraryRecursive(maxDepth: 7)
        var largeIterator = ValueInterpreter(largeGen, seed: 42, maxRuns: 20)
        var largeHeights: [Int] = []
        while let tree = try largeIterator.next() {
            largeHeights.append(tree.height)
        }

        let avgSmall = Double(smallHeights.reduce(0, +)) / Double(max(1, smallHeights.count))
        let avgLarge = Double(largeHeights.reduce(0, +)) / Double(max(1, largeHeights.count))

        #expect(avgSmall < avgLarge, "Average small height (\(avgSmall)) should be less than large (\(avgLarge))")
    }

    @Test("maxDepth 0 produces only base cases")
    func maxDepthZeroProducesBase() throws {
        let gen = BST.arbitraryRecursive(maxDepth: 0)
        var iterator = ValueInterpreter(gen, seed: 42, maxRuns: 10)

        while let tree = try iterator.next() {
            #expect(tree == .leaf, "At maxDepth 0, recursive should produce only base case")
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
        let baseGen = Gen.choose(in: UInt(0) ... 9)._map { BST.node(left: .leaf, value: $0, right: .leaf) }
        let gen = Gen.recursive(base: baseGen, depthRange: 1 ... 5) { recurse, remaining in
            let nodeBranch = Gen.zip(recurse(), Gen.choose(in: UInt(0) ... 9), recurse())._map { left, value, right in
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
            switch ReductionMaterializer.materialize(gen, prefix: sequence, mode: .exact, fallbackTree: tree) {
            case let .success(materialized, _, _):
                print("success")
                #expect(materialized == value, "Materialized value should match original. Original: \(value), materialized: \(String(describing: materialized))")
            case .rejected, .failed:
                Issue.record("Expected .success for value: \(value)")
            }
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

        @Test("maxDepth 0 produces only base case (null)")
        func maxDepthZeroProducesBase() throws {
            let gen = JSONValue.arbitraryRecursive(maxDepth: 0)
            var iterator = ValueInterpreter(gen, seed: 42, maxRuns: 10)

            while let value = try iterator.next() {
                #expect(value == .null, "At maxDepth 0, recursive should produce only base case, got: \(value)")
            }
        }

        @Test("Depth scales with maxDepth")
        func depthScaling() throws {
            let smallGen = JSONValue.arbitraryRecursive(maxDepth: 2)
            var smallIterator = ValueInterpreter(smallGen, seed: 42, maxRuns: 30)
            var smallDepths: [Int] = []
            while let value = try smallIterator.next() {
                smallDepths.append(value.depth)
            }

            let largeGen = JSONValue.arbitraryRecursive(maxDepth: 7)
            var largeIterator = ValueInterpreter(largeGen, seed: 42, maxRuns: 30)
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
                switch ReductionMaterializer.materialize(gen, prefix: sequence, mode: .exact, fallbackTree: tree) {
                case let .success(materialized, _, _):
                    #expect(materialized == value, "Materialized value should match original. Original: \(value), materialized: \(String(describing: materialized))")
                case .rejected, .failed:
                    Issue.record("Expected .success for value: \(value)")
                }
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
            var iterator = ValueInterpreter(gen, seed: 42, maxRuns: 50)

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
