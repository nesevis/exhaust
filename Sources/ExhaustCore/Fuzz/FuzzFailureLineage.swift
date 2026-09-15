// Failure lineage: the unreduced failing child beside the parent it was mutated from, for offline reading of what a mutation did to reach a fault.
//
// The report keeps reduced counterexamples per cluster and the breadcrumb keeps hashes for crash recovery; neither pairs a failing child with its parent. On rare mutants the pairing is the whole question: which arm, applied to what, produced the witness. Off unless `EXHAUST_FAILURE_LINEAGE` names a directory, and then costs nothing until a search candidate fails.

import Foundation

/// Appends one JSON line per failing search candidate: provenance, parent and child sequences and rendered values, the structural diff between them, and what the failure gate and classification did with it.
package struct FuzzFailureLineage {
    /// What the runner knows about a failing candidate before the gate sees it.
    package struct Provenance {
        package let attemptIndex: Int
        package let phase: FuzzPhase
        package let origin: CandidateOrigin
        package let arms: MutationArmSet
        package let reseedRanges: [ClosedRange<Int>]
        package let parentIndex: Int?
        package let parentHash: UInt64
        package let childHash: UInt64
        package let childSequence: ChoiceSequence
        package let childValue: String
        package let symptom: String

        package init(
            attemptIndex: Int,
            phase: FuzzPhase,
            origin: CandidateOrigin,
            arms: MutationArmSet,
            reseedRanges: [ClosedRange<Int>],
            parentIndex: Int?,
            parentHash: UInt64,
            childHash: UInt64,
            childSequence: ChoiceSequence,
            childValue: String,
            symptom: String
        ) {
            self.attemptIndex = attemptIndex
            self.phase = phase
            self.origin = origin
            self.arms = arms
            self.reseedRanges = reseedRanges
            self.parentIndex = parentIndex
            self.parentHash = parentHash
            self.childHash = childHash
            self.childSequence = childSequence
            self.childValue = childValue
            self.symptom = symptom
        }
    }

    private let path: String
    private let seed: UInt64
    /// Distinguishes runners sharing one process, such as the tasks of one harness shard; the harness log's task order maps it back to a task name.
    private let runStartNanoseconds: UInt64

    /// Creates a writer under `directory`, or nil when the environment did not ask for one.
    package init?(directory: String?, seed: UInt64) {
        guard let directory else {
            return nil
        }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        path = directory + "/failure-lineage-\(ProcessInfo.processInfo.processIdentifier).jsonl"
        self.seed = seed
        runStartNanoseconds = monotonicNanoseconds()
    }

    /// Writes one row. `parentSequence` and `parentValue` are nil for candidates with no parent (fresh draws, screening rows, whole-value injections). `cluster` is nil when the gate did not reduce. The parent's phase, root phase, and generation say where its lineage began: a mutation-phase root is a fresh draw the mixture admitted.
    package func record(
        _ provenance: Provenance,
        parentSequence: ChoiceSequence?,
        parentValue: String?,
        gate: String,
        cluster: String?,
        isNewCluster: Bool?,
        parentPhase: FuzzPhase? = nil,
        parentRootPhase: FuzzPhase? = nil,
        parentGeneration: Int? = nil
    ) {
        var armNames: [String] = []
        for arm in MutationArm.allCases where provenance.arms.contains(arm) {
            armNames.append("\(arm)")
        }
        let diff = parentSequence.map { Self.diff(parent: $0, child: provenance.childSequence) }
        var fields: [(String, String)] = [
            ("seed", "\(seed)"),
            ("run", "\(runStartNanoseconds)"),
            ("attempt", "\(provenance.attemptIndex)"),
            ("phase", Self.quote("\(provenance.phase)")),
            ("origin", Self.quote("\(provenance.origin)")),
            ("arms", "[" + armNames.map(Self.quote).joined(separator: ",") + "]"),
            ("reseedRanges", "[" + provenance.reseedRanges.map { "[\($0.lowerBound),\($0.upperBound)]" }.joined(separator: ",") + "]"),
            ("parentIndex", provenance.parentIndex.map { "\($0)" } ?? "null"),
            ("parentHash", "\(provenance.parentHash)"),
            ("childHash", "\(provenance.childHash)"),
            ("symptom", Self.quote(provenance.symptom)),
            ("gate", Self.quote(gate)),
            ("cluster", cluster.map(Self.quote) ?? "null"),
            ("newCluster", isNewCluster.map { $0 ? "true" : "false" } ?? "null"),
            ("parentPhase", parentPhase.map { Self.quote("\($0)") } ?? "null"),
            ("parentRootPhase", parentRootPhase.map { Self.quote("\($0)") } ?? "null"),
            ("parentGeneration", parentGeneration.map { "\($0)" } ?? "null"),
            ("childSequence", Self.quote(Self.render(provenance.childSequence))),
            ("childValue", Self.quote(provenance.childValue)),
            ("parentSequence", parentSequence.map { Self.quote(Self.render($0)) } ?? "null"),
            ("parentValue", parentValue.map(Self.quote) ?? "null"),
        ]
        if let diff {
            fields.append(("parentChanged", "[\(diff.parentRange.lowerBound),\(diff.parentRange.upperBound)]"))
            fields.append(("childChanged", "[\(diff.childRange.lowerBound),\(diff.childRange.upperBound)]"))
            fields.append(("parentChangedEntries", Self.quote(Self.render(ChoiceSequence(parentSequence![diff.parentRange])))))
            fields.append(("childChangedEntries", Self.quote(Self.render(ChoiceSequence(provenance.childSequence[diff.childRange])))))
        }
        let line = "{" + fields.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}\n"
        append(line)
    }

    // MARK: - Rendering

    /// One token per entry: markers by their short symbol, a value as `tag:bits`, a branch as `b<id>/<count>`.
    static func render(_ sequence: ChoiceSequence) -> String {
        var tokens: [String] = []
        tokens.reserveCapacity(sequence.count)
        for entry in sequence {
            switch entry {
                case let .value(value):
                    tokens.append("\(value.choice.tag):\(value.choice.bitPattern64)")
                case let .branch(branch):
                    tokens.append("b\(branch.id)/\(branch.branchCount)")
                default:
                    tokens.append(entry.shortString)
            }
        }
        return tokens.joined(separator: " ")
    }

    /// The smallest spans that differ: everything outside the common prefix and common suffix. Half-open ranges over each sequence; an empty range marks a pure insertion or deletion at that position.
    static func diff(parent: ChoiceSequence, child: ChoiceSequence) -> (parentRange: Range<Int>, childRange: Range<Int>) {
        var prefix = 0
        let limit = min(parent.count, child.count)
        while prefix < limit, parent[prefix] == child[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < limit - prefix, parent[parent.count - 1 - suffix] == child[child.count - 1 - suffix] {
            suffix += 1
        }
        return (prefix ..< (parent.count - suffix), prefix ..< (child.count - suffix))
    }

    private static func quote(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count + 2)
        escaped.append("\"")
        for scalar in text.unicodeScalars {
            switch scalar {
                case "\"": escaped.append("\\\"")
                case "\\": escaped.append("\\\\")
                case "\n": escaped.append("\\n")
                case "\r": escaped.append("\\r")
                case "\t": escaped.append("\\t")
                default:
                    if scalar.value < 0x20 {
                        escaped.append(String(format: "\\u%04x", scalar.value))
                    } else {
                        escaped.unicodeScalars.append(scalar)
                    }
            }
        }
        escaped.append("\"")
        return escaped
    }

    private func append(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}
