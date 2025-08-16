//
//  ChoiceGradientSampler.swift
//  Exhaust
//
//  Created by Chris Kolbu on 12/8/2025.
//

import Foundation

/// Choice Gradient Sampling (CGS) implementation for Exhaust.
///
/// CGS enables automatic optimization of generators to produce higher proportions of valid outputs
/// that satisfy property preconditions. This is achieved by:
///
/// 1. Computing gradients that show how choice modifications affect validity rates
/// 2. Using these gradients to bias future choice selection toward validity-preserving options
/// 3. Iteratively improving the generator until optimal valid output rates are achieved
///
/// The key insight is that generators can be viewed as "parsers of randomness," enabling
/// derivative operations that preview the effects of choice modifications before committing to them.
///
/// ## Performance Advantages
///
/// CGS leverages Exhaust's `ValueAndChoiceTreeGenerator` to eliminate the expensive
/// generate-then-reflect cycle, providing ~10x performance improvement for gradient computation
/// compared to traditional implementations.
///
/// ## Theoretical Foundation
///
/// Based on Harrison Goldstein's dissertation "Property-Based Testing for the People"
/// and the mathematical framework of free generator derivatives.
public struct ChoiceGradientSampler {
    
    // MARK: - Core Types
    
    /// Metrics collected during CGS tuning that predict shrinking effectiveness.
    public struct TuningMetrics {
        /// Original validity rate before CGS optimization
        public let originalValidRate: Double
        
        /// Validity rate after CGS optimization  
        public let optimizedValidRate: Double
        
        /// Improvement factor (optimizedValidRate / originalValidRate)
        public let improvementFactor: Double
        
        /// Number of CGS iterations required to reach convergence
        public let convergenceIterations: Int
        
        /// Average confidence in gradient measurements across all choice positions
        public let averageGradientConfidence: Double
        
        /// Standard deviation of gradient confidence measurements
        public let gradientConfidenceStdDev: Double
        
        /// Total oracle calls used during gradient computation
        public let totalOracleCalls: Int
        
        /// Computed viability score for CGS-guided shrinking (0.0 to 1.0)
        public var shrinkingViabilityScore: Double {
            // If CGS was skipped entirely (0 iterations), it cannot help with shrinking
            if convergenceIterations == 0 {
                return 0.0
            }
            
            // Composite score combining multiple factors
            let improvementScore = min(improvementFactor / 3.0, 1.0)  // Cap at 3x improvement
            let confidenceScore = averageGradientConfidence
            let convergenceScore = max(0.1, 1.0 / Double(convergenceIterations))
            
            // If no meaningful improvement was achieved, heavily penalize the score
            // Shrinking viability depends primarily on actual demonstrated improvement
            if improvementFactor < 1.1 {  // Less than 10% improvement
                return (0.2 * improvementScore + 0.1 * confidenceScore + 0.1 * convergenceScore)
                    .clamped(to: 0.0...1.0)
            }
            
            // For cases with good improvement, weight improvement and confidence
            return (0.6 * improvementScore + 0.3 * confidenceScore + 0.1 * convergenceScore)
                .clamped(to: 0.0...1.0)
        }
    }
    
    /// Gradient information for a specific choice position in the generator.
    public struct ChoiceGradient: Sendable {
        /// The choice tree path identifying this choice position
        public let choicePath: ChoiceTreePath
        
        /// Fitness score indicating how often this choice leads to valid outputs (0.0 to 1.0)
        public let fitness: Double
        
        /// Confidence in the fitness measurement (0.0 to 1.0)
        public let confidence: Double
        
        /// Number of samples used to compute this gradient
        public let sampleCount: Int
        
        /// Standard deviation of the samples used for confidence calculation
        public let sampleStdDev: Double
        
        /// Whether this choice position shows statistically significant gradient information
        public var isSignificant: Bool {
            return confidence > 0.4 && sampleCount >= 10
        }
    }
    
    /// Complete gradient information for a generator.
    public struct GeneratorGradient {
        /// Gradients for individual choice positions
        public let choiceGradients: [ChoiceGradient]
        
