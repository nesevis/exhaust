import Foundation

// MARK: - Reporter Protocol

/// Protocol for outputting Tyche reports in different formats
public protocol TycheReporter {
    func report(_ report: TycheReport)
}

// MARK: - Console Reporter

/// Reports Tyche analysis to the console with formatted output
public struct ConsoleReporter: TycheReporter {
    private let useColors: Bool
    private let verbosity: ConsoleVerbosity

    public enum ConsoleVerbosity {
        case summary
        case detailed
        case verbose
    }

    public init(useColors: Bool = true, verbosity: ConsoleVerbosity = .detailed) {
        self.useColors = useColors
        self.verbosity = verbosity
    }

    public func report(_ report: TycheReport) {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium

        print(colorize("🎲 Tyche Property-Based Testing Report", color: .blue, bold: true))
        print(colorize("Generated: \(formatter.string(from: report.reportTimestamp))", color: .gray))
        print()

        printGenerationSection(report.generationReport)
        printShrinkingSection(report.shrinkingReport)
        printTestRunSection(report.testRunReport)

        print(colorize("📊 Report complete", color: .green, bold: true))
    }

    private func printGenerationSection(_ report: GenerationReport) {
        print(colorize("📈 Generation Analysis", color: .cyan, bold: true))

        // Distribution Metrics
        print("  📊 Distribution Quality:")
        print("    • Entropy: \(format(report.distributionMetrics.entropy))")
        print("    • Uniformity: \(format(report.distributionMetrics.uniformityScore))")
        print("    • Autocorrelation: \(format(report.distributionMetrics.autocorrelationCoefficient))")
        print("    • Coverage: \(formatPercentage(report.distributionMetrics.coveragePercentage))")

        // Coverage Metrics
        if verbosity != .summary {
            print("  🎯 Coverage Analysis:")
            print("    • Input Space: \(formatPercentage(report.coverageMetrics.inputSpaceCoverage))")
            print("    • Boundary Coverage: \(formatPercentage(report.coverageMetrics.boundaryCoverage))")
            print("    • Equivalence Classes: \(formatPercentage(report.coverageMetrics.equivalenceClassCoverage))")
        }

        // Bias Detection
        if verbosity == .verbose {
            print("  ⚖️ Bias Detection:")
            print("    • Value Clustering: \(format(report.biasDetection.valueClusteringScore))")
            print("    • Size Sensitivity: \(format(report.biasDetection.sizeParameterSensitivity))")
            if !report.biasDetection.branchSelectionBias.isEmpty {
                print("    • Branch Selection Bias:")
                for (branch, bias) in report.biasDetection.branchSelectionBias.prefix(3) {
                    print("      - \(branch): \(format(bias))")
                }
            }
        }

        // Performance
        print("  ⚡ Performance:")
        print("    • Avg Generation Time: \(formatDuration(report.performanceMetrics.averageGenerationLatency))")
        print("    • Entropy Consumption: \(format(report.performanceMetrics.entropyConsumptionRate)) bits/sec")

        print()
    }

    private func printShrinkingSection(_ report: ShrinkingReport) {
        print(colorize("🔍 Shrinking Analysis", color: .yellow, bold: true))

        // Convergence
        print("  🎯 Convergence:")
        print("    • Average Steps: \(format(report.convergenceMetrics.averageStepsToConvergence))")
        print("    • Success Rate: \(formatPercentage(report.convergenceMetrics.convergenceSuccessRate))")
        print("    • Greedy vs Exhaustive: \(format(report.convergenceMetrics.greedyVsExhaustiveEffectiveness))")

        // Effectiveness
        if verbosity != .summary {
            print("  📉 Effectiveness:")
            print("    • Reduction Ratio: \(format(report.effectivenessMetrics.reductionRatio))")
            print("    • Minimal Quality: \(format(report.effectivenessMetrics.minimalCounterexampleQuality))")
            print("    • Replay Consistency: \(formatPercentage(report.effectivenessMetrics.replayConsistency))")
        }

        // Candidate Statistics
        if verbosity == .verbose {
            print("  📊 Candidates:")
            print("    • Total Generated: \(report.candidateStatistics.totalCandidatesGenerated)")
            print("    • Actually Tested: \(report.candidateStatistics.candidatesActuallyTested)")
            print("    • Testing Efficiency: \(formatPercentage(report.candidateStatistics.testingEfficiency))")
        }

        print()
    }

