//
//  AdvancedFeatureTests.swift
//  ExhaustTests
//
//  Advanced tests including recursive structures, enums, conditional generation,
//  and complex scenarios.
//

import Exhaust
import Testing

// MARK: - Advanced Data Structures

struct TestTree<T: Equatable>: Equatable {
    let value: T
    let children: [TestTree<T>]
}

@Suite("Advanced Features")
struct AdvancedFeatureTests {
    @Suite("Recursive Structures")
    struct RecursiveTests {
        @Test("Recursive tree generation with depth control")
        func recursiveTreeGeneration() throws {
            func treeGen(depth: Int) -> ReflectiveGenerator<TestTree<Int>> {
                if depth <= 0 {
                    // Leaf node
                    return #gen(.int(in: 1 ... 100))
                        .mapped(forward: { TestTree(value: $0, children: []) },
                                backward: \.value)
                } else {
                    // Internal node with children
                    return #gen(.int(in: 1 ... 100), treeGen(depth: depth - 1).array(length: 0 ... 3)) { value, children in
                        TestTree(value: value, children: children)
                    }
                }
            }

            let generator = treeGen(depth: 3).resize(100)
            let trees = try #example(generator, count: 10, seed: 42)
            #expect(trees.count == 10)
            #expect(trees.contains { $0.children.isEmpty == false })

            /// Validate tree structure
            func validateDepth(_ tree: TestTree<Int>, maxDepth: Int) -> Bool {
                guard (1 ... 100).contains(tree.value), tree.children.count <= 3 else {
                    return false
                }
                if maxDepth <= 0 {
                    return tree.children.isEmpty
                }
                return tree.children.allSatisfy { validateDepth($0, maxDepth: maxDepth - 1) }
            }

            for tree in trees {
                #expect(validateDepth(tree, maxDepth: 3))
            }

            let report = #examine(generator, .samples(10), .replay(42))
            #expect(report.passed)
        }

        @Test("Nested lensed properties")
        func nestedLensedProperties() {
            struct Outer: Equatable { // swiftlint:disable:this nesting
                let inners: [Inner]
                let id: UInt
            }
            struct Inner: Equatable { // swiftlint:disable:this nesting
                let id: UInt
            }

            // This works
            let innerGen = #gen(.uint())
                .array(length: 1 ... 1)
                .mapped(
                    forward: { ints in ints.map { Inner(id: $0) } },
                    backward: { inners in inners.map(\.id) }
                )

            let innerGen2 = #gen(.uint()) { Inner(id: $0) }
                .array(length: 1 ... 1)

            // Test the two type-safe approaches
            for generator in [innerGen, innerGen2] {
                // Test the outer generator with each inner generator
                let outerGen = #gen(generator, .uint()) { inners, id in
                    Outer(inners: inners, id: id)
                }

                #expect(#examine(outerGen, .samples(20), .replay(42)).passed)
            }
        }
    }

    @Suite("Extreme Value Handling")
    struct ExtremeValueTests {
        @Test("Generator robustness with extreme values")
        func extremeValueHandling() {
            let extremeGenerators: [ReflectiveGenerator<Int>] = [
                #gen(.int(in: Int.min ... Int.min)), // Minimum value
                #gen(.int(in: Int.max ... Int.max)), // Maximum value
                #gen(.int(in: -1 ... 1)), // Small range around zero
                #gen(.int(in: 0 ... 0)), // Single value
            ]

            for generator in extremeGenerators {
                #expect(#examine(generator, .samples(10), .replay(42)).passed)
            }
        }

        @Test("Large nested structures reflect and replay")
        func largeNestedStructures() {
            // Generate structures with significant nesting but reasonable memory usage
            let largeNestedGen = #gen(.int())
                .array(length: 50 ... 50) // 50 elements
                .array(length: 10 ... 10) // 10 inner arrays
                .array(length: 2 ... 2) // 2 outer arrays

            let report = #examine(largeNestedGen, .samples(3), .replay(42)) { $0 == $1 }
            #expect(report.passed)
            #expect(report.valuesGenerated == 3)
            #expect(report.replayDeterminismSuccesses == 3)
        }
    }
}
