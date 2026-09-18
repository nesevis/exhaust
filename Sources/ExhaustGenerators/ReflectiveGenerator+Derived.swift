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

/// Returns the completed derivation for these arguments, building it on first request.
///
/// Building one costs several times what a whole property run draws from it, and the result is a pure function of the arguments below: a type's annotation is one declaration, so the same request always yields the same generator. A test file calling `T.gen(...)` once per test would otherwise pay that construction each time.
///
/// A request carrying `overriding:` is built every time. Generators are not `Hashable`, so an override cannot join the key, and treating two override sets as interchangeable would hand back a generator built from the wrong ones.
private func preparedGenerator<Value: __Exhaustable.Conformance>(
    for type: Value.Type,
    depth: RootDepth,
    maximumNodes: Int?,
    stateSpace: GeneratorStateSpace,
    overrides: [ObjectIdentifier: ReflectiveGenerator<Any>]
) -> ReflectiveGenerator<Value> {
    guard overrides.isEmpty else {
        return builtGenerator(
            for: type,
            depth: depth,
            maximumNodes: maximumNodes,
            stateSpace: stateSpace,
            overrides: overrides
        )
    }
    let key = DerivedGeneratorKey(
        type: ObjectIdentifier(type),
        depth: DepthKey(depth),
        maximumNodes: maximumNodes,
        stateSpace: stateSpace
    )
    if let cached = derivedGenerators.withValue({ $0[key] }) as? ReflectiveGenerator<Value> {
        return cached
    }
    let generator = sharedBuilder(for: type).withValue { builder in
        rootGenerator(from: builder, for: type, depth: depth, maximumNodes: maximumNodes, stateSpace: stateSpace)
    }
    derivedGenerators.withValue { generators in
        generators[key] = generator
        guard generators.count > maximumCachedDerivations else {
            return
        }
        generators.removeAll()
        derivationBuilders.withValue { $0.removeAll() }
    }
    return generator
}

/// How many completed derivations both caches hold before they are emptied.
///
/// A cached derivation retains the whole layer graph behind it, and its builder retains every layer built for that type, so neither cache can be bounded without the other: releasing a generator while its builder still holds its layers frees nothing. A workload that sweeps node ceilings or scaling origins reaches a new key every call and would otherwise accumulate a layer graph per call for the life of the process.
///
/// Emptying wholesale rather than evicting by age is deliberate. A miss costs a rebuild and nothing more, and a workload that trips this ceiling is one whose requests do not repeat, where no eviction order would have kept the right entries. A suite whose requests do repeat settles far below it.
private let maximumCachedDerivations = 256

/// The builder this type's derivations go through, created on first request.
///
/// A builder caches its layers by type, depth, node allowance, and state space, so two requests that differ only in those share every layer they have in common. Building twenty node ceilings through separate builders cost 5003ms against 378ms through one.
///
/// Each type gets its own box, so the build below is serialized only against other requests for the same type, where it saves duplicated work, and never against an unrelated type. That matters under a parallel test runner, where many tests reach a cold cache at once: without it they each build their own copy of the same generator.
private func sharedBuilder(for type: (some __Exhaustable.Conformance).Type) -> SendableBox<BudgetedGeneratorDerivation> {
    let reference = ObjectIdentifier(type)
    if let existing = derivationBuilders.withValue({ $0[reference] }) {
        return existing
    }
    // Resolved outside the lock; another thread may insert one meanwhile, and the check below keeps whichever landed first so a type never has two builders.
    let candidate = SendableBox(BudgetedGeneratorDerivation(plan: resolvedPlan(for: type)))
    return derivationBuilders.withValue { builders in
        if let existing = builders[reference] {
            return existing
        }
        builders[reference] = candidate
        return candidate
    }
}

/// Resolves the dependency graph for a type with no overrides, turning a structural failure into a precondition the way `gen(...)` does.
private func resolvedPlan(for type: (some __Exhaustable.Conformance).Type) -> GeneratorDerivationPlan {
    do {
        return try GeneratorDerivationPlan(for: type, overrides: [:])
    } catch {
        preconditionFailure(String(describing: error))
    }
}

/// Builds one root layer set through an existing builder, reusing whatever layers it already holds.
private func rootGenerator<Value: __Exhaustable.Conformance>(
    from builder: BudgetedGeneratorDerivation,
    for type: Value.Type,
    depth: RootDepth,
    maximumNodes: Int?,
    stateSpace: GeneratorStateSpace
) -> ReflectiveGenerator<Value> {
    do {
        return try builder.root(for: type, depth: depth, maximumNodes: maximumNodes, stateSpace: stateSpace)
    } catch {
        preconditionFailure(String(describing: error))
    }
}

/// Builds a derivation that cannot be shared, because its overrides are part of what it produces. Keeps resolution, depth, and node-budget diagnostics on one nonthrowing boundary, so a caller of `gen(...)` sees a precondition failure rather than an error to handle.
private func builtGenerator<Value: __Exhaustable.Conformance>(
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

/// Builders by annotated type, shared across every request for that type that carried no overrides. Emptied alongside ``derivedGenerators``, because a builder holds every layer built for its type.
private let derivationBuilders = SendableBox<[ObjectIdentifier: SendableBox<BudgetedGeneratorDerivation>]>([:])

/// Completed derivations for every request that carried no overrides, bounded by ``maximumCachedDerivations``.
private let derivedGenerators = SendableBox<[DerivedGeneratorKey: Any]>([:])

/// Everything that shapes a derivation, so two requests share a generator only when they would have built the same one.
///
/// The metatype rather than a type name: Swift gives one metatype per type in a process, so it separates `Box<Int>` from `Box<String>` for a pointer compare, and it is the identity the derivation plan keys on everywhere else.
private struct DerivedGeneratorKey: Hashable, Sendable {
    let type: ObjectIdentifier
    let depth: DepthKey
    let maximumNodes: Int?
    let stateSpace: GeneratorStateSpace
}

/// Mirrors ``RootDepth`` as a value that can key a dictionary.
private enum DepthKey: Hashable, Sendable {
    case pinned(Int)
    case drawn(ceiling: Int, scaling: ScalingKey)

    init(_ depth: RootDepth) {
        switch depth {
            case let .pinned(depth):
                self = .pinned(depth)
            case let .drawn(ceiling, scaling):
                self = .drawn(ceiling: ceiling, scaling: ScalingKey(scaling))
        }
    }
}

/// Mirrors ``SizeScaling`` as a value that can key a dictionary, rather than adding a conformance to a public type whose shape is settled. A new case there stops this initializer compiling, which is where the omission should surface.
private enum ScalingKey: Hashable, Sendable {
    case constant
    case linear
    case linearFrom(UInt64)
    case exponential
    case exponentialFrom(UInt64)

    init(_ scaling: SizeScaling<UInt64>) {
        switch scaling {
            case .constant:
                self = .constant
            case .linear:
                self = .linear
            case let .linearFrom(origin):
                self = .linearFrom(origin)
            case .exponential:
                self = .exponential
            case let .exponentialFrom(origin):
                self = .exponentialFrom(origin)
        }
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