    private func printTestRunSection(_ report: TestRunReport) {
        print(colorize("🧪 Test Run Analysis", color: .magenta, bold: true))

        // Success/Failure Rates
        print("  📈 Test Outcomes:")
        print("    • Success Rate: \(formatPercentage(report.successFailureRates.successRate))")
        print("    • Failure Rate: \(formatPercentage(report.successFailureRates.failureRate))")
        print("    • Average Duration: \(formatDuration(report.successFailureRates.averageTestDuration))")

        // Counterexample Patterns
        if verbosity != .summary {
            print("  🔍 Counterexamples:")
            print("    • Clustering: \(format(report.counterexamplePatterns.clusteringCoefficient))")
            print("    • Avg Shrinking Steps: \(format(report.counterexamplePatterns.averageShrinkingSteps))")
            if !report.counterexamplePatterns.commonPatterns.isEmpty {
                print("    • Common Patterns: \(report.counterexamplePatterns.commonPatterns.prefix(3).joined(separator: ", "))")
            }
        }

        // Quality Assessment
        if verbosity == .verbose {
            print("  🎯 Statistical Quality:")
            print("    • Overall Score: \(format(report.statisticalQuality.overallQualityScore))")
            print("    • Distribution Fitness: \(format(report.statisticalQuality.distributionFitness))")
            for (test, score) in report.statisticalQuality.randomnessTestResults.prefix(3) {
                print("    • \(test.capitalized): \(format(score))")
            }
        }

        print()
    }

    // MARK: - Formatting Helpers

    private func colorize(_ text: String, color: ConsoleColor, bold: Bool = false) -> String {
        guard useColors else { return text }

        var result = color.ansiCode + text + ConsoleColor.reset.ansiCode
        if bold {
            result = ConsoleColor.bold.ansiCode + result
        }
        return result
    }

    private func format(_ value: Double) -> String {
        return String(format: "%.3f", value)
    }

    private func formatPercentage(_ value: Double) -> String {
        return String(format: "%.1f%%", value * 100)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 0.001 {
            return String(format: "%.2fμs", duration * 1_000_000)
        } else if duration < 1.0 {
            return String(format: "%.2fms", duration * 1000)
        } else {
            return String(format: "%.2fs", duration)
        }
    }

    private enum ConsoleColor {
        case red, green, yellow, blue, magenta, cyan, gray, bold, reset

        var ansiCode: String {
            switch self {
            case .red: return "\u{001B}[31m"
            case .green: return "\u{001B}[32m"
            case .yellow: return "\u{001B}[33m"
            case .blue: return "\u{001B}[34m"
            case .magenta: return "\u{001B}[35m"
            case .cyan: return "\u{001B}[36m"
            case .gray: return "\u{001B}[37m"
            case .bold: return "\u{001B}[1m"
            case .reset: return "\u{001B}[0m"
            }
        }
    }
}

// MARK: - JSON Reporter

/// Reports Tyche analysis as JSON to a file
public struct JSONReporter: TycheReporter {
    private let outputURL: URL
    private let prettyPrint: Bool

    public init(outputURL: URL, prettyPrint: Bool = true) {
        self.outputURL = outputURL
        self.prettyPrint = prettyPrint
    }

    public func report(_ report: TycheReport) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if prettyPrint {
                encoder.outputFormatting = .prettyPrinted
            }

            let jsonData = try encoder.encode(TycheReportJSON(report: report))
            try jsonData.write(to: outputURL)

            print("📄 Tyche JSON report written to: \(outputURL.path)")
        } catch {
            print("❌ Failed to write JSON report: \(error)")
        }
    }
}

// MARK: - CSV Reporter

/// Reports Tyche analysis as CSV for statistical analysis
public struct CSVReporter: TycheReporter {
    private let outputURL: URL

    public init(outputURL: URL) {
        self.outputURL = outputURL
    }

