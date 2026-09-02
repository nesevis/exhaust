import ExhaustCore
import IssueReporting

public extension ReflectiveGenerator {
    /// Tries weighted partial generators one at a time until one produces a value, and fails the run when none does.
    ///
    /// Each arm produces an optional. A `nil` result withdraws that arm, and the next draw is made among the arms not yet tried, so the node auditions its alternatives where ``oneOf(weighted:fileID:line:column:)`` commits to its first draw. Use it for constrained generation where an arm can only discover that it does not apply by attempting its sub-generation, such as a typing rule whose premises must both be satisfiable. Where applicability is cheap to decide up front, filter the candidates and use `oneOf`.
    ///
    /// ```swift
    /// let term = #gen(.backtrack(always: [
    ///     (1, literalGen(matching: type)),
    ///     (3, applicationGen(producing: type, in: context)),
    ///     (2, variableGen(of: type, in: context)),
    /// ]))
    /// ```
    ///
    /// When every arm produces `nil` the node throws, the current generation run ends, and an issue is recorded at this call site. Use `always:` only when at least one arm cannot fail in any context this node is reached from, typically a base case. When absence is a legitimate outcome, or the node sits inside a larger backtracking generator whose enclosing arms should treat its exhaustion as their own failure, use ``backtrack(failable:fileID:line:column:)``. To retry from the top with fresh draws, filter the `nil` out of a `failable:` node instead of listing nil-producing arms here: an arm that produces nil is always a withdrawn arm, so `.just(nil)` in this list is dead weight.
    ///
    /// Failed attempts consume randomness but are not recorded. The choice sequence holds only the winning arm, so reduction, mutation, and replay see an ordinary weighted choice. A node costs up to the sum of its arms' attempts, not the average. Reflection decomposes a value through the first arm in declaration order that can produce it, exactly as `oneOf` does.
    ///
    /// - Parameter choices: Weighted arms. Weights are relative frequencies and must be positive.
    static func backtrack(
        always choices: [(Int, ReflectiveGenerator<Output?>)],
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) -> ReflectiveGenerator<Output> {
        var arms: [(weight: UInt64, generator: Generator<Output?>)] = []
        arms.reserveCapacity(choices.count)
        var allReflective = true
        for (weight, generator) in choices {
            precondition(weight > 0, "Backtrack arm weights must be greater than zero")
            arms.append((UInt64(weight), generator.gen))
            allReflective = allReflective && generator.isReflective
        }
        return Gen.backtrack(
            always: arms,
            fileID: fileID,
            line: line,
            column: column,
            onExhausted: {
                reportError(
                    "Every arm of backtrack(always:) produced nil, so no value could be generated and the run ended early. Add an arm that cannot fail here, or use backtrack(failable:) and handle nil.",
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
            }
        ).wrapped(isReflective: allReflective)
    }

    /// Tries weighted partial generators one at a time until one produces a value, and fails the run when none does.
    ///
    /// Each arm produces an optional. A `nil` result withdraws that arm, and the next draw is made among the arms not yet tried, so the node auditions its alternatives where ``oneOf(_:fileID:line:column:)`` commits to its first draw. Use it for constrained generation where an arm can only discover that it does not apply by attempting its sub-generation, such as a typing rule whose premises must both be satisfiable. Where applicability is cheap to decide up front, filter the candidates and use `oneOf`.
    ///
    /// ```swift
    /// let term = #gen(.backtrack(
    ///     always: (1, literalGen(matching: type)),
    ///     (3, applicationGen(producing: type, in: context))
    /// ))
    /// ```
    ///
    /// When every arm produces `nil` the node throws, the current generation run ends, and an issue is recorded at this call site. Use `always:` only when at least one arm cannot fail in any context this node is reached from, typically a base case. When absence is a legitimate outcome, or the node sits inside a larger backtracking generator whose enclosing arms should treat its exhaustion as their own failure, use ``backtrack(failable:fileID:line:column:)``. To retry from the top with fresh draws, filter the `nil` out of a `failable:` node instead of listing nil-producing arms here: an arm that produces nil is always a withdrawn arm, so `.just(nil)` in this list is dead weight.
    ///
    /// Failed attempts consume randomness but are not recorded. The choice sequence holds only the winning arm, so reduction, mutation, and replay see an ordinary weighted choice. A node costs up to the sum of its arms' attempts, not the average. Reflection decomposes a value through the first arm in declaration order that can produce it, exactly as `oneOf` does.
    ///
    /// - Parameter choices: Weighted arms. Weights are relative frequencies and must be positive.
    static func backtrack(
        always choices: (Int, ReflectiveGenerator<Output?>)...,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) -> ReflectiveGenerator<Output> {
        backtrack(always: choices, fileID: fileID, filePath: filePath, line: line, column: column)
    }

    /// Tries weighted partial generators one at a time until one produces a value, and produces nil when none does.
    ///
    /// Each arm produces an optional. A `nil` result withdraws that arm, and the next draw is made among the arms not yet tried, so the node auditions its alternatives where ``oneOf(weighted:fileID:line:column:)`` commits to its first draw. Use it for constrained generation where an arm can only discover that it does not apply by attempting its sub-generation, such as a typing rule whose premises must both be satisfiable. Where applicability is cheap to decide up front, filter the candidates and use `oneOf`.
    ///
    /// ```swift
    /// let annotation = #gen(.backtrack(failable: [
    ///     (1, explicitAnnotationGen(for: binding)),
    ///     (1, inferredAnnotationGen(for: binding)),
    /// ]))
    /// ```
    ///
    /// `nil` is the result when every arm produces `nil`, and it is a recorded, reflectable, mutation-reachable outcome: the reducer can move a value toward absence and the mutator can flip a node into or out of it. Use `failable:` when absence is meaningful (an optional subterm, an annotation that may be omitted), or when the node sits inside a larger backtracking generator whose enclosing arms should treat its exhaustion as their own failure. When nil would indicate a generator bug, use ``backtrack(always:fileID:filePath:line:column:)`` and avoid the `Optional` plumbing. An arm that produces nil is always a withdrawn arm, never the recorded absence, so `.just(nil)` in this list is dead weight.
    ///
    /// Failed attempts consume randomness but are not recorded. The choice sequence holds only the winning arm, so reduction, mutation, and replay see an ordinary weighted choice with one extra branch for absence, ordered after the real arms so reduction prefers a value over `nil`. A node costs up to the sum of its arms' attempts, not the average. Reflection decomposes a value through the first arm in declaration order that can produce it, exactly as `oneOf` does.
    ///
    /// - Parameter choices: Weighted arms. Weights are relative frequencies and must be positive.
    static func backtrack<Wrapped>(
        failable choices: [(Int, ReflectiveGenerator<Wrapped?>)],
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> ReflectiveGenerator<Wrapped?> {
        // `Wrapped` is a method generic and `Output` stays free so the implicit-member form infers: the chain's result must equal its contextual base, and a result spelled `ReflectiveGenerator<Output?>` could never equal a base of `ReflectiveGenerator<Output>`.
        var arms: [(weight: UInt64, generator: Generator<Wrapped?>)] = []
        arms.reserveCapacity(choices.count)
        var allReflective = true
        for (weight, generator) in choices {
            precondition(weight > 0, "Backtrack arm weights must be greater than zero")
            arms.append((UInt64(weight), generator.gen))
            allReflective = allReflective && generator.isReflective
        }
        return Gen.backtrack(failable: arms, fileID: fileID, line: line, column: column)
            .wrapped(isReflective: allReflective)
    }

    /// Tries weighted partial generators one at a time until one produces a value, and produces nil when none does.
    ///
    /// Each arm produces an optional. A `nil` result withdraws that arm, and the next draw is made among the arms not yet tried, so the node auditions its alternatives where ``oneOf(_:fileID:line:column:)`` commits to its first draw. Use it for constrained generation where an arm can only discover that it does not apply by attempting its sub-generation, such as a typing rule whose premises must both be satisfiable. Where applicability is cheap to decide up front, filter the candidates and use `oneOf`.
    ///
    /// ```swift
    /// let annotation = #gen(.backtrack(
    ///     failable: (1, explicitAnnotationGen(for: binding)),
    ///     (1, inferredAnnotationGen(for: binding))
    /// ))
    /// ```
    ///
    /// `nil` is the result when every arm produces `nil`, and it is a recorded, reflectable, mutation-reachable outcome: the reducer can move a value toward absence and the mutator can flip a node into or out of it. Use `failable:` when absence is meaningful (an optional subterm, an annotation that may be omitted), or when the node sits inside a larger backtracking generator whose enclosing arms should treat its exhaustion as their own failure. When nil would indicate a generator bug, use ``backtrack(always:fileID:filePath:line:column:)`` and avoid the `Optional` plumbing. An arm that produces nil is always a withdrawn arm, never the recorded absence, so `.just(nil)` in this list is dead weight.
    ///
    /// Failed attempts consume randomness but are not recorded. The choice sequence holds only the winning arm, so reduction, mutation, and replay see an ordinary weighted choice with one extra branch for absence, ordered after the real arms so reduction prefers a value over `nil`. A node costs up to the sum of its arms' attempts, not the average. Reflection decomposes a value through the first arm in declaration order that can produce it, exactly as `oneOf` does.
    ///
    /// - Parameter choices: Weighted arms. Weights are relative frequencies and must be positive.
    static func backtrack<Wrapped>(
        failable choices: (Int, ReflectiveGenerator<Wrapped?>)...,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> ReflectiveGenerator<Wrapped?> {
        backtrack(failable: choices, fileID: fileID, line: line, column: column)
    }
}
