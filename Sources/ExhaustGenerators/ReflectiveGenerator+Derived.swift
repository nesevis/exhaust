import Exhaustable
import ExhaustCore

package extension ReflectiveGenerator where Output: __Exhaustable.Conformance {
    /// The nesting ceiling a derived generator reaches at full size when neither the type's `@Exhaustable(maximumDepth:)` nor the `maximumDepth:` argument sets one.
    static var defaultMaximumDepth: Int {
        10
    }

    /// Implements the size-ramped derivation behind ``__Exhaustable/Conformance/gen(maximumDepth:maximumNodes:stateSpace:scaling:overriding:)``.
    static func derived<each Override>(
        maximumDepth: Int? = nil,
        maximumNodes: Int? = nil,
        stateSpace: GeneratorStateSpace? = nil,
        scaling: SizeScaling<Int> = .linear,
        overriding overrides: repeat ReflectiveGenerator<each Override>
    ) -> ReflectiveGenerator<Output> {
        let space = stateSpace ?? Output.__generatorDescriptor.stateSpace
        let ceiling = maximumDepth ?? Output.__generatorDescriptor.maximumDepth ?? defaultMaximumDepth
        precondition(ceiling >= 0, "Depth must be non-negative")
        return preparedGenerator(
            for: Output.self,
            depth: .drawn(ceiling: ceiling, scaling: depthScaling(scaling)),
            maximumNodes: maximumNodes ?? Output.__generatorDescriptor.maximumNodes,
            stateSpace: space,
            overrides: overrideTable(repeat each overrides)
        )
    }

    /// Implements the pinned-depth derivation behind ``__Exhaustable/Conformance/gen(depth:maximumNodes:stateSpace:overriding:)``.
    static func derived<each Override>(
        depth: Int,
        maximumNodes: Int? = nil,
        stateSpace: GeneratorStateSpace? = nil,
        overriding overrides: repeat ReflectiveGenerator<each Override>
    ) -> ReflectiveGenerator<Output> {
        let space = stateSpace ?? Output.__generatorDescriptor.stateSpace
        precondition(depth >= 0, "Depth must be non-negative")
        return preparedGenerator(
            for: Output.self,
            depth: .pinned(depth),
            maximumNodes: maximumNodes ?? Output.__generatorDescriptor.maximumNodes,
            stateSpace: space,
            overrides: overrideTable(repeat each overrides)
        )
    }
}

public extension __Exhaustable.Conformance {
    /// Builds the generator derived from this type's `@Exhaustable` annotation.
    ///
    /// This factory is available because the application type was declared with `@Exhaustable`. Call it from a test target that imports `Exhaust` or `ExhaustGenerators`; the application target only needs `Exhaustable`.
    ///
    /// ```swift
    /// let terms = Term.gen()
    /// let constrained = Term.gen(
    ///     maximumDepth: 4,
    ///     stateSpace: .small,
    ///     overriding: .int(in: 0 ... 9)
    /// )
    /// ```
    ///
    /// With no arguments, `gen()` uses the annotation's settings. Arguments override the root for this generator, while nested annotated types retain their own tighter limits.
    ///
    /// Depth controls recursive nesting and normally grows with Exhaust's size parameter. Crossing into another annotated type consumes one depth unit; arrays, optionals, sets, and dictionaries pass the allowance through without consuming it. Use ``gen(depth:maximumNodes:stateSpace:overriding:)`` when a test needs one fixed depth. A node ceiling limits annotated values and standard containers, not memory or work inside overrides. ``GeneratorStateSpace`` controls the breadth of default numeric, sequence, and date payloads.
    ///
    /// Overrides match payload types, including occurrences inside standard containers. They replace built-in or derived payload generators but do not replace the root generator. Sets, dictionaries, and forward-only overrides can disable reflection.
    ///
    /// - Parameters:
    ///   - maximumDepth: The root recursive-depth ceiling. Defaults to the annotation or 10.
    ///   - maximumNodes: An optional root structural-node ceiling. Defaults to the annotation or no node ceiling.
    ///   - stateSpace: The root state space. Defaults to the annotation or `.full`.
    ///   - scaling: How depth grows with Exhaust's size parameter. Defaults to `.linear`.
    ///   - overrides: Generators matched to payload types.
    /// - Returns: A derived generator for this type.
    static func gen<each Override>(
        maximumDepth: Int? = nil,
        maximumNodes: Int? = nil,
        stateSpace: GeneratorStateSpace? = nil,
        scaling: SizeScaling<Int> = .linear,
        overriding overrides: repeat ReflectiveGenerator<each Override>
    ) -> ReflectiveGenerator<Self> {
        .derived(
            maximumDepth: maximumDepth,
            maximumNodes: maximumNodes,
            stateSpace: stateSpace,
            scaling: scaling,
            overriding: repeat each overrides
        )
    }

