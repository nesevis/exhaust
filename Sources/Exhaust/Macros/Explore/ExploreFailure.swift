import CustomDump
import ExhaustCore

/// Formats a classification-aware test failure for reporting.
struct ExploreFailure<Output> {
    let counterexample: Output
    let original: Output?
    let seed: UInt64
    let invocations: ExploreInvocationCounts
    let directedSamplingBudget: Int
    let matchedDirections: [(index: Int, name: String)]
    var reducedSequence: ChoiceSequence?
    var reductionProducedNoImprovement: Bool = false

    /// Renders the failure as a human-readable string with direction attribution.
    func render() -> String {
        var lines: [String] = []

        let encodedSeed = ReplaySeed.Resolved.sampling(seed: seed, iteration: nil).encoded
        lines.append("Property failed after \(invocations.total) property invocations (seed \(encodedSeed))")

        if matchedDirections.isEmpty == false {
            let names = matchedDirections.map { "\"\($0.name)\"" }.joined(separator: ", ")
            lines.append("")
            lines.append("Directions: \(names)")
        }

        if let original {
            if let summary = summarizeReduction(original: original, reduced: counterexample, reducedSequence: reducedSequence) {
                lines.append("")
                lines.append("Reduction summary:")
                for line in summary.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("  \(line)")
                }
            }
        }

        lines.append("")
        lines.append("Counterexample:")
        var counterexampleDump = ""
        customDump(counterexample, to: &counterexampleDump, maxDepth: 3)
        for line in counterexampleDump.split(separator: "\n", omittingEmptySubsequences: false) {
            lines.append("  \(line)")
        }

        if let original {
            if let reductionDiff = diff(original, counterexample) {
                lines.append("")
                lines.append("Reduction diff:")
                for line in reductionDiff.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("  \(line)")
                }
            }
        }

        if reductionProducedNoImprovement {
            lines.append("")
            lines.append("Note: this result could not be reduced.")
        }

        lines.append("")
        lines.append("Property invoked: \(invocations.total) times")
        lines.append("  Warm-up: \(invocations.warmup)")
        lines.append("  Regression: \(invocations.regression)")
        lines.append("  Directed sampling: \(invocations.directedSampling)/\(directedSamplingBudget)")
        lines.append("  Reduction: \(invocations.reduction)")
        lines.append("  Diagnostic: \(invocations.diagnostic)")

        lines.append("")
        lines.append("Reproduce: .replay(\"\(encodedSeed)\")")

        return lines.joined(separator: "\n")
    }
}
