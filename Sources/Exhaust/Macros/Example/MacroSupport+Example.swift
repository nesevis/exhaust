//
//  MacroSupport+Example.swift
//  Exhaust
//
//  Created by Chris Kolbu on 9/6/2026.
//

import IssueReporting

public extension __ExhaustRuntime {
    /// Generates a single value from a generator. Runtime target of `#example` expansion.
    ///
    /// Runs the same interpreter the `#exhaust` sampling phase uses, so a seed with an iteration suffix (for example `"5QF8M2-3"`) reproduces exactly the value that run generated. A plain numeric seed or no seed generates one value at size 50.
    static func __example<Output>(
        _ refGen: ReflectiveGenerator<Output>,
        seed: ReplaySeed?,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) throws -> Output {
        let gen = refGen.gen
        let resolved = try resolveExampleSeed(seed, fileID: fileID, filePath: filePath, line: line, column: column)

        var interpreter: ValueAndChoiceTreeInterpreter<Output>
        if let iteration = resolved.iteration {
            // Match the sampling pipeline: same run index, same per-run PRNG derivation, same size ramp.
            interpreter = ValueAndChoiceTreeInterpreter(
                gen,
                materializePicks: false,
                seed: resolved.seed,
                maxRuns: UInt64(iteration),
                initialRunIndex: UInt64(iteration - 1)
            )
        } else {
            interpreter = ValueAndChoiceTreeInterpreter(
                gen,
                materializePicks: false,
                seed: resolved.seed,
                maxRuns: 1,
                sizeOverride: 50
            )
        }
        guard let value = try interpreter.nextValueOnly() else {
            throw GeneratorError.sparseValidityCondition
        }
        return value
    }

    /// Generates an array of values from a generator. Runtime target of `#example` expansion.
    ///
    /// Runs the same interpreter the `#exhaust` sampling phase uses, so with the same seed the produced values match that phase's values one for one. A seed with an iteration suffix starts at that iteration instead of the first.
    static func __exampleArray<Output>(
        _ refGen: ReflectiveGenerator<Output>,
        count: Int,
        seed: ReplaySeed?,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) throws -> [Output] {
        guard count >= 0 else {
            reportError("#example count must be non-negative; got \(count)", fileID: fileID, filePath: filePath, line: line, column: column)
            throw GeneratorError.invalidExampleCount(count)
        }
        let gen = refGen.gen
        let resolved = try resolveExampleSeed(seed, fileID: fileID, filePath: filePath, line: line, column: column)
        let startIndex = UInt64((resolved.iteration ?? 1) - 1)

        var interpreter = ValueAndChoiceTreeInterpreter(
            gen,
            materializePicks: false,
            seed: resolved.seed,
            maxRuns: startIndex + UInt64(count),
            initialRunIndex: startIndex
        )
        var results: [Output] = []
        while let value = try interpreter.nextValueOnly() {
            results.append(value)
        }
        if results.count < count {
            reportError(
                "#example: generator produced \(results.count) of \(count) requested values. If the generator uses a sparse filter, consider restructuring it to produce valid values directly.",
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
        }
        return results
    }

    /// Resolves a `#example` seed to a numeric seed and optional 1-based iteration, rejecting seed kinds `#example` cannot honor.
    private static func resolveExampleSeed(
        _ seed: ReplaySeed?,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) throws -> (seed: UInt64?, iteration: Int?) {
        guard let seed else {
            return (nil, nil)
        }
        guard let resolved = seed.resolve() else {
            reportError("Invalid replay seed: \(seed)", fileID: fileID, filePath: filePath, line: line, column: column)
            throw GeneratorError.invalidReplaySeed("\(seed)")
        }
        switch resolved {
            case let .screening(row):
                reportError(
                    "Screening replay seeds (U-prefixed) cannot be replayed by #example, which has no covering array. Use #exhaust(gen, .replay(...)) instead.",
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
                throw GeneratorError.invalidReplaySeed("screening row \(row) is not replayable by #example")
            case let .sampling(numericSeed, iteration):
                if let iteration, iteration < 1 {
                    reportError("Invalid replay seed iteration: \(iteration)", fileID: fileID, filePath: filePath, line: line, column: column)
                    throw GeneratorError.invalidReplaySeed("iteration \(iteration) is not a valid 1-based index")
                }
                return (numericSeed, iteration)
        }
    }
}
