//
//  InterpreterWrapperHandlers.swift
//  Exhaust
//
//  Created by Codex on 21/2/2026.
//

public enum InterpreterWrapperHandlers {
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

    @inline(__always)
    public static func unwrapPruneInput(_ inputValue: some Any) -> Any? {
        guard let optional = .some(inputValue as Any?), let wrappedValue = optional else {
            return nil
        }
        return wrappedValue
    }
}
