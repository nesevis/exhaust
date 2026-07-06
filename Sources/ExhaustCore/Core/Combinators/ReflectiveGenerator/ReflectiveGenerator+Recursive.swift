//
//  ReflectiveGenerator+Recursive.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/5/2026.
//

public extension ReflectiveGenerator {
    /// Creates a recursive generator with a constant base case value.
    ///
    /// The `extend` closure receives a `recurse` thunk and a `remaining` depth budget that counts down from the drawn depth (outermost) to 1 (innermost). To terminate early, return a generator that doesn't call `recurse()` — this short-circuits the recursion since inner layers are only reachable through `recurse()`.
    ///
    /// ```swift
    /// let treeGen: ReflectiveGenerator<Tree> = #gen(.recursive(
    ///     baseValue: .leaf,
    ///     depthRange: 0...5
    /// ) { recurse, remaining in
    ///     .oneOf(
    ///         .just(.leaf),
    ///         #gen(recurse(), .int(in: 0...9), recurse()).map { .node($0, $1, $2) }
    ///     )
    /// })
    /// ```
    ///
    /// The `baseValue` label is deliberate: with a plain `base:` label and an `Any`-typed `Output`, a generator argument can satisfy this overload too, silently capturing the generator itself as the base value. The distinct label makes that mistake unrepresentable.
    ///
    /// - Note: Each recursive layer adds stack frames during generation, so a deep `depthRange` can exhaust the stack and crash. The practical ceiling depends on the generator's structure and the build configuration: optimized ExhaustCore builds (the precompiled framework on Apple platforms) tolerate deeper ranges than from-source debug builds.
    ///
    /// - Parameters:
    ///   - baseValue: The ground value used when recursion bottoms out.
    ///   - depthRange: The range of recursive layers to unfold.
    ///   - extend: Closure that builds one recursive layer from the previous layer.
    /// - Returns: A generator that produces recursive values with depth-controlled structure.
    static func recursive(
        baseValue: Output,
        depthRange: ClosedRange<Int>,
        extend: @Sendable @escaping (@Sendable @escaping () -> ReflectiveGenerator<Output>, Int) -> ReflectiveGenerator<Output>
    ) -> ReflectiveGenerator<Output> {
        recursive(base: Gen.just(baseValue).wrapped, depthRange: depthRange, extend: extend)
    }

    /// Creates a recursive generator with a generator base case and a reducible depth range.
    ///
    /// The depth is drawn from `depthRange` as a `chooseBits` entry in the choice sequence, making it reducible. The reducer can collapse subtrees by driving the depth toward the range's lower bound.
    ///
    /// - Note: Each recursive layer adds stack frames during generation, so a deep `depthRange` can exhaust the stack and crash. The practical ceiling depends on the generator's structure and the build configuration: optimized ExhaustCore builds (the precompiled framework on Apple platforms) tolerate deeper ranges than from-source debug builds.
    ///
    /// ```swift
    /// let exprGen: ReflectiveGenerator<Expr> = .recursive(
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
        base: ReflectiveGenerator<Output>,
        depthRange: ClosedRange<Int>,
        extend: @Sendable @escaping (@Sendable @escaping () -> ReflectiveGenerator<Output>, Int) -> ReflectiveGenerator<Output>
    ) -> ReflectiveGenerator<Output> {
        precondition(depthRange.lowerBound >= 0, "lower bound must be >= 0")
        // Bridge the Sendable boundary: Gen.recursive is internal and provides a non-Sendable
        // recurse thunk. The public API requires @Sendable on the thunk so users can capture it
        // in #gen(...) closures. The wrap is safe because Generator is @unchecked Sendable.
        return Gen.recursive(
            base: base.gen,
            depthRange: UInt64(depthRange.lowerBound) ... UInt64(depthRange.upperBound)
        ) { recurse, remaining in
            nonisolated(unsafe) let capturedRecurse = recurse
            let sendableRecurse: @Sendable () -> ReflectiveGenerator<Output> = { capturedRecurse().wrapped }
            return extend(sendableRecurse, Int(remaining)).gen
        }.wrapped
    }
}
