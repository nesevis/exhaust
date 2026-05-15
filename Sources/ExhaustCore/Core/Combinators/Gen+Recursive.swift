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
            @escaping () -> Generator<Output>,
            UInt64
        ) -> Generator<Output>
    ) -> Generator<Output> {
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
        base: Generator<Output>,
        depthRange: ClosedRange<UInt64>,
        extend: @escaping (@escaping () -> Generator<Output>, UInt64) -> Generator<Output>
    ) -> Generator<Output> {
        // Build all layers eagerly. Layer 0 = base, layer N = extend applied N times.
        var layers: [Generator<Output>] = [base]
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

    // MARK: - Unfold

    /// Generates values by iteratively transforming state from a seed, with reducible iteration depth.
    ///
    /// Starting from an initial state produced by `seed`, the generator repeatedly calls `step` to either produce the final value (`.done`) or continue with new state (`.recurse`). The `remaining` parameter counts down from the chosen depth to zero; `step` must return `.done` when `remaining` is zero.
    ///
    /// The iteration count is drawn from `depthRange` as a reducible depth-control choice. The reducer can collapse iterations through structural operations to find the minimum number of steps needed to trigger a property failure. Because the chosen depth may be less than the upper bound, `step` should not assume that `remaining` starts at any particular value — use it only for relative decisions (for example, "generate a leaf when `remaining` is zero") rather than absolute thresholds.
    ///
    /// - Parameters:
    ///   - seed: Generator for the initial state.
    ///   - depthRange: The range of iteration counts to draw from. The lower bound must be at least 1.
    ///   - step: Closure that receives the current state and remaining depth, returning a generator of ``UnfoldStep``.
    /// - Returns: A generator producing values built by iterative state transformation.
    static func unfold<State, Output>(
        seed: Generator<State>,
        depthRange: ClosedRange<Int>,
        step: @escaping (State, UInt64) -> Generator<UnfoldStep<State, Output>>,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> Generator<Output> {
        precondition(depthRange.lowerBound >= 1, "lower bound must be >= 1")
        func loop(
            state: Generator<State>,
            remaining: UInt64
        ) -> Generator<Output> {
            state.bindReified(
                { currentState in
                    step(currentState, remaining).bindReified(
                        { result in
                            switch result {
                            case let .done(output):
                                return Gen.just(output)
                            case let .recurse(nextState):
                                guard remaining > 0 else {
                                    preconditionFailure(
                                        "step returned .recurse at remaining=0; "
                                            + "step must return .done when remaining is 0"
                                    )
                                }
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

    /// Generates a depth index tagged with ``TypeTag/depthControl``. Excluded from value search during reduction — structural operations handle depth reduction while preserving structural context.
    static func chooseDepth(in range: ClosedRange<UInt64>) -> Generator<UInt64> {
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