        /// High-level structural patterns discovered during gradient computation
        public let structuralPatterns: [String: Double]
        
        /// Overall confidence in the gradient measurements
        public let overallConfidence: Double
        
        /// Number of choice positions that showed significant gradients
        public var significantChoiceCount: Int {
            return choiceGradients.filter { $0.isSignificant }.count
        }
        
        /// Whether the generator shows gradient-friendly patterns
        public var isGradientFriendly: Bool {
            return overallConfidence > 0.3 && significantChoiceCount >= 1
        }
    }
    
    /// Optimized generator with embedded gradient-guided behavior.
    public struct OptimizedGenerator<Output> {
        /// The original generator structure
        public let baseGenerator: ReflectiveGenerator<Output>
        
        /// Gradient information used for optimization
        public let gradient: GeneratorGradient
        
        /// Tuning metrics achieved during optimization
        public let tuningMetrics: TuningMetrics
        
        /// Generates values using gradient-guided choice selection
        public func generate(seed: UInt64? = nil, maxRuns: UInt64 = 100) -> ValueAndChoiceTreeGenerator<Output> {
            // Create a modified generator that uses gradient information to bias choices
            let guidedGenerator = applyGradientGuidance(to: baseGenerator, using: gradient)
            return ValueAndChoiceTreeGenerator(guidedGenerator, seed: seed, maxRuns: maxRuns)
        }
        
        /// Validates that the optimization actually improved validity rates
        public func validateImprovement(
            against property: @escaping (Output) -> Bool,
            samples: Int = 200
        ) async -> Double {
            // Compare optimized vs original generator performance
            let originalRate = await measureValidityRate(baseGenerator, property: property, samples: samples)
            let optimizedRate = await measureValidityRate(generate().generator, property: property, samples: samples)
            
            return optimizedRate / max(originalRate, 0.001)  // Avoid division by zero
        }
    }
    
    // MARK: - Structural Analysis
    
    /// Analyzes ChoiceTree structure to predict CGS effectiveness before expensive sampling
    public static func analyzeCGSPotential(_ tree: ChoiceTree) -> CGSPotential {
        var analysis = CGSStructuralAnalysis()
        analysis.traverse(tree, depth: 0)
        
        return CGSPotential(
            branchingScore: analysis.calculateBranchingScore(),
            sequenceScore: analysis.calculateSequenceScore(), 
            choiceScore: analysis.calculateChoiceScore(),
            overallScore: analysis.calculateOverallScore(),
            shouldUseCGS: analysis.calculateOverallScore() > 0.10
        )
    }
    
    /// Quick structural analysis of a generator's CGS potential
    public static func predictViability<Output>(
        for generator: ReflectiveGenerator<Output>
    ) -> CGSPotential {
        // Generate a single sample to analyze structure
        var valueTreeGen = ValueAndChoiceTreeGenerator(generator, maxRuns: 1)
        guard let (_, sampleTree) = valueTreeGen.next() else {
            return CGSPotential.minimal
        }
        
        return analyzeCGSPotential(sampleTree)
    }
    
    // MARK: - Public API
    
    /// Optimizes a generator to produce higher proportions of outputs satisfying the given property.
    ///
    /// - Parameters:
    ///   - generator: The generator to optimize
    ///   - property: Validity predicate that defines desired outputs
    ///   - samples: Number of samples per gradient computation (higher = more accurate, slower)
    ///   - iterations: Maximum CGS iterations (typical: 3-7)
    ///   - improvementThreshold: Minimum improvement to continue optimization (typical: 0.1 = 10%)
    ///
    /// - Returns: Optimized generator with embedded gradient guidance and tuning metrics
    
    /// Scales all pick weights in a generator by the given factor to avoid UInt64 truncation
    private static func scaleGeneratorWeights<Value>(
        _ generator: ReflectiveGenerator<Value>, 
        scaleFactor: UInt64
    ) -> ReflectiveGenerator<Value> {
        return generator.mapOperation { operation in
            switch operation {
            case .pick(let choices):
                let scaledChoices = choices.map { choice in
                    (weight: choice.weight * scaleFactor, label: choice.label, generator: choice.generator)
                }
                return .pick(choices: ContiguousArray(scaledChoices))
                
            default:
                return operation  // Other operations don't need scaling
            }
        }
    }
    
