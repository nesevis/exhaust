import CustomDump
import ExhaustCore

/// Formats a classification-aware test failure for reporting.
struct ExploreFailure<Output> {
    let counterexample: Output
    let original: Output?
    let seed: UInt64
    let propertyInvocations: Int
    let totalBudget: Int
    let matchedDirections: [(index: Int, name: String)]
    var reducedSequence: ChoiceSequence?

    /// Renders the failure as a human-readable string with direction attribution.
    func render() -> String {
        var lines: [String] = []

        let encodedSeed = CrockfordBase32.encode(seed: seed, iteration: propertyInvocations)
        lines.append("Property failed (iteration \(propertyInvocations)/\(totalBudget), seed \(encodedSeed))")

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
        customDump(counterexample, to: &counterexampleDump)
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

        lines.append("")
        lines.append("Property invoked: \(propertyInvocations) times")

        lines.append("")
        lines.append("Reproduce: .replay(\"\(CrockfordBase32.encode(seed: seed, iteration: propertyInvocations))\")")

        return lines.joined(separator: "\n")
    }
}
