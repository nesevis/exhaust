//
//  CGSBinarySearchTreeTests.swift
//  Exhaust
//
//  Tests showcasing Choice Gradient Sampling (CGS) on Binary Search Trees,
//  following the reference implementation from the thesis.
//

import Testing
@testable import Exhaust
import Foundation

// MARK: - Binary Search Tree Definition

enum BinarySearchTree<T: Comparable & Arbitrary & BitPatternConvertible & Hashable>: Equatable, Arbitrary, Hashable {
    case leaf
    indirect case node(left: BinarySearchTree<T>, value: T, right: BinarySearchTree<T>)
    
    static var arbitrary: ReflectiveGenerator<BinarySearchTree<T>> {
        bstGenerator(maxDepth: 5)
//        Gen.choose(in: 1...5).bind {
//        }
    }
    
    /// Creates a standard recursive binary tree generator.
    /// CGS will learn to optimize the choice weights and value ranges to increase BST validity.
    private static func bstGenerator(maxDepth: Int) -> ReflectiveGenerator<BinarySearchTree<T>> {
        if maxDepth <= 0 {
            return Gen.just(.leaf)
        }
        
        return Gen.pick(choices: [
            (weight: 1, Gen.just(.leaf)),
            (weight: 3, Gen.zip(
                bstGenerator(maxDepth: maxDepth - 1),
                Gen.choose(in: T.init(bitPattern64: 0)...T.init(bitPattern64: 9)),
                bstGenerator(maxDepth: maxDepth - 1)
            ).map { left, value, right in
                .node(left: left, value: value, right: right)
            })
        ])
    }
    
//    func hash(into hasher: inout Hasher) {
//        switch self {
//        case .leaf:
//            hasher.combine(1)
//        case .node(let left, let value, let right):
//            hasher.combine(left)
//            hasher.combine(value)
//            hasher.combine(right)
//        }
//    }
}


// MARK: - BST Validation

extension BinarySearchTree {
    /// Validates that this tree satisfies the binary search tree property
    func isValidBST() -> Bool {
        return isValidBST(min: nil, max: nil)
    }
    
    private func isValidBST(min: T?, max: T?) -> Bool {
        switch self {
        case .leaf:
            return true
        case let .node(left, value, right):
            // Check bounds
            if let min = min, value <= min { return false }
            if let max = max, value >= max { return false }
            
            // Recursively check subtrees with updated bounds
            return left.isValidBST(min: min, max: value) && 
                   right.isValidBST(min: value, max: max)
        }
    }
    
    /// Returns the height of the tree (for debugging/analysis)
    var height: Int {
        switch self {
        case .leaf: return 0
        case let .node(left, _, right):
            return 1 + max(left.height, right.height)
        }
    }
    
    /// Returns the number of nodes in the tree
    var nodeCount: Int {
        switch self {
        case .leaf: return 0
        case let .node(left, _, right):
            return 1 + left.nodeCount + right.nodeCount
        }
    }
}

// MARK: - Helper Functions

func countChoicesInTree(_ tree: ChoiceTree) -> Int {
    switch tree {
    case .choice(_, _):
        return 1
    case .just(_):
        return 0
    case let .sequence(_, elements, _):
        return elements.reduce(0) { $0 + countChoicesInTree($1) }
    case let .branch(_, _, children):
        return children.reduce(0) { $0 + countChoicesInTree($1) }
    case let .group(children):
        return children.reduce(0) { $0 + countChoicesInTree($1) }
    case let .selected(child):
        return countChoicesInTree(child)
    case .getSize(_):
        return 0
    case let .resize(_, children):
        return children.reduce(0) { $0 + countChoicesInTree($1) }
    case .important(let child):
        return countChoicesInTree(child)
    }
}

// MARK: - CGS BST Tests

@Suite("CGS Binary Search Tree Tests")
struct CGSBinarySearchTreeTests {
    