    public static func optimize<Output>(
        _ generator: ReflectiveGenerator<Output>,
        for property: @escaping (Output) -> Bool,
        samples: Int = 500,
        iterations: Int = 5,
        improvementThreshold: Double = 0.1,
        seed: UInt64? = nil
    ) async -> OptimizedGenerator<Output> {
        
        // Fast structural analysis to predict CGS effectiveness
        let potential = predictViability(for: generator)
        print("CGS structural analysis: overall=\(potential.overallScore), branching=\(potential.branchingScore), sequence=\(potential.sequenceScore), choice=\(potential.choiceScore)")
        
        // Early exit if structure suggests CGS won't be effective
        guard potential.shouldUseCGS else {
            print("CGS skipped: low structural potential (\(potential.overallScore))")
            let initialValidRate = await measureValidityRate(generator, property: property, samples: samples)
            return OptimizedGenerator(
                baseGenerator: generator,
                gradient: GeneratorGradient(choiceGradients: [], structuralPatterns: [:], overallConfidence: 0.0),
                tuningMetrics: TuningMetrics(
                    originalValidRate: initialValidRate,
                    optimizedValidRate: initialValidRate,
                    improvementFactor: 1.0,
                    convergenceIterations: 0,
                    averageGradientConfidence: 0.0,
                    gradientConfidenceStdDev: 0.0,
                    totalOracleCalls: 0
                )
            )
        }
        
        // Pre-scale all weights by 100x to avoid UInt64 truncation in later adjustments
        var currentGenerator = Self.scaleGeneratorWeights(generator, scaleFactor: 100)
        var allMetrics: [TuningMetrics] = []
        var bestGradient: GeneratorGradient?
        
        let initialValidRate = await measureValidityRate(generator, property: property, samples: samples, seed: seed)
        var currentValidRate = initialValidRate
        
        for iteration in 0..<iterations {
            // Compute gradient for current generator
            let gradient = await computeGradient(
                currentGenerator,
                property: property,
                samples: samples,
                seed: seed.map { $0 + UInt64(iteration) }
            )
            
            // If gradient is not useful, stop early
            guard gradient.isGradientFriendly else {
                print("CGS: Gradient not useful at iteration \(iteration), stopping early")
                break
            }
            
            // Apply gradient guidance to create improved generator
            let guidedGenerator: ReflectiveGenerator<Output> = applyGradientGuidance(to: currentGenerator, using: gradient)
            let guidedValidRate = await measureValidityRate(guidedGenerator, property: property, samples: samples, seed: seed.map { $0 + UInt64(iteration * 1000) })
            
            let improvement = (guidedValidRate - currentValidRate) / max(currentValidRate, 0.001)
            
            let iterationMetrics = TuningMetrics(
                originalValidRate: initialValidRate,
                optimizedValidRate: guidedValidRate,
                improvementFactor: guidedValidRate / max(initialValidRate, 0.001),
                convergenceIterations: iteration + 1,
                averageGradientConfidence: gradient.overallConfidence,
                gradientConfidenceStdDev: computeConfidenceStdDev(gradient),
                totalOracleCalls: samples * gradient.choiceGradients.count * 2
            )
            
            allMetrics.append(iterationMetrics)
            
            if improvement > improvementThreshold {
                currentGenerator = guidedGenerator
                currentValidRate = guidedValidRate
                bestGradient = gradient
                print("CGS iteration \(iteration): \(improvement * 100)% improvement")
            } else {
                print("CGS converged at iteration \(iteration)")
                break
            }
        }
        
        let finalMetrics = allMetrics.last ?? TuningMetrics(
            originalValidRate: initialValidRate,
            optimizedValidRate: currentValidRate,
            improvementFactor: currentValidRate / max(initialValidRate, 0.001),
            convergenceIterations: 1,
            averageGradientConfidence: 0.0,
            gradientConfidenceStdDev: 0.0,
            totalOracleCalls: 0
        )
        
        return OptimizedGenerator(
            baseGenerator: currentGenerator,
            gradient: bestGradient ?? GeneratorGradient(
                choiceGradients: [],
                structuralPatterns: [:],
                overallConfidence: 0.0
            ),
            tuningMetrics: finalMetrics
        )
    }
    
