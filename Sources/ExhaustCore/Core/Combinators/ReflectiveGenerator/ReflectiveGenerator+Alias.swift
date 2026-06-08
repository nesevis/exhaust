//
//  ReflectiveGenerator+Alias.swift
//  Exhaust
//

// MARK: - flatMap / flatMapped

//
// Aliases for bind / bound. Most Swift developers encounter flatMap before bind,
// so these aid discoverability without duplicating implementation.

public extension ReflectiveGenerator {
    /// Chains this generator with a dependent generator whose structure depends on the produced value.
    ///
    /// This is an alias for ``bind(_:)`` using the more familiar Swift naming convention. Use `flatMap` when the next generator genuinely depends on the value from this one — for example, generating an array whose length is determined by a previously generated integer. When generators are independent, prefer `#gen(a, b) { ... }` — they compose without introducing a dependency edge in the choice graph.
    ///
    /// - Parameter transform: A function that takes the generated value and returns a new generator.
    /// - Returns: A generator that sequences the two computations.
    func flatMap<NewOutput>(
        _ transform: @Sendable @escaping (Output) throws -> ReflectiveGenerator<NewOutput>,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) rethrows -> ReflectiveGenerator<NewOutput> {
        try bind(transform, fileID: fileID, line: line, column: column)
    }

    /// Chains this generator with a dependent generator, with a backward extraction function for reflection.
    ///
    /// This is an alias for ``bound(forward:backward:)`` using the more familiar Swift naming convention. The `forward` function takes the inner value and returns a dependent generator. The `backward` function extracts the inner value from the final output, enabling ``#examine`` to decompose a concrete value back through the dependency.
    ///
    /// ```swift
    /// let sized = #gen(.int(in: 1...10)).flatMapped(
    ///     forward: { n in .string(length: n) },
    ///     backward: { str in str.count }
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - forward: Function that takes the generated value and returns a new generator.
    ///   - backward: Function that extracts the inner value from the final output.
    /// - Returns: A generator that sequences the two computations with bidirectional support.
    func flatMapped<NewValue>(
        forward: @Sendable @escaping (Output) throws -> ReflectiveGenerator<NewValue>,
        backward: @Sendable @escaping (NewValue) throws -> Output,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) rethrows -> ReflectiveGenerator<NewValue> {
        try bound(forward: forward, backward: backward, fileID: fileID, line: line, column: column)
    }

    /// Chains this generator with a dependent generator, using a key path for backward extraction.
    ///
    /// This is an alias for ``bound(forward:backward:)`` using the more familiar Swift naming convention. Use this when the backward direction is a simple property access rather than an arbitrary closure.
    ///
    /// ```swift
    /// let gen = #gen(.int(in: 1...10)).flatMapped(
    ///     forward: { n in .string(length: n) },
    ///     backward: \String.count
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - forward: Function that takes the generated value and returns a new generator.
    ///   - backward: Key path to extract the inner value from the final output.
    /// - Returns: A generator that sequences the two computations with bidirectional support.
    func flatMapped<NewValue>(
        forward: @Sendable @escaping (Output) throws -> ReflectiveGenerator<NewValue>,
        backward: KeyPath<NewValue, Output>,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) rethrows -> ReflectiveGenerator<NewValue> {
        try bound(forward: forward, backward: backward, fileID: fileID, line: line, column: column)
    }
}
