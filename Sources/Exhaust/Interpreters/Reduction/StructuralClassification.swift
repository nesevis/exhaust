//
//  StructuralClassification.swift
//  Exhaust
//
//  Created by Chris Kolbu on 8/8/2025.
//

import Foundation

/// Captures structural patterns from ChoiceTrees for machine learning classification
public struct StructuralFingerprint: Hashable, Sendable {
    public let maxDepth: Int
    public let nodeTypeCounts: [String: Int]
    public let dominantPattern: String
    public let complexityDistribution: [Double]
    public let importantNodeRatio: Double
    public let avgBranchingFactor: Double
    public let reductionPotential: Double
    
    // Shannon entropy measures
    public let structuralEntropy: Double
    public let valueEntropy: Double
    public let branchingEntropy: Double
    
    public init(from tree: ChoiceTree) {
        var analysis = StructuralAnalysis()
        analysis.analyze(tree, depth: 0)
        
        self.maxDepth = analysis.maxDepth
        self.nodeTypeCounts = analysis.nodeTypeCounts
        self.dominantPattern = Self.determineDominantPattern(from: analysis.nodeTypeCounts)
        self.complexityDistribution = Self.calculateComplexityDistribution(from: analysis.complexities)
        self.importantNodeRatio = analysis.totalNodes > 0 ? Double(analysis.importantNodes) / Double(analysis.totalNodes) : 0.0
        self.avgBranchingFactor = analysis.branchingFactors.isEmpty ? 0.0 : analysis.branchingFactors.reduce(0, +) / Double(analysis.branchingFactors.count)
        self.reductionPotential = Self.estimateReductionPotential(analysis: analysis)
        
        // Calculate Shannon entropy measures
        self.structuralEntropy = Self.calculateStructuralEntropy(from: analysis.nodeTypeCounts)
        self.valueEntropy = Self.calculateValueEntropy(from: analysis.choiceValues)
        self.branchingEntropy = Self.calculateBranchingEntropy(from: analysis.branchingFactors)
    }
    
    private static func determineDominantPattern(from counts: [String: Int]) -> String {
        guard let maxCount = counts.values.max(), maxCount > 0 else { return "empty" }
        let dominantTypes = counts.filter { $0.value == maxCount }.keys
        
        if dominantTypes.count == 1 {
            return dominantTypes.first! + "-heavy"
        } else if dominantTypes.contains("choice") && dominantTypes.contains("sequence") {
            return "choice-sequence-mixed"
        } else {
            return "mixed"
        }
    }
    
    private static func calculateComplexityDistribution(from complexities: [UInt64]) -> [Double] {
        guard !complexities.isEmpty else { return [0.0, 0.0, 0.0, 0.0] }
        
        let sorted = complexities.map { Double($0) }.sorted()
        let count = sorted.count
        
        return [
            sorted[0], // min (0th percentile)
            sorted[count / 4], // 25th percentile
            sorted[count / 2], // median (50th percentile)
            sorted[3 * count / 4] // 75th percentile
        ]
    }
    
    private static func estimateReductionPotential(analysis: StructuralAnalysis) -> Double {
        let sequenceReduction = analysis.nodeTypeCounts["sequence", default: 0] > 0 ? 0.3 : 0.0
        let importantNodeBoost = analysis.importantNodes > 0 ? 0.4 : 0.0
        let complexityFactor = analysis.avgComplexity > 100 ? 0.2 : 0.1
        let depthPenalty = analysis.maxDepth > 10 ? -0.1 : 0.0
        
        return min(1.0, max(0.0, sequenceReduction + importantNodeBoost + complexityFactor + depthPenalty))
    }
    
    /// Calculate Shannon entropy of node type distribution
    private static func calculateStructuralEntropy(from nodeTypeCounts: [String: Int]) -> Double {
        let totalNodes = nodeTypeCounts.values.reduce(0, +)
        guard totalNodes > 0 else { return 0.0 }
        
        let probabilities = nodeTypeCounts.values.map { Double($0) / Double(totalNodes) }
        return shannonEntropy(probabilities: probabilities)
    }
    
    /// Calculate Shannon entropy of choice value distributions
    private static func calculateValueEntropy(from choiceValues: [ChoiceValue]) -> Double {
        guard !choiceValues.isEmpty else { return 0.0 }
        
        // Group values into bins for entropy calculation
        let valueBins = binChoiceValues(choiceValues)
        let totalValues = choiceValues.count
        
        let probabilities = valueBins.map { Double($0) / Double(totalValues) }
        return shannonEntropy(probabilities: probabilities)
    }
    
