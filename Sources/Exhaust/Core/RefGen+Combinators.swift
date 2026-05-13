//
//  RefGen+Combinators.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/5/2026.
//

public extension RefGen {
    /// Transforms the output type with a provided inverse for reflection.
    ///
    /// Use this when the transform involves computation that ``#gen`` cannot invert: arithmetic, conditional logic, lossy conversions. For struct or class initializers with labeled arguments, prefer ``#gen`` with a trailing closure; the macro synthesizes the inverse via `Mirror`.
    ///
    /// - Parameters:
    ///   - forward: Function to transform generated values.
    ///   - backward: Function to transform reflection targets back to original type.
    /// - Returns: A generator producing values of the new output type.
    /// - Throws: Rethrows errors from the transformation functions.
    func mapped<NewOutput>(
        forward: @Sendable @escaping (Output) throws -> NewOutput,
        backward: @Sendable @escaping (NewOutput) throws -> Output
    ) rethrows -> RefGen<NewOutput> {
        RefGen<NewOutput> {
            Gen.contramap(
                backward,
                Gen.liftF(.transform(
                    kind: .map(
                        forward: { try forward($0 as! Output) },
                        inputType: Output.self,
                        outputType: NewOutput.self
                    ),
                    inner: gen.erase()
                ))
            )
        }
    }

    /// Creates a bidirectional transformation using a forward function and a key path for backward.
    ///
    /// Transforms the output type while providing a key path as the inverse for reflection.
    ///
    /// Use this when the backward direction can be expressed as a property extraction rather than an arbitrary closure.
    ///
    /// - Parameters:
    ///   - forward: Function to transform generated values.
    ///   - backward: Key path to extract the original value from the new type.
    /// - Returns: A generator producing values of the new output type.
    /// - Throws: Rethrows errors from the forward transformation.
    func mapped<NewOutput>(
        forward: @Sendable @escaping (Output) throws -> NewOutput,
        backward: KeyPath<NewOutput, Output>
    ) rethrows -> RefGen<NewOutput> {
        nonisolated(unsafe) let backward = backward
        return try mapped(forward: forward, backward: { $0[keyPath: backward] })
    }
    
    /// Chains this generator with a dependent generator, with a backward extraction function for reflection.
    ///
    /// This is the bind-level analogue of ``mapped(forward:backward:)``. The `backward` function extracts the inner generator's input from the final output, enabling reflection (and therefore reduction) through the bind.
    ///
    /// - Forward: Takes the inner value and returns a dependent generator.
    /// - Backward: Extracts the inner value from the final output, enabling reflection to decompose through the bind.
    ///
    /// ```swift
    /// let sized = #gen(.int(in: 1...10)).bound(
    ///     forward: { n in .string(length: n) },
    ///     backward: { str in str.count }
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - forward: Function that takes the generated value and returns a new generator.
    ///   - backward: Function that extracts the inner value from the final output.
    /// - Returns: A generator that sequences the two computations with bidirectional support.
    func bound<NewValue>(
        forward: @Sendable @escaping (Output) throws -> RefGen<NewValue>,
        backward: @Sendable @escaping (NewValue) throws -> Output,
        fileID: String = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) rethrows -> RefGen<NewValue> {
        RefGen<NewValue> {
            let fingerprint = Gen.sourceFingerprint(fileID: fileID, line: line, column: column)
            return Gen.liftF(.transform(
                kind: .bind(
                    fingerprint: fingerprint,
                    forward: { try forward($0 as! Output).gen.erase() },
                    backward: { try backward($0 as! NewValue) as Any },
                    inputType: Output.self,
                    outputType: NewValue.self
                ),
                inner: gen.erase()
            ))
        }
    }

    /// Chains this generator with a dependent generator, using a key path for backward extraction.
    ///
    /// Use this when the backward direction is a simple property access rather than an arbitrary closure.
    ///
    /// ```swift
    /// let gen = #gen(.int(in: 1...10)).bound(
    ///     forward: { n in .string(length: n) },
    ///     backward: \String.count
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - forward: Function that takes the generated value and returns a new generator.
    ///   - backward: Key path to extract the inner value from the final output.
    /// - Returns: A generator that sequences the two computations with bidirectional support.
    func bound<NewValue>(
        forward: @Sendable @escaping (Output) throws -> RefGen<NewValue>,
        backward: KeyPath<NewValue, Output>,
        fileID: String = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) rethrows -> RefGen<NewValue> {
        RefGen<NewValue> {
            let fingerprint = Gen.sourceFingerprint(fileID: fileID, line: line, column: column)
            return Gen.liftF(.transform(
                kind: .bind(
                    fingerprint: fingerprint,
                    forward: { try forward($0 as! Output).gen.erase() },
                    backward: { ($0 as! NewValue)[keyPath: backward] },
                    inputType: Output.self,
                    outputType: NewValue.self
                ),
                inner: gen.erase()
            ))
        }
    }
}
