import ExhaustCore

/// Represents the result of one step in an ``ReflectiveGenerator/unfold(seed:maxDepth:step:)`` loop.
public enum UnfoldStep<State, Value> {
    /// Produces the final output and stops iterating.
    case done(Value)
    /// Continues with the given state for the next iteration.
    case recurse(State)
}

public extension ReflectiveGenerator {
    /// Generates values by iteratively transforming state from a seed.
    ///
    /// Starting from an initial state produced by `seed`, the generator repeatedly calls `step` to either produce the final value (`.done`) or continue with new state (`.recurse`). The `remaining` parameter counts down from `maxDepth` to zero; `step` must return `.done` when `remaining` is zero.
    ///
    /// ```swift
    /// let listGen = ReflectiveGenerator<[Int]>.unfold(
    ///     seed: .just([]),
    ///     maxDepth: 5
    /// ) { list, remaining in
    ///     if remaining == 0 {
    ///         return .just(.done(list))
    ///     }
    ///     return .bool().map { shouldStop in
    ///         shouldStop ? .done(list) : .recurse(list + [list.count])
    ///     }
    /// }
    /// ```
    ///
    /// - Note: Each iteration uses a forward-only bind, so the reducer can minimize choice sequences and search bound values but reflection is not supported.
    ///
    /// - Parameters:
    ///   - seed: Generator for the initial state.
    ///   - maxDepth: Maximum number of `.recurse` steps before `step` must return `.done`.
    ///   - step: Closure that receives the current state and remaining depth, returning a generator of ``UnfoldStep``.
    /// - Returns: A generator producing values built by iterative state transformation.
    static func unfold<State>(
        seed: ReflectiveGenerator<State>,
        maxDepth: Int,
        step: @escaping @Sendable (State, UInt64) -> ReflectiveGenerator<UnfoldStep<State, Value>>,
        fileID: String = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> ReflectiveGenerator<Value> {
        @Sendable func loop(
            state: ReflectiveGenerator<State>,
            remaining: UInt64
        ) -> ReflectiveGenerator<Value> {
            state.bind(
                { currentState in
                    step(currentState, remaining).bind(
                        { result in
                            switch result {
                            case let .done(output):
                                return .just(output)
                            case let .recurse(nextState):
                                guard remaining > 0 else {
                                    preconditionFailure(
                                        "step returned .recurse at remaining=0; "
                                        + "step must return .done when remaining is 0"
                                    )
                                }
                                return loop(
                                    state: .just(nextState),
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

        return loop(state: seed, remaining: UInt64(maxDepth))
    }
}
