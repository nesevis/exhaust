//
//  ChoiceTree+StructuralClassification.swift
//  Exhaust
//
//  Created by Chris Kolbu on 8/8/2025.
//

import Foundation

extension ChoiceTree {
    /// Extracts structural features for machine learning classification
    public func extractStructuralFeatures() -> StructuralFingerprint {
        return StructuralFingerprint(from: self)
    }
    
    /// Extracts features specifically for pass selection classification
    public func passSelectionFeatures() -> [String: Any] {
        let fingerprint = extractStructuralFeatures()
        
        return [
            "max_depth": fingerprint.maxDepth,
            "choice_count": fingerprint.nodeTypeCounts["choice", default: 0],
            "sequence_count": fingerprint.nodeTypeCounts["sequence", default: 0],
            "branch_count": fingerprint.nodeTypeCounts["branch", default: 0],
            "group_count": fingerprint.nodeTypeCounts["group", default: 0],
            "dominant_pattern": fingerprint.dominantPattern,
            "important_node_ratio": fingerprint.importantNodeRatio,
            "avg_branching_factor": fingerprint.avgBranchingFactor,
            "reduction_potential": fingerprint.reductionPotential,
            "complexity_q1": fingerprint.complexityDistribution[0],
            "complexity_median": fingerprint.complexityDistribution[2],
            "complexity_q3": fingerprint.complexityDistribution[3],
            "structural_entropy": fingerprint.structuralEntropy,
            "value_entropy": fingerprint.valueEntropy,
            "branching_entropy": fingerprint.branchingEntropy
        ]
    }
    
    /// Extracts features specifically for boundary detection classification
    public func boundaryFeatures() -> [String: Any] {
        var boundaryFeatures: [String: Any] = [:]
        var rangeUtilizations: [Double] = []
        var avgRangeSizes: [Double] = []
        
        func analyzeBoundaries(_ tree: ChoiceTree) {
            switch tree {
            case let .choice(value, metadata):
                let range = metadata.validRanges[0]
                let rangeSize = Double(range.upperBound - range.lowerBound)
                let currentValue = Double(value.convertible.bitPattern64)
                let rangeMidpoint = Double(range.lowerBound + range.upperBound) / 2.0
                let utilization = abs(currentValue - rangeMidpoint) / (rangeSize / 2.0)
                
                avgRangeSizes.append(rangeSize)
                rangeUtilizations.append(min(1.0, utilization))
                
            case let .sequence(_, elements, _):
                elements.forEach(analyzeBoundaries)
                
            case let .branch(_, _, gen):
                analyzeBoundaries(gen)
                
            case let .group(children):
                children.forEach(analyzeBoundaries)
                
            case let .resize(_, choices):
                choices.forEach(analyzeBoundaries)
                
            case let .important(child), let .selected(child):
                analyzeBoundaries(child)
                
            default:
                break
            }
        }
        
        analyzeBoundaries(self)
        
        boundaryFeatures["avg_range_size"] = avgRangeSizes.isEmpty ? 0.0 : avgRangeSizes.reduce(0, +) / Double(avgRangeSizes.count)
        boundaryFeatures["max_range_size"] = avgRangeSizes.max() ?? 0.0
        boundaryFeatures["avg_range_utilization"] = rangeUtilizations.isEmpty ? 0.0 : rangeUtilizations.reduce(0, +) / Double(rangeUtilizations.count)
        boundaryFeatures["range_count"] = rangeUtilizations.count
        
        return boundaryFeatures
    }
    
    /// Extracts features for convergence prediction
    public func convergenceFeatures() -> [String: Any] {
        let fingerprint = extractStructuralFeatures()
        let boundaryInfo = boundaryFeatures()
        
        return [
            "important_node_ratio": fingerprint.importantNodeRatio,
            "complexity_range": fingerprint.complexityDistribution[3] - fingerprint.complexityDistribution[0],
            "avg_complexity": fingerprint.complexityDistribution[2],
            "structural_complexity": Double(structuralComplexity),
            "total_complexity": Double(complexity),
            "convergence_indicator": fingerprint.reductionPotential,
            "range_utilization": boundaryInfo["avg_range_utilization"] as? Double ?? 0.0,
            "structural_entropy": fingerprint.structuralEntropy,
            "value_entropy": fingerprint.valueEntropy,
            "entropy_convergence_factor": (fingerprint.structuralEntropy + fingerprint.valueEntropy) / 2.0
        ]
    }
    
