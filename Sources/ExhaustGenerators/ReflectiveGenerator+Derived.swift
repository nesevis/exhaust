import Exhaustable
import ExhaustCore

public extension ReflectiveGenerator where Output: __Exhaustable.Conformance {
    /// The nesting ceiling a derived generator reaches at full size when neither the type's `@Exhaustable(maximumDepth:)` nor the `maximumDepth:` argument sets one.
    static var defaultMaximumDepth: Int {
        10
    }

    /// Derives a generator from the metadata emitted by `@Exhaustable`.
    ///
    /// Annotated types expose this factory as `Term.gen(...)`.
    ///
    /// ```swift
    /// let terms = Term.gen(overriding: .int(in: 0 ... 3))
    /// ```
    /// Every case that fits the drawn depth is one arm of a uniform pick. Crossing into another structurally derived type consumes one unit of depth. Arrays, optionals, sets, and dictionaries pass the depth allowance through to their contents; when those contents cannot fit, only the empty container is generated. At depth zero, payload-free cases take precedence when the type has any.
    ///
    /// A finite product can require a positive minimum depth. The recorded depth choice ranges from that minimum through the ceiling and grows with the size parameter. Reduction can lower this choice, but cannot select an unconstructible layer. A type with no finite construction, or a ceiling below its minimum, fails a precondition before building any layers.
    ///
    /// Generic types are resolved by concrete specialization, so `Tree<Int>` and `Tree<Bool>` have separate layers. Discovery permits finite specialization cycles but rejects more than 32 distinct specializations of one annotation on an active dependency path. This guards against recursively growing type arguments, independently of depth and node ceilings. An exact payload override can terminate the dependency.
    ///
    /// The ceiling comes from the call, then the type's annotation, then ``defaultMaximumDepth``. A nested type's annotated ceiling also bounds it wherever it occurs as a structural payload. Reflection is best effort, not a derivation requirement: sets, dictionaries, and forward-only payloads do not promise it. Recorded choices still support replay and reduction. When reflection is available, it decomposes a value at the root ceiling, where all shallower constructions are available; a successful reflected replay must reproduce the value.
    ///
    /// Payload resolution first uses an exact override, then structural derivation for an annotated type, then a standard container recipe, then Exhaust's built-in defaults for standard-library and Foundation types. Container contents use the same resolver, so element overrides are honored inside nested containers. Supply custom payload generators through `overriding:`; a user-defined generator property is not discovered automatically. Supplied generators are opaque: depth bounds apply to the derived structure, not to recursion or filtering inside an override.
    ///
    /// Set `stateSpace: .small` to favor collisions with numeric magnitudes up to 100, automatically derived sequence lengths up to 10, and 201 daily dates centered on January 1, 2026 UTC. `.tiny` uses numeric and sequence ceilings of 10 and 5, respectively, and 21 daily dates around the same midpoint. `.medium` uses numeric and sequence ceilings of 10,000 and 20 to reduce processing costs while preserving the full date domain. Sequence limits apply to arrays, sets, dictionaries, strings, and `Data`. The default, `.full`, preserves the built-in generators' existing domains and scaling, including sequence lengths up to 100 and `Date.distantPast...Date.distantFuture` at one-minute resolution. This policy propagates through annotated types and container contents. Nested annotations cap it, while explicit payload overrides retain their own domains. See ``GeneratorStateSpace`` for details.
    ///
    /// Set `maximumNodes:` to split a structural allowance as well as limiting depth. Each annotated value, standard container, and opaque payload costs one node. Products reserve each child's minimum cost, then divide the remainder evenly. Containers reserve one node for themselves and split the rest among their elements; dictionary keys and values both count. The root allowance ramps linearly from its minimum constructible cost to the ceiling as size grows, rounding down. This can exclude unbalanced values even when their total cost would fit. Reflection uses the full allowance, but must still fit the same splitting policy.
    ///
    /// A nested annotation caps its allocated share, never replenishes it. Exact overrides are opaque one-node leaves, so this is not a memory or execution-time bound. Layers for every distinct allowance are built up front, so construction cost grows about linearly with the ceiling for products and closer to quadratically for recursive containers; ceilings in the thousands on container-heavy types are slow to construct. Invalid limits and insufficient budgets fail a precondition before construction. Omit the limit to retain depth-only behavior unless a nested annotation supplies a node ceiling.
    ///
    /// - Parameters:
    ///   - maximumDepth: The root depth ceiling, overriding the type's annotation. Defaults to the annotation or ``defaultMaximumDepth``.
    ///   - maximumNodes: A positive structural node ceiling, overriding the root annotation. Defaults to the annotation or no node limit.
    ///   - stateSpace: Overrides the root's payload-domain preset, which defaults to `.full`. Nested annotations cap the inherited preset; explicit payload overrides are unaffected. See ``GeneratorStateSpace``.
    ///   - scaling: How the drawn depth scales with the size parameter. Defaults to `.linear`, which reaches the ceiling at full size.
    ///   - overrides: Generators matched by payload output type, including payloads inside containers.
    /// - Returns: A generator with a reducible choice of constructible depth and best-effort reflection.
    static func derived<each Override>(
        maximumDepth: Int? = nil,
        maximumNodes: Int? = nil,
        stateSpace: GeneratorStateSpace? = nil,
        scaling: SizeScaling<Int> = .linear,
        overriding overrides: repeat ReflectiveGenerator<each Override>
    ) -> ReflectiveGenerator<Output> {
        let policy = stateSpace ?? Output.__generatorDescriptor.stateSpace
        let ceiling = maximumDepth ?? Output.__generatorDescriptor.maximumDepth ?? defaultMaximumDepth
        precondition(ceiling >= 0, "Depth must be non-negative")
        return preparedGenerator(
            for: Output.self,
            depth: .drawn(ceiling: ceiling, scaling: depthScaling(scaling)),
            maximumNodes: maximumNodes ?? Output.__generatorDescriptor.maximumNodes,
            stateSpace: policy,
            overrides: overrideTable(repeat each overrides)
        )
    }