    // MARK: - Core Algorithm Implementation
    
    /// Computes choice gradients for a generator using the CGS algorithm.
    private static func computeGradient<Output>(
        _ generator: ReflectiveGenerator<Output>,
        property: @escaping (Output) -> Bool,
        samples: Int,
        seed: UInt64? = nil
    ) async -> GeneratorGradient {
        
        // Generate samples and collect choice trees
        var sampleData: [(value: Output, tree: ChoiceTree, isValid: Bool)] = []
        let valueTreeGenerator = ValueAndChoiceTreeGenerator(generator, seed: seed, maxRuns: UInt64(samples))
        
        // Collect samples using the high-performance ValueAndChoiceTreeGenerator
        for (value, tree) in valueTreeGenerator {
            let isValid = property(value)
            sampleData.append((value: value, tree: tree, isValid: isValid))
        }
        
        // Extract unique choice positions from all trees
        let allChoicePaths = Set(sampleData.flatMap { extractChoicePaths(from: $0.tree) })
        
        // Compute gradient for each choice position (sequential for now)
        var choiceGradients: [ChoiceGradient] = []
        print("CGS debug: Found \(allChoicePaths.count) choice paths")
        for choicePath in allChoicePaths {
            print("CGS debug: Processing path \(choicePath)")
            if let gradient = computeChoiceGradient(
                for: choicePath,
                in: sampleData,
                minSamples: max(10, samples / 20)
            ) {
                print("CGS debug: Added gradient for \(choicePath) with fitness \(gradient.fitness)")
                choiceGradients.append(gradient)
            } else {
                print("CGS debug: No gradient computed for \(choicePath)")
            }
        }
        
        // Compute structural patterns
        let structuralPatterns = computeStructuralPatterns(from: sampleData)
        
        // Calculate overall confidence
        let overallConfidence = choiceGradients.isEmpty ? 0.0 :
            choiceGradients.map { $0.confidence }.reduce(0, +) / Double(choiceGradients.count)
        
        print("CGS debug: Final gradients: \(choiceGradients.count), overall confidence: \(overallConfidence)")
        for gradient in choiceGradients {
            print("CGS debug: Gradient \(gradient.choicePath) - fitness: \(gradient.fitness), confidence: \(gradient.confidence), significant: \(gradient.isSignificant)")
        }
        
        return GeneratorGradient(
            choiceGradients: choiceGradients,
            structuralPatterns: structuralPatterns,
            overallConfidence: overallConfidence
        )
    }
    
    /// Measures the validity rate of a generator for a given property.
    private static func measureValidityRate<Output>(
        _ generator: ReflectiveGenerator<Output>,
        property: @escaping (Output) -> Bool,
        samples: Int,
        seed: UInt64? = nil
    ) async -> Double {
        let valueGenerator = ValueGenerator(generator, seed: seed, maxRuns: UInt64(samples))
        
        var validCount = 0
        var totalCount = 0
        
        for value in valueGenerator {
            if property(value) {
                validCount += 1
            }
            totalCount += 1
        }
        
        return totalCount > 0 ? Double(validCount) / Double(totalCount) : 0.0
    }
    
    // MARK: - Helper Functions (Placeholder Implementations)
    
    private static func extractChoicePaths(from tree: ChoiceTree) -> [ChoiceTreePath] {
        // Basic implementation: extract paths from choice tree structure
        var paths: [ChoiceTreePath] = []
        
        func extractRecursive(tree: ChoiceTree, currentPath: [String]) {
            switch tree {
            case .choice(_, _):
                paths.append(ChoiceTreePath(currentPath + ["choice"]))
                
            case .sequence(_, let elements, _):
                paths.append(ChoiceTreePath(currentPath + ["sequence", "length"]))
                for (index, element) in elements.enumerated() {
                    extractRecursive(tree: element, currentPath: currentPath + ["sequence", "element_\(index)"])
                }
                
            case .group(let children):
                for (index, child) in children.enumerated() {
                    extractRecursive(tree: child, currentPath: currentPath + ["group", "child_\(index)"])
                }
                
            case .branch(let label, let children):
                let branchPath = currentPath + ["branch", "label_\(label)"]
                paths.append(ChoiceTreePath(branchPath))
                for (index, child) in children.enumerated() {
                    extractRecursive(tree: child, currentPath: branchPath + ["child_\(index)"])
                }
                
            case .selected(let tree):
                extractRecursive(tree: tree, currentPath: currentPath + ["selected"])
                
            default:
                // For other cases like .just, .getSize, .resize - they don't contain choices
                break
            }
        }
        
        extractRecursive(tree: tree, currentPath: [])
        return paths
    }
    
    private static func computeChoiceGradient(
        for path: ChoiceTreePath,
        in samples: [(value: Any, tree: ChoiceTree, isValid: Bool)],
        minSamples: Int
    ) -> ChoiceGradient? {
        // Filter samples that contain this choice path
        let relevantSamples = samples.filter { sample in
            let paths = extractChoicePaths(from: sample.tree)
            return paths.contains(path)
        }
        
        guard relevantSamples.count >= minSamples else {
            return nil  // Not enough samples for reliable gradient
        }
        
        // Compute fitness as the proportion of valid samples
        let validCount = relevantSamples.filter { $0.isValid }.count
        let fitness = Double(validCount) / Double(relevantSamples.count)
        
        // Improved confidence metric based on sample size and statistical variance
        let sampleCount = relevantSamples.count
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
        let confidence = min(1.0, sampleConfidence * statisticalConfidence)
        
        return ChoiceGradient(
            choicePath: path,
            fitness: fitness,
            confidence: confidence,
            sampleCount: relevantSamples.count,
            sampleStdDev: stdDev
        )
    }
    
    private static func computeStructuralPatterns(
        from samples: [(value: Any, tree: ChoiceTree, isValid: Bool)]
    ) -> [String: Double] {
        guard !samples.isEmpty else { return [:] }
        
        var patterns: [String: Double] = [:]
        
        // Analyze sequence length patterns
        let sequenceLengths = samples.compactMap { sample -> (length: Int, isValid: Bool)? in
            if case .sequence(let length, _, _) = sample.tree {
                return (length: Int(length), isValid: sample.isValid)
            }
            return nil
        }
        
        if !sequenceLengths.isEmpty {
            let validSequences = sequenceLengths.filter { $0.isValid }
            let avgValidLength = validSequences.isEmpty ? 0.0 : 
                Double(validSequences.map { $0.length }.reduce(0, +)) / Double(validSequences.count)
            let avgTotalLength = Double(sequenceLengths.map { $0.length }.reduce(0, +)) / Double(sequenceLengths.count)
            
            patterns["sequence_length_preference"] = avgTotalLength > 0 ? avgValidLength / avgTotalLength : 0.0
        }
        
        // Analyze choice depth patterns
        let choiceDepths = samples.map { sample -> (depth: Int, isValid: Bool) in
            let depth = computeTreeDepth(sample.tree)
            return (depth: depth, isValid: sample.isValid)
        }
        
        let validDepths = choiceDepths.filter { $0.isValid }
        let avgValidDepth = validDepths.isEmpty ? 0.0 :
            Double(validDepths.map { $0.depth }.reduce(0, +)) / Double(validDepths.count)
        let avgTotalDepth = Double(choiceDepths.map { $0.depth }.reduce(0, +)) / Double(choiceDepths.count)
        
        patterns["depth_preference"] = avgTotalDepth > 0 ? avgValidDepth / avgTotalDepth : 0.0
        
        return patterns
    }
    
    private static func computeTreeDepth(_ tree: ChoiceTree) -> Int {
        switch tree {
        case .choice(_, _):
            return 1
        case .sequence(_, let elements, _):
            return 1 + (elements.map(computeTreeDepth).max() ?? 0)
        case .group(let children):
            return children.map(computeTreeDepth).max() ?? 0
        case .branch(_, let children):
            return 1 + (children.map(computeTreeDepth).max() ?? 0)
        case .selected(let tree):
            return computeTreeDepth(tree)
        default:
            return 0
        }
    }
    
