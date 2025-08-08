//
//  FeatureExtractionTests.swift
//  ExhaustTests
//
//  Created by Chris Kolbu on 8/8/2025.
//

import Testing
@testable import Exhaust

@Suite("Feature Extraction Tests")
struct FeatureExtractionTests {
    
    @Test("Feature extraction produces correct vector length")
    func testFeatureVectorLength() async throws {
        let tree = ChoiceTree.choice(
            ChoiceValue.unsigned(42),
            ChoiceMetadata(validRanges: [0...100], strategies: [])
        )
        
        let featureVector = tree.toFeatureVector()
        let expectedLength = ChoiceTree.featureNames.count
        
        #expect(featureVector.count == expectedLength)
        #expect(featureVector.count == 23) // As defined in featureNames
    }
    
    @Test("Pass selection features contain expected keys")
    func testPassSelectionFeatures() async throws {
        let tree = ChoiceTree.group([
            ChoiceTree.choice(ChoiceValue.unsigned(1), ChoiceMetadata(validRanges: [0...10], strategies: [])),
            ChoiceTree.sequence(
                length: 2,
                elements: [
                    ChoiceTree.choice(ChoiceValue.unsigned(2), ChoiceMetadata(validRanges: [0...10], strategies: [])),
                    ChoiceTree.choice(ChoiceValue.unsigned(3), ChoiceMetadata(validRanges: [0...10], strategies: []))
                ],
                ChoiceMetadata(validRanges: [0...10], strategies: [])
            )
        ])
        
        let features = tree.passSelectionFeatures()
        let expectedKeys = [
            "max_depth", "choice_count", "sequence_count", "branch_count", "group_count",
            "dominant_pattern", "important_node_ratio", "avg_branching_factor", "reduction_potential",
            "complexity_q1", "complexity_median", "complexity_q3"
        ]
        
        for key in expectedKeys {
            #expect(features[key] != nil, "Missing key: \(key)")
        }
    }
    
    @Test("Boundary features analysis")
    func testBoundaryFeatures() async throws {
        let tree = ChoiceTree.choice(
            ChoiceValue.unsigned(75), // 75% through range 0...100
            ChoiceMetadata(validRanges: [0...100], strategies: [])
        )
        
        let boundaryFeatures = tree.boundaryFeatures()
        
        #expect(boundaryFeatures["avg_range_size"] as? Double == 100.0)
        #expect(boundaryFeatures["max_range_size"] as? Double == 100.0)
        #expect(boundaryFeatures["range_count"] as? Int == 1)
        
        // Range utilization should be calculated based on position in range
        let utilization = boundaryFeatures["avg_range_utilization"] as? Double ?? 0.0
        #expect(utilization > 0.0)
    }
    
    @Test("Convergence features capture important ratio")
    func testConvergenceFeatures() async throws {
        let importantChoice = ChoiceTree.important(
            ChoiceTree.choice(ChoiceValue.unsigned(5), ChoiceMetadata(validRanges: [0...10], strategies: []))
        )
        
        let tree = ChoiceTree.group([
            importantChoice,
            ChoiceTree.choice(ChoiceValue.unsigned(8), ChoiceMetadata(validRanges: [0...10], strategies: []))
        ])
        
        let convergenceFeatures = tree.convergenceFeatures()
        
        #expect(convergenceFeatures["important_node_ratio"] as? Double ?? 0.0 > 0.0)
        #expect(convergenceFeatures["structural_complexity"] != nil)
        #expect(convergenceFeatures["convergence_indicator"] != nil)
    }
    
    @Test("Range features handle multiple choices")
    func testRangeFeatures() async throws {
        let elements = [
            ChoiceTree.choice(ChoiceValue.unsigned(10), ChoiceMetadata(validRanges: [0...100], strategies: [])),
            ChoiceTree.choice(ChoiceValue.unsigned(50), ChoiceMetadata(validRanges: [0...1000], strategies: [])),
            ChoiceTree.choice(ChoiceValue.unsigned(5), ChoiceMetadata(validRanges: [0...10], strategies: []))
        ]
        
        let tree = ChoiceTree.group(elements)
        let rangeFeatures = tree.rangeFeatures()
        
        #expect(rangeFeatures["choice_count"] as? Int == 3)
        #expect(rangeFeatures["avg_range_size"] as? Double ?? 0.0 > 0.0)
        #expect(rangeFeatures["range_size_variance"] as? Double ?? 0.0 > 0.0) // Should have variance due to different range sizes
    }
    
    @Test("Entropy features included in pass selection")
    func testEntropyInPassSelection() async throws {
        let tree = ChoiceTree.group([
            ChoiceTree.choice(ChoiceValue.unsigned(1), ChoiceMetadata(validRanges: [0...10], strategies: [])),
            ChoiceTree.sequence(
                length: 2,
                elements: [ChoiceTree.choice(ChoiceValue.unsigned(2), ChoiceMetadata(validRanges: [0...10], strategies: []))],
                ChoiceMetadata(validRanges: [0...10], strategies: [])
            )
        ])
        
        let passFeatures = tree.passSelectionFeatures()
        
        #expect(passFeatures["structural_entropy"] != nil)
        #expect(passFeatures["value_entropy"] != nil)
        #expect(passFeatures["branching_entropy"] != nil)
        
        // Values should be non-negative
        #expect((passFeatures["structural_entropy"] as? Double ?? -1) >= 0.0)
        #expect((passFeatures["value_entropy"] as? Double ?? -1) >= 0.0)
        #expect((passFeatures["branching_entropy"] as? Double ?? -1) >= 0.0)
    }
}