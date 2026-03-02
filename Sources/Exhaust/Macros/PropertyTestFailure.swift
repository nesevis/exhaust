import CustomDump
@_spi(ExhaustInternal) import ExhaustCore

struct PropertyTestFailure<Output> {
    let counterexample: Output
    let original: Output?
    let sourceCode: String?
    let seed: UInt64?
    let iteration: Int
    let maxIterations: UInt64
    let blueprint: String?
    let oracleCalls: Int?

    func render(format: ExhaustLog.Format) -> String {
        switch format {
        case .human:
            renderHuman()
        case .llmOptimized:
            renderLLMOptimized()
        }
    }

    // MARK: - Human format

    private func renderHuman() -> String {
        var lines: [String] = []

        if let seed {
            lines.append("Property failed (iteration \(iteration)/\(maxIterations), seed \(seed))")
        } else {
            lines.append("Property failed (reflecting)")
        }
        if let sourceCode {
            lines.append("  \(sourceCode)")
        }

        lines.append("")
        lines.append("Counterexample:")
        var counterexampleDump = ""
        customDump(counterexample, to: &counterexampleDump)
        for line in counterexampleDump.split(separator: "\n", omittingEmptySubsequences: false) {
            lines.append("  \(line)")
        }

        if let original {
            if let shrinkDiff = diff(original, counterexample) {
                lines.append("")
                lines.append("Shrink diff:")
                for line in shrinkDiff.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("  \(line)")
                }
            }
        }

        if let oracleCalls {
            lines.append("")
            lines.append("Oracle calls: \(oracleCalls)")
        }

        if let seed {
            lines.append("")
            lines.append("Reproduce: .replay(\(seed))")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - LLM-optimized format

    private func renderLLMOptimized() -> String {
        var counterexampleDump = ""
        customDump(counterexample, to: &counterexampleDump)

        var parts: [String] = []
        parts.append("\"event\":\"property_failed\"")
        if let seed {
            parts.append("\"seed\":\(seed)")
        }
        parts.append("\"iteration\":\(iteration)")
        parts.append("\"maxIterations\":\(maxIterations)")

        if let sourceCode {
            parts.append("\"source\":\"\(escapeJSON(sourceCode))\"")
        }

        parts.append("\"counterexample\":\"\(escapeJSON(counterexampleDump))\"")

        if let original {
            var originalDump = ""
            customDump(original, to: &originalDump)
            parts.append("\"original\":\"\(escapeJSON(originalDump))\"")
        }

        if let oracleCalls {
            parts.append("\"oracleCalls\":\(oracleCalls)")
        }

        if let seed {
            parts.append("\"replay\":\".replay(\(seed))\"")
        }

        return "{\(parts.joined(separator: ","))}"
    }

    private func escapeJSON(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "\\":
                escaped += "\\\\"
            case "\"":
                escaped += "\\\""
            case "\n":
                escaped += "\\n"
            case "\r":
                escaped += "\\r"
            case "\t":
                escaped += "\\t"
            default:
                escaped.append(character)
            }
        }
        return escaped
    }
}