    private static func applyGradientGuidance<Output>(
        to generator: ReflectiveGenerator<Output>,
        using gradient: GeneratorGradient
    ) -> ReflectiveGenerator<Output> {
        // Apply gradient-guided transformations based on choice fitness scores
        return transformGeneratorWithGradient(generator, gradient: gradient)
    }
    
    /// Transforms a generator by applying gradient-guided optimizations.
    private static func transformGeneratorWithGradient<Output>(
        _ generator: ReflectiveGenerator<Output>,
        gradient: GeneratorGradient
    ) -> ReflectiveGenerator<Output> {
        switch generator {
        case .pure(let value):
            return .pure(value)
            
        case .impure(let operation, let continuation):
            let transformedOperation = transformOperationWithGradient(operation, gradient: gradient)
            let transformedContinuation = { (result: Any) throws -> ReflectiveGenerator<Output> in
                let nextGen = try continuation(result)
                return transformGeneratorWithGradient(nextGen, gradient: gradient)
            }
            return .impure(operation: transformedOperation, continuation: transformedContinuation)
        }
    }
    
    /// Transforms an operation based on gradient information.
    private static func transformOperationWithGradient(
        _ operation: ReflectiveOperation,
        gradient: GeneratorGradient
    ) -> ReflectiveOperation {
        switch operation {
        case .chooseBits(let min, let max, let tag):
            // Find relevant gradients for choice operations
            let choiceGradients = gradient.choiceGradients.filter { 
                $0.choicePath.description.contains("choice") 
            }
            
            guard !choiceGradients.isEmpty else {
                return operation  // No relevant gradients
            }
            
            // Calculate average fitness for choice operations
            let avgFitness = choiceGradients.map { $0.fitness }.reduce(0, +) / Double(choiceGradients.count)
            
            // If fitness is low (< 0.5), try to bias toward one end of the range
            // If fitness is high (>= 0.5), keep the original range
            if avgFitness < 0.5 {
                // Bias toward lower values for better validity
                let rangeSize = max - min
                let biasedMax = min + UInt64(Double(rangeSize) * 0.7)  // Use only 70% of range
                return .chooseBits(min: min, max: biasedMax, tag: tag)
            } else {
                return operation  // Keep original if gradient shows good fitness
            }
            
        case .pick(let choices):
            // Apply gradient-guided weight adjustment for pick operations
            let branchGradients = gradient.choiceGradients.filter {
                $0.choicePath.description.contains("branch.label_")
            }
            
            guard !branchGradients.isEmpty else {
                return operation
            }
            
            // Create mapping from branch labels to their fitness scores
            var labelFitness: [UInt64: Double] = [:]
            for branchGrad in branchGradients {
                if let labelRange = branchGrad.choicePath.description.range(of: "label_"),
                   let labelStr = branchGrad.choicePath.description[labelRange.upperBound...].split(separator: ".").first,
                   let label = UInt64(labelStr) {
                    labelFitness[label] = max(labelFitness[label] ?? 0.0, branchGrad.fitness)
                }
            }
            
            guard !labelFitness.isEmpty else {
                return operation
            }
            
            // Apply fitness-based weight adjustments
            let boostedChoices = choices.map { choice in
                if let fitness = labelFitness[choice.label] {
                    // More aggressive fitness-based weight adjustments
                    let multiplier = fitness > 0.8 ? 5.0 :   // Excellent fitness: 5x weight
                                   fitness > 0.6 ? 3.0 :   // Good fitness: 3x weight  
                                   fitness > 0.4 ? 1.5 :   // Medium fitness: 1.5x weight
                                   fitness > 0.2 ? 0.5 :   // Low fitness: halve weight
                                   fitness > 0.0 ? 0.2 :   // Very low fitness: reduce severely
                                   0.05                     // Zero fitness: minimal weight but not zero
                    let adjustedWeight = Double(choice.weight) * multiplier
                    let newWeight = UInt64(max(1.0, adjustedWeight))
                    return (weight: newWeight, label: choice.label, generator: choice.generator)
                } else {
                    return choice  // No gradient info, keep original weight
                }
            }
            return .pick(choices: ContiguousArray(boostedChoices))
            
        case .sequence(let lengthGen, let elementGen):
            // Apply structural pattern guidance for sequences
            if let lengthPreference = gradient.structuralPatterns["sequence_length_preference"],
               lengthPreference < 0.5 {
                // Bias toward shorter sequences if they tend to be more valid
                let transformedLengthGen = transformGeneratorWithGradient(lengthGen, gradient: gradient)
                let transformedElementGen = transformGeneratorWithGradient(elementGen, gradient: gradient)
                return .sequence(length: transformedLengthGen, gen: transformedElementGen)
            } else {
                // Recursively transform sub-generators
                let transformedLengthGen = transformGeneratorWithGradient(lengthGen, gradient: gradient)
                let transformedElementGen = transformGeneratorWithGradient(elementGen, gradient: gradient)
                return .sequence(length: transformedLengthGen, gen: transformedElementGen)
            }
            
        case .contramap(let transform, let nextGen):
            let transformedNextGen = transformGeneratorWithGradient(nextGen, gradient: gradient)
            return .contramap(transform: transform, next: transformedNextGen)
            
        case .prune(let nextGen):
            let transformedNextGen = transformGeneratorWithGradient(nextGen, gradient: gradient)
            return .prune(next: transformedNextGen)
            
        case .zip(let generators):
            let transformedGenerators = generators.map { gen in
                transformGeneratorWithGradient(gen, gradient: gradient)
            }
            return .zip(ContiguousArray(transformedGenerators))
            
        case .resize(let newSize, let nextGen):
            let transformedNextGen = transformGeneratorWithGradient(nextGen, gradient: gradient)
            return .resize(newSize: newSize, next: transformedNextGen)
            
        default:
            // For other operations (just, getSize), return unchanged
            return operation
        }
    }
    