    /// Calculate Shannon entropy of branching factor distribution
    private static func calculateBranchingEntropy(from branchingFactors: [Double]) -> Double {
        guard !branchingFactors.isEmpty else { return 0.0 }
        
        // Convert to integer bins for entropy calculation
        let intBranchingFactors = branchingFactors.map { Int($0) }
        let branchingCounts = Dictionary(grouping: intBranchingFactors, by: { $0 })
            .mapValues { $0.count }
        
        let totalFactors = branchingFactors.count
        let probabilities = branchingCounts.values.map { Double($0) / Double(totalFactors) }
        return shannonEntropy(probabilities: probabilities)
    }
    
    /// Calculate Shannon entropy from probability distribution
    private static func shannonEntropy(probabilities: [Double]) -> Double {
        return probabilities
            .filter { $0 > 0.0 } // Filter out zero probabilities
            .reduce(0.0) { entropy, p in
                entropy - p * log2(p)
            }
    }
    
    /// Bin choice values for entropy calculation
    private static func binChoiceValues(_ values: [ChoiceValue]) -> [Int] {
        // Create logarithmic bins based on complexity values
        let complexities = values.map { $0.complexity }
        guard let maxComplexity = complexities.max(), maxComplexity > 0 else {
            return [values.count] // All values in one bin if no complexity
        }
        
        let numBins = min(10, max(2, Int(sqrt(Double(values.count))))) // Adaptive bin count
        let logMaxComplexity = log10(Double(maxComplexity) + 1)
        
        var bins = Array(repeating: 0, count: numBins)
        
        for complexity in complexities {
            let logComplexity = log10(Double(complexity) + 1)
            let binIndex = min(numBins - 1, Int((logComplexity / logMaxComplexity) * Double(numBins)))
            bins[binIndex] += 1
        }
        
        return bins.filter { $0 > 0 } // Return only non-empty bins
    }
}

/// Internal helper for analyzing ChoiceTree structure
private struct StructuralAnalysis {
    var maxDepth: Int = 0
    var nodeTypeCounts: [String: Int] = [:]
    var totalNodes: Int = 0
    var importantNodes: Int = 0
    var complexities: [UInt64] = []
    var branchingFactors: [Double] = []
    var avgComplexity: Double = 0.0
    var choiceValues: [ChoiceValue] = []
    
    mutating func analyze(_ tree: ChoiceTree, depth: Int) {
        maxDepth = max(maxDepth, depth)
        totalNodes += 1
        complexities.append(tree.complexity)
        
        switch tree {
        case let .choice(value, _):
            nodeTypeCounts["choice", default: 0] += 1
            choiceValues.append(value)
            
        case .just:
            nodeTypeCounts["just", default: 0] += 1
            
        case let .sequence(_, elements, _):
            nodeTypeCounts["sequence", default: 0] += 1
            branchingFactors.append(Double(elements.count))
            for element in elements {
                analyze(element, depth: depth + 1)
            }
            
        case let .branch(_, _, children):
            nodeTypeCounts["branch", default: 0] += 1
            branchingFactors.append(Double(children.count))
            for child in children {
                analyze(child, depth: depth + 1)
            }
            
        case let .group(children):
            nodeTypeCounts["group", default: 0] += 1
            branchingFactors.append(Double(children.count))
            for child in children {
                analyze(child, depth: depth + 1)
            }
            
        case .getSize:
            nodeTypeCounts["getSize", default: 0] += 1
            
        case let .resize(_, choices):
            nodeTypeCounts["resize", default: 0] += 1
            branchingFactors.append(Double(choices.count))
            for choice in choices {
                analyze(choice, depth: depth + 1)
            }
            
        case let .important(child):
            importantNodes += 1
            analyze(child, depth: depth)
            
        case let .selected(child):
            nodeTypeCounts["selected", default: 0] += 1
            analyze(child, depth: depth)
        }
        
        // Calculate average complexity after analysis
        if !complexities.isEmpty {
            avgComplexity = Double(complexities.reduce(0, +)) / Double(complexities.count)
        }
    }
}

/// Represents learned shrinking strategies from classification
public enum ClassificationStrategy: String, CaseIterable, Sendable {
    case sequenceReduction = "sequence_reduction"
    case boundaryTightening = "boundary_tightening"
    case structuralSimplification = "structural_simplification"
    case coordinatedReduction = "coordinated_reduction"
    case convergenceCheck = "convergence_check"
    case binaryReduction = "binary_reduction"
    case fundamentalReduction = "fundamental_reduction"
}

/// Classification outcome predicting shrinking effectiveness
public struct ShrinkingPrediction: Sendable {
    public let recommendedStrategy: ClassificationStrategy
    public let confidence: Double
    public let alternativeStrategies: [ClassificationStrategy]
    public let estimatedEffectiveness: Double
    
    public init(recommendedStrategy: ClassificationStrategy, confidence: Double, alternativeStrategies: [ClassificationStrategy] = [], estimatedEffectiveness: Double) {
        self.recommendedStrategy = recommendedStrategy
        self.confidence = confidence
        self.alternativeStrategies = alternativeStrategies
        self.estimatedEffectiveness = estimatedEffectiveness
    }
}
