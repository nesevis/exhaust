import Foundation

// MARK: - Core Reporting Data Structures

/// Metadata captured during value generation
public struct GenerationMetadata: Sendable {
    public let timestamp: Date
    public let operationType: String
    public let generatorType: String
    public let size: UInt64
    public let entropy: UInt64?
    public let duration: TimeInterval

    public init(timestamp: Date = Date(), operationType: String, generatorType: String, size: UInt64, entropy: UInt64? = nil, duration: TimeInterval) {
        self.timestamp = timestamp
        self.operationType = operationType
        self.generatorType = generatorType
        self.size = size
        self.entropy = entropy
        self.duration = duration
    }
}

/// Metadata captured during shrinking operations
public struct ShrinkingMetadata: Sendable {
    public let timestamp: Date
    public let originalComplexity: UInt64
    public let targetComplexity: UInt64
    public let stepType: ShrinkStepType
    public let duration: TimeInterval
    public let wasSuccessful: Bool

    public init(timestamp: Date = Date(), originalComplexity: UInt64, targetComplexity: UInt64, stepType: ShrinkStepType, duration: TimeInterval, wasSuccessful: Bool) {
        self.timestamp = timestamp
        self.originalComplexity = originalComplexity
        self.targetComplexity = targetComplexity
        self.stepType = stepType
        self.duration = duration
        self.wasSuccessful = wasSuccessful
    }
}

/// Types of shrinking steps
public enum ShrinkStepType: Sendable {
    case greedyCandidate
    case exhaustiveCandidate
    case replay
}

/// Test outcome metadata
public struct TestOutcome {
    public let timestamp: Date
    public let wasSuccessful: Bool
    public let counterexampleValue: Any?
    public let shrinkingSteps: Int
    public let totalDuration: TimeInterval

    public init(timestamp: Date = Date(), wasSuccessful: Bool, counterexampleValue: Any? = nil, shrinkingSteps: Int = 0, totalDuration: TimeInterval) {
        self.timestamp = timestamp
        self.wasSuccessful = wasSuccessful
        self.counterexampleValue = counterexampleValue
        self.shrinkingSteps = shrinkingSteps
        self.totalDuration = totalDuration
    }
}

// MARK: - Analysis Data Structures

/// Statistical distribution analysis results
public struct DistributionAnalysis {
    public let entropy: Double
    public let uniformityScore: Double
    public let autocorrelationCoefficient: Double
    public let coveragePercentage: Double

    public init(entropy: Double, uniformityScore: Double, autocorrelationCoefficient: Double, coveragePercentage: Double) {
        self.entropy = entropy
        self.uniformityScore = uniformityScore
        self.autocorrelationCoefficient = autocorrelationCoefficient
        self.coveragePercentage = coveragePercentage
    }
}

/// Coverage analysis across input space
public struct CoverageAnalysis {
    public let inputSpaceCoverage: Double
    public let boundaryCoverage: Double
    public let equivalenceClassCoverage: Double
    public let temporalDistribution: [String: Int]

    public init(inputSpaceCoverage: Double, boundaryCoverage: Double, equivalenceClassCoverage: Double, temporalDistribution: [String: Int]) {
        self.inputSpaceCoverage = inputSpaceCoverage
        self.boundaryCoverage = boundaryCoverage
        self.equivalenceClassCoverage = equivalenceClassCoverage
        self.temporalDistribution = temporalDistribution
    }
}

/// Bias detection analysis
public struct BiasAnalysis {
    public let branchSelectionBias: [String: Double]
    public let valueClusteringScore: Double
    public let sizeParameterSensitivity: Double

    public init(branchSelectionBias: [String: Double], valueClusteringScore: Double, sizeParameterSensitivity: Double) {
        self.branchSelectionBias = branchSelectionBias
        self.valueClusteringScore = valueClusteringScore
        self.sizeParameterSensitivity = sizeParameterSensitivity
    }
}

/// Performance analysis metrics
public struct PerformanceAnalysis {
    public let averageGenerationLatency: TimeInterval
    public let memoryUsagePattern: [String: Double]
    public let entropyConsumptionRate: Double

    public init(averageGenerationLatency: TimeInterval, memoryUsagePattern: [String: Double], entropyConsumptionRate: Double) {
        self.averageGenerationLatency = averageGenerationLatency
        self.memoryUsagePattern = memoryUsagePattern
        self.entropyConsumptionRate = entropyConsumptionRate
    }
}

/// Shrinking convergence analysis
public struct ConvergenceAnalysis {
    public let averageStepsToConvergence: Double
    public let convergenceSuccessRate: Double
    public let greedyVsExhaustiveEffectiveness: Double

    public init(averageStepsToConvergence: Double, convergenceSuccessRate: Double, greedyVsExhaustiveEffectiveness: Double) {
        self.averageStepsToConvergence = averageStepsToConvergence
        self.convergenceSuccessRate = convergenceSuccessRate
        self.greedyVsExhaustiveEffectiveness = greedyVsExhaustiveEffectiveness
    }
}

/// Analysis of shrinking paths
public struct ShrinkPathAnalysis {
    public let averagePathLength: Double
    public let pathComplexityReduction: Double
    public let branchingFactor: Double

    public init(averagePathLength: Double, pathComplexityReduction: Double, branchingFactor: Double) {
        self.averagePathLength = averagePathLength
        self.pathComplexityReduction = pathComplexityReduction
        self.branchingFactor = branchingFactor
    }
}