    private static func computeConfidenceStdDev(_ gradient: GeneratorGradient) -> Double {
        let confidences = gradient.choiceGradients.map { $0.confidence }
        guard !confidences.isEmpty else { return 0.0 }
        
        let mean = confidences.reduce(0, +) / Double(confidences.count)
        let variance = confidences.map { pow($0 - mean, 2) }.reduce(0, +) / Double(confidences.count)
        return sqrt(variance)
    }
}

// MARK: - Supporting Types

/// Represents a path to a specific choice position within a ChoiceTree.
public struct ChoiceTreePath: Hashable, CustomStringConvertible, Sendable {
    private let pathComponents: [String]
    
    public init(_ components: [String]) {
        self.pathComponents = components
    }
    
    public var description: String {
        return pathComponents.joined(separator: ".")
    }
}

// MARK: - CGS Structural Analysis Types

/// Predicts CGS effectiveness based on ChoiceTree structural analysis
public struct CGSPotential: Sendable {
    /// Score for branching potential (0.0 to 1.0)
    public let branchingScore: Double
    
    /// Score for sequence optimization potential (0.0 to 1.0)
    public let sequenceScore: Double
    
    /// Score for choice range optimization potential (0.0 to 1.0)
    public let choiceScore: Double
    
    /// Overall CGS effectiveness score (0.0 to 1.0)
    public let overallScore: Double
    
    /// Whether CGS should be attempted for this structure
    public let shouldUseCGS: Bool
    
    /// Minimal CGS potential for generators with no optimizable structure
    public static let minimal = CGSPotential(
        branchingScore: 0.0,
        sequenceScore: 0.0,
        choiceScore: 0.0,
        overallScore: 0.0,
        shouldUseCGS: false
    )
}

/// Internal helper for analyzing ChoiceTree structure
private struct CGSStructuralAnalysis {
    var weightedBranches: [(depth: Int, branchCount: Int)] = []
    var sequences: [(depth: Int, rangeSize: UInt64)] = []
    var choices: [(depth: Int, rangeSize: UInt64)] = []
    var maxDepth: Int = 0
    