    /// Builds the generator derived from this type's `@Exhaustable` annotation at a fixed recursive depth.
    ///
    /// ```swift
    /// let terms = Term.gen(depth: 4, overriding: .int(in: 0 ... 3))
    /// ```
    ///
    /// Unlike ``gen(maximumDepth:maximumNodes:stateSpace:scaling:overriding:)``, this overload does not draw or reduce a root depth choice. Values may still terminate before the requested depth.
    ///
    /// - Parameters:
    ///   - depth: The fixed root depth ceiling.
    ///   - maximumNodes: An optional structural-node ceiling.
    ///   - stateSpace: The root state space. Defaults to the annotation or `.full`.
    ///   - overrides: Generators matched to payload types.
    /// - Returns: A derived generator at the requested depth.
    static func gen<each Override>(
        depth: Int,
        maximumNodes: Int? = nil,
        stateSpace: GeneratorStateSpace? = nil,
        overriding overrides: repeat ReflectiveGenerator<each Override>
    ) -> ReflectiveGenerator<Self> {
        .derived(depth: depth, maximumNodes: maximumNodes, stateSpace: stateSpace, overriding: repeat each overrides)
    }
}

// MARK: - Helpers

/// Keeps resolution, depth, and node-budget diagnostics on one nonthrowing boundary, with or without a node ceiling. Both `derived` overloads reach the throwing derivation through here, so a caller of `gen(...)` sees a precondition failure rather than an error to handle.
private func preparedGenerator<Value: __Exhaustable.Conformance>(
    for type: Value.Type,
    depth: RootDepth,
    maximumNodes: Int?,
    stateSpace: GeneratorStateSpace,
    overrides: [ObjectIdentifier: ReflectiveGenerator<Any>]
) -> ReflectiveGenerator<Value> {
    do {
        let plan = try GeneratorDerivationPlan(for: type, overrides: overrides)
        return try BudgetedGeneratorDerivation(plan: plan).root(
            for: type,
            depth: depth,
            maximumNodes: maximumNodes,
            stateSpace: stateSpace
        )
    } catch {
        preconditionFailure(String(describing: error))
    }
}

/// Converts the public signed scaling to the unsigned representation used by depth controls. Negative origins clamp to zero, which has the same effect as clamping them into the nonnegative depth range.
private func depthScaling(_ scaling: SizeScaling<Int>) -> SizeScaling<UInt64> {
    switch scaling {
        case .constant:
            .constant
        case .linear:
            .linear
        case let .linearFrom(origin):
            .linearFrom(origin: UInt64(clamping: origin))
        case .exponential:
            .exponential
        case let .exponentialFrom(origin):
            .exponentialFrom(origin: UInt64(clamping: origin))
    }
}

/// Keys each override by its output type, which the pack iteration cannot name directly.
private func overrideTable<each Override>(_ overrides: repeat ReflectiveGenerator<each Override>) -> [ObjectIdentifier: ReflectiveGenerator<Any>] {
    var table: [ObjectIdentifier: ReflectiveGenerator<Any>] = [:]
    for override in repeat each overrides {
        registerOverride(override, in: &table)
    }
    return table
}

private func registerOverride<Override>(
    _ override: ReflectiveGenerator<Override>,
    in table: inout [ObjectIdentifier: ReflectiveGenerator<Any>]
) {
    table[ObjectIdentifier(Override.self)] = override.erasedForDerivation()
}