/// Shrinking effectiveness metrics
public struct ShrinkEffectivenessAnalysis {
    public let reductionRatio: Double
    public let minimalCounterexampleQuality: Double
    public let replayConsistency: Double

    public init(reductionRatio: Double, minimalCounterexampleQuality: Double, replayConsistency: Double) {
        self.reductionRatio = reductionRatio
        self.minimalCounterexampleQuality = minimalCounterexampleQuality
        self.replayConsistency = replayConsistency
    }
}

/// Shrinking candidate statistics
public struct CandidateStatistics {
    public let totalCandidatesGenerated: Int
    public let candidatesActuallyTested: Int
    public let testingEfficiency: Double

    public init(totalCandidatesGenerated: Int, candidatesActuallyTested: Int, testingEfficiency: Double) {
        self.totalCandidatesGenerated = totalCandidatesGenerated
        self.candidatesActuallyTested = candidatesActuallyTested
        self.testingEfficiency = testingEfficiency
    }
}

/// Test outcome analysis
public struct TestOutcomeAnalysis {
    public let successRate: Double
    public let failureRate: Double
    public let averageTestDuration: TimeInterval

    public init(successRate: Double, failureRate: Double, averageTestDuration: TimeInterval) {
        self.successRate = successRate
        self.failureRate = failureRate
        self.averageTestDuration = averageTestDuration
    }
}

/// Counterexample pattern analysis
public struct CounterexampleAnalysis {
    public let clusteringCoefficient: Double
    public let commonPatterns: [String]
    public let averageShrinkingSteps: Double

    public init(clusteringCoefficient: Double, commonPatterns: [String], averageShrinkingSteps: Double) {
        self.clusteringCoefficient = clusteringCoefficient
        self.commonPatterns = commonPatterns
        self.averageShrinkingSteps = averageShrinkingSteps
    }
}

/// Generator composition analysis
public struct CompositionAnalysis {
    public let combinatorEffectiveness: [String: Double]
    public let nestingDepthImpact: Double
    public let compositionComplexity: Double

    public init(combinatorEffectiveness: [String: Double], nestingDepthImpact: Double, compositionComplexity: Double) {
        self.combinatorEffectiveness = combinatorEffectiveness
        self.nestingDepthImpact = nestingDepthImpact
        self.compositionComplexity = compositionComplexity
    }
}

/// Statistical quality assessment
public struct QualityAnalysis {
    public let randomnessTestResults: [String: Double]
    public let distributionFitness: Double
    public let overallQualityScore: Double

    public init(randomnessTestResults: [String: Double], distributionFitness: Double, overallQualityScore: Double) {
        self.randomnessTestResults = randomnessTestResults
        self.distributionFitness = distributionFitness
        self.overallQualityScore = overallQualityScore
    }
}

// MARK: - Comprehensive Report Structures

/// Complete generation analysis report
public struct GenerationReport {
    public let distributionMetrics: DistributionAnalysis
    public let coverageMetrics: CoverageAnalysis
    public let biasDetection: BiasAnalysis
    public let performanceMetrics: PerformanceAnalysis

    public init(distributionMetrics: DistributionAnalysis, coverageMetrics: CoverageAnalysis, biasDetection: BiasAnalysis, performanceMetrics: PerformanceAnalysis) {
        self.distributionMetrics = distributionMetrics
        self.coverageMetrics = coverageMetrics
        self.biasDetection = biasDetection
        self.performanceMetrics = performanceMetrics
    }
}

/// Complete shrinking analysis report
public struct ShrinkingReport {
    public let convergenceMetrics: ConvergenceAnalysis
    public let pathAnalysis: ShrinkPathAnalysis
    public let effectivenessMetrics: ShrinkEffectivenessAnalysis
    public let candidateStatistics: CandidateStatistics

    public init(convergenceMetrics: ConvergenceAnalysis, pathAnalysis: ShrinkPathAnalysis, effectivenessMetrics: ShrinkEffectivenessAnalysis, candidateStatistics: CandidateStatistics) {
        self.convergenceMetrics = convergenceMetrics
        self.pathAnalysis = pathAnalysis
        self.effectivenessMetrics = effectivenessMetrics
        self.candidateStatistics = candidateStatistics
    }
}

/// Complete test run analysis report
public struct TestRunReport {
    public let successFailureRates: TestOutcomeAnalysis
    public let counterexamplePatterns: CounterexampleAnalysis
    public let generatorCompositionMetrics: CompositionAnalysis
    public let statisticalQuality: QualityAnalysis

    public init(successFailureRates: TestOutcomeAnalysis, counterexamplePatterns: CounterexampleAnalysis, generatorCompositionMetrics: CompositionAnalysis, statisticalQuality: QualityAnalysis) {
        self.successFailureRates = successFailureRates
        self.counterexamplePatterns = counterexamplePatterns
        self.generatorCompositionMetrics = generatorCompositionMetrics
        self.statisticalQuality = statisticalQuality
    }
}

/// Master report combining all analyses
public struct TycheReport {
    public let generationReport: GenerationReport
    public let shrinkingReport: ShrinkingReport
    public let testRunReport: TestRunReport
    public let reportTimestamp: Date

    public init(generationReport: GenerationReport, shrinkingReport: ShrinkingReport, testRunReport: TestRunReport, reportTimestamp: Date = Date()) {
        self.generationReport = generationReport
        self.shrinkingReport = shrinkingReport
        self.testRunReport = testRunReport
        self.reportTimestamp = reportTimestamp
    }
}