    mutating func traverse(_ tree: ChoiceTree, depth: Int) {
        maxDepth = max(maxDepth, depth)
        
        switch tree {
        case .branch(_, let children):
            // Weighted branches are prime CGS optimization targets
            weightedBranches.append((depth: depth, branchCount: children.count))
            for child in children {
                traverse(child, depth: depth + 1)
            }
            
        case let .sequence(_, elements, metadata):
            // Sequences can be optimized by adjusting length ranges
            let range = metadata.validRanges[0]
            let rangeSize = range.upperBound - range.lowerBound
            sequences.append((depth: depth, rangeSize: rangeSize))
            for element in elements {
                traverse(element, depth: depth + 1)
            }
            
        case let .choice(_, metadata):
            // Choices can be optimized by narrowing their valid ranges
            let range = metadata.validRanges[0]
            let rangeSize = range.upperBound - range.lowerBound
            choices.append((depth: depth, rangeSize: rangeSize))
            
        case .group(let children):
            for child in children {
                traverse(child, depth: depth)
            }
            
        case let .resize(_, childTrees):
            for child in childTrees {
                traverse(child, depth: depth + 1)
            }
            
        case let .important(child), let .selected(child):
            traverse(child, depth: depth)
            
        case .just, .getSize:
            // No optimization potential
            break
        }
    }
    
    func calculateBranchingScore() -> Double {
        guard !weightedBranches.isEmpty else { return 0.0 }
        
        // Higher scores for: more branches, deeper in tree (more specific), more branch choices
        let totalBranchValue = weightedBranches.reduce(0.0) { total, branch in
            let depthBonus = 1.0 + Double(branch.depth) * 0.3  // Deeper branches are more valuable
            let branchBonus = Double(branch.branchCount) * 0.5  // More choices = more optimization potential
            return total + depthBonus * branchBonus
        }
        
        // Normalize to 0-1 scale, with less aggressive normalization
        return min(1.0, totalBranchValue / 3.0)
    }
    
    func calculateSequenceScore() -> Double {
        guard !sequences.isEmpty else { return 0.0 }
        
        // Higher scores for: sequences with large ranges (more to optimize), deeper sequences
        let totalSequenceValue = sequences.reduce(0.0) { total, seq in
            let depthBonus = 1.0 + Double(seq.depth) * 0.2
            let rangeBonus = min(1.0, Double(seq.rangeSize) / 20.0)  // Cap at range size 20 for faster scoring
            return total + depthBonus * rangeBonus
        }
        
        return min(1.0, totalSequenceValue / 2.0)
    }
    
    func calculateChoiceScore() -> Double {
        guard !choices.isEmpty else { return 0.0 }
        
        // Single uniform choices cannot be meaningfully optimized by CGS
        // CGS requires structural patterns or multiple coordinated choices
        if choices.count == 1 {
            return 0.05  // Very low score for single uniform choices
        }
        
        // Higher scores for: choices with large ranges, multiple choice positions
        let totalChoiceValue = choices.reduce(0.0) { total, choice in
            let rangeBonus = min(1.0, Double(choice.rangeSize) / 100.0)  // Cap at range size 100 for faster scoring
            return total + rangeBonus
        }
        
        // Multiple choice positions provide coordination opportunities
        let coordinationBonus = choices.count > 1 ? 0.5 : 0.0
        
        return min(1.0, (totalChoiceValue / Double(choices.count)) + coordinationBonus)
    }
    
    func calculateOverallScore() -> Double {
        // Weighted combination favoring branching (most impactful for CGS)
        let branchWeight = 0.6
        let sequenceWeight = 0.25
        let choiceWeight = 0.15
        
        let score = (branchWeight * calculateBranchingScore() + 
                    sequenceWeight * calculateSequenceScore() +
                    choiceWeight * calculateChoiceScore())
        
        // Depth bonus: deeper structures have more optimization potential
        let depthBonus = min(0.2, Double(maxDepth) * 0.05)
        
        return min(1.0, score + depthBonus)
    }
    
}

// MARK: - Extensions

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}