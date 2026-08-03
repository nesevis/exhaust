//
//  MacroSupport+Examine.swift
//  Exhaust
//
//  Created by Chris Kolbu on 9/6/2026.
//

import IssueReporting

public extension __ExhaustRuntime {
    // MARK: - Examination

    /// Validates a generator's reflection, replay, and health. Runtime target of `#examine` expansion.
    ///
    /// Falls back to choice-sequence comparison for non-`Equatable` types. Skips the reflection check for synthesized generators (``ReflectiveGenerator/isSynthesized``), which are forward-only by design.
    @discardableResult
    static func __examine(
        _ refGen: ReflectiveGenerator<some Any>,
        settings: [ExamineSettings],
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) -> ExamineReport {
        let config = ExamineReportingConfiguration(from: settings)

        let seed: UInt64?
        switch resolveExamineReplaySeed(config.replaySeed, fileID: fileID, filePath: filePath, line: line, column: column) {
            case .unseeded:
                seed = nil
            case let .seeded(resolvedSeed):
                seed = resolvedSeed
            case .invalid:
                return emptyExamineReport()
        }

        let gen = refGen.gen
        return gen.validate(
            samples: config.samples,
            seed: seed,
            skipReflection: refGen.isSynthesized,
            reporting: config,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }

    /// Validates a generator with a user-provided replay determinism check. Runtime target of `#examine` expansion with trailing closure.
    @discardableResult
    static func __examine<Output>(
        _ refGen: ReflectiveGenerator<Output>,
        settings: [ExamineSettings],
        replayCheck: @escaping @Sendable (Output, Output) -> Bool,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) -> ExamineReport {
        let config = ExamineReportingConfiguration(from: settings)

        let seed: UInt64?
        switch resolveExamineReplaySeed(config.replaySeed, fileID: fileID, filePath: filePath, line: line, column: column) {
            case .unseeded:
                seed = nil
            case let .seeded(resolvedSeed):
                seed = resolvedSeed
            case .invalid:
                return emptyExamineReport()
        }

        let gen = refGen.gen
        return gen.validate(
            samples: config.samples,
            seed: seed,
            skipReflection: refGen.isSynthesized,
            replayCheck: { lhs, rhs in
                guard let lhs = lhs as? Output, let rhs = rhs as? Output else {
                    return false
                }
                return replayCheck(lhs, rhs)
            },
            reporting: config,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }
}

// MARK: - Replay Seed Resolution

private extension __ExhaustRuntime {
    /// The outcome of resolving an `#examine` replay seed.
    enum ExamineSeedResolution {
        /// No seed was supplied; validation runs unseeded.
        case unseeded
        /// A sampling seed to validate under.
        case seeded(UInt64)
        /// The seed failed to decode or names a screening row. The error is already reported; the run must return an empty report.
        case invalid
    }

    /// Resolves an optional replay seed to a sampling seed, reporting an error for anything else.
    ///
    /// Screening seeds are rejected rather than ignored: they address a covering-array row that `#examine` cannot replay, and honoring their seed digits as a sampling seed would silently validate a different stream than the one the seed names.
    static func resolveExamineReplaySeed(
        _ replaySeed: ReplaySeed?,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) -> ExamineSeedResolution {
        guard let replaySeed else {
            return .unseeded
        }
        switch replaySeed.resolve() {
            case let .sampling(seed, _):
                return .seeded(seed)
            case .valueScreening, .specScreening:
                reportError(
                    "Screening replay seeds (with a U row marker) address a covering-array row and cannot seed #examine. Pass the run seed from a prior report.",
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
                return .invalid
            case nil:
                reportError(
                    "Invalid replay seed: \(replaySeed)",
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
                return .invalid
        }
    }

    /// The report an `#examine` run returns when its replay seed is unusable: zero samples, with the failure already reported as an issue.
    static func emptyExamineReport() -> ExamineReport {
        ExamineReport(
            sampleCount: 0,
            valuesGenerated: 0,
            reflectionRoundTripSuccesses: 0,
            replayDeterminismSuccesses: nil,
            uniqueChoiceSequences: 0,
            reflectionSkipped: false,
            pinnedFieldCount: 0,
            failures: [],
            generationTime: 0,
            elapsedTime: 0,
            filterObservations: [:],
            numericCoverage: [],
            branchCoverage: 1.0,
            sequenceLengthDeciles: 10,
            hasSequences: false,
            sequenceLengthMin: 0,
            sequenceLengthMax: 0,
            sequenceLengthMean: 0,
            characterCoverage: [],
            complexityDeciles: 10,
            representativeTree: nil
        )
    }
}