    @Test("CGS adaptation versus rejection sampling")
    func testCGSAdaptationVsRejectionSampling() async throws {
        let naive = BinarySearchTree<UInt>.arbitrary
        
        let validBst: (BinarySearchTree<UInt>) -> Bool = { tree in
            return tree.isValidBST() && tree != .leaf
        }
        
        var start = Date()
        let rejectionSampled = naive.filter(validBst)
        let rejection = ValueInterpreter(rejectionSampled, maxRuns: 100000)
        let rsampled = Array(rejection)
        let results = rsampled.map { validBst($0) }
        print("Rejection sampling: true \(results.count(where: { $0 })) false: \(results.count(where: { !$0 }))")
        print("Rejection sampling: Unique BSTs: \(Set(rsampled.filter(validBst)).count)")
        print("Rejection sampling: \(Date().timeIntervalSince(start) * 1000)ms")
        
        start = Date()
        let adapted = try SpeculativeAdaptationInterpreter.adapt(original: naive, samples: 1000, validBst)
        print("CGS: adaptation \(Date().timeIntervalSince(start) * 1000)ms")
        start = Date()
        let cgs = ValueInterpreter(adapted, maxRuns: 100000)
        let cgsArr = Array(cgs)
        var cgsResults = cgsArr.map { validBst($0) }
//        print("CGS: \(adapted.debugDescription)")
        print("CGS sampling: true \(cgsResults.count(where: { $0 })) false: \(cgsResults.count(where: { !$0 }))")
        print("CGS: Unique BSTs: \(Set(cgsArr.filter(validBst)).count)")
        print("CGS: \(Date().timeIntervalSince(start) * 1000)ms")
        
        print("Rejection: \(rejectionSampled.debugDescription)")
        print("CGS: \(adapted.debugDescription)")
    }
    