    public func report(_ report: TycheReport) {
        do {
            let csvContent = generateCSVContent(report)
            try csvContent.write(to: outputURL, atomically: true, encoding: .utf8)

            print("📊 Tyche CSV report written to: \(outputURL.path)")
        } catch {
            print("❌ Failed to write CSV report: \(error)")
        }
    }

    private func generateCSVContent(_ report: TycheReport) -> String {
        var lines: [String] = []

        // Header
        lines.append("metric,category,value")

        // Generation metrics
        lines.append("entropy,distribution,\(report.generationReport.distributionMetrics.entropy)")
        lines.append("uniformity,distribution,\(report.generationReport.distributionMetrics.uniformityScore)")
        lines.append("autocorrelation,distribution,\(report.generationReport.distributionMetrics.autocorrelationCoefficient)")
        lines.append("coverage,distribution,\(report.generationReport.distributionMetrics.coveragePercentage)")

        lines.append("input_space_coverage,coverage,\(report.generationReport.coverageMetrics.inputSpaceCoverage)")
        lines.append("boundary_coverage,coverage,\(report.generationReport.coverageMetrics.boundaryCoverage)")
        lines.append("equivalence_class_coverage,coverage,\(report.generationReport.coverageMetrics.equivalenceClassCoverage)")

        lines.append("value_clustering,bias,\(report.generationReport.biasDetection.valueClusteringScore)")
        lines.append("size_sensitivity,bias,\(report.generationReport.biasDetection.sizeParameterSensitivity)")

        lines.append("avg_generation_latency,performance,\(report.generationReport.performanceMetrics.averageGenerationLatency)")
        lines.append("entropy_consumption_rate,performance,\(report.generationReport.performanceMetrics.entropyConsumptionRate)")

        // Shrinking metrics
        lines.append("avg_steps_to_convergence,shrinking,\(report.shrinkingReport.convergenceMetrics.averageStepsToConvergence)")
        lines.append("convergence_success_rate,shrinking,\(report.shrinkingReport.convergenceMetrics.convergenceSuccessRate)")
        lines.append("greedy_vs_exhaustive,shrinking,\(report.shrinkingReport.convergenceMetrics.greedyVsExhaustiveEffectiveness)")

        lines.append("reduction_ratio,effectiveness,\(report.shrinkingReport.effectivenessMetrics.reductionRatio)")
        lines.append("minimal_quality,effectiveness,\(report.shrinkingReport.effectivenessMetrics.minimalCounterexampleQuality)")
        lines.append("replay_consistency,effectiveness,\(report.shrinkingReport.effectivenessMetrics.replayConsistency)")

        // Test run metrics
        lines.append("success_rate,outcomes,\(report.testRunReport.successFailureRates.successRate)")
        lines.append("failure_rate,outcomes,\(report.testRunReport.successFailureRates.failureRate)")
        lines.append("avg_test_duration,outcomes,\(report.testRunReport.successFailureRates.averageTestDuration)")

        lines.append("counterexample_clustering,counterexamples,\(report.testRunReport.counterexamplePatterns.clusteringCoefficient)")
        lines.append("avg_shrinking_steps,counterexamples,\(report.testRunReport.counterexamplePatterns.averageShrinkingSteps)")

        lines.append("overall_quality_score,quality,\(report.testRunReport.statisticalQuality.overallQualityScore)")
        lines.append("distribution_fitness,quality,\(report.testRunReport.statisticalQuality.distributionFitness)")

        return lines.joined(separator: "\n")
    }
}

// MARK: - HTML Reporter

/// Reports Tyche analysis as an HTML file with visualizations
public struct HTMLReporter: TycheReporter {
    private let outputURL: URL
    private let includeCharts: Bool

    public init(outputURL: URL, includeCharts: Bool = true) {
        self.outputURL = outputURL
        self.includeCharts = includeCharts
    }

    public func report(_ report: TycheReport) {
        do {
            let htmlContent = generateHTMLContent(report)
            try htmlContent.write(to: outputURL, atomically: true, encoding: .utf8)

            print("🌐 Tyche HTML report written to: \(outputURL.path)")
        } catch {
            print("❌ Failed to write HTML report: \(error)")
        }
    }

