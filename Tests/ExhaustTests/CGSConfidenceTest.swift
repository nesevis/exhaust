//
//  CGSConfidenceTest.swift  
//  Exhaust
//
//  Created by Chris Kolbu on 13/8/2025.
//

import Testing
import Foundation
@testable import Exhaust

struct CGSConfidenceTest {
    
    @Test("Test confidence calculation scenarios")
    func testConfidenceCalculationScenarios() {
        // Test different scenarios to understand confidence calculation
        
        print("=== Confidence Calculation Tests ===")
        
        // Scenario 1: Perfect fitness, many samples (should be very high confidence)
        let perfectManyResults = calculateConfidence(validSamples: 151, totalSamples: 151, minSamples: 10)
        print("Perfect fitness, 151 samples: \(perfectManyResults)")
        
        // Scenario 2: Good fitness, moderate samples  
        let goodModerateResults = calculateConfidence(validSamples: 24, totalSamples: 36, minSamples: 10)
        print("Good fitness (67%), 36 samples: \(goodModerateResults)")
        
        // Scenario 3: Medium fitness, few samples
        let mediumFewResults = calculateConfidence(validSamples: 7, totalSamples: 13, minSamples: 10)
        print("Medium fitness (54%), 13 samples: \(mediumFewResults)")
        
        // Scenario 4: Bad fitness, many samples (should still be confident it's bad)
        let badManyResults = calculateConfidence(validSamples: 10, totalSamples: 100, minSamples: 10)
        print("Bad fitness (10%), 100 samples: \(badManyResults)")
        
        // Test old vs new algorithm comparison
        print("\n=== Old vs New Algorithm Comparison ===")
        let testCases = [
            (valid: 151, total: 151, desc: "Perfect, many samples"),
            (valid: 24, total: 36, desc: "Good, moderate samples"),
            (valid: 7, total: 13, desc: "Medium, few samples"),
            (valid: 10, total: 100, desc: "Bad, many samples")
        ]
        
        for testCase in testCases {
            let newConf = calculateConfidence(validSamples: testCase.valid, totalSamples: testCase.total, minSamples: 10)
            let oldConf = calculateOldConfidence(sampleCount: testCase.total, minSamples: 10)
            print("\(testCase.desc): Old=\(String(format: "%.3f", oldConf)), New=\(String(format: "%.3f", newConf))")
        }
    }
    
    private func calculateConfidence(validSamples: Int, totalSamples: Int, minSamples: Int) -> Double {
        let fitness = Double(validSamples) / Double(totalSamples)
        let sampleCount = totalSamples
        let validProportion = fitness
        
        // Statistical variance: highest uncertainty at p=0.5, lowest at p=0.0 or p=1.0
        let variance = validProportion * (1.0 - validProportion)
        let stdDev = sqrt(variance / Double(sampleCount))
        
        // Sample size confidence: more samples = higher confidence
        let sampleConfidence = min(1.0, Double(sampleCount) / Double(max(minSamples * 4, 50)))
        
        // Statistical confidence: lower variance = higher confidence
        // Less aggressive penalty for moderate standard errors
        let statisticalConfidence = max(0.5, 1.0 - (stdDev * 2.0)) // Less aggressive scaling
        
        // Combined confidence: both sample size and statistical reliability matter
        return min(1.0, sampleConfidence * statisticalConfidence)
    }
    
    private func calculateOldConfidence(sampleCount: Int, minSamples: Int) -> Double {
        return min(1.0, Double(sampleCount) / Double(max(minSamples * 2, 20)))
    }
}