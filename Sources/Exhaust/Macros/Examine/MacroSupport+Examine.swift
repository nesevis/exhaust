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

        var seed: UInt64?
        if let replaySeed = config.replaySeed {
            guard let resolved = replaySeed.resolve() else {
                reportIssue(
                    "Invalid replay seed: \(replaySeed)",
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
                return ExamineReport(
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
            seed = resolved.seed
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

        var seed: UInt64?
        if let replaySeed = config.replaySeed {
            guard let resolved = replaySeed.resolve() else {
                reportIssue(
                    "Invalid replay seed: \(replaySeed)",
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
                return ExamineReport(
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
            seed = resolved.seed
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
