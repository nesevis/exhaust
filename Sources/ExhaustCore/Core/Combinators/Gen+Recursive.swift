// Combinator for recursive generator definitions.
// Enables declarative recursive data type generation with explicit depth control.

public extension Gen {
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
    ///   - base: The ground value used when recursion bottoms out
    ///   - maxDepth: Maximum number of recursive layers to unfold
    ///   - extend: Closure that builds one recursive layer from the previous layer
    /// - Returns: A generator that produces recursive values with depth-controlled structure
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
    /// Use this overload when the base case itself needs randomness (e.g. random leaf values).
    ///
    /// The generator is eagerly unfolded at construction time into a plain generator tree — no special runtime operation exists. This means recursive generators are fully transparent to all interpreters (generation, reflection, replay, CGS tuning).
    ///
    /// - Parameters:
    ///   - base: Generator for the base case
    ///   - maxDepth: Maximum number of recursive layers to unfold
    ///   - extend: Closure that builds one recursive layer from the previous layer
    /// - Returns: A generator that produces recursive values with depth-controlled structure
    static func recursive<Output>(
        base: ReflectiveGenerator<Output>,
        depthRange: ClosedRange<UInt64>,
        extend: @escaping (
            @escaping () -> ReflectiveGenerator<Output>,
            UInt64
        ) -> ReflectiveGenerator<Output>
    ) -> ReflectiveGenerator<Output> {
        // Build layers inside-out: the first extend call uses remaining=1
        // (innermost layer), and the last uses remaining=maxDepth (outermost).
        //
        // Per-layer siteID disambiguation is handled at interpretation time by
        // VACTI and ReductionMaterializer, which augment siteIDs with pickDepth.
        // No generator-level rewriting is needed.
        Gen.choose(in: depthRange, scaling: .constant)._bound(
            forward: { generatorDepth in
                guard generatorDepth > 0 else { return base }
                var current: ReflectiveGenerator<Output> = base
                var layer = generatorDepth
                while layer > 0 {
                    let prev = current
                    current = extend({ prev }, layer)
                    layer -= 1
                }
                return current
            },
            backward: { _ in depthRange.upperBound }
        )
    }
}
