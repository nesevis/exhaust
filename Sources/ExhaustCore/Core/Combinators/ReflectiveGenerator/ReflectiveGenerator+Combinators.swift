//
//  ReflectiveGenerator+Combinators.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/5/2026.
//

public extension ReflectiveGenerator {
    /// Adapts a generator to a new output type while preserving reflection support.
    ///
    /// Use this when the transform involves computation that ``#gen`` cannot invert automatically: arithmetic, conditional logic, lossy conversions. For struct or class initializers with labeled arguments, prefer ``#gen`` with a trailing closure — the macro synthesizes the inverse via `Mirror`.
    ///
    /// ```swift
    /// let celsiusGen = #gen(.double(in: -40...100)).mapped(
    ///     forward: { $0 * 9 / 5 + 32 },
    ///     backward: { ($0 - 32) * 5 / 9 }
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - forward: Function to transform generated values.
    ///   - backward: Function to transform reflection targets back to the original type.
    /// - Returns: A generator producing values of the new output type.
    /// - Throws: Rethrows errors from the transformation functions.
    func mapped<NewOutput>(
        forward: @Sendable @escaping (Output) throws -> NewOutput,
        backward: @Sendable @escaping (NewOutput) throws -> Output
    ) rethrows -> ReflectiveGenerator<NewOutput> {
        try Gen.contramap(backward, gen.map(forward)).wrapped
    }

    /// Adapts a generator to a new output type, using a key path as the inverse for reflection.
    ///
    /// Use this when the backward direction is a simple property extraction rather than an arbitrary closure.
    ///
    /// - Parameters:
    ///   - forward: Function to transform generated values.
    ///   - backward: Key path to extract the original value from the new type.
    /// - Returns: A generator producing values of the new output type.
    /// - Throws: Rethrows errors from the forward transformation.
    func mapped<NewOutput>(
        forward: @Sendable @escaping (Output) throws -> NewOutput,
        backward: KeyPath<NewOutput, Output>
    ) rethrows -> ReflectiveGenerator<NewOutput> {
        nonisolated(unsafe) let backward = backward
        return try mapped(forward: forward, backward: { $0[keyPath: backward] })
    }

    /// Chains this generator with a dependent generator, with a backward extraction function for reflection.
    ///
    /// This is the bind-level analogue of ``mapped(forward:backward:)``. The `forward` function takes the inner value and returns a dependent generator. The `backward` function extracts the inner value from the final output, enabling reflection to decompose through the bind.
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
        forward: @Sendable @escaping (Output) throws -> ReflectiveGenerator<NewValue>,
        backward: @Sendable @escaping (NewValue) throws -> Output,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) rethrows -> ReflectiveGenerator<NewValue> {
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
        )).wrapped
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
        forward: @Sendable @escaping (Output) throws -> ReflectiveGenerator<NewValue>,
        backward: KeyPath<NewValue, Output>,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) rethrows -> ReflectiveGenerator<NewValue> {
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
        )).wrapped
    }
}