    /// Derives a generator with the nesting depth pinned rather than drawn.
    ///
    /// Use this to reproduce a fixed construction budget. Values may terminate earlier; the bound does not require them to reach the requested depth. Reduction operates within that layer rather than lowering a root depth choice. A depth below the type's minimum constructible depth fails a precondition.
    ///
    /// ```swift
    /// let terms = Term.gen(depth: 4, overriding: .int(in: 0 ... 3))
    /// ```
    ///
    /// - Parameters:
    ///   - depth: How many nested structurally derived types a value may contain.
    ///   - maximumNodes: An optional positive structural ceiling. Its allowance still scales with size even though depth is pinned.
    ///   - stateSpace: Overrides the root's payload-domain preset. Numeric bounds, default sequence lengths, and date ranges still scale with size even though depth is pinned.
    ///   - overrides: Generators matched by payload output type, including payloads inside containers.
    /// - Returns: A generator built at the requested depth, with best-effort reflection.
    static func derived<each Override>(
        depth: Int,
        maximumNodes: Int? = nil,
        stateSpace: GeneratorStateSpace? = nil,
        overriding overrides: repeat ReflectiveGenerator<each Override>
    ) -> ReflectiveGenerator<Output> {
        let policy = stateSpace ?? Output.__generatorDescriptor.stateSpace
        precondition(depth >= 0, "Depth must be non-negative")
        return preparedGenerator(
            for: Output.self,
            depth: .pinned(depth),
            maximumNodes: maximumNodes ?? Output.__generatorDescriptor.maximumNodes,
            stateSpace: policy,
            overrides: overrideTable(repeat each overrides)
        )
    }
}

public extension __Exhaustable.Conformance {
    /// Builds the generator derived from this type's `@Exhaustable` annotation.
    ///
    /// This factory is the test-target counterpart to the application type's annotation: `Term.gen()` is available because `Term` was declared with `@Exhaustable`. Pass arguments to customize the derived depth, node ceiling, state space, or payload generators at the use site.
    ///
    /// ```swift
    /// let generator = Term.gen()
    /// let term = try #example(generator)
    /// let configured = Term.gen(maximumDepth: 6, maximumNodes: 128, stateSpace: .small)
    /// let combined = #gen(configured, .bool())
    /// ```
    ///
    /// With no arguments, this uses the annotation's defaults. It is available when importing `ExhaustGenerators` or `Exhaust`; the application's annotated type only needs `Exhaustable`. Use the returned ``ReflectiveGenerator`` directly with `#example` or compose it with `#gen`. Other derived types resolve this type structurally; declaring a custom generator property does not change that resolution. The root depth is a reducible choice that grows with Exhaust's size parameter. Use ``gen(depth:maximumNodes:stateSpace:overriding:)`` to pin it instead. The explicit ceiling overrides the root annotation; nested annotated types retain their own ceilings. A ceiling below the minimum constructible depth, or a type with no finite construction, fails a precondition.
    ///
    /// Overrides match payload types, including elements inside standard containers. They take precedence over structural derivation and built-in defaults. They do not replace the root generator, but can replace occurrences of its type as payloads. Depth bounds do not constrain recursion or filtering inside an override. A node ceiling splits one root allowance among child values and containers; nested ceilings cap the allocated share. Overrides count as one opaque node. See ``ReflectiveGenerator/derived(maximumDepth:maximumNodes:stateSpace:scaling:overriding:)`` for counting, splitting, and reflection details.
    ///
    /// - Parameters:
    ///   - maximumDepth: The root depth ceiling. Defaults to the annotation or 10.
    ///   - maximumNodes: A positive structural node ceiling. Defaults to the annotation or no node limit; its allowance grows linearly with size.
    ///   - stateSpace: Overrides the root's payload-domain preset, which defaults to `.full`. Nested types and containers inherit it, subject to nested annotation caps. Explicit payload overrides keep their own domains.
    ///   - scaling: How the drawn depth scales with the size parameter. Defaults to `.linear`.
    ///   - overrides: Generators matched by payload output type, including payloads inside containers.
    /// - Returns: A generator with a reducible choice of constructible depth and best-effort reflection.
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

    /// Builds the generator derived from this type's `@Exhaustable` annotation at a fixed depth.
    ///
    /// Use this overload when the test needs a fixed derived depth rather than a depth drawn from Exhaust's size parameter.
    ///
    /// ```swift
    /// let generator = Term.gen(depth: 4, overriding: .int(in: 0 ... 3))
    /// let term = try #example(generator)
    /// ```
    ///
    /// Values may terminate before the requested depth. Reduction stays within this layer instead of lowering a root depth choice. An insufficient depth or a type with no finite construction fails a precondition. Payload overrides and nested type ceilings follow ``gen(maximumDepth:maximumNodes:stateSpace:scaling:overriding:)``.
    ///
    /// - Parameters:
    ///   - depth: The root nesting bound, overriding the root annotation's ceiling.
    ///   - maximumNodes: An optional positive structural ceiling. Its allowance still scales with size even though depth is pinned.
    ///   - stateSpace: Overrides the root's payload-domain preset. Numeric bounds, default sequence lengths, and date ranges still scale with size even though depth is pinned.
    ///   - overrides: Generators matched by payload output type, including payloads inside containers.
    /// - Returns: A generator built at the requested depth, with best-effort reflection.
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

/// Keeps resolution, depth, and node-budget diagnostics on one nonthrowing public boundary, with or without a node ceiling.
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
