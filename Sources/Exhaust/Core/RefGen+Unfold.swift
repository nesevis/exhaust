//
//  RefGen+Unfold.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/5/2026.
//

public extension RefGen {
    /// Generates values by iteratively transforming state from a seed.
    ///
    /// Starting from an initial state produced by `seed`, the generator repeatedly calls `step` to either produce the final value (`.done`) or continue with new state (`.recurse`). The `remaining` parameter counts down from the chosen depth to zero; `step` must return `.done` when `remaining` is zero.
    ///
    /// The iteration count is drawn from `depthRange` as a reducible depth-control choice. The reducer can collapse iterations through structural operations to find the minimum number of steps needed to trigger a property failure. Because the chosen depth may be less than the upper bound, `step` should not assume that `remaining` starts at any particular value — use it only for relative decisions (for example, "generate a leaf when `remaining` is zero") rather than absolute thresholds.
    ///
    /// ```swift
    /// let listGen = ReflectiveGenerator<[Int]>.unfold(
    ///     seed: .just([]),
    ///     depthRange: 1 ... 5
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
    /// - Note: Each iteration uses an internal bind, so the reducer can minimize choice sequences and search bound values but reflection is not supported.
    ///
    /// - Parameters:
    ///   - seed: Generator for the initial state.
    ///   - depthRange: The range of iteration counts to draw from. The lower bound must be at least 1.
    ///   - step: Closure that receives the current state and remaining depth, returning a generator of ``UnfoldStep``.
    /// - Returns: A generator producing values built by iterative state transformation.
    static func unfold<State>(
        seed: RefGen<State>,
        depthRange: ClosedRange<Int>,
        step: @Sendable @escaping (State, UInt64) -> RefGen<UnfoldStep<State, Output>>,
        fileID: String = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> RefGen<Output> {
        RefGen {
            Gen.unfold(
                seed: seed.gen,
                depthRange: depthRange,
                step: { step($0, $1).gen },
                fileID: fileID,
                line: line,
                column: column
            )
        }
    }
}
