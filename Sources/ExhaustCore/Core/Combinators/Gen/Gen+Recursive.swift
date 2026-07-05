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
    /// Gen.recursive(baseValue: .leaf, depthRange: 0 ... 5) { recurse, remaining in
    ///     guard remaining > 1 else { return .just(.leaf) }
    ///     Gen.pick(choices: [
    ///         (1, .just(.leaf)),
    ///         (Int(remaining), Gen.zip(recurse(), Gen.choose(in: 0...9), recurse()).map { .node($0, $1, $2) })
    ///     ])
    /// }
    /// ```
    ///
    /// The `baseValue` label is deliberate: with a plain `base:` label and a generic `Output`, a `Generator` argument can satisfy this overload too (any value converts to `Output == Any`), silently capturing the generator itself as the base value. The distinct label makes that mistake unrepresentable.
    ///
    /// - Parameters:
    ///   - baseValue: The ground value used when recursion bottoms out.
    ///   - depthRange: The range of recursive layers to unfold.
    ///   - extend: Closure that builds one recursive layer from the previous layer.
    /// - Returns: A generator that produces recursive values with depth-controlled structure.
    static func recursive<Output>(
        baseValue: Output,
        depthRange: ClosedRange<Int>,
        extend: @escaping (
            @escaping () -> Generator<Output>,
            UInt64
        ) -> Generator<Output>
    ) -> Generator<Output> {
        precondition(depthRange.lowerBound >= 0, "lower bound must be >= 0")
        return recursive(base: Gen.just(baseValue), depthRange: UInt64(depthRange.lowerBound) ... UInt64(depthRange.upperBound), extend: extend)
    }

    /// Creates a recursive generator with a generator base case.
    ///
    /// Use this overload when the base case itself needs randomness (for example random leaf values).
    ///
    /// Eagerly unfolded at construction time into a plain generator tree, so all interpreters (generation, reflection, replay, CGS tuning) handle it without special-case logic.
    ///
    /// - Parameters:
    ///   - base: Generator for the base case.
    ///   - depthRange: The range of recursive layers to unfold.
    ///   - extend: Closure that builds one recursive layer from the previous layer.
    /// - Returns: A generator that produces recursive values with depth-controlled structure.
    static func recursive<Output>(
        base: Generator<Output>,
        depthRange: ClosedRange<UInt64>,
        extend: @escaping (@escaping () -> Generator<Output>, UInt64) -> Generator<Output>
    ) -> Generator<Output> {
        // Build all layers eagerly. Layer 0 = base, layer N = extend applied N times.
        var layers: [Generator<Output>] = [base]
        for layer in 0 ..< depthRange.upperBound {
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

    // MARK: - Unfold

    /// Generates values by iteratively transforming state from a seed, with reducible iteration depth.
    ///
    /// Use unfold for iterative state machines where each step consumes the previous state and either continues or terminates. For tree-shaped recursion with branching, use ``recursive(base:depthRange:extend:)`` instead.
    ///
    /// The iteration count is drawn from `depthRange` as a reducible depth-control choice. The reducer can collapse iterations through structural operations to find the minimum number of steps needed to trigger a property failure. `step` is only called while `remaining` is at least 1; when the drawn depth is exhausted, `finish` converts the final state into the output. Because the chosen depth may be less than the upper bound, `step` should use `remaining` only for relative decisions rather than absolute thresholds.
    ///
    /// - Parameters:
    ///   - seed: Generator for the initial state.
    ///   - depthRange: The range of iteration counts to draw from. A drawn depth of 0 produces `finish(seed)` directly.
    ///   - step: Closure that receives the current state and remaining depth (always at least 1), returning a generator of ``UnfoldStep``.
    ///   - finish: Converts the final state into the output when the drawn depth is exhausted without `step` returning ``UnfoldStep/done(_:)``.
    /// - Returns: A generator producing values built by iterative state transformation.
    static func unfold<State, Output>(
        seed: Generator<State>,
        depthRange: ClosedRange<Int>,
        step: @escaping (State, UInt64) -> Generator<UnfoldStep<State, Output>>,
        finish: @escaping (State) -> Output,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> Generator<Output> {
        precondition(depthRange.lowerBound >= 0, "lower bound must be >= 0")
        func loop(
            state: Generator<State>,
            remaining: UInt64
        ) -> Generator<Output> {
            state.bindReified(
                { currentState in
                    guard remaining > 0 else {
                        return Gen.just(finish(currentState))
                    }
                    return step(currentState, remaining).bindReified(
                        { result in
                            switch result {
                                case let .done(output):
                                    return Gen.just(output)
                                case let .recurse(nextState):
                                    return loop(
                                        state: Gen.just(nextState),
                                        remaining: remaining - 1
                                    )
                            }
                        },
                        fileID: fileID, line: line &+ 1, column: column
                    )
                },
                fileID: fileID, line: line, column: column
            )
        }

        let range = UInt64(depthRange.lowerBound) ... UInt64(depthRange.upperBound)
        return chooseDepth(in: range)
            ._bound(
                forward: { depth in loop(state: seed, remaining: depth) },
                backward: { _ in range.upperBound }
            )
    }

    // MARK: - Depth Control

    /// Generates a depth index tagged with ``TypeTag/depthControl``.
    ///
    /// Separate from ``chooseBits`` so the reducer excludes depth choices from value search. Depth is changed only by structural operations (remove, replace), which can collapse entire recursive layers while preserving context. Value search on depth would risk creating structurally incoherent trees.
    static func chooseDepth(in range: ClosedRange<UInt64>) -> Generator<UInt64> {
        let operation = ReflectiveOperation.chooseBits(
            min: range.lowerBound,
            max: range.upperBound,
            tag: .depthControl,
            isRangeExplicit: true
        )
        return .impure(operation: operation) { result in
            try .pure(UInt64(bitPattern64: chooseBitsBitPattern(result)))
        }
    }
}