    /// Extracts features for range refinement classification  
    public func rangeFeatures() -> [String: Any] {
        var features: [String: Any] = [:]
        var choiceRanges: [(current: Double, rangeSize: Double, utilization: Double)] = []
        
        func analyzeRanges(_ tree: ChoiceTree) {
            switch tree {
            case let .choice(value, metadata):
                let range = metadata.validRanges[0]
                let rangeSize = Double(range.upperBound - range.lowerBound)
                let currentValue = Double(value.convertible.bitPattern64)
                let rangeStart = Double(range.lowerBound)
                let utilization = rangeSize > 0 ? (currentValue - rangeStart) / rangeSize : 0.0
                
                choiceRanges.append((current: currentValue, rangeSize: rangeSize, utilization: utilization))
                
            case let .sequence(length, elements, metadata):
                let lengthRange = metadata.validRanges[0]
                let lengthRangeSize = Double(lengthRange.upperBound - lengthRange.lowerBound)
                let lengthUtilization = lengthRangeSize > 0 ? Double(length - lengthRange.lowerBound) / lengthRangeSize : 0.0
                
                choiceRanges.append((current: Double(length), rangeSize: lengthRangeSize, utilization: lengthUtilization))
                elements.forEach(analyzeRanges)
                
            case let .branch(_, _, gen):
                analyzeRanges(gen)
                
            case let .group(children):
                children.forEach(analyzeRanges)
                
            case let .resize(_, choices):
                choices.forEach(analyzeRanges)
                
            case let .important(child), let .selected(child):
                analyzeRanges(child)
                
            default:
                break
            }
        }
        
        analyzeRanges(self)
        
        if !choiceRanges.isEmpty {
            let avgRangeSize = choiceRanges.map(\.rangeSize).reduce(0, +) / Double(choiceRanges.count)
            let avgUtilization = choiceRanges.map(\.utilization).reduce(0, +) / Double(choiceRanges.count)
            let maxRangeSize = choiceRanges.map(\.rangeSize).max() ?? 0.0
            let minRangeSize = choiceRanges.map(\.rangeSize).min() ?? 0.0
            
            features["avg_range_size"] = avgRangeSize
            features["max_range_size"] = maxRangeSize  
            features["min_range_size"] = minRangeSize
            features["range_size_variance"] = maxRangeSize - minRangeSize
            features["avg_utilization"] = avgUtilization
            features["choice_count"] = choiceRanges.count
        } else {
            features["avg_range_size"] = 0.0
            features["max_range_size"] = 0.0
            features["min_range_size"] = 0.0
            features["range_size_variance"] = 0.0
            features["avg_utilization"] = 0.0
            features["choice_count"] = 0
        }
        
        return features
    }
    
    /// Creates a standardized feature vector for generic classification
    public func toFeatureVector() -> [Double] {
        let fingerprint = extractStructuralFeatures()
        let passFeatures = passSelectionFeatures()
        let boundaryFeatures = boundaryFeatures()
        let convergenceFeatures = convergenceFeatures()
        let rangeFeatures = rangeFeatures()
        
        return [
            // Structural features
            Double(fingerprint.maxDepth),
            Double(fingerprint.nodeTypeCounts["choice", default: 0]),
            Double(fingerprint.nodeTypeCounts["sequence", default: 0]),
            Double(fingerprint.nodeTypeCounts["branch", default: 0]),
            Double(fingerprint.nodeTypeCounts["group", default: 0]),
            fingerprint.importantNodeRatio,
            fingerprint.avgBranchingFactor,
            fingerprint.reductionPotential,
            
            // Complexity distribution
            fingerprint.complexityDistribution[0], // min
            fingerprint.complexityDistribution[1], // q1  
            fingerprint.complexityDistribution[2], // median
            fingerprint.complexityDistribution[3], // q3
            
            // Shannon entropy measures
            fingerprint.structuralEntropy,
            fingerprint.valueEntropy,
            fingerprint.branchingEntropy,
            
            // Boundary features
            boundaryFeatures["avg_range_size"] as? Double ?? 0.0,
            boundaryFeatures["max_range_size"] as? Double ?? 0.0,
            boundaryFeatures["avg_range_utilization"] as? Double ?? 0.0,
            
            // Range features
            rangeFeatures["avg_utilization"] as? Double ?? 0.0,
            rangeFeatures["range_size_variance"] as? Double ?? 0.0,
            
            // High-level metrics
            Double(structuralComplexity),
            Double(complexity),
            combinatoryComplexity
        ]
    }
    
    /// Creates feature names corresponding to toFeatureVector()
    public static var featureNames: [String] {
        return [
            "max_depth", "choice_count", "sequence_count", "branch_count", "group_count",
            "important_node_ratio", "avg_branching_factor", "reduction_potential",
            "complexity_min", "complexity_q1", "complexity_median", "complexity_q3",
            "structural_entropy", "value_entropy", "branching_entropy",
            "avg_range_size", "max_range_size", "avg_range_utilization",
            "avg_utilization", "range_size_variance",
            "structural_complexity", "total_complexity", "combinatory_complexity"
        ]
    }
}
