import CustomDump
import ExhaustCore

struct PropertyTestFailure<Output> {
    let counterexample: Output
    let original: Output?
    let sourceCode: String?
    let seed: UInt64?
    let iteration: Int
    let samplingBudget: UInt64
    /// The ChoiceSequence shortString
    let blueprint: String?
    let propertyInvocations: Int?
    var replayHint: String?
    /// When `true`, renders only the replay seed — the `#expect` assertions provide per-value detail.
    var transparent: Bool = false

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
        if transparent {
            return renderHumanTransparent()
        }

        var lines: [String] = []

        if let seed {
            let encodedSeed = CrockfordBase32.encode(seed)
            lines.append("Property failed (iteration \(iteration)/\(samplingBudget), seed \(encodedSeed))")
        } else {
            lines.append("Property failed (iteration \(iteration)/\(samplingBudget))")
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
            if let reductionDiff = diff(original, counterexample) {
                lines.append("")
                lines.append("Reduction diff:")
                for line in reductionDiff.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("  \(line)")
                }
            }
        }

        if let propertyInvocations {
            lines.append("")
            lines.append("Property invoked: \(propertyInvocations) times")
        }

        if let seed {
            lines.append("")
            lines.append("Reproduce: .replay(\"\(CrockfordBase32.encode(seed))\")")
        } else if let replayHint {
            lines.append("")
            lines.append(replayHint)
        }

        return lines.joined(separator: "\n")
    }

    /// Renders only the replay seed — the `#expect` assertions provide per-value detail.
    private func renderHumanTransparent() -> String {
        if let seed {
            return "Reproduce: .replay(\"\(CrockfordBase32.encode(seed))\")"
        } else if let replayHint {
            return replayHint
        } else {
            return "Property failed (no replay seed available)"
        }
    }

    // MARK: - LLM-optimized format

    private func renderLLMOptimized() -> String {
        var counterexampleDump = ""
        customDump(counterexample, to: &counterexampleDump)

        var parts: [String] = []
        parts.append("\"event\":\"property_failed\"")
        if let seed {
            let encodedSeed = CrockfordBase32.encode(seed)
            parts.append("\"seed\":\"\(encodedSeed)\"")
        }
        parts.append("\"iteration\":\(iteration)")
        parts.append("\"samplingBudget\":\(samplingBudget)")

        if let sourceCode {
            parts.append("\"source\":\"\(escapeJSON(sourceCode))\"")
        }

        if transparent == false {
            parts.append("\"counterexample\":\"\(escapeJSON(counterexampleDump))\"")

            if let original {
                var originalDump = ""
                customDump(original, to: &originalDump)
                parts.append("\"original\":\"\(escapeJSON(originalDump))\"")
            }
        }

        if let propertyInvocations {
            parts.append("\"propertyInvocations\":\(propertyInvocations)")
        }

        if let seed {
            let encodedSeed = CrockfordBase32.encode(seed)
            parts.append("\"replay\":\".replay(\\\"\(encodedSeed)\\\")\"")
        } else if let replayHint {
            parts.append("\"replayHint\":\"\(escapeJSON(replayHint))\"")
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
