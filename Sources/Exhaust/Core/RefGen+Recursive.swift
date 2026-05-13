//
//  RefGen+Recursive.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/5/2026.
//

public extension RefGen {
    /// Creates a recursive generator with a constant base case value.
    ///
    /// The `extend` closure receives a `recurse` thunk and a `remaining` depth budget that counts down from `maxDepth` (outermost) to 1 (innermost). To terminate early, return a generator that doesn't call `recurse()` — this short-circuits the recursion since inner layers are only reachable through `recurse()`.
    ///
    /// ```swift
    /// let treeGen: Generator<Tree> = #gen(.recursive(
    ///     base: .leaf,
    ///     depthRange: 0...5
    /// ) { recurse, remaining in
    ///     .oneOf(
    ///         .just(.leaf),
    ///         #gen(recurse(), .int(in: 0...9), recurse()).map { .node($0, $1, $2) }
    ///     )
    /// })
    /// ```
    ///
    /// - Parameters:
    ///   - base: The ground value used when recursion bottoms out.
    ///   - depthRange: The range of recursive layers to unfold.
    ///   - extend: Closure that builds one recursive layer from the previous layer.
    /// - Returns: A generator that produces recursive values with depth-controlled structure.
    static func recursive(
        base: Output,
        depthRange: ClosedRange<Int>,
        extend: @Sendable @escaping (@Sendable @escaping () -> RefGen<Output>, UInt64) -> RefGen<Output>
    ) -> RefGen<Output> {
        precondition(depthRange.lowerBound >= 0, "lower bound must be >= 0")
        return recursive(
            base: RefGen { Gen.just(base) },
            depthRange: UInt64(depthRange.lowerBound) ... UInt64(depthRange.upperBound),
            extend: extend
        )
    }

    /// Creates a recursive generator with a constant base case value.
    ///
    /// The `extend` closure receives a `recurse` thunk and a `remaining` depth budget that counts down from `maxDepth` (outermost) to 1 (innermost). To terminate early, return a generator that doesn't call `recurse()` — this short-circuits the recursion since inner layers are only reachable through `recurse()`.
    ///
    /// ```swift
    /// let treeGen: Generator<Tree> = #gen(.recursive(
    ///     base: .leaf,
    ///     depthRange: UInt64(0)...UInt64(5)
    /// ) { recurse, remaining in
    ///     .oneOf(
    ///         .just(.leaf),
    ///         #gen(recurse(), .int(in: 0...9), recurse()).map { .node($0, $1, $2) }
    ///     )
    /// })
    /// ```
    ///
    /// - Parameters:
    ///   - base: The ground value used when recursion bottoms out.
    ///   - depthRange: The range of recursive layers to unfold.
    ///   - extend: Closure that builds one recursive layer from the previous layer.
    /// - Returns: A generator that produces recursive values with depth-controlled structure.
    static func recursive(
        base: Output,
        depthRange: ClosedRange<UInt64>,
        extend: @Sendable @escaping (@Sendable @escaping () -> RefGen<Output>, UInt64) -> RefGen<Output>
    ) -> RefGen<Output> {
        recursive(base: RefGen { Gen.just(base) }, depthRange: depthRange, extend: extend)
    }

    /// Creates a recursive generator with a generator base case and a reducible depth range.
    ///
    /// The depth is drawn from `depthRange` as a `chooseBits` entry in the choice sequence, making it reducible. The reducer can collapse subtrees by driving the depth toward the range's lower bound.
    ///
    /// ```swift
    /// let exprGen: Generator<Expr> = .recursive(
    ///     base: #gen(.int(in: 0...99)).map { .literal($0) },
    ///     depthRange: 0...4
    /// ) { recurse, remaining in
    ///     .oneOf(.just(.literal(0)), #gen(recurse(), recurse()).map { .add($0, $1) })
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - base: Generator for the base case.
    ///   - depthRange: Range of depths to draw from (lower bound can be 0 for fully collapsible trees).
    ///   - extend: Closure that builds one recursive layer from the previous layer.
    /// - Returns: A generator that produces recursive values with depth-controlled structure.
    static func recursive(
        base: RefGen<Output>,
        depthRange: ClosedRange<Int>,
        extend: @Sendable @escaping (@Sendable @escaping () -> RefGen<Output>, UInt64) -> RefGen<Output>
    ) -> RefGen<Output> {
        precondition(depthRange.lowerBound >= 0, "lower bound must be >= 0")
        return recursive(
            base: base,
            depthRange: UInt64(depthRange.lowerBound) ... UInt64(depthRange.upperBound),
            extend: extend
        )
    }

    /// Creates a recursive generator with a generator base case and a reducible depth range.
    ///
    /// The depth is drawn from `depthRange` as a `chooseBits` entry in the choice sequence, making it reducible. The reducer can collapse subtrees by driving the depth toward the range's lower bound.
    ///
    /// - Parameters:
    ///   - base: Generator for the base case.
    ///   - depthRange: Range of depths to draw from (lower bound can be 0 for fully collapsible trees).
    ///   - extend: Closure that builds one recursive layer from the previous layer.
    /// - Returns: A generator that produces recursive values with depth-controlled structure.
    static func recursive(
        base: RefGen<Output>,
        depthRange: ClosedRange<UInt64>,
        extend: @Sendable @escaping (@Sendable @escaping () -> RefGen<Output>, UInt64) -> RefGen<Output>
    ) -> RefGen<Output> {
        RefGen {
            // Bridge the Sendable boundary: Gen.recursive is internal and provides a non-Sendable
            // recurse thunk. The public API requires @Sendable on the thunk so users can capture it
            // in #gen(...) closures. The wrap is safe because Generator is @unchecked Sendable.
            Gen.recursive(base: base.gen, depthRange: depthRange) { recurse, remaining in
                nonisolated(unsafe) let capturedRecurse = recurse
                let sendableRecurse: @Sendable () -> RefGen<Output> = { RefGen { capturedRecurse() } }
                return extend(sendableRecurse, remaining).gen
            }
        }
    }
}
