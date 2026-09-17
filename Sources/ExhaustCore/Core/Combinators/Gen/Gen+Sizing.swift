// Operations for controlling and accessing the size parameter in generators.
// The size parameter is used to control the complexity and scale of generated values.

package extension Gen {
    /// Retrieves the raw size parameter without a backward comap.
    ///
    /// Use this for framework internals that need the true interpreter size. User-facing code should use ``getSize(_:)`` instead, which reifies the size for reduction. Reflection uses an enclosing ``resize(_:_:)`` value when present and otherwise defaults to 100.
    static func rawGetSize() -> Generator<UInt64> {
        .impure(operation: .getSize) { result in
            if let typedResult = result as? UInt64 {
                return .pure(typedResult)
            }
            throw GeneratorError.typeMismatch(
                expected: "\(UInt64.self)",
                actual: String(describing: type(of: result))
            )
        }
    }

    /// Retrieves the current size parameter and feeds it into a generator-producing closure.
    ///
    /// The size parameter (1-100) controls generated-value complexity. It starts small and grows as tests progress, so simple counterexamples are found first. The closure receives the current size and returns a generator to run. Reflection uses the innermost enclosing ``resize(_:_:)`` value, or 100 when no explicit resize is present.
    ///
    /// - Parameter forward: A closure that receives the current size and returns a generator.
    /// - Returns: A generator that produces the result of the size-dependent inner generator.
    static func getSize<Output>(
        _ forward: @escaping (UInt64) -> Generator<Output>
    ) -> Generator<Output> {
        rawGetSize()._bound(forward: forward, backward: { _ in 100 })
    }

    /// The declared range of a reducible size choice. Generation pins the value to the current size; the reducer may lower it anywhere in this range.
    static let reducibleSizeRange: ClosedRange<UInt64> = 1 ... 100

    /// Draws the current size as a reducible choice and feeds it into a generator-producing closure.
    ///
    /// Unlike ``getSize(_:)``, whose ``ReflectiveOperation/getSize`` leaf contributes no choice-sequence entry and whose bind the ``ChoiceGraphBuilder`` treats as transparent, this form emits a `chooseBits` pinned to the size (``ChooseBitsScaling/size``) under a reified bind. The size therefore appears in the ``ChoiceSequence`` with ``reducibleSizeRange`` as its valid range, so value encoders and bound-value search can lower it during reduction. The materializer resolves it like any other choice: the declared range admits every proposal, and `.generate` mode pins to the active size exactly as a raw read would.
    ///
    /// The pinned draw consumes no PRNG output and the choice is invisible to screening, so replay seeds and screening rows match the non-reified form. Dependent generators are built once per distinct size through ``BuiltGeneratorTable``.
    ///
    /// - Parameters:
    ///   - fingerprint: The bind's source fingerprint, so distinct call sites classify separately in the ``ChoiceGraph``.
    ///   - forward: A pure closure that receives the current size and returns a generator.
    /// - Returns: A generator that produces the result of the size-dependent inner generator.
    static func reducibleGetSize<Output>(
        fingerprint: UInt64,
        _ forward: @escaping (UInt64) -> Generator<Output>
    ) -> Generator<Output> {
        let built = BuiltGeneratorTable<UInt64>()
        let sizeChoice: Generator<UInt64> = choose(
            in: reducibleSizeRange,
            type: UInt64.self,
            isRangeExplicit: true,
            scaling: .size
        )
        return Gen.liftF(.transform(
            kind: .bind(
                fingerprint: fingerprint,
                forward: { input in
                    let size = input as! UInt64
                    return built.generator(for: size) { forward(size).erase() }
                },
                backward: { _ in reducibleSizeRange.upperBound as Any },
                inputType: UInt64.self,
                outputType: Output.self
            ),
            inner: sizeChoice.erase()
        ))
    }

    /// Retrieves the current size parameter without reifying the dependent bind.
    ///
    /// Use this on internal hot paths whose structural operations already expose the dependency, such as size-dependent sequence lengths. Reflection uses an enclosing ``resize(_:_:)`` value when present and otherwise supplies size 100, allowing the downstream generator to expose its full range without adding a ``ReflectiveOperation/transform(kind:inner:)`` bind node.
    ///
    /// - Parameter forward: A closure that receives the current size and returns a generator.
    /// - Returns: A generator that produces the result of the size-dependent inner generator.
    static func nonReifiedGetSize<Output>(
        _ forward: @escaping (UInt64) -> Generator<Output>
    ) -> Generator<Output> {
        Gen.contramap(
            { (_: Output) in UInt64(100) },
            rawGetSize()
        ).bind(forward)
    }

    /// Overrides the size parameter for a nested generator scope.
    ///
    /// Use this to cap complexity of nested generators — for example, forcing small collections inside a larger structure, or limiting recursive depth independently of the outer test's size progression. The override is lexically scoped: any ``getSize(_:)`` or ``chooseBits`` with scaling inside `generator` sees `newSize`, but the enclosing generator's size is restored after `generator` completes.
    ///
    /// - Parameters:
    ///   - newSize: The size parameter to use for the nested generator.
    ///   - generator: The generator to run with the modified size.
    /// - Returns: A generator that runs with the specified size parameter.
    static func resize<Output>(
        _ newSize: UInt64,
        _ generator: Generator<Output>
    ) -> Generator<Output> {
        liftF(.resize(newSize: newSize, next: generator.erase()))
    }
}

package extension FreerMonad where Operation == ReflectiveOperation, Value == UInt64 {
    /// Returns the continuation following an interpretation-time size read.
    ///
    /// Recognizes both a bare ``ReflectiveOperation/getSize`` and the contramap-wrapped form produced by ``Gen/nonReifiedGetSize(_:)``. Passing a size to the returned continuation produces the dependent generator without interpreting or reifying a bind.
    var getSizeContinuation: ((Any) throws -> AnyGenerator)? {
        switch self {
            case let .impure(.getSize, continuation):
                continuation
            case let .impure(.contramap(_, innerGenerator), continuation):
                if case .impure(.getSize, _) = innerGenerator {
                    continuation
                } else {
                    nil
                }
            case .pure, .impure:
                nil
        }
    }
}
