// Combinator for recursive generator definitions.
// Enables declarative recursive data type generation with automatic depth control.

public extension Gen {
    /// Creates a recursive generator with a constant base case value.
    ///
    /// The `extend` closure receives two arguments:
    /// - `recurse`: A thunk that returns a generator for "recurse here" positions
    /// - `remaining`: The recursion budget, which decreases with each layer
    ///
    /// ```swift
    /// Gen.recursive(base: .leaf) { recurse, remaining in
    ///     Gen.oneOf(
    ///         weighted: (1, .just(.leaf)),
    ///         (Int(remaining), Gen.zip(recurse(), Gen.choose(in: 0...9), recurse()).map { .node($0, $1, $2) })
    ///     )
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - base: The ground value used when recursion bottoms out
    ///   - extend: Closure that builds one recursive layer from the previous layer
    /// - Returns: A generator that produces recursive values with size-controlled depth
    static func recursive<Output>(
        base: Output,
        extend: @escaping (@escaping () -> ReflectiveGenerator<Output>, UInt64) -> ReflectiveGenerator<Output>
    ) -> ReflectiveGenerator<Output> {
        recursive(base: Gen.just(base), extend: extend)
    }

    /// Creates a recursive generator with a generator base case.
    ///
    /// Use this overload when the base case itself needs randomness (e.g. random leaf values).
    ///
    /// - Parameters:
    ///   - base: Generator for the base case
    ///   - extend: Closure that builds one recursive layer from the previous layer
    /// - Returns: A generator that produces recursive values with size-controlled depth
    static func recursive<Output>(
        base: ReflectiveGenerator<Output>,
        extend: @escaping (@escaping () -> ReflectiveGenerator<Output>, UInt64) -> ReflectiveGenerator<Output>
    ) -> ReflectiveGenerator<Output> {
        let erasedExtend: (@escaping () -> ReflectiveGenerator<Any>, UInt64) -> ReflectiveGenerator<Any> = { recurse, remaining in
            extend({ recurse().map { $0 as! Output } }, remaining).erase()
        }

        return .impure(operation: .recursive(
            base: base.erase(),
            extend: erasedExtend
        )) { result in
            guard let typed = result as? Output else {
                throw GeneratorError.typeMismatch(
                    expected: String(describing: Output.self),
                    actual: String(describing: type(of: result))
                )
            }
            return .pure(typed)
        }
    }

    /// Unfolds a recursive generator into a plain generator by iteratively applying the
    /// extension closure. Each iteration halves the remaining budget.
    ///
    /// The outermost layer (executed first during generation) receives the largest
    /// `remaining` value, making recursion more likely at the top and less likely
    /// at deeper levels — matching the intuition that "remaining budget decreases
    /// as you go deeper."
    ///
    /// At size 100 with `/= 2`: ~7 layers. A binary tree with 7 layers = 127 nodes.
    static func unfoldRecursive(
        base: ReflectiveGenerator<Any>,
        extend: (@escaping () -> ReflectiveGenerator<Any>, UInt64) -> ReflectiveGenerator<Any>,
        size: UInt64
    ) -> ReflectiveGenerator<Any> {
        // Collect the remaining values for each layer (largest to smallest)
        var budgets: [UInt64] = []
        var r = size
        while r > 0 {
            budgets.append(r)
            r /= 2
        }

        // Build layers inside-out: the first extend call uses the smallest budget
        // (innermost layer), and the last uses the largest (outermost layer).
        var current = base
        for budget in budgets.reversed() {
            let prev = current
            current = extend({ prev }, budget)
        }
        return current
    }
}
