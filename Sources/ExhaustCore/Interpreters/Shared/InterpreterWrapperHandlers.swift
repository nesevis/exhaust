//
//  InterpreterWrapperHandlers.swift
//  Exhaust
//
//  Created by Codex on 21/2/2026.
//

/// Provides shared handler logic for operations that wrap an inner generator (contramap, prune, resize, classify, transform) across both VACTI and VI interpreters.
package enum InterpreterWrapperHandlers {
    /// Runs a subgenerator and feeds its result into a continuation, short-circuiting with `nil` if the subgenerator produces no value.
    @inline(__always)
    public static func continueAfterSubgenerator<SubResult, Output>(
        runSubgenerator: () throws -> SubResult?,
        runContinuation: (SubResult) throws -> Output?
    ) throws -> Output? {
        guard let subResult = try runSubgenerator() else {
            return nil
        }
        return try runContinuation(subResult)
    }

    /// Unwraps the optional layer added by a prune operation, returning `nil` when the input is `Optional.none` so the pruned branch is skipped.
    @inline(__always)
    public static func unwrapPruneInput(_ inputValue: some Any) -> Any? {
        guard let optional = .some(inputValue as Any?), let wrappedValue = optional else {
            return nil
        }
        return wrappedValue
    }
}
