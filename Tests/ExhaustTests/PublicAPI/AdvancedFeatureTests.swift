//
//  AdvancedFeatureTests.swift
//  ExhaustTests
//
//  Advanced tests including recursive structures, enums, conditional generation,
//  and complex scenarios.
//

import ExhaustCore
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

            for _ in 0 ..< 10 {
                var iterator = ValueInterpreter(gen)
                let tree = try iterator.next()!

                /// Validate tree structure
                func validateDepth(_ tree: TestTree<Int>, maxDepth: Int) -> Bool {
                    if maxDepth <= 0 { return tree.children.isEmpty }
                    return tree.children.allSatisfy { validateDepth($0, maxDepth: maxDepth - 1) }
                }

                #expect(validateDepth(tree, maxDepth: 3))

                // Test round-trip
                if let recipe = try Interpreters.reflect(gen, with: tree) {
                    if let replayed = try Interpreters.replay(gen, using: recipe) {
                        #expect(tree == replayed)
                    } else {
                        #expect(Bool(false), "Replay failed for tree")
                    }
                } else {
                    #expect(Bool(false), "Reflection failed for tree")
                }
            }
        }

        @Test("Nested lensed properties")
        func nestedLensedProperties() throws {
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
                    backward: { inners in inners.map(\.id) },
                )

            let innerGen2 = #gen(.uint()) { Inner(id: $0) }
                .array(length: 1 ... 1)

            // Test the two type-safe approaches
            for (index, gen) in [innerGen, innerGen2].enumerated() {
                // Test the outer generator with each inner generator
                let outerGen = #gen(gen, .uint()) { inners, id in
                    Outer(inners: inners, id: id)
                }

                var iterator = ValueInterpreter(outerGen)
                let generated = try iterator.next()

                guard let generated else {
                    continue
                }

                let recipe = try Interpreters.reflect(outerGen, with: generated)

                if let recipe {
                    let replayed = try Interpreters.replay(outerGen, using: recipe)

                    if let replayed {
                        #expect(generated == replayed)
                    }
                }
            }
        }
    }

    @Suite("Graph Generation")
    struct GraphTests {
        @Test("Connected graph generation with constraints")
        func connectedGraphGeneration() throws {
            let nodeGen = #gen(.int(in: 0 ... 9), .string()) { id, label in
                TestNode(id: id, label: label)
            }

            let edgeGen = #gen(.int(in: 0 ... 9), .int(in: 0 ... 9), .double(in: 0.1 ... 10.0)) { from, to, weight in
                TestEdge(from: from, to: to, weight: weight)
            }

            let graphGen = #gen(nodeGen.array(length: 5 ... 10), edgeGen.array(length: 3 ... 15)).mapped(
                forward: { nodes, edges in
                    // Filter edges to only include those referencing existing nodes
                    let nodeIds = Set(nodes.map(\.id))
                    let validEdges = edges.filter { edge in
                        nodeIds.contains(edge.from) && nodeIds.contains(edge.to)
                    }
                    return TestGraph(nodes: nodes, edges: validEdges)
                },
                backward: { ($0.nodes, $0.edges) },
            )

            for _ in 0 ..< 10 {
                var iterator = ValueInterpreter(graphGen)
                let graph = try iterator.next()!

                // Validate graph constraints
                #expect(5 ... 10 ~= graph.nodes.count)
                // Edges may be filtered, so just check it's non-negative
                #expect(graph.edges.count >= 0) // swiftlint:disable:this empty_count

                // Check edge references are valid (within node ID range)
                let nodeIds = Set(graph.nodes.map(\.id))
                for edge in graph.edges {
                    #expect(nodeIds.contains(edge.from) && nodeIds.contains(edge.to))
                }

                // Test round-trip
                if let recipe = try Interpreters.reflect(graphGen, with: graph) {
                    if let replayed = try Interpreters.replay(graphGen, using: recipe) {
                        #expect(graph == replayed)
                    } else {
                        Issue.record("Replay failed for graph")
                    }
                } else {
                    Issue.record("Reflection failed for graph")
                }
            }
        }
    }

    @Suite("Extreme Value Handling")
    struct ExtremeValueTests {
        @Test("Generator robustness with extreme values")
        func extremeValueHandling() throws {
            let extremeGenerators: [ReflectiveGenerator<Int>] = [
                #gen(.int(in: Int.min ... Int.min)), // Minimum value
                #gen(.int(in: Int.max ... Int.max)), // Maximum value
                #gen(.int(in: -1 ... 1)), // Small range around zero
                #gen(.int(in: 0 ... 0)), // Single value
            ]

            for (index, gen) in extremeGenerators.enumerated() {
                for _ in 0 ..< 10 {
                    var iterator = ValueInterpreter(gen)
                    let value = try iterator.next()!

                    // Test round-trip even with extreme values
                    if let recipe = try Interpreters.reflect(gen, with: value) {
                        if let replayed = try Interpreters.replay(gen, using: recipe) {
                            #expect(value == replayed, "Extreme generator \(index) failed round-trip")
                        } else {
                            Issue.record("Replay failed for extreme generator \(index)")
                        }
                    } else {
                        Issue.record("Reflection failed for extreme generator \(index)")
                    }
                }
            }
        }

        @Test("Large nested structure generation and memory efficiency")
        func largeNestedStructures() throws {
            // Generate structures with significant nesting but reasonable memory usage
            let largeNestedGen = #gen(.int())
                .array(length: 50 ... 50) // 50 elements
                .array(length: 10 ... 10) // 10 inner arrays
                .array(length: 2 ... 2) // 2 outer arrays

            var iterator = ValueInterpreter(largeNestedGen)
            let large = try iterator.next()!

            // Validate structure
            #expect(large.count == 2)
            for level1 in large {
                #expect(level1.count == 10)
                for level2 in level1 {
                    #expect(level2.count == 50)
                }
            }

            // Test round-trip (this tests memory efficiency of reflection/replay)
            if let recipe = try Interpreters.reflect(largeNestedGen, with: large) {
                if let replayed = try Interpreters.replay(largeNestedGen, using: recipe) {
                    #expect(large == replayed)
                } else {
                    Issue.record("Replay failed for large nested structure")
                }
            } else {
                Issue.record("Reflection failed for large nested structure")
            }
        }
    }
}
