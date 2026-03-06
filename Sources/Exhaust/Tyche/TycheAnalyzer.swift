import Foundation
import ExhaustCore

/// Statistical analyzer for Tyche reporting data
struct TycheAnalyzer {
    // MARK: - Generation Analysis

    func analyzeGeneration(_ events: [GenerationEvent], duration: TimeInterval) -> GenerationReport {
        let distributionMetrics = analyzeDistribution(events)
        let coverageMetrics = analyzeCoverage(events, totalDuration: duration)
        let biasDetection = analyzeBias(events)
        let performanceMetrics = analyzePerformance(events, totalDuration: duration)

        return GenerationReport(
            distributionMetrics: distributionMetrics,
            coverageMetrics: coverageMetrics,
            biasDetection: biasDetection,
            performanceMetrics: performanceMetrics,
        )
    }

    // MARK: - Shrinking Analysis

    func analyzeShrinking(_ events: [ShrinkingEvent], duration: TimeInterval) -> ShrinkingReport {
        let convergenceMetrics = analyzeConvergence(events, totalDuration: duration)
        let pathAnalysis = analyzeShrinkPaths(events)
        let effectivenessMetrics = analyzeEffectiveness(events)
        let candidateStatistics = analyzeCandidates(events)

        return ShrinkingReport(
            convergenceMetrics: convergenceMetrics,
            pathAnalysis: pathAnalysis,
            effectivenessMetrics: effectivenessMetrics,
            candidateStatistics: candidateStatistics,
        )
    }

    // MARK: - Test Run Analysis

    func analyzeTestRuns(_ outcomes: [TestOutcome], duration: TimeInterval) -> TestRunReport {
        let successFailureRates = analyzeOutcomes(outcomes, totalDuration: duration)
        let counterexamplePatterns = analyzeCounterexamples(outcomes)
        let generatorCompositionMetrics = analyzeComposition(outcomes)
        let statisticalQuality = analyzeQuality(outcomes)

        return TestRunReport(
            successFailureRates: successFailureRates,
            counterexamplePatterns: counterexamplePatterns,
            generatorCompositionMetrics: generatorCompositionMetrics,
            statisticalQuality: statisticalQuality,
        )
    }

    // MARK: - Distribution Analysis

    private func analyzeDistribution(_ events: [GenerationEvent]) -> DistributionAnalysis {
        guard !events.isEmpty else {
            return DistributionAnalysis(entropy: 0, uniformityScore: 0, autocorrelationCoefficient: 0, coveragePercentage: 0)
        }

        let entropy = calculateEntropy(events)
        let uniformityScore = calculateUniformity(events)
        let autocorrelationCoefficient = calculateAutocorrelation(events)
        let coveragePercentage = calculateCoverage(events)

        return DistributionAnalysis(
            entropy: entropy,
            uniformityScore: uniformityScore,
            autocorrelationCoefficient: autocorrelationCoefficient,
            coveragePercentage: coveragePercentage,
        )
    }

    private func calculateEntropy(_ events: [GenerationEvent]) -> Double {
        // Shannon entropy calculation for generated values
        guard !events.isEmpty else { return 0.0 }

        var valueCounts: [String: Int] = [:]

        for event in events {
            let key = String(describing: event.value)
            valueCounts[key, default: 0] += 1
        }

        let total = Double(events.count)
        let entropy = valueCounts.values.reduce(0.0) { entropy, count in
            let probability = Double(count) / total
            guard probability > 0 else { return entropy }
            return entropy - probability * log2(probability)
        }

        return entropy.isFinite ? entropy : 0.0
    }

    private func calculateUniformity(_ events: [GenerationEvent]) -> Double {
        // Kolmogorov-Smirnov test approximation for uniformity
        let entropyEvents = events.compactMap(\.metadata.entropy)
        guard !entropyEvents.isEmpty else { return 0.0 }

        // Simple uniformity score based on distribution of entropy values
        let sortedEntropy = entropyEvents.sorted()
        let expectedValues = (0 ..< sortedEntropy.count).map { i in
            Double(i) / Double(sortedEntropy.count - 1)
        }

        let maxDeviation = zip(sortedEntropy, expectedValues).map { actual, expected in
            abs(Double(actual) / Double(UInt64.max) - expected)
        }.max() ?? 0.0

        return max(0.0, 1.0 - maxDeviation)
    }

    private func calculateAutocorrelation(_ events: [GenerationEvent]) -> Double {
        // Simplified autocorrelation for sequence analysis
        let entropySequence = events.compactMap(\.metadata.entropy)
        guard entropySequence.count > 1 else { return 0.0 }

        var correlation = 0.0
        for i in 0 ..< entropySequence.count - 1 {
            let current = Double(entropySequence[i])
            let next = Double(entropySequence[i + 1])
            correlation += (current * next) / (Double(UInt64.max) * Double(UInt64.max))
        }

        return correlation / Double(entropySequence.count - 1)
    }

    private func calculateCoverage(_ events: [GenerationEvent]) -> Double {
        // Estimate coverage of input space
        let uniqueValues = Set(events.map { String(describing: $0.value) })
        let totalEvents = events.count

        guard totalEvents > 0 else { return 0.0 }

        return Double(uniqueValues.count) / Double(totalEvents)
    }

    // MARK: - Coverage Analysis

    private func analyzeCoverage(_ events: [GenerationEvent], totalDuration _: TimeInterval) -> CoverageAnalysis {
        let inputSpaceCoverage = calculateCoverage(events)
        let boundaryCoverage = calculateBoundaryCoverage(events)
        let equivalenceClassCoverage = calculateEquivalenceClassCoverage(events)
        let temporalDistribution = calculateTemporalDistribution(events)

        return CoverageAnalysis(
            inputSpaceCoverage: inputSpaceCoverage,
            boundaryCoverage: boundaryCoverage,
            equivalenceClassCoverage: equivalenceClassCoverage,
            temporalDistribution: temporalDistribution,
        )
    }

    private func calculateBoundaryCoverage(_ events: [GenerationEvent]) -> Double {
        // Approximate boundary coverage for numerical types
        let entropyEvents = events.compactMap(\.metadata.entropy)
        guard !entropyEvents.isEmpty else { return 0.0 }

        let minValue = entropyEvents.min()!
        let maxValue = entropyEvents.max()!
        let boundaries = [UInt64.min, UInt64.max, minValue, maxValue]

        let boundaryHits = entropyEvents.count(where: { value in
            boundaries.contains { value &- $0 < 1000 }
        })

        return Double(boundaryHits) / Double(entropyEvents.count)
    }

    private func calculateEquivalenceClassCoverage(_ events: [GenerationEvent]) -> Double {
        // Group by operation type as equivalence classes
        var operationCounts: [String: Int] = [:]

        for event in events {
            let operationType = event.metadata.operationType
            operationCounts[operationType, default: 0] += 1
        }

        guard !operationCounts.isEmpty else { return 0.0 }

        // Calculate coverage balance across operation types
        let totalEvents = events.count
        let expectedPerClass = Double(totalEvents) / Double(operationCounts.count)

        let deviation = operationCounts.values.map { count in
            abs(Double(count) - expectedPerClass) / expectedPerClass
        }.reduce(0, +) / Double(operationCounts.count)

        return max(0.0, 1.0 - deviation)
    }

    private func calculateTemporalDistribution(_ events: [GenerationEvent]) -> [String: Int] {
        var hourCounts: [String: Int] = [:]

        for event in events {
            let hour = Calendar.current.component(.hour, from: event.metadata.timestamp)
            let key = "hour_\(hour)"
            hourCounts[key, default: 0] += 1
        }

        return hourCounts
    }

    // MARK: - Bias Analysis

    private func analyzeBias(_ events: [GenerationEvent]) -> BiasAnalysis {
        let branchSelectionBias = calculateBranchSelectionBias(events)
        let valueClusteringScore = calculateValueClustering(events)
        let sizeParameterSensitivity = calculateSizeParameterSensitivity(events)

        return BiasAnalysis(
            branchSelectionBias: branchSelectionBias,
            valueClusteringScore: valueClusteringScore,
            sizeParameterSensitivity: sizeParameterSensitivity,
        )
    }

    private func calculateBranchSelectionBias(_ events: [GenerationEvent]) -> [String: Double] {
        let pickEvents = events.filter { $0.metadata.operationType.contains("pick") }
        guard !pickEvents.isEmpty else { return [:] }

        var branchCounts: [String: Int] = [:]

        for event in pickEvents {
            let branch = String(describing: event.value)
            branchCounts[branch, default: 0] += 1
        }

        let totalPicks = pickEvents.count
        var biasScores: [String: Double] = [:]

        for (branch, count) in branchCounts {
            let frequency = Double(count) / Double(totalPicks)
            let expectedFrequency = 1.0 / Double(branchCounts.count)
            let bias = abs(frequency - expectedFrequency) / expectedFrequency
            biasScores[branch] = bias
        }

        return biasScores
    }

    private func calculateValueClustering(_ events: [GenerationEvent]) -> Double {
        let entropyEvents = events.compactMap(\.metadata.entropy)
        guard entropyEvents.count > 1 else { return 0.0 }

        let sortedEntropy = entropyEvents.sorted()
        var clusteringScore = 0.0

        for i in 0 ..< sortedEntropy.count - 1 {
            let gap = sortedEntropy[i + 1] - sortedEntropy[i]
            clusteringScore += Double(gap) / Double(UInt64.max)
        }

        return clusteringScore / Double(sortedEntropy.count - 1)
    }

    private func calculateSizeParameterSensitivity(_ events: [GenerationEvent]) -> Double {
        let sizeGroups = Dictionary(grouping: events) { $0.metadata.size }
        guard sizeGroups.count > 1 else { return 0.0 }

        let sizeCounts = sizeGroups.mapValues { $0.count }
        let totalEvents = events.count

        let variance = sizeCounts.values.map { count in
            let frequency = Double(count) / Double(totalEvents)
            let expected = 1.0 / Double(sizeCounts.count)
            return pow(frequency - expected, 2)
        }.reduce(0, +) / Double(sizeCounts.count)

        return sqrt(variance)
    }

    // MARK: - Performance Analysis

    private func analyzePerformance(_ events: [GenerationEvent], totalDuration: TimeInterval) -> PerformanceAnalysis {
        let averageGenerationLatency = events.isEmpty ? 0.0 : events.map(\.metadata.duration).reduce(0, +) / Double(events.count)
        let memoryUsagePattern = calculateMemoryUsage(events)
        let entropyConsumptionRate = calculateEntropyConsumption(events, totalDuration: totalDuration)

        return PerformanceAnalysis(
            averageGenerationLatency: averageGenerationLatency.isFinite ? averageGenerationLatency : 0.0,
            memoryUsagePattern: memoryUsagePattern,
            entropyConsumptionRate: entropyConsumptionRate.isFinite ? entropyConsumptionRate : 0.0,
        )
    }

    private func calculateMemoryUsage(_ events: [GenerationEvent]) -> [String: Double] {
        // Simplified memory usage estimation
        var memoryUsage: [String: Double] = [:]

        for event in events {
            let operationType = event.metadata.operationType
            let estimatedMemory = Double(MemoryLayout.size(ofValue: event.value))
            memoryUsage[operationType, default: 0.0] += estimatedMemory
        }

        return memoryUsage
    }

    private func calculateEntropyConsumption(_ events: [GenerationEvent], totalDuration: TimeInterval) -> Double {
        let totalEntropy = events.compactMap(\.metadata.entropy).reduce(UInt64(0)) { total, value in
            let added = total &+ value
            return max(added, total)
        }
        guard totalDuration > 0 else { return 0.0 }
        return Double(totalEntropy) / totalDuration
    }

    // MARK: - Shrinking Analysis Implementations

    private func analyzeConvergence(_ events: [ShrinkingEvent], totalDuration _: TimeInterval) -> ConvergenceAnalysis {
        let successfulEvents = events.filter(\.metadata.wasSuccessful)
        let averageStepsToConvergence = Double(successfulEvents.count)
        let convergenceSuccessRate = events.isEmpty ? 0.0 : Double(successfulEvents.count) / Double(events.count)

        let greedyEvents = events.filter { $0.metadata.stepType == .greedyCandidate }
        let exhaustiveEvents = events.filter { $0.metadata.stepType == .exhaustiveCandidate }

        let greedySuccessRate = greedyEvents.isEmpty ? 0.0 : Double(greedyEvents.count(where: { $0.metadata.wasSuccessful })) / Double(greedyEvents.count)
        let exhaustiveSuccessRate = exhaustiveEvents.isEmpty ? 0.0 : Double(exhaustiveEvents.count(where: { $0.metadata.wasSuccessful })) / Double(exhaustiveEvents.count)

        let greedyVsExhaustiveEffectiveness = exhaustiveSuccessRate > 0.01 ? greedySuccessRate / exhaustiveSuccessRate : 1.0

        return ConvergenceAnalysis(
            averageStepsToConvergence: averageStepsToConvergence.isFinite ? averageStepsToConvergence : 0.0,
            convergenceSuccessRate: convergenceSuccessRate.isFinite ? convergenceSuccessRate : 0.0,
            greedyVsExhaustiveEffectiveness: greedyVsExhaustiveEffectiveness.isFinite ? greedyVsExhaustiveEffectiveness : 1.0,
        )
    }

    private func analyzeShrinkPaths(_ events: [ShrinkingEvent]) -> ShrinkPathAnalysis {
        let averagePathLength = Double(events.count)
        let complexityReductions = events.map { Double($0.metadata.originalComplexity) - Double($0.metadata.targetComplexity) }
        let pathComplexityReduction = complexityReductions.reduce(0, +) / max(1.0, Double(complexityReductions.count))

        let branchingFactor = calculateBranchingFactor(events)

        return ShrinkPathAnalysis(
            averagePathLength: averagePathLength,
            pathComplexityReduction: pathComplexityReduction,
            branchingFactor: branchingFactor,
        )
    }

    private func calculateBranchingFactor(_ events: [ShrinkingEvent]) -> Double {
        // Simplified branching factor calculation
        let groupedByOriginal = Dictionary(grouping: events) { $0.metadata.originalComplexity }
        let branchingFactors = groupedByOriginal.values.map { Double($0.count) }
        return branchingFactors.reduce(0, +) / max(1.0, Double(branchingFactors.count))
    }

    private func analyzeEffectiveness(_ events: [ShrinkingEvent]) -> ShrinkEffectivenessAnalysis {
        let successfulEvents = events.filter(\.metadata.wasSuccessful)
        let complexityReductions = successfulEvents.map {
            Double($0.metadata.originalComplexity) - Double($0.metadata.targetComplexity)
        }

        let reductionRatio = complexityReductions.reduce(0, +) / max(1.0, Double(complexityReductions.count))
        let minimalCounterexampleQuality = calculateMinimalCounterexampleQuality(events)
        let replayConsistency = calculateReplayConsistency(events)

        return ShrinkEffectivenessAnalysis(
            reductionRatio: reductionRatio,
            minimalCounterexampleQuality: minimalCounterexampleQuality,
            replayConsistency: replayConsistency,
        )
    }

    private func calculateMinimalCounterexampleQuality(_ events: [ShrinkingEvent]) -> Double {
        let finalComplexities = events.map(\.metadata.targetComplexity)
        let minComplexity = finalComplexities.min() ?? 0
        let maxComplexity = finalComplexities.max() ?? 1

        return 1.0 - (Double(minComplexity) / max(1.0, Double(maxComplexity)))
    }

    private func calculateReplayConsistency(_ events: [ShrinkingEvent]) -> Double {
        // Simplified consistency measure
        let successfulReplays = events.count(where: { $0.metadata.wasSuccessful })
        return Double(successfulReplays) / max(1.0, Double(events.count))
    }

    private func analyzeCandidates(_ events: [ShrinkingEvent]) -> CandidateStatistics {
        let totalCandidatesGenerated = events.count
        let candidatesActuallyTested = events.count(where: { $0.metadata.wasSuccessful })
        let testingEfficiency = Double(candidatesActuallyTested) / max(1.0, Double(totalCandidatesGenerated))

        return CandidateStatistics(
            totalCandidatesGenerated: totalCandidatesGenerated,
            candidatesActuallyTested: candidatesActuallyTested,
            testingEfficiency: testingEfficiency,
        )
    }

    // MARK: - Test Run Analysis Implementations

    private func analyzeOutcomes(_ outcomes: [TestOutcome], totalDuration _: TimeInterval) -> TestOutcomeAnalysis {
        let successfulTests = outcomes.filter(\.wasSuccessful)
        let failedTests = outcomes.filter { !$0.wasSuccessful }

        let successRate = outcomes.isEmpty ? 0.0 : Double(successfulTests.count) / Double(outcomes.count)
        let failureRate = outcomes.isEmpty ? 0.0 : Double(failedTests.count) / Double(outcomes.count)
        let averageTestDuration = outcomes.isEmpty ? 0.0 : outcomes.map(\.totalDuration).reduce(0, +) / Double(outcomes.count)

        return TestOutcomeAnalysis(
            successRate: successRate.isFinite ? successRate : 0.0,
            failureRate: failureRate.isFinite ? failureRate : 0.0,
            averageTestDuration: averageTestDuration.isFinite ? averageTestDuration : 0.0,
        )
    }

    private func analyzeCounterexamples(_ outcomes: [TestOutcome]) -> CounterexampleAnalysis {
        let counterexamples = outcomes.compactMap(\.counterexampleValue)
        let clusteringCoefficient = calculateCounterexampleClustering(counterexamples)
        let commonPatterns = extractCommonPatterns(counterexamples)
        let averageShrinkingSteps = outcomes.isEmpty ? 0.0 : Double(outcomes.map(\.shrinkingSteps).reduce(0, +)) / Double(outcomes.count)

        return CounterexampleAnalysis(
            clusteringCoefficient: clusteringCoefficient.isFinite ? clusteringCoefficient : 0.0,
            commonPatterns: commonPatterns,
            averageShrinkingSteps: averageShrinkingSteps.isFinite ? averageShrinkingSteps : 0.0,
        )
    }

    private func calculateCounterexampleClustering(_ counterexamples: [Any]) -> Double {
        // Simplified clustering coefficient
        let stringRepresentations = counterexamples.map { String(describing: $0) }
        let uniqueValues = Set(stringRepresentations)

        return 1.0 - (Double(uniqueValues.count) / max(1.0, Double(stringRepresentations.count)))
    }

    private func extractCommonPatterns(_ counterexamples: [Any]) -> [String] {
        let stringRepresentations = counterexamples.map { String(describing: $0) }
        let counts = Dictionary(grouping: stringRepresentations) { $0 }.mapValues { $0.count }

        return counts.filter { $0.value > 1 }.keys.sorted()
    }

    private func analyzeComposition(_: [TestOutcome]) -> CompositionAnalysis {
        // Simplified composition analysis
        let combinatorEffectiveness = ["pick": 0.8, "choose": 0.9, "sequence": 0.7]
        let nestingDepthImpact = 0.1
        let compositionComplexity = 0.5

        return CompositionAnalysis(
            combinatorEffectiveness: combinatorEffectiveness,
            nestingDepthImpact: nestingDepthImpact,
            compositionComplexity: compositionComplexity,
        )
    }

    private func analyzeQuality(_: [TestOutcome]) -> QualityAnalysis {
        let randomnessTestResults = ["entropy": 0.85, "uniformity": 0.75, "independence": 0.80]
        let distributionFitness = 0.82
        let overallQualityScore = randomnessTestResults.values.reduce(0, +) / Double(randomnessTestResults.count)

        return QualityAnalysis(
            randomnessTestResults: randomnessTestResults,
            distributionFitness: distributionFitness,
            overallQualityScore: overallQualityScore,
        )
    }
}