    @Test("CGS optimisation versus rejection sampling")
    func testCGSVsRejectionSampling() async throws {
        let naive = BinarySearchTree<UInt>.arbitrary
        
        let validBst: (BinarySearchTree<UInt>) -> Bool = { tree in
            return tree.isValidBST()
        }
        
        let rejectionSampled = naive.filter(validBst)
        
        let adapted = try SpeculativeAdaptationInterpreter.adapt(original: naive, validBst)
        
        let optimized = await ChoiceGradientSampler.optimize(
            naive,
            for: validBst,
            samples: 50,  // Thesis parameter: N=50
            iterations: 15,  // More iterations for convergence
            seed: 12345  // Fixed seed for reproducible results
        )
        print("BST CGS Results:")
        print("  Original validity rate: \(String(format: "%.3f", optimized.tuningMetrics.originalValidRate))")
        print("  Optimized validity rate: \(String(format: "%.3f", optimized.tuningMetrics.optimizedValidRate))")
        print("  Improvement factor: \(String(format: "%.2fx", optimized.tuningMetrics.improvementFactor))")
        print("  Convergence iterations: \(optimized.tuningMetrics.convergenceIterations)")
        print("  Total oracle calls: \(optimized.tuningMetrics.totalOracleCalls)")
        print("  Shrinking viability score: \(String(format: "%.3f", optimized.tuningMetrics.shrinkingViabilityScore))")
        
        let cgsOptimised = optimized.baseGenerator
        
        let seed: UInt64 = 12345
        let maxRuns: UInt64 = 1_000_000
        var naiveIterator = ValueInterpreter(naive, seed: seed, maxRuns: maxRuns)
        var rejectionIterator = ValueInterpreter(rejectionSampled, seed: seed, maxRuns: maxRuns)
        var cgsIterator = ValueInterpreter(cgsOptimised, seed: seed, maxRuns: maxRuns)
        var validNaive = [Int: Int]()
        var validRejection = validNaive
        var validCGS = validNaive
        
        var start = Date()
        while Date().timeIntervalSince(start) < 1, let next = naiveIterator.next() {
            if validBst(next) {
                validNaive[next.height, default: 0] += 1
            }
        }
        print("Generated \(validNaive.sorted(by: { $0.key < $1 .key })) (total: \(validNaive.values.reduce(0, +))) valid values using the naive method.")
        
        start = Date()
        while Date().timeIntervalSince(start) < 1, let next = rejectionIterator.next() {
            if validBst(next) {
                validRejection[next.height, default: 0] += 1
            }
        }
        print("Generated \(validRejection.sorted(by: { $0.key < $1 .key })) (total: \(validRejection.values.reduce(0, +))) valid values using rejection samplng.")
        
        start = Date()
        while Date().timeIntervalSince(start) < 1, let next = cgsIterator.next() {
            if validBst(next) {
                validCGS[next.height, default: 0] += 1
            }
        }
        print("Generated \(validCGS.sorted(by: { $0.key < $1 .key })) (total: \(validCGS.values.reduce(0, +))) valid values using choice gradient samplng-optimised generator.")
        
        let cgs = ValueAndChoiceTreeInterpreter(cgsOptimised, seed: seed, maxRuns: 1).first(where: { _ in true })
        let rejection = ValueAndChoiceTreeInterpreter(cgsOptimised, seed: seed, maxRuns: 1).first(where: { _ in true })
        
        print()
    }
    
//    @Test("CGS2 reference implementation versus rejection sampling")
//    func testCGS2VsRejectionSampling() async throws {
//        let naive = BinarySearchTree<UInt>.arbitrary
//        
//        let validBst: (BinarySearchTree<UInt>) -> Bool = { tree in
//            return tree.isValidBST()
//        }
//        
//        let rejectionSampled = naive.filter(validBst)
//        
//        let optimized = await ChoiceGradientSampler2.optimize(
//            naive,
//            for: validBst,
//            samples: 50,  // Thesis parameter: N=50
//            maxIterations: 5
//        )
//        
//        print("BST CGS2 (Reference) Results:")
//        print("  Original validity rate: \(String(format: "%.3f", optimized.originalValidRate))")
//        print("  Final validity rate: \(String(format: "%.3f", optimized.finalValidRate))")
//        print("  Improvement factor: \(String(format: "%.2fx", optimized.improvementFactor))")
//        print("  Valid values discovered: \(optimized.validValues.count)")
//        
//        let seed: UInt64 = 12345
//        let maxRuns: UInt64 = 1_000_000
//        var naiveIterator = ValueInterpreter(naive, seed: seed, maxRuns: maxRuns)
//        var rejectionIterator = ValueInterpreter(rejectionSampled, seed: seed, maxRuns: maxRuns)
//        var cgs2Iterator = ValueInterpreter(optimized.optimizedGenerator, seed: seed, maxRuns: maxRuns)
//        var validNaive = [Int: Int]()
//        var validRejection = validNaive
//        var validCGS2 = validNaive
//        
//        var start = Date()
//        while Date().timeIntervalSince(start) < 1, let next = naiveIterator.next() {
//            if validBst(next) {
//                validNaive[next.height, default: 0] += 1
//            }
//        }
//        print("Generated \(validNaive.sorted(by: { $0.key < $1.key })) (total: \(validNaive.values.reduce(0, +))) valid values using the naive method.")
//        
//        start = Date()
//        while Date().timeIntervalSince(start) < 1, let next = rejectionIterator.next() {
//            if validBst(next) {
//                validRejection[next.height, default: 0] += 1
//            }
//        }
//        print("Generated \(validRejection.sorted(by: { $0.key < $1.key })) (total: \(validRejection.values.reduce(0, +))) valid values using rejection sampling.")
//        
//        start = Date()
//        while Date().timeIntervalSince(start) < 1, let next = cgs2Iterator.next() {
//            if validBst(next) {
//                validCGS2[next.height, default: 0] += 1
//            }
//        }
//        print("Generated \(validCGS2.sorted(by: { $0.key < $1.key })) (total: \(validCGS2.values.reduce(0, +))) valid values using CGS2 reference implementation.")
//        
//        print()
//    }
    
    @Test("CGS optimization for BST validity")
    func testCGSBSTOptimization() async throws {
        // Create a naive generator that produces arbitrary binary trees
//        let naiveGenerator = Gen.classify(
//            BinarySearchTree<UInt>.arbitrary,
//            ("leaf", { $0.height == 0 }),
//            ("2", { $0.height == 2 }),
//            ("3", { $0.height == 3 }),
//            ("4", { $0.height == 4 }),
//            (">4", { $0.height > 4 })
//        )
        
        let naiveGenerator = BinarySearchTree<UInt>.arbitrary
        
        // Debug: Analyze the generator structure directly
        print("=== Debug: Generator Structure Analysis ===")
        let potential = ChoiceGradientSampler.predictViability(for: naiveGenerator)
        print("Structural Analysis Details:")
        print("  Branching Score: \(potential.branchingScore)")
        print("  Sequence Score: \(potential.sequenceScore)")
        print("  Choice Score: \(potential.choiceScore)")
        print("  Overall Score: \(potential.overallScore)")
        print("  Should Use CGS: \(potential.shouldUseCGS)")
        
        // Debug: Generate a few samples to see the ChoiceTree structure
        var valueTreeGen = ValueAndChoiceTreeInterpreter(naiveGenerator, maxRuns: 3)
        for i in 0..<3 {
            if let (value, tree) = valueTreeGen.next() {
                print("Sample \(i + 1):")
                print("  Generated value height: \(value.height)")
//                print("  ChoiceTree structure (first 500 chars): \(String(tree.debugDescription.prefix(500)))")
                // Count choices recursively
                let choiceCount = countChoicesInTree(tree)
                print("  Choice nodes in tree: \(choiceCount)")
            }
        }
        print("=== End Debug ===\n")
        
        // Property: tree must be a valid BST
        let bstProperty: (BinarySearchTree<UInt>) -> Bool = { tree in
            if case .leaf = tree {
                return false
            }
            return tree.isValidBST()
        }
        
        // Run CGS optimization to improve BST validity rate
        let optimized = await ChoiceGradientSampler.optimize(
            naiveGenerator,
            for: bstProperty,
            samples: 50,  // Thesis parameter: N=50
            iterations: 15,  // More iterations for convergence
            seed: 12345  // Fixed seed for reproducible results
        )
        
        // Validate metrics and improvement
        #expect(optimized.tuningMetrics.originalValidRate >= 0.0)
        #expect(optimized.tuningMetrics.optimizedValidRate > optimized.tuningMetrics.originalValidRate)
        #expect(optimized.tuningMetrics.improvementFactor > 1.0)
        
        print("BST CGS Results:")
        print("  Original validity rate: \(String(format: "%.3f", optimized.tuningMetrics.originalValidRate))")
        print("  Optimized validity rate: \(String(format: "%.3f", optimized.tuningMetrics.optimizedValidRate))")
        print("  Improvement factor: \(String(format: "%.2fx", optimized.tuningMetrics.improvementFactor))")
        print("  Convergence iterations: \(optimized.tuningMetrics.convergenceIterations)")
        print("  Total oracle calls: \(optimized.tuningMetrics.totalOracleCalls)")
        print("  Shrinking viability score: \(String(format: "%.3f", optimized.tuningMetrics.shrinkingViabilityScore))")
        
        // Test that the optimized generator actually produces valid BSTs more frequently
        var validCount = 0
        let testSamples = 100
        var iterator = ValueInterpreter(optimized.baseGenerator, seed: 67890)
        
        // Track height distribution
        var heightCounts: [Int: Int] = [:]
        var validHeightCounts: [Int: Int] = [:]
        
        for _ in 0..<testSamples {
            if let tree = iterator.next() {
                let height = tree.height
                heightCounts[height, default: 0] += 1
                
                let isValid = tree.isValidBST() && tree.height > 0  // Exclude leaves
                if isValid {
                    validCount += 1
                    validHeightCounts[height, default: 0] += 1
                }
            }
        }
        
        let actualValidityRate = Double(validCount) / Double(testSamples)
        print("  Actual post-optimization validity rate: \(String(format: "%.3f", actualValidityRate))")
        
        // Print height distribution
        print("  Height distribution (all trees):")
        let sortedHeights = heightCounts.keys.sorted()
        for height in sortedHeights {
            let count = heightCounts[height]!
            let percentage = Double(count) / Double(testSamples) * 100
            print("    Height \(height): \(count) trees (\(String(format: "%.1f", percentage))%)")
        }
        
        print("  Height distribution (valid BSTs only):")
        if validCount > 0 {
            let sortedValidHeights = validHeightCounts.keys.sorted()
            for height in sortedValidHeights {
                let count = validHeightCounts[height]!
                let percentage = Double(count) / Double(validCount) * 100
                print("    Height \(height): \(count) valid BSTs (\(String(format: "%.1f", percentage))%)")
            }
        } else {
            print("    No valid BSTs generated")
        }
        
        // The optimized generator should produce valid BSTs at a reasonable rate
        #expect(actualValidityRate > 0.1)  // At least 10% should be valid
        print(optimized.baseGenerator.debugDescription)
    }
    
    @Test("BST property validation examples")
    func testBSTPropertyValidation() {
        // Valid BST examples
        let validBST1: BinarySearchTree<Int> = .leaf
        let validBST2: BinarySearchTree<Int> = .node(left: .leaf, value: 5, right: .leaf)
        let validBST3: BinarySearchTree<Int> = .node(
            left: .node(left: .leaf, value: 2, right: .leaf),
            value: 5,
            right: .node(left: .leaf, value: 8, right: .leaf)
        )
        
        #expect(validBST1.isValidBST())
        #expect(validBST2.isValidBST())
        #expect(validBST3.isValidBST())
        
        // Invalid BST examples
        let invalidBST1: BinarySearchTree<Int> = .node(
            left: .node(left: .leaf, value: 7, right: .leaf),  // 7 > 5, violates BST property
            value: 5,
            right: .leaf
        )
        let invalidBST2: BinarySearchTree<Int> = .node(
            left: .leaf,
            value: 5,
            right: .node(left: .leaf, value: 3, right: .leaf)  // 3 < 5, violates BST property
        )
        
        #expect(!invalidBST1.isValidBST())
        #expect(!invalidBST2.isValidBST())
    }
    
    @Test("BST generation analysis")
    func testBSTGenerationAnalysis() {
        let generator = BinarySearchTree<Int>.arbitrary
        var iterator = ValueInterpreter(generator, seed: 42)
        
        var totalTrees = 0
        var validBSTs = 0
        var heights: [Int] = []
        var nodeCounts: [Int] = []
        
        for _ in 0..<1000 {
            if let tree = iterator.next() {
                totalTrees += 1
                
                if tree.isValidBST() {
                    validBSTs += 1
                }
                
                heights.append(tree.height)
                nodeCounts.append(tree.nodeCount)
            }
        }
        
        let validityRate = Double(validBSTs) / Double(totalTrees)
        let avgHeight = heights.isEmpty ? 0.0 : Double(heights.reduce(0, +)) / Double(heights.count)
        let avgNodeCount = nodeCounts.isEmpty ? 0.0 : Double(nodeCounts.reduce(0, +)) / Double(nodeCounts.count)
        
        print("Naive BST Generation Analysis:")
        print("  Total trees generated: \(totalTrees)")
        print("  Valid BSTs: \(validBSTs)")
        print("  Naive validity rate: \(String(format: "%.3f", validityRate))")
        print("  Average height: \(String(format: "%.2f", avgHeight))")
        print("  Average node count: \(String(format: "%.2f", avgNodeCount))")
        
        #expect(totalTrees > 0)
        #expect(validityRate >= 0.0)
        #expect(validityRate <= 1.0)
    }
    
    @Test("CGS with bounded BST values")
    func testCGSBoundedBSTValues() async throws {
        // Create a generator for BSTs with values in a small range (0-9, like the thesis)
        let boundedGenerator = BinarySearchTree<Int>.arbitrary.map { tree in
            tree.mapValues { abs($0) % 10 }
        }
        
        let bstProperty: (BinarySearchTree<Int>) -> Bool = { tree in
            tree.isValidBST()
        }
        
        let optimized = await ChoiceGradientSampler.optimize(
            boundedGenerator,
            for: bstProperty,
            samples: 200,
            iterations: 10,
            seed: 54321
        )
        
        print("Bounded BST (0-9) CGS Results:")
        print("  Original validity rate: \(String(format: "%.3f", optimized.tuningMetrics.originalValidRate))")
        print("  Optimized validity rate: \(String(format: "%.3f", optimized.tuningMetrics.optimizedValidRate))")
        print("  Improvement factor: \(String(format: "%.2fx", optimized.tuningMetrics.improvementFactor))")
        
        #expect(optimized.tuningMetrics.optimizedValidRate >= optimized.tuningMetrics.originalValidRate)
    }
}

// MARK: - Helper Extensions

extension BinarySearchTree {
    /// Maps the values in the tree using the provided transformation
    func mapValues<U: Comparable>(_ transform: (T) -> U) -> BinarySearchTree<U> {
        switch self {
        case .leaf:
            return .leaf
        case let .node(left, value, right):
            return .node(
                left: left.mapValues(transform),
                value: transform(value),
                right: right.mapValues(transform)
            )
        }
    }
}
