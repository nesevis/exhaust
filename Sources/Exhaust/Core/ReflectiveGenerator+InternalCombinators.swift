//
//  Generator+InternalCombinators.swift
//  Exhaust
//
//  Created by Chris Kolbu on 8/3/2026.
//

import ExhaustCore

extension Generator where Operation == ReflectiveOperation {
    /// Creates a bidirectional transformation of this generator using forward and backward functions.
    /// Note that ``#gen`` with a closure will attempt to synthesize the backward mapping during macro expansion.
    ///
    /// Preserves bidirectional support across type changes, unlike the forward-only ``map`` which loses reflection. Both directions must be provided:
    ///
    /// - **Forward**: Transforms generated values to the new output type
    /// - **Backward**: During reflection, transforms target values back to the original type
    ///
    /// - Parameters:
    ///   - forward: Function to transform generated values.
    ///   - backward: Function to transform reflection targets back to original type.
    /// - Returns: A generator producing values of the new output type.
    /// - Throws: Rethrows errors from the transformation functions.
    func _mapped<NewOutput>(
        forward: @escaping (Value) throws -> NewOutput,
        backward: @escaping (NewOutput) throws -> Value
    ) rethrows -> Generator<NewOutput> {
        try Gen.contramap(backward, _map(forward))
    }
}
