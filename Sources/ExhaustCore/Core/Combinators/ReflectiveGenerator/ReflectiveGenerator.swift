/// Produces arbitrary values for property-based testing.
///
/// Construct generators with the `#gen` macro and static factory methods (`.int()`, `.string()`, `.bool()`, and so on), then combine them with `.array()`, `.filter()`, `.map()`, and pass the result to `#exhaust`. Prefer `#gen(.int(…))` over spelling out `ReflectiveGenerator.int(…)`. The type name is needed only for annotations and `.recursive`/`.unfold` roots.
///
/// ```swift
/// let gen = #gen(
///     .int(in: 0...100)
///         .array(length: 1...10)
///         .filter { $0.contains(where: { $0 > 50 }) }
/// )
///
/// #exhaust(gen) { array in
///     array.sorted() == array // finds unsorted arrays
/// }
/// ```
///
/// When a property fails, Exhaust automatically reduces the counterexample to a minimal failing case.
///
/// Reflection lets `#exhaust(…, reflecting:)` start from a concrete value and recover the generator choices needed to reduce it. Bidirectional transforms such as ``mapped(forward:backward:)`` and ``bound(forward:backward:)`` preserve that capability.
///
/// The ``ReflectiveGenerator`` type does not itself guarantee reflection support. Forward-only transforms such as ``map(_:)`` and ``bind(_:fileID:line:column:)``, along with factory methods that document a lossy conversion, cannot decompose a value passed to `#exhaust(…, reflecting:)`. Exhaust can still generate values through them, replay those values from recorded choices, and reduce generated counterexamples.
///
/// - Note: `@unchecked Sendable` is safe because the underlying indirect enum stores only `@Sendable` closures and `Sendable` value types. The compiler cannot verify sendability through the indirection automatically.
public struct ReflectiveGenerator<Output>: @unchecked Sendable {
    package let gen: Generator<Output>

    /// Whether this generator was synthesized from a `Decodable` type via ``GeneratorSynthesizer``.
    ///
    /// Generators synthesized from JSON example data may contain `.just` nodes for fields where the ``GeneratorSynthesizer`` could not build a full generator (for example, non-`CaseIterable` enums). These fields are pinned to the constant value from the example JSON. Diagnostic tools can check this flag to distinguish synthesized generators from hand-written ones.
    public let isSynthesized: Bool

    /// Wraps an already-constructed generator.
    package init(_ gen: Generator<Output>, isSynthesized: Bool = false) {
        self.gen = gen
        self.isSynthesized = isSynthesized
    }

    /// Chains this generator with a dependent generator whose structure depends on the produced value.
    ///
    /// Use `.bind` when the next generator genuinely depends on the value from this one, such as generating an array whose length is determined by a previously generated integer. When generators are independent, prefer `#gen(a, b) { … }` because they compose without introducing a dependency edge in the choice graph.
    ///
    /// This transform is forward-only. Exhaust still replays and reduces generated counterexamples from recorded choices, but `#exhaust(…, reflecting:)` cannot cross the dependency. Use ``bound(forward:backward:)`` when the final output can recover the value that selected the dependent generator.
    ///
    /// - Parameter transform: A function that takes the generated value and returns a new generator.
    /// - Returns: A generator that sequences the two computations.
    public func bind<NewOutput>(
        _ transform: @Sendable @escaping (Output) throws -> ReflectiveGenerator<NewOutput>,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) rethrows -> ReflectiveGenerator<NewOutput> {
        let fingerprint = Gen.sourceFingerprint(fileID: fileID, line: line, column: column)
        return Gen.liftF(.transform(
            kind: .bind(
                fingerprint: fingerprint,
                forward: { try transform($0 as! Output).gen.erase() },
                backward: nil,
                inputType: Output.self,
                outputType: NewOutput.self
            ),
            inner: gen.erase()
        )).wrapped
    }

    /// Applies a forward-only transform to the generated value.
    ///
    /// Reduction is unaffected because the reducer operates on the choice sequence, not the transformed output. `#exhaust(…, reflecting:)` cannot pass through this transform. For reflection support, use ``mapped(forward:backward:)`` or ``#gen`` with a trailing closure.
    ///
    /// ```swift
    /// let lengths = #gen(.asciiString()).map { $0.count }
    /// ```
    ///
    /// - Parameter transform: A function to apply to each generated value.
    /// - Returns: A generator producing the transformed values.
    public func map<NewOutput>(
        _ transform: @Sendable @escaping (Output) throws -> NewOutput
    ) rethrows -> ReflectiveGenerator<NewOutput> {
        Gen.liftF(.transform(
            kind: .map(
                forward: { try transform($0 as! Output) },
                backward: nil,
                inputType: Output.self,
                outputType: NewOutput.self
            ),
            inner: gen.erase()
        )).wrapped
    }
}

// MARK: - Generator → ReflectiveGenerator

package extension FreerMonad where Operation == ReflectiveOperation {
    /// Wraps this generator in a ``ReflectiveGenerator``.
    var wrapped: ReflectiveGenerator<Value> {
        ReflectiveGenerator(self)
    }
}

// MARK: - CustomDebugStringConvertible

extension ReflectiveGenerator: CustomDebugStringConvertible {
    public var debugDescription: String {
        let typeName = "\(Output.self)"
        let synthesized = isSynthesized ? " (synthesized)" : ""
        return "ReflectiveGenerator<\(typeName)>\(synthesized)\n"
            + gen.treeDescription(prefix: "", isLast: true)
    }
}

extension ReflectiveGenerator: CustomStringConvertible {
    public var description: String {
        let synthesized = isSynthesized ? " (synthesized)" : ""
        return "ReflectiveGenerator<\(Output.self)>\(synthesized)"
    }
}
