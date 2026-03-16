//
//  AdvancedFeatureTests.swift
//  ExhaustTests
//
//  Advanced tests including recursive structures, enums, conditional generation,
//  and complex scenarios.
//

import Testing
@testable import Exhaust

// MARK: - Advanced Data Structures

struct TestTree<T: Equatable>: Equatable {
    let value: T
    let children: [TestTree<T>]
}

struct TestGraph: Equatable {
    let nodes: [TestNode]
    let edges: [TestEdge]
}

struct TestNode: Equatable {
    let id: Int
    let label: String
}

struct TestEdge: Equatable {
    let from: Int
    let to: Int
    let weight: Double
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
                    return #gen(.int(in: 1 ... 100)) { value in
                        TestTree(value: value, children: [])
                    }
                } else {
                    // Internal node with children
                    return #gen(.int(in: 1 ... 100), treeGen(depth: depth - 1).array(length: 0 ... 3)) { value, children in
                        TestTree(value: value, children: children)
                    }
                }
            }

            let gen = treeGen(depth: 3)
            let trees = #example(gen, count: 10, seed: 42)

            /// Validate tree structure
            func validateDepth(_ tree: TestTree<Int>, maxDepth: Int) -> Bool {
                if maxDepth <= 0 { return tree.children.isEmpty }
                return tree.children.allSatisfy { validateDepth($0, maxDepth: maxDepth - 1) }
            }

            for tree in trees {
                #expect(validateDepth(tree, maxDepth: 3))
            }

            // Test round-trip
            #examine(gen, samples: 10, seed: 42)
        }

        @Test("Nested lensed properties")
        func nestedLensedProperties() {
            struct Outer: Equatable {
                let inners: [Inner]
                let id: UInt
            }
            struct Inner: Equatable {
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
            for gen in [innerGen, innerGen2] {
                // Test the outer generator with each inner generator
                let outerGen = #gen(gen, .uint()) { inners, id in
                    Outer(inners: inners, id: id)
                }

                #examine(outerGen, samples: 20, seed: 42)
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

            for gen in extremeGenerators {
                #examine(gen, samples: 10, seed: 42)
            }
        }

        @Test("Large nested structure generation and memory efficiency")
        func largeNestedStructures() {
            // Generate structures with significant nesting but reasonable memory usage
            let largeNestedGen = #gen(.int())
                .array(length: 50 ... 50) // 50 elements
                .array(length: 10 ... 10) // 10 inner arrays
                .array(length: 2 ... 2) // 2 outer arrays

            // Test round-trip (this tests memory efficiency of reflection/replay)
            #examine(largeNestedGen, samples: 3, seed: 42)
        }
    }
}
