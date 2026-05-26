import CustomDump
import ExhaustCore
import Foundation
import IssueReporting

// MARK: - Types

/// Summarizes the correctness and coverage results of a ``#examine`` validation run.
///
/// Capture the return value of ``#examine`` to assert on coverage quality:
/// ```swift
/// let report = #examine(myGen, .samples(200))
/// #expect(report.decilesCovered.allSatisfy { $0.value >= 6 })
/// #expect(report.branchCoverage == 1.0)
/// ```
///
/// Correctness properties (``reflectionRoundTripSuccesses``, ``replayDeterminismSuccesses``) reflect whether the generator round-trips and replays correctly. Coverage properties (``decilesCovered``, ``branchCoverage``, ``sequenceLengthDeciles``, ``characterVariety``, ``complexityDeciles``) measure how well the generator explores its domain. When a metric does not apply to the generator (for example, ``branchCoverage`` on a generator with no picks), the property returns a passing default so assertions do not fail on irrelevant checks.
public struct ExamineReport: Sendable, CustomStringConvertible {
    /// Number of samples requested for the validation run.
    public let sampleCount: Int
    /// Number of values the generator actually produced. Lower than ``sampleCount`` when generation fails for some samples.
    public let valuesGenerated: Int
    /// Number of values that survived reflection round-trip without change. Equal to ``valuesGenerated`` for a healthy generator.
    public let reflectionRoundTripSuccesses: Int
    /// Number of values that replayed deterministically from their choice tree. Equal to ``valuesGenerated`` for a healthy generator.
    public let replayDeterminismSuccesses: Int
    /// Number of distinct choice sequences observed across all generated values. A value of 1 means every sample produced the same output.
    public let uniqueChoiceSequences: Int
    /// All validation failures detected during the run. Empty when the generator is healthy.
    public let failures: [ExamineFailure]
    /// Wall-clock time spent generating values, in seconds. Does not include correctness checks.
    public let generationTime: Double
    /// Total wall-clock time for the entire validation run, in seconds.
    public let elapsedTime: Double
    /// Per-filter predicate observations accumulated during generation, keyed by filter fingerprint. Check ``FilterObservation/validityRate`` and ``FilterObservation/sourceLocation`` to identify sparse filters.
    public let filterObservations: [UInt64: FilterObservation]

    // MARK: - Coverage Metrics

    /// Per-type decile coverage. Each entry reports how many of 10 equal-width histogram bins received at least one observation for that numeric type. Values are normalized within each node's valid range before bucketing. Returns an empty array when the generator has no numeric parameters with a domain size of 10 or more.
    public let decilesCovered: [(type: String, value: Int)]
    /// Fraction of all pick branches observed out of all possible branches across all pick sites. Returns 1.0 when the generator has no pick sites.
    public let branchCoverage: Double
    /// Minimum decile coverage across all sequence-length sites. A value below 10 means at least one sequence site did not explore its full length range. Returns 10 when the generator has no sequences.
    public let sequenceLengthDeciles: Int
    /// Whether the generator contains sequence nodes.
    public let hasSequences: Bool
    /// Per-domain character variety. Each entry reports the fraction covered and the domain size. Empty when the generator has no character parameters. The minimum variety across all domains is used for single-value assertions.
    public let characterCoverage: [(domainSize: Int, variety: Double)]

    /// Minimum character variety across all character domains. Returns 1.0 when the generator has no character parameters.
    public var characterVariety: Double {
        characterCoverage.map(\.variety).min() ?? 1.0
    }

    /// Deciles covered in the normalized per-sample complexity distribution. A value below 10 means the generator does not produce a full variety of structural sizes. Returns 10 when complexity does not vary (for example, generators with no sequences).
    public let complexityDeciles: Int
    /// A representative sample from the midpoint of the run, showing the generator's structural shape at a typical size parameter.
    package let representativeTree: ChoiceTree?

    /// Whether the validation passed with no failures.
    public var passed: Bool {
        failures.isEmpty
    }

    /// The fraction of generated values that survived reflection round-trip.
    public var reflectionSuccessRate: Double {
        guard valuesGenerated > 0 else { return 0 }
        return Double(reflectionRoundTripSuccesses) / Double(valuesGenerated)
    }

