//
//  ReflectiveGenerator+Unfold.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/5/2026.
//

public extension ReflectiveGenerator {
    /// Generates values by iteratively transforming state from a seed.
    ///
    /// Starting from an initial state produced by `seed`, the generator repeatedly calls `step` to either produce the final value (`.done`) or continue with new state (`.recurse`). When the drawn iteration budget is exhausted, the library calls `finish` to convert the final state into the output, so `step` never runs with a `remaining` of zero.
    ///
    /// The iteration count is drawn from `depthRange` as a reducible depth-control choice. The reducer can collapse iterations through structural operations to find the minimum number of steps needed to trigger a property failure. Because the chosen depth may be less than the upper bound, `step` should use `remaining` only for relative decisions rather than absolute thresholds.
    ///
    /// ```swift
    /// let listGen = ReflectiveGenerator<[Int]>.unfold(
    ///     seed: .just([]),
    ///     depthRange: 0 ... 5,
    ///     step: { list, remaining in
    ///         .bool().map { shouldStop in
    ///             shouldStop ? .done(list) : .recurse(list + [list.count])
    ///         }
    ///     },
    ///     finish: { list in list }
    /// )
    /// ```
    ///
    /// - Note: Each iteration uses an internal bind, so the reducer can minimize choice sequences and search bound values but reflection is not supported.
    ///
    /// - Parameters:
    ///   - seed: Generator for the initial state.
    ///   - depthRange: The range of iteration counts to draw from. A drawn depth of 0 produces `finish(seed)` directly.
    ///   - step: Closure that receives the current state and remaining depth (always at least 1), returning a generator of ``UnfoldStep``.
    ///   - finish: Converts the final state into the output when the iteration budget is exhausted without `step` returning ``UnfoldStep/done(_:)``.
    /// - Returns: A generator producing values built by iterative state transformation.
    static func unfold<State>(
        seed: ReflectiveGenerator<State>,
        depthRange: ClosedRange<Int>,
        step: @Sendable @escaping (State, Int) -> ReflectiveGenerator<UnfoldStep<State, Output>>,
        finish: @Sendable @escaping (State) -> Output,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> ReflectiveGenerator<Output> {
        Gen.unfold(
            seed: seed.gen,
            depthRange: depthRange,
            step: { step($0, Int($1)).gen },
            finish: finish,
            fileID: fileID,
            line: line,
            column: column
        ).wrapped
    }
}
