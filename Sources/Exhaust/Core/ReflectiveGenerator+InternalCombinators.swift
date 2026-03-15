//
//  ReflectiveGenerator+InternalCombinators.swift
//  Exhaust
//
//  Created by Chris Kolbu on 8/3/2026.
//

import ExhaustCore

extension ReflectiveGenerator where Operation == ReflectiveOperation {
    /// Creates a bidirectional transformation of this generator using forward and backward functions.
    /// Note that ``#gen`` with a closure will attempt to synthesize the backward mapping during macro expansion.
    ///
    /// This is the fundamental operation for adapting generators to work with different types while preserving the bidirectional capability. Both directions must be provided:
    ///
    /// - **Forward**: Transforms generated values to the new output type
    /// - **Backward**: During reflection, transforms target values back to the original type
    ///
    /// - Parameters:
    ///   - forward: Function to transform generated values
    ///   - backward: Function to transform reflection targets back to original type
    /// - Returns: A generator producing values of the new output type
    /// - Throws: Rethrows errors from the transformation functions
    @inlinable
    func _mapped<NewOutput>(
        forward: @escaping (Value) throws -> NewOutput,
        backward: @escaping (NewOutput) throws -> Value,
    ) rethrows -> ReflectiveGenerator<NewOutput> {
        try Gen.contramap(backward, _map(forward))
    }

    /// Internal version of ``bound(forward:backward:)`` without `@Sendable` requirements.
    @inlinable
    func _bound<NewValue>(
        forward: @escaping (Value) throws -> ReflectiveGenerator<NewValue>,
        backward: @escaping (NewValue) throws -> Value,
    ) rethrows -> ReflectiveGenerator<NewValue> {
        Gen.liftF(.transform(
            kind: .bind(
                forward: { try forward($0 as! Value).erase() },
                backward: { try backward($0 as! NewValue) as Any },
                inputType: String(describing: Value.self),
                outputType: String(describing: NewValue.self),
            ),
            inner: erase(),
        ))
    }
}
