import CustomDump
import ExhaustCore
import IssueReporting

// MARK: - Types

/// A report summarizing the results of generator validation.
public struct ValidationReport: Sendable, CustomStringConvertible {
    public let sampleCount: Int
    public let valuesGenerated: Int
    public let reflectionRoundTripSuccesses: Int
    public let replayDeterminismSuccesses: Int
    public let uniqueChoiceSequences: Int
    public let failures: [ValidationFailure]
    /// Total wall-clock time for the validation run, in seconds.
    public let elapsedTime: Double

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

    /// Average time per sample (generate + reflect + replay), in seconds.
    public var averageTimePerSample: Double {
        guard valuesGenerated > 0 else { return 0 }
        return elapsedTime / Double(valuesGenerated)
    }

    /// Whether the average time per sample exceeds 5 ms, suggesting the generator may be too expensive for large-scale property testing.
    public var isSlowGenerator: Bool {
        averageTimePerSample > 0.005
    }

    public var description: String {
        var lines: [String] = []
        lines.append("ValidationReport(samples: \(sampleCount), generated: \(valuesGenerated))")
        lines.append("  Reflection round-trip: \(reflectionRoundTripSuccesses)/\(valuesGenerated) (\(String(format: "%.1f", reflectionSuccessRate * 100))%)")
        lines.append("  Replay determinism:    \(replayDeterminismSuccesses)/\(valuesGenerated)")
        lines.append("  Unique sequences:      \(uniqueChoiceSequences)/\(valuesGenerated) (\(String(format: "%.1f", uniquenessRate * 100))%)")
        let perSampleMs = averageTimePerSample * 1000
        lines.append("  Avg time per sample:   \(String(format: "%.2f", perSampleMs)) ms\(isSlowGenerator ? " (slow)" : "")")
        if failures.isEmpty {
            lines.append("  Result: PASSED")
        } else {
            lines.append("  Result: FAILED (\(failures.count) failure(s))")
            for failure in failures {
                lines.append("    - \(failure)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// A specific validation failure detected during generator validation.
public enum ValidationFailure: Sendable, CustomStringConvertible {
    case reflectionRoundTripMismatch(sampleIndex: Int, detail: String)
    case reflectionFailed(sampleIndex: Int, errorDescription: String?)
    case replayFailed(sampleIndex: Int)
    case replayNonDeterministic(sampleIndex: Int, detail: String?)
    case noValuesGenerated
    /// Reflection failed because the generator contains a forward-only `map` or `bind`.
    case forwardOnlyTransform(inputType: String, outputType: String, kind: String)

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
        }
    }
}

// MARK: - Non-Equatable overload

public extension ReflectiveGenerator where Operation == ReflectiveOperation {
    /// Validates this generator by checking reflection round-trip, replay determinism, and generation health. Uses choice-sequence comparison for round-trip checks.
    ///
    /// Failures are recorded as test issues via `reportIssue`, so calling this inside a test is sufficient — no assertions needed.
    ///
    /// - Parameters:
    ///   - samples: Number of values to generate and test. Defaults to 200.
    ///   - seed: Optional seed for deterministic validation runs.
    /// - Returns: A ``ValidationReport`` summarizing the results.
    @discardableResult
    func validate(
        samples: Int = 200,
        seed: UInt64? = nil,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) -> ValidationReport {
        _validate(
            samples: samples,
            seed: seed,
            differ: nil,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }
}

// MARK: - Equatable overload

public extension ReflectiveGenerator where Operation == ReflectiveOperation, Value: Equatable {
    /// Validates this generator by checking reflection round-trip, replay determinism, and generation health. Uses `Equatable` conformance and `CustomDump.diff` for rich failure output.
    ///
    /// Failures are recorded as test issues via `reportIssue`, so calling this inside a test is sufficient — no assertions needed.
    ///
    /// - Parameters:
    ///   - samples: Number of values to generate and test. Defaults to 200.
    ///   - seed: Optional seed for deterministic validation runs.
    /// - Returns: A ``ValidationReport`` summarizing the results.
    @discardableResult
    func validate(
        samples: Int = 200,
        seed: UInt64? = nil,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) -> ValidationReport {
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

private extension ReflectiveGenerator where Operation == ReflectiveOperation {
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
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) -> ValidationReport {
        let maxFailures = 20
        var failures: [ValidationFailure] = []
        var forwardOnlyDetected = false
        var valuesGenerated = 0
        var roundTripSuccesses = 0
        var determinismSuccesses = 0
        var uniqueSequences: Set<ChoiceSequence> = []
        let startTime = ContinuousClock.now

        var iterator = ValueAndChoiceTreeInterpreter(
            self,
            seed: seed,
            maxRuns: UInt64(samples)
        )

        for sampleIndex in 0 ..< samples {
            guard let (value, tree) = try? iterator.next() else { continue }
            valuesGenerated += 1

            let generatedSequence = ChoiceSequence.flatten(tree)
            uniqueSequences.insert(generatedSequence)

            // -- Round-trip check --
            if !forwardOnlyDetected, failures.count < maxFailures {
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
                        // Non-Equatable path: compare via choice sequences
                        let reflectedSequence = ChoiceSequence.flatten(tree)
                        if generatedSequence == reflectedSequence {
                            roundTripSuccesses += 1
                        } else {
                            let detail = "choice sequences differ: \(generatedSequence.shortString) vs \(reflectedSequence.shortString)"
                            failures.append(.reflectionRoundTripMismatch(
                                sampleIndex: sampleIndex,
                                detail: detail
                            ))
                        }
                    }
                } catch let error as Interpreters.ReflectionError {
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
                            errorDescription: "\(error)"
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

        let elapsed = ContinuousClock.now - startTime
        let elapsedSeconds =
            Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) * 1e-18

        if valuesGenerated == 0 {
            failures.append(.noValuesGenerated)
        }

        let report = ValidationReport(
            sampleCount: samples,
            valuesGenerated: valuesGenerated,
            reflectionRoundTripSuccesses: roundTripSuccesses,
            replayDeterminismSuccesses: determinismSuccesses,
            uniqueChoiceSequences: uniqueSequences.count,
            failures: failures,
            elapsedTime: elapsedSeconds
        )

        for failure in report.failures {
            reportIssue(
                "\(failure)",
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
        }

        return report
    }
}
