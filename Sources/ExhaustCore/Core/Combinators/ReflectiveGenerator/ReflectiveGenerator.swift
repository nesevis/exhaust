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

    /// Whether every transform in this generator preserves reflection — no forward-only ``map(_:)`` or ``bind(_:fileID:line:column:)`` sits between the choices and the output, and no factory discards information reflection would need to recover the choices (set and dictionary construction, shuffling, unfold's internal binds).
    ///
    /// Carried at composition rather than recomputed: the ``FreerMonad`` spine hides its tail behind continuations, so it cannot be folded after the fact. Each combinator states its claim through ``FreerMonad/wrapped(isReflective:)``, ANDing the flags of the generators it combines — a forward-only transform or an information-discarding factory contributes `false` and the flag is monotone, never recovering. A `true` reading is a promise that ``Interpreters/reflect(_:with:where:)`` can decompose a value through this generator; a `false` reading means it cannot, so callers such as comparison-operand injection can skip the attempt. Over-claiming is safe: reflection still returns nil on a value it cannot decompose, so the flag is an optimization, not a correctness gate. Combinators whose layers are produced by closures at generation time (``recursive(base:depthRange:extend:)``, ``getSize(_:)``) cannot inspect those layers at construction and over-claim deliberately.
    package let isReflective: Bool

    /// Wraps an already-constructed generator.
    ///
    /// `isReflective` has no default so every construction site states whether reflection can decompose values through the wrapped generator; a silent default here is how an over-claim slips into a whole family of factories.
    package init(_ gen: Generator<Output>, isSynthesized: Bool = false, isReflective: Bool) {
        self.gen = gen
        self.isSynthesized = isSynthesized
        self.isReflective = isReflective
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
        )).wrapped(isReflective: false)
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
        )).wrapped(isReflective: false)
    }
}

// MARK: - Generator → ReflectiveGenerator

package extension FreerMonad where Operation == ReflectiveOperation {
    /// Wraps this generator in a ``ReflectiveGenerator``, carrying the composed reflection status.
    ///
    /// The parameter has no default so every combinator states its claim explicitly. Leaf generators and framework-authored exact inverse pairs pass `true`; a combinator over ``ReflectiveGenerator`` inputs passes the AND of their flags plus whether the operation it introduces preserves reflection; a forward-only ``ReflectiveGenerator/map(_:)`` or ``ReflectiveGenerator/bind(_:fileID:line:column:)``, and any factory whose construction discards information reflection would need, passes `false`.
    func wrapped(isReflective: Bool) -> ReflectiveGenerator<Value> {
        ReflectiveGenerator(self, isReflective: isReflective)
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
