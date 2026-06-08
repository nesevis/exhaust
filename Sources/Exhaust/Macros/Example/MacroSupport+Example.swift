//
//  MacroSupport+Example.swift
//  Exhaust
//
//  Created by Chris Kolbu on 9/6/2026.
//

import IssueReporting

public extension __ExhaustRuntime {
    /// Generates a single value from a generator. Runtime target of `#example` expansion.
    static func __example<Output>(
        _ refGen: ReflectiveGenerator<Output>,
        seed: UInt64?,
        fileID _: StaticString = #fileID,
        filePath _: StaticString = #filePath,
        line _: UInt = #line,
        column _: UInt = #column
    ) throws -> Output {
        let gen = refGen.gen
        var interpreter = ValueInterpreter(gen, seed: seed, maxRuns: 1, sizeOverride: 50)
        guard let value = try interpreter.next() else {
            throw GeneratorError.sparseValidityCondition
        }
        return value
    }

    /// Generates an array of values from a generator. Runtime target of `#example` expansion.
    static func __exampleArray<Output>(
        _ refGen: ReflectiveGenerator<Output>,
        count: UInt64,
        seed: UInt64?,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) throws -> [Output] {
        let gen = refGen.gen
        var interpreter = ValueInterpreter(gen, seed: seed, maxRuns: count)
        var results: [Output] = []
        while let value = try interpreter.next() {
            results.append(value)
        }
        if results.count < count {
            reportIssue(
                "#example: generator produced \(results.count) of \(count) requested values. If the generator uses a sparse filter, consider restructuring it to produce valid values directly.",
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
        }
        return results
    }
}
