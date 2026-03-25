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
        maxDepth: UInt64,
        extend: @escaping (
            @escaping () -> ReflectiveGenerator<Output>,
            UInt64
        ) -> ReflectiveGenerator<Output>
    ) -> ReflectiveGenerator<Output> {
        recursive(base: Gen.just(base), maxDepth: maxDepth, extend: extend)
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
        maxDepth: UInt64,
        extend: @escaping (
            @escaping () -> ReflectiveGenerator<Output>,
            UInt64
        ) -> ReflectiveGenerator<Output>
    ) -> ReflectiveGenerator<Output> {
        // Generate a base siteID at construction time. Each unfolded layer gets
        // a deterministic siteID (baseSiteID &+ remaining) so CGS can tune
        // each layer independently while remaining stable across unfolds.
        var prng = Xoshiro256()
        let baseSiteID = prng.next()

        // Build layers inside-out: the first extend call uses remaining=1
        // (innermost layer), and the last uses remaining=maxDepth (outermost).
        guard maxDepth > 0 else { return base }

        var current: ReflectiveGenerator<Output> = base
        for layer in 1 ... maxDepth {
            let prev = current
            let built = extend({ prev }, layer)
            current = replaceTopLevelPickSiteID(built, with: baseSiteID &+ layer)
        }
        return current
    }
}

/// Replaces the siteID of the top-level pick operation in a generator, if present.
/// Used by `Gen.recursive` to give each layer a deterministic siteID for CGS tuning.
private func replaceTopLevelPickSiteID<Output>(
    _ gen: ReflectiveGenerator<Output>,
    with siteID: UInt64
) -> ReflectiveGenerator<Output> {
    guard case let .impure(operation, continuation) = gen,
          case let .pick(choices) = operation
    else { return gen }

    let replaced = ContiguousArray(choices.map { choice in
        ReflectiveOperation.PickTuple(
            siteID: siteID,
            id: choice.id,
            weight: choice.weight,
            generator: choice.generator
        )
    })
    return .impure(operation: .pick(choices: replaced), continuation: continuation)
}