    /// The fraction of generated values with distinct choice sequences.
    public var uniquenessRate: Double {
        guard valuesGenerated > 0 else { return 0 }
        return Double(uniqueChoiceSequences) / Double(valuesGenerated)
    }

    /// Average generation time per sample, in seconds. Does not include correctness checks.
    public var averageTimePerSample: Double {
        guard valuesGenerated > 0 else { return 0 }
        return generationTime / Double(valuesGenerated)
    }

    /// Whether the average time per sample exceeds 5 ms, suggesting the generator may be too expensive for large-scale property testing.
    public var isSlowGenerator: Bool {
        averageTimePerSample > 0.005
    }

    public var description: String {
        var lines: [String] = []
        let perSampleMs = averageTimePerSample * 1000
        lines.append("#examine: \(valuesGenerated) samples, \(String(format: "%.3f", perSampleMs))ms/sample")

        lines.append("  Correctness: \(reflectionRoundTripSuccesses)/\(valuesGenerated) reflection, \(replayDeterminismSuccesses)/\(valuesGenerated) replay")
        lines.append("  Unique: \(uniqueChoiceSequences)/\(valuesGenerated)")

        let hasDeciles = decilesCovered.isEmpty == false
        let hasBranches = branchCoverage < 1.0
        let hasCharacterCoverage = characterCoverage.isEmpty == false

        if hasDeciles || hasSequences || hasBranches || hasCharacterCoverage {
            lines.append("  Coverage:")
            for entry in decilesCovered {
                let bar = decileBar(covered: entry.value)
                lines.append("    \(entry.type): \(bar) \(entry.value)/10 deciles")
            }
            if hasSequences {
                lines.append("    Sequences: \(sequenceLengthDeciles)/10 deciles")
            }
            if hasBranches {
                lines.append("    Branches: \(String(format: "%.0f", branchCoverage * 100))%")
            }
            if hasCharacterCoverage {
                for entry in characterCoverage {
                    lines.append("    Characters: \(String(format: "%.0f", entry.variety * 100))% (of \(entry.domainSize) code points)")
                }
            }
        }

        if filterObservations.isEmpty == false {
            lines.append("  Filters:")
            for (_, observation) in filterObservations.sorted(by: { $0.key < $1.key }) {
                let location: String
                if let source = observation.sourceLocation {
                    let file = "\(source.fileID)".split(separator: "/").last.map(String.init) ?? "\(source.fileID)"
                    location = "\(file):\(source.line)"
                } else {
                    location = "unknown"
                }
                let filterTypeLabel = observation.filterType?.shortDescription ?? "auto"
                let discarded = observation.attempts - observation.passes
                lines.append("    \(location): \(String(format: "%.0f", observation.validityRate * 100))% (\(filterTypeLabel), \(discarded) discarded)")
            }
        }

        if complexityDeciles < 10 {
            lines.append("  Complexity: \(complexityDeciles)/10 deciles")
        }

        if failures.isEmpty == false {
            lines.append("  Failures: \(failures.count)")
            for failure in failures.prefix(5) {
                lines.append("    - \(failure)")
            }
            if failures.count > 5 {
                lines.append("    ... and \(failures.count - 5) more")
            }
        }

        if let tree = representativeTree {
            lines.append("  Example:")
            for treeLine in tree.debugDescription.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("    \(treeLine)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func decileBar(covered: Int) -> String {
        var bar = "["
        for index in 0 ..< 10 {
            bar += index < covered ? "\u{2022}" : " "
        }
        bar += "]"
        return bar
    }
}

/// Describes a single failure detected during an ``#examine`` validation run.
///
/// Match on cases to diagnose failures reported in ``ExamineReport/failures``.
public enum ExamineFailure: Sendable, CustomStringConvertible {
    /// The generator's `backward` mapping does not invert its `forward` mapping for this sample. Check that `backward(forward(x)) == x` holds.
    case reflectionRoundTripMismatch(sampleIndex: Int, detail: String)
    /// Reflection threw an error for this sample. The generator may use an unsupported operation or have an incomplete backward mapping.
    case reflectionFailed(sampleIndex: Int, errorDescription: String?)
    /// Replaying the choice tree produced no value. The generator may depend on external state that changed between generation and replay.
    case replayFailed(sampleIndex: Int)
    /// Two replays of the same choice tree produced different values. The generator contains non-determinism, for example, reliance on mutable external state.
    case replayNonDeterministic(sampleIndex: Int, detail: String?)
    /// The generator produced no values at all. It may always throw, or its filter may reject every candidate.
    case noValuesGenerated
    /// The generator contains a forward-only `map` or `bind` without a backward mapping. Use `.mapped(forward:backward:)` or `.bound(forward:backward:)` to provide an inverse.
    case forwardOnlyTransform(inputType: String, outputType: String, kind: String)
    /// A filter predicate passed less than 5% of the time over at least 20 attempts. The generator is spending most of its budget on rejection.
    case lowFilterValidityRate(fingerprint: UInt64, rate: Double, attempts: Int)

    public var description: String {
        switch self {
            case let .reflectionRoundTripMismatch(index, detail):
                "Sample \(index): reflection round-trip mismatch — \(detail)"
            case let .reflectionFailed(index, error):
                "Sample \(index): reflection failed — \(error ?? "unknown error")"
            case let .replayFailed(index):
                "Sample \(index): replay returned nil"
            case let .replayNonDeterministic(index, detail):
                "Sample \(index): replay produced different results" + (detail.map { " — \($0)" } ?? "")
            case .noValuesGenerated:
                "Generator produced no values"
            case let .forwardOnlyTransform(inputType, outputType, "map"):
                "Reflection blocked by forward-only map (\(inputType) → \(outputType)). Use .mapped(forward:backward:) to provide an inverse."
            case let .forwardOnlyTransform(inputType, outputType, _):
                "Reflection blocked by bind (\(inputType) → \(outputType)). This will prevent replay and reduction of externally created values of \(outputType)."
            case let .lowFilterValidityRate(fingerprint, rate, attempts):
                "Filter \(String(format: "%08X", fingerprint & 0xFFFF_FFFF)): validity rate \(String(format: "%.1f", rate * 100))% over \(attempts) attempts. Generation is spending most of its time on rejection. Consider widening the input range or relaxing the predicate."
        }
    }
}

// MARK: - Non-Equatable overload

package extension Generator where Operation == ReflectiveOperation {
    /// Validates this generator by checking reflection round-trip, replay determinism, and generation health. Uses choice-sequence comparison for round-trip checks.
    ///
    /// Failures are recorded as test issues via ``reportIssue``, so calling this inside a test is sufficient — no assertions needed.
    ///
    /// - Parameters:
    ///   - samples: Number of values to generate and test. Defaults to 200.
    ///   - seed: Optional seed for deterministic validation runs.
    ///   - reporting: Optional per-check severity configuration. When `nil`, all failures are reported at ``ExamineSeverity/error`` severity.
    /// - Returns: A ``ExamineReport`` summarizing the results.
    @discardableResult
    func validate(
        samples: Int = 200,
        seed: UInt64? = nil,
        reporting: ExamineReportingConfiguration? = nil,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) -> ExamineReport {
        _validate(
            samples: samples,
            seed: seed,
            differ: nil,
            reporting: reporting,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }
}

// MARK: - Equatable overload

package extension Generator where Operation == ReflectiveOperation, Value: Equatable {
    /// Validates this generator by checking reflection round-trip, replay determinism, and generation health. Uses `Equatable` conformance and `CustomDump.diff` for rich failure output.
    ///
    /// Failures are recorded as test issues via ``reportIssue``, so calling this inside a test is sufficient — no assertions needed.
    ///
    /// - Parameters:
    ///   - samples: Number of values to generate and test. Defaults to 200.
    ///   - seed: Optional seed for deterministic validation runs.
    ///   - reporting: Optional per-check severity configuration. When `nil`, all failures are reported at ``ExamineSeverity/error`` severity.
    /// - Returns: A ``ExamineReport`` summarizing the results.
    @discardableResult
    func validate(
        samples: Int = 200,
        seed: UInt64? = nil,
        reporting: ExamineReportingConfiguration? = nil,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) -> ExamineReport {
        _validate(
            samples: samples,
            seed: seed,
            differ: { lhs, rhs in
                guard let l = lhs as? Value, let r = rhs as? Value else {
                    return .notEqual(detail: "type mismatch")
                }
                if l == r { return .equal }
                return .notEqual(detail: diff(l, r) ?? "\(l) != \(r)")
            },
            reporting: reporting,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }
}

// MARK: - Shared implementation

private enum DiffResult {
    case equal
    case notEqual(detail: String)
}

private extension Generator where Operation == ReflectiveOperation {
    /// Core validation loop shared by both overloads.
    ///
    /// - Parameters:
    ///   - samples: Number of values to generate.
    ///   - seed: Optional deterministic seed.
    ///   - differ: Value differ for round-trip and determinism checks.
    ///     Returns `.equal` or `.notEqual(detail:)` with a rich diff string.
    ///     When `nil`, choice-sequence comparison is used instead.
    func _validate(
        samples: Int,
        seed: UInt64?,
        differ: ((Any, Any) -> DiffResult)?,
        reporting: ExamineReportingConfiguration?,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) -> ExamineReport {
        let maxFailures = 20
        var failures: [ExamineFailure] = []
        var forwardOnlyDetected = false
        var valuesGenerated = 0
        var roundTripSuccesses = 0
        var determinismSuccesses = 0
        var uniqueSequences: Set<ChoiceSequence> = []
        var storedTrees: [ChoiceTree] = []
        storedTrees.reserveCapacity(samples)
        let startNanoseconds = monotonicNanoseconds()

        var iterator = ValueAndChoiceTreeInterpreter(
            self,
            seed: seed,
            maxRuns: UInt64(samples)
        )

        var generationNanoseconds: UInt64 = 0

        for sampleIndex in 0 ..< samples {
            let genStart = monotonicNanoseconds()
            guard let (value, tree) = try? iterator.next() else { continue }
            generationNanoseconds += monotonicNanoseconds() - genStart
            valuesGenerated += 1
            storedTrees.append(tree)

            let generatedSequence = ChoiceSequence.flatten(tree)
            uniqueSequences.insert(generatedSequence)

            // -- Round-trip check --
            if forwardOnlyDetected == false, failures.count < maxFailures {
                do {
                    let reflectedTree = try Interpreters.reflect(self, with: value)
                    let tree = reflectedTree ?? tree

                    if let differ {
                        // Equatable path: replay the reflected tree and compare values
                        if let replayedValue = try Interpreters.replay(self, using: tree) {
                            switch differ(value, replayedValue) {
                                case .equal:
                                    roundTripSuccesses += 1
                                case let .notEqual(detail):
                                    failures.append(.reflectionRoundTripMismatch(
                                        sampleIndex: sampleIndex,
                                        detail: detail
                                    ))
                            }
                        } else {
                            failures.append(.reflectionFailed(
                                sampleIndex: sampleIndex,
                                errorDescription: "replay of reflected tree returned nil"
                            ))
                        }
                    } else {
                        // Non-Equatable path: walk both trees and compare values at every choice site
                        let originalTree = storedTrees[valuesGenerated - 1]
                        if let mismatch = ChoiceTree.compareValues(originalTree, tree) {
                            failures.append(.reflectionRoundTripMismatch(
                                sampleIndex: sampleIndex,
                                detail: mismatch
                            ))
                        } else {
                            roundTripSuccesses += 1
                        }
                    }
                } catch let error as ReflectionError {
                    switch error {
                        case let .forwardOnlyMap(inputType, outputType):
                            failures.append(.forwardOnlyTransform(
                                inputType: "\(inputType)",
                                outputType: "\(outputType)",
                                kind: "map"
                            ))
                            forwardOnlyDetected = true
                        case let .forwardOnlyBind(inputType, outputType):
                            failures.append(.forwardOnlyTransform(
                                inputType: "\(inputType)",
                                outputType: "\(outputType)",
                                kind: "bind"
                            ))
                            forwardOnlyDetected = true
                        default:
                            failures.append(.reflectionFailed(
                                sampleIndex: sampleIndex,
                                errorDescription: localizedErrorMessage(error)
                            ))
                    }
                } catch {
                    failures.append(.reflectionFailed(
                        sampleIndex: sampleIndex,
                        errorDescription: "\(error)"
                    ))
                }
            }

            // -- Determinism check --
            if failures.count < maxFailures {
                do {
                    let replay1 = try Interpreters.replay(self, using: tree)
                    let replay2 = try Interpreters.replay(self, using: tree)

                    if let r1 = replay1, let r2 = replay2 {
                        if let differ {
                            switch differ(r1, r2) {
                                case .equal:
                                    determinismSuccesses += 1
                                case let .notEqual(detail):
                                    failures.append(.replayNonDeterministic(
                                        sampleIndex: sampleIndex,
                                        detail: detail
                                    ))
                            }
                        } else {
                            // Non-Equatable: both non-nil is sufficient since replay is deterministic by construction
                            determinismSuccesses += 1
                        }
                    } else {
                        failures.append(.replayFailed(sampleIndex: sampleIndex))
                    }
                } catch {
                    failures.append(.replayFailed(sampleIndex: sampleIndex))
                }
            }
        }

        let nanosecondsPerSecond = 1_000_000_000.0
        let totalElapsedNanoseconds = monotonicNanoseconds() - startNanoseconds
        let elapsedSeconds = Double(totalElapsedNanoseconds) / nanosecondsPerSecond
        let generationSeconds = Double(generationNanoseconds) / nanosecondsPerSecond

        if valuesGenerated == 0 {
            failures.append(.noValuesGenerated)
        }

        for (fingerprint, observation) in iterator.filterObservations where observation.attempts >= 20 {
            if observation.validityRate < 0.05 {
                failures.append(.lowFilterValidityRate(
                    fingerprint: fingerprint,
                    rate: observation.validityRate,
                    attempts: observation.attempts
                ))
            }
        }

        let coverage = ExamineCoverageAnalysis.analyze(trees: storedTrees)

        let report = ExamineReport(
            sampleCount: samples,
            valuesGenerated: valuesGenerated,
            reflectionRoundTripSuccesses: roundTripSuccesses,
            replayDeterminismSuccesses: determinismSuccesses,
            uniqueChoiceSequences: uniqueSequences.count,
            failures: failures,
            generationTime: generationSeconds,
            elapsedTime: elapsedSeconds,
            filterObservations: iterator.filterObservations,
            decilesCovered: coverage.decilesCovered,
            branchCoverage: coverage.branchCoverage,
            sequenceLengthDeciles: coverage.sequenceLengthDeciles,
            hasSequences: coverage.hasSequences,
            characterCoverage: coverage.characterCoverage,
            complexityDeciles: coverage.complexityDeciles,
            representativeTree: Self.medianComplexityTree(from: storedTrees)
        )

        if reporting?.suppressIssueReporting == true {
            return report
        }

        for failure in report.failures {
            let examineSeverity: ExamineSeverity = switch failure {
                case .reflectionRoundTripMismatch, .reflectionFailed, .forwardOnlyTransform:
                    reporting?.reflectionSeverity ?? .error
                case .replayFailed, .replayNonDeterministic:
                    reporting?.determinismSeverity ?? .error
                case .lowFilterValidityRate:
                    reporting?.filterHealthSeverity ?? .error
                case .noValuesGenerated:
                    .error
            }

            guard let issueSeverity = examineSeverity.issueSeverity else { continue }

            switch failure {
                case let .lowFilterValidityRate(fingerprint, _, _):
                    if let location = report.filterObservations[fingerprint]?.sourceLocation {
                        reportIssue(
                            "\(failure)",
                            severity: issueSeverity,
                            fileID: location.fileID,
                            filePath: location.filePath,
                            line: location.line,
                            column: location.column
                        )
                    } else {
                        reportIssue(
                            "\(failure)",
                            severity: issueSeverity,
                            fileID: fileID,
                            filePath: filePath,
                            line: line,
                            column: column
                        )
                    }
                default:
                    reportIssue(
                        "\(failure)",
                        severity: issueSeverity,
                        fileID: fileID,
                        filePath: filePath,
                        line: line,
                        column: column
                    )
            }
        }

        return report
    }

    static func medianComplexityTree(from trees: [ChoiceTree]) -> ChoiceTree? {
        guard trees.isEmpty == false else { return nil }
        let scored = trees.enumerated().map { (index: $0.offset, complexity: $0.element.complexity) }
        let sorted = scored.sorted { $0.complexity < $1.complexity }
        return trees[sorted[sorted.count / 2].index]
    }
}

func localizedErrorMessage(_ error: any Error) -> String {
    guard let localized = error as? LocalizedError else {
        return "\(error)"
    }
    return [localized.errorDescription, localized.recoverySuggestion]
        .compactMap(\.self)
        .joined(separator: "\n\n")
}
