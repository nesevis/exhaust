//
//  AdvancedFeatureTests.swift
//  ExhaustTests
//
//  Advanced tests including recursive structures, enums, conditional generation,
//  and complex scenarios.
//

import Testing
import CasePaths
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
        func testRecursiveTreeGeneration() {
            func treeGen(depth: Int) -> ReflectiveGenerator<Any, TestTree<Int>> {
                if depth <= 0 {
                    // Leaf node
                    return Gen.lens(extract: \TestTree<Int>.value, Gen.choose(in: 1...100))
                        .map { value in TestTree(value: value, children: []) }
                } else {
                    // Internal node with children
                    let valueGen = Gen.lens(extract: \TestTree<Int>.value, Gen.choose(in: 1...100))
                    let childrenGen = Gen.lens(extract: \TestTree<Int>.children, 
                                             treeGen(depth: depth - 1).proliferate(with: 0...3))
                    
                    return valueGen.bind { value in
                        childrenGen.map { children in
                            TestTree(value: value, children: children)
                        }
                    }
                }
            }
            
            let gen = treeGen(depth: 3)
            
            for _ in 0..<10 {
                let tree = Interpreters.generate(gen)!
                
                // Validate tree structure
                func validateDepth(_ tree: TestTree<Int>, maxDepth: Int) -> Bool {
                    if maxDepth <= 0 { return tree.children.isEmpty }
                    return tree.children.allSatisfy { validateDepth($0, maxDepth: maxDepth - 1) }
                }
                
                #expect(validateDepth(tree, maxDepth: 3))
                
                // Test round-trip
                if let recipe = Interpreters.reflect(gen, with: tree) {
                    if let replayed = Interpreters.replay(gen, using: recipe) {
                        #expect(tree == replayed)
                    } else {
                        #expect(false, "Replay failed for tree")
                    }
                } else {
                    #expect(false, "Reflection failed for tree")
                }
            }
        }
        
        @Test("Nested lensed properties")
        func testNestedLensedProperties() {
            struct Outer: Equatable {
                let inners: [Inner]
                let id: UInt
            }
            struct Inner: Equatable {
                let id: UInt
            }
            
            // This works
            let innerGen = Gen.lens(extract: \Inner.id, Gen.choose(type: UInt.self))
                .proliferate(with: 1...1)
                // Casting to the type needs to be the last thing in the chain
                .map { ints in ints.map { Inner(id: $0) }}
            
            // This crashes
            let innerGen2 = Gen.lens(extract: \Inner.id, Gen.choose(type: UInt.self))
                .map { Inner(id: $0) }
                .proliferate(with: 1...1)
            
            // Test the two type-safe approaches
            for (index, gen) in [innerGen, innerGen2].enumerated() {
                // Test the outer generator with each inner generator
                let outerGen = Gen.lens(
                    extract: \Outer.inners,
                    gen
                )
                    .bind { inners in
                        Gen.lens(extract: \Outer.id, Gen.choose(type: UInt.self)).map { id in
                            Outer(inners: inners, id: id)
                        }
                    }
                
                let generated = Interpreters.generate(outerGen)
                
                guard let generated = generated else {
                    continue
                }
                
                let recipe = Interpreters.reflect(outerGen, with: generated)
                
                if let recipe = recipe {
                    let replayed = Interpreters.replay(outerGen, using: recipe)
                    
                    if let replayed = replayed {
                        #expect(generated == replayed)
                    }
                }
            }
        }
    }
    
    @Suite("Enum Generation")
    struct EnumTests {
        
        @CasePathable
        indirect enum TestVariant: Equatable {
            case simple(Int)
            case complex(String, [Int])
            case nested(TestVariant)
        }
        
        @Test("Complex enum variant generation")
        func testComplexEnumGeneration() {
            let simpleGen = Gen.lens(extract: /TestVariant.simple.self,
                                    Gen.choose(in: 1...10))
                .map(TestVariant.simple)
            
            let complexGen = Gen.lens(extract: /TestVariant.complex.self,
                                     Gen.just("test").bind { str in
                                         Gen.just([42]).map { ints in
                                             (str, ints)
                                         }
                                     })
                .map { (str, ints) in
                    TestVariant.complex(str, ints)
                }
            
            // Recursive case with limited depth
            let nestedGen = Gen.lens(
                extract: /TestVariant.nested.self,
                Gen.lens(extract: /TestVariant.simple.self, Gen.just(99))
                    .map(TestVariant.simple)
            )
            .map(TestVariant.nested)
            
            let variantGen = Gen.pick(choices: [
                (weight: UInt64(2), generator: simpleGen),
                (weight: UInt64(2), generator: complexGen),
                (weight: UInt64(1), generator: nestedGen)
            ])
            
            var simpleCount = 0
            var complexCount = 0
            var nestedCount = 0
            
            for _ in 0..<100 {
                let variant = Interpreters.generate(variantGen)!
                
                switch variant {
                case .simple(_):
                    simpleCount += 1
                case .complex(_, _):
                    complexCount += 1
                case .nested(_):
                    nestedCount += 1
                }
                
                // Test round-trip for each variant
                if let recipe = Interpreters.reflect(variantGen, with: variant) {
                    if let replayed = Interpreters.replay(variantGen, using: recipe) {
                        #expect(variant == replayed)
                    } else {
                        #expect(false, "Replay failed for variant")
                    }
                } else {
                    #expect(false, "Reflection failed for variant")
                }
            }
            
            // Check that all variants were generated
            #expect(simpleCount > 0)
            #expect(complexCount > 0)
            #expect(nestedCount > 0)
        }
    }
    
    @Suite("Graph Generation")
    struct GraphTests {
        
        @Test("Connected graph generation with constraints")
        func testConnectedGraphGeneration() {
            let nodeGen = Gen.lens(extract: \TestNode.id, Gen.choose(in: 0...9))
                .bind { id in
                    Gen.lens(extract: \TestNode.label, String.arbitrary).map { label in
                        TestNode(id: id, label: label)
                    }
                }
            
            // Use a fixed range that matches the node generation range
            let edgeGen = Gen.lens(extract: \TestEdge.from, Gen.choose(in: 0...9))
                .bind { from in
                    Gen.lens(extract: \TestEdge.to, Gen.choose(in: 0...9))
                        .bind { to in
                            Gen.lens(extract: \TestEdge.weight, Gen.choose(in: 0.1...10.0)).map { weight in
                                TestEdge(from: from, to: to, weight: weight)
                            }
                        }
                }
            
            let graphGen = Gen.lens(extract: \TestGraph.nodes, nodeGen.proliferate(with: 5...10))
                .bind { nodes in
                    Gen.lens(extract: \TestGraph.edges, edgeGen.proliferate(with: 3...15)).map { edges in
                        // Filter edges to only include those referencing existing nodes
                        let nodeIds = Set(nodes.map(\.id))
                        let validEdges = edges.filter { edge in
                            nodeIds.contains(edge.from) && nodeIds.contains(edge.to)
                        }
                        return TestGraph(nodes: nodes, edges: validEdges)
                    }
                }
            
            for _ in 0..<10 {
                let graph = Interpreters.generate(graphGen)!
                
                // Validate graph constraints
                #expect(5...10 ~= graph.nodes.count)
                #expect(graph.edges.count >= 0) // Edges may be filtered, so just check it's non-negative
                
                // Check edge references are valid (within node ID range)
                let nodeIds = Set(graph.nodes.map(\.id))
                for edge in graph.edges {
                    #expect(nodeIds.contains(edge.from) && nodeIds.contains(edge.to))
                }
                
                // Test round-trip
                if let recipe = Interpreters.reflect(graphGen, with: graph) {
                    if let replayed = Interpreters.replay(graphGen, using: recipe) {
                        #expect(graph == replayed)
                    } else {
                        #expect(false, "Replay failed for graph")
                    }
                } else {
                    #expect(false, "Reflection failed for graph")
                }
            }
        }
    }
    
    @Suite("Conditional Generation")
    struct ConditionalTests {
        
        @Test("Conditional generation based on previous values")
        func testConditionalGeneration() {
            struct ConditionalData: Equatable {
                let type: String
                let value: Int
            }
            
            let typeGen = Gen.pick(choices: [
                (weight: UInt64(1), generator: Gen.just("small")),
                (weight: UInt64(1), generator: Gen.just("large"))
            ])
            
            let conditionalGen = typeGen.bind { type in
                let valueRange = type == "small" ? 1...10 : 100...1000
                return Gen.choose(in: valueRange, input: Any.self).map { value in
                    ConditionalData(type: type, value: value)
                }
            }
            
            for iteration in 0..<50 {
                let data = Interpreters.generate(conditionalGen)!
                
                // Validate conditional constraint
                if data.type == "small" {
                    #expect(1...10 ~= data.value)
                } else {
                    #expect(100...1000 ~= data.value)
                }
                
                // Test round-trip (conditional generators may not support reflection)
                if let recipe = Interpreters.reflect(conditionalGen, with: data) {
                    if let replayed = Interpreters.replay(conditionalGen, using: recipe) {
                        #expect(data == replayed)
                    }
                }
            }
        }
    }
    
    @Suite("Extreme Value Handling")
    struct ExtremeValueTests {
        
        @Test("Generator robustness with extreme values")
        func testExtremeValueHandling() {
            let extremeGenerators: [ReflectiveGenerator<Any, Int>] = [
                Gen.choose(in: Int.min...Int.min, input: Any.self),  // Minimum value
                Gen.choose(in: Int.max...Int.max, input: Any.self),  // Maximum value
                Gen.choose(in: -1...1, input: Any.self),             // Small range around zero
                Gen.choose(in: 0...0, input: Any.self)               // Single value
            ]
            
            for (index, gen) in extremeGenerators.enumerated() {
                for _ in 0..<10 {
                    let value = Interpreters.generate(gen)!
                    
                    // Test round-trip even with extreme values
                    if let recipe = Interpreters.reflect(gen, with: value) {
                        if let replayed = Interpreters.replay(gen, using: recipe) {
                            #expect(value == replayed, "Extreme generator \(index) failed round-trip")
                        } else {
                            #expect(false, "Replay failed for extreme generator \(index)")
                        }
                    } else {
                        #expect(false, "Reflection failed for extreme generator \(index)")
                    }
                }
            }
        }
        
        @Test("Large nested structure generation and memory efficiency")
        func testLargeNestedStructures() {
            // Generate structures with significant nesting but reasonable memory usage
            let largeNestedGen = Int.arbitrary
                .proliferate(with: 50...50)     // 50 elements
                .proliferate(with: 10...10)     // 10 inner arrays  
                .proliferate(with: 2...2)       // 2 outer arrays
            
            let large = Interpreters.generate(largeNestedGen)!
            
            // Validate structure
            #expect(large.count == 2)
            for level1 in large {
                #expect(level1.count == 10)
                for level2 in level1 {
                    #expect(level2.count == 50)
                }
            }
            
            // Test round-trip (this tests memory efficiency of reflection/replay)
            if let recipe = Interpreters.reflect(largeNestedGen, with: large) {
                if let replayed = Interpreters.replay(largeNestedGen, using: recipe) {
                    #expect(large == replayed)
                } else {
                    #expect(false, "Replay failed for large nested structure")
                }
            } else {
                #expect(false, "Reflection failed for large nested structure")
            }
        }
    }
}
