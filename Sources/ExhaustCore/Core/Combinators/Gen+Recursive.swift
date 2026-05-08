// Combinator for recursive generator definitions.
// Enables declarative recursive data type generation with explicit depth control.

package extension Gen {
    /// Creates a recursive generator with a constant base case value.
    ///
    /// The `extend` closure receives two arguments:
    /// - `recurse`: A thunk that returns a generator for "recurse here" positions
    /// - `remaining`: Depth budget, counting down from `maxDepth` (outermost) to 1 (innermost)
    ///
    /// To terminate early, return a generator that doesn't call `recurse()`. This short-circuits the recursion — inner layers are never reached since `recurse()` is the only way to reference them:
    ///
    /// ```swift
    /// Gen.recursive(base: .leaf, maxDepth: 5) { recurse, remaining in
    ///     guard remaining > 1 else { return .just(.leaf) }
    ///     Gen.pick(choices: [
    ///         (1, .just(.leaf)),
    ///         (Int(remaining), Gen.zip(recurse(), Gen.choose(in: 0...9), recurse()).map { .node($0, $1, $2) })
    ///     ])
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - base: The ground value used when recursion bottoms out.
    ///   - depthRange: The range of recursive layers to unfold.
    ///   - extend: Closure that builds one recursive layer from the previous layer.
    /// - Returns: A generator that produces recursive values with depth-controlled structure.
    static func recursive<Output>(
        base: Output,
        depthRange: ClosedRange<Int>,
        extend: @escaping (
            @escaping () -> ReflectiveGenerator<Output>,
            UInt64
        ) -> ReflectiveGenerator<Output>
    ) -> ReflectiveGenerator<Output> {
        precondition(depthRange.lowerBound >= 0, "lower bound must be >= 0")
        return recursive(base: Gen.just(base), depthRange: UInt64(depthRange.lowerBound) ... UInt64(depthRange.upperBound), extend: extend)
    }

    /// Creates a recursive generator with a generator base case.
    ///
    /// Use this overload when the base case itself needs randomness (for example random leaf values).
    ///
    /// The generator is eagerly unfolded at construction time into a plain generator tree — no special runtime operation exists. This means recursive generators are fully transparent to all interpreters (generation, reflection, replay, CGS tuning).
    ///
    /// - Parameters:
    ///   - base: Generator for the base case.
    ///   - depthRange: The range of recursive layers to unfold.
    ///   - extend: Closure that builds one recursive layer from the previous layer.
    /// - Returns: A generator that produces recursive values with depth-controlled structure.
    static func recursive<Output>(
        base: ReflectiveGenerator<Output>,
        depthRange: ClosedRange<UInt64>,
        extend: @escaping (@escaping () -> ReflectiveGenerator<Output>, UInt64) -> ReflectiveGenerator<Output>
    ) -> ReflectiveGenerator<Output> {
        // Build all layers eagerly. Layer 0 = base, layer N = extend applied N times.
        var layers: [ReflectiveGenerator<Output>] = [base]
        for layer in 0 ... depthRange.upperBound {
            let availableLayers = layers // capture current set
            // recurse() draws its OWN depth independently
            let recurseGen = chooseDepth(in: 0 ... UInt64(layer))
                ._bound(
                    forward: { depth in availableLayers[Int(depth)] },
                    backward: { _ in UInt64(layer) }
                )
            layers.append(extend({ recurseGen }, UInt64(layer + 1)))
        }

        // Outer depth draw selects the root layer
        return chooseDepth(in: depthRange)
            ._bound(
                forward: { depth in layers[Int(depth)] },
                backward: { _ in depthRange.upperBound }
            )
    }

    /// Generates a depth index tagged with ``TypeTag/depthControl``. Excluded from value search during reduction — structural operations handle depth reduction while preserving structural context.
    private static func chooseDepth(in range: ClosedRange<UInt64>) -> ReflectiveGenerator<UInt64> {
        let operation = ReflectiveOperation.chooseBits(
            min: range.lowerBound,
            max: range.upperBound,
            tag: .depthControl,
            isRangeExplicit: true
        )
        return .impure(operation: operation) { result in
            guard let convertible = result as? any BitPatternConvertible else {
                throw GeneratorError.typeMismatch(
                    expected: "any BitPatternConvertible",
                    actual: String(describing: Swift.type(of: result))
                )
            }
            return .pure(UInt64(bitPattern64: convertible.bitPattern64))
        }
    }
}