    private func generateHTMLContent(_ report: TycheReport) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .medium

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Tyche Property-Based Testing Report</title>
            <style>
                body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; margin: 40px; }
                h1 { color: #2c3e50; }
                h2 { color: #34495e; border-bottom: 2px solid #ecf0f1; padding-bottom: 10px; }
                .metric { margin: 10px 0; }
                .metric-label { font-weight: bold; color: #2c3e50; }
                .metric-value { color: #27ae60; }
                .section { margin: 30px 0; }
                .timestamp { color: #7f8c8d; font-size: 0.9em; }
                .performance { background: #ecf0f1; padding: 15px; border-radius: 5px; }
                .score { font-size: 1.2em; font-weight: bold; }
                .score.good { color: #27ae60; }
                .score.medium { color: #f39c12; }
                .score.poor { color: #e74c3c; }
            </style>
        </head>
        <body>
            <h1>🎲 Tyche Property-Based Testing Report</h1>
            <p class="timestamp">Generated: \(formatter.string(from: report.reportTimestamp))</p>
            
            <div class="section">
                <h2>📈 Generation Analysis</h2>
                <div class="metric">
                    <span class="metric-label">Entropy:</span>
                    <span class="metric-value">\(String(format: "%.3f", report.generationReport.distributionMetrics.entropy))</span>
                </div>
                <div class="metric">
                    <span class="metric-label">Uniformity:</span>
                    <span class="metric-value">\(String(format: "%.1f%%", report.generationReport.distributionMetrics.uniformityScore * 100))</span>
                </div>
                <div class="metric">
                    <span class="metric-label">Coverage:</span>
                    <span class="metric-value">\(String(format: "%.1f%%", report.generationReport.distributionMetrics.coveragePercentage * 100))</span>
                </div>
                <div class="performance">
                    <h3>⚡ Performance</h3>
                    <div class="metric">
                        <span class="metric-label">Average Generation Time:</span>
                        <span class="metric-value">\(formatDuration(report.generationReport.performanceMetrics.averageGenerationLatency))</span>
                    </div>
                </div>
            </div>
            
            <div class="section">
                <h2>🔍 Shrinking Analysis</h2>
                <div class="metric">
                    <span class="metric-label">Average Steps to Convergence:</span>
                    <span class="metric-value">\(String(format: "%.1f", report.shrinkingReport.convergenceMetrics.averageStepsToConvergence))</span>
                </div>
                <div class="metric">
                    <span class="metric-label">Success Rate:</span>
                    <span class="metric-value">\(String(format: "%.1f%%", report.shrinkingReport.convergenceMetrics.convergenceSuccessRate * 100))</span>
                </div>
                <div class="metric">
                    <span class="metric-label">Reduction Ratio:</span>
                    <span class="metric-value">\(String(format: "%.3f", report.shrinkingReport.effectivenessMetrics.reductionRatio))</span>
                </div>
            </div>
            
            <div class="section">
                <h2>🧪 Test Run Analysis</h2>
                <div class="metric">
                    <span class="metric-label">Success Rate:</span>
                    <span class="metric-value score \(getScoreClass(report.testRunReport.successFailureRates.successRate))">\(String(format: "%.1f%%", report.testRunReport.successFailureRates.successRate * 100))</span>
                </div>
                <div class="metric">
                    <span class="metric-label">Average Test Duration:</span>
                    <span class="metric-value">\(formatDuration(report.testRunReport.successFailureRates.averageTestDuration))</span>
                </div>
                <div class="metric">
                    <span class="metric-label">Overall Quality Score:</span>
                    <span class="metric-value score \(getScoreClass(report.testRunReport.statisticalQuality.overallQualityScore))">\(String(format: "%.3f", report.testRunReport.statisticalQuality.overallQualityScore))</span>
                </div>
            </div>
            
            <footer>
                <p class="timestamp">Report generated by Tyche - Property-Based Testing Analysis</p>
            </footer>
        </body>
        </html>
        """
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 0.001 {
            return String(format: "%.2fμs", duration * 1_000_000)
        } else if duration < 1.0 {
            return String(format: "%.2fms", duration * 1000)
        } else {
            return String(format: "%.2fs", duration)
        }
    }

    private func getScoreClass(_ score: Double) -> String {
        if score >= 0.8 {
            return "good"
        } else if score >= 0.6 {
            return "medium"
        } else {
            return "poor"
        }
    }
}

// MARK: - JSON Codable Wrapper

private struct TycheReportJSON: Codable {
    let generationReport: GenerationReportJSON
    let shrinkingReport: ShrinkingReportJSON
    let testRunReport: TestRunReportJSON
    let reportTimestamp: Date

    init(report: TycheReport) {
        generationReport = GenerationReportJSON(report: report.generationReport)
        shrinkingReport = ShrinkingReportJSON(report: report.shrinkingReport)
        testRunReport = TestRunReportJSON(report: report.testRunReport)
        reportTimestamp = report.reportTimestamp
    }
}

private struct GenerationReportJSON: Codable {
    let distributionMetrics: DistributionAnalysisJSON
    let coverageMetrics: CoverageAnalysisJSON
    let biasDetection: BiasAnalysisJSON
    let performanceMetrics: PerformanceAnalysisJSON

    init(report: GenerationReport) {
        distributionMetrics = DistributionAnalysisJSON(analysis: report.distributionMetrics)
        coverageMetrics = CoverageAnalysisJSON(analysis: report.coverageMetrics)
        biasDetection = BiasAnalysisJSON(analysis: report.biasDetection)
        performanceMetrics = PerformanceAnalysisJSON(analysis: report.performanceMetrics)
    }
}

private struct DistributionAnalysisJSON: Codable {
    let entropy: Double
    let uniformityScore: Double
    let autocorrelationCoefficient: Double
    let coveragePercentage: Double

    init(analysis: DistributionAnalysis) {
        entropy = analysis.entropy
        uniformityScore = analysis.uniformityScore
        autocorrelationCoefficient = analysis.autocorrelationCoefficient
        coveragePercentage = analysis.coveragePercentage
    }
}

private struct CoverageAnalysisJSON: Codable {
    let inputSpaceCoverage: Double
    let boundaryCoverage: Double
    let equivalenceClassCoverage: Double
    let temporalDistribution: [String: Int]

    init(analysis: CoverageAnalysis) {
        inputSpaceCoverage = analysis.inputSpaceCoverage
        boundaryCoverage = analysis.boundaryCoverage
        equivalenceClassCoverage = analysis.equivalenceClassCoverage
        temporalDistribution = analysis.temporalDistribution
    }
}

private struct BiasAnalysisJSON: Codable {
    let branchSelectionBias: [String: Double]
    let valueClusteringScore: Double
    let sizeParameterSensitivity: Double

    init(analysis: BiasAnalysis) {
        branchSelectionBias = analysis.branchSelectionBias
        valueClusteringScore = analysis.valueClusteringScore
        sizeParameterSensitivity = analysis.sizeParameterSensitivity
    }
}

private struct PerformanceAnalysisJSON: Codable {
    let averageGenerationLatency: TimeInterval
    let memoryUsagePattern: [String: Double]
    let entropyConsumptionRate: Double

    init(analysis: PerformanceAnalysis) {
        averageGenerationLatency = analysis.averageGenerationLatency
        memoryUsagePattern = analysis.memoryUsagePattern
        entropyConsumptionRate = analysis.entropyConsumptionRate
    }
}

private struct ShrinkingReportJSON: Codable {
    let convergenceMetrics: ConvergenceAnalysisJSON
    let pathAnalysis: ShrinkPathAnalysisJSON
    let effectivenessMetrics: ShrinkEffectivenessAnalysisJSON
    let candidateStatistics: CandidateStatisticsJSON

    init(report: ShrinkingReport) {
        convergenceMetrics = ConvergenceAnalysisJSON(analysis: report.convergenceMetrics)
        pathAnalysis = ShrinkPathAnalysisJSON(analysis: report.pathAnalysis)
        effectivenessMetrics = ShrinkEffectivenessAnalysisJSON(analysis: report.effectivenessMetrics)
        candidateStatistics = CandidateStatisticsJSON(statistics: report.candidateStatistics)
    }
}

private struct ConvergenceAnalysisJSON: Codable {
    let averageStepsToConvergence: Double
    let convergenceSuccessRate: Double
    let greedyVsExhaustiveEffectiveness: Double

    init(analysis: ConvergenceAnalysis) {
        averageStepsToConvergence = analysis.averageStepsToConvergence
        convergenceSuccessRate = analysis.convergenceSuccessRate
        greedyVsExhaustiveEffectiveness = analysis.greedyVsExhaustiveEffectiveness
    }
}

private struct ShrinkPathAnalysisJSON: Codable {
    let averagePathLength: Double
    let pathComplexityReduction: Double
    let branchingFactor: Double

    init(analysis: ShrinkPathAnalysis) {
        averagePathLength = analysis.averagePathLength
        pathComplexityReduction = analysis.pathComplexityReduction
        branchingFactor = analysis.branchingFactor
    }
}

private struct ShrinkEffectivenessAnalysisJSON: Codable {
    let reductionRatio: Double
    let minimalCounterexampleQuality: Double
    let replayConsistency: Double

    init(analysis: ShrinkEffectivenessAnalysis) {
        reductionRatio = analysis.reductionRatio
        minimalCounterexampleQuality = analysis.minimalCounterexampleQuality
        replayConsistency = analysis.replayConsistency
    }
}

private struct CandidateStatisticsJSON: Codable {
    let totalCandidatesGenerated: Int
    let candidatesActuallyTested: Int
    let testingEfficiency: Double

    init(statistics: CandidateStatistics) {
        totalCandidatesGenerated = statistics.totalCandidatesGenerated
        candidatesActuallyTested = statistics.candidatesActuallyTested
        testingEfficiency = statistics.testingEfficiency
    }
}

private struct TestRunReportJSON: Codable {
    let successFailureRates: TestOutcomeAnalysisJSON
    let counterexamplePatterns: CounterexampleAnalysisJSON
    let generatorCompositionMetrics: CompositionAnalysisJSON
    let statisticalQuality: QualityAnalysisJSON

    init(report: TestRunReport) {
        successFailureRates = TestOutcomeAnalysisJSON(analysis: report.successFailureRates)
        counterexamplePatterns = CounterexampleAnalysisJSON(analysis: report.counterexamplePatterns)
        generatorCompositionMetrics = CompositionAnalysisJSON(analysis: report.generatorCompositionMetrics)
        statisticalQuality = QualityAnalysisJSON(analysis: report.statisticalQuality)
    }
}

private struct TestOutcomeAnalysisJSON: Codable {
    let successRate: Double
    let failureRate: Double
    let averageTestDuration: TimeInterval

    init(analysis: TestOutcomeAnalysis) {
        successRate = analysis.successRate
        failureRate = analysis.failureRate
        averageTestDuration = analysis.averageTestDuration
    }
}

private struct CounterexampleAnalysisJSON: Codable {
    let clusteringCoefficient: Double
    let commonPatterns: [String]
    let averageShrinkingSteps: Double

    init(analysis: CounterexampleAnalysis) {
        clusteringCoefficient = analysis.clusteringCoefficient
        commonPatterns = analysis.commonPatterns
        averageShrinkingSteps = analysis.averageShrinkingSteps
    }
}

private struct CompositionAnalysisJSON: Codable {
    let combinatorEffectiveness: [String: Double]
    let nestingDepthImpact: Double
    let compositionComplexity: Double

    init(analysis: CompositionAnalysis) {
        combinatorEffectiveness = analysis.combinatorEffectiveness
        nestingDepthImpact = analysis.nestingDepthImpact
        compositionComplexity = analysis.compositionComplexity
    }
}

private struct QualityAnalysisJSON: Codable {
    let randomnessTestResults: [String: Double]
    let distributionFitness: Double
    let overallQualityScore: Double

    init(analysis: QualityAnalysis) {
        randomnessTestResults = analysis.randomnessTestResults
        distributionFitness = analysis.distributionFitness
        overallQualityScore = analysis.overallQualityScore
    }
}
