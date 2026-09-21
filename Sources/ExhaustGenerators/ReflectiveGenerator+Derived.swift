import Exhaustable
import ExhaustCore

package extension ReflectiveGenerator where Output: __Exhaustable.Conformance {
    /// Builds a size-ramped derivation from root settings.
    static func derived<each Override>(
        _ settings: ExhaustableSettings...,
        scaling: SizeScaling<Int> = .linear,
        overriding overrides: repeat ReflectiveGenerator<each Override>
    ) -> ReflectiveGenerator<Output> {
        resolvedDerived(
            for: Output.self,
            settings: settings,
            rootRecursion: drawnRootRecursion(scaling: scaling),
            overriding: repeat each overrides
        )
    }

    /// Builds a derivation with fixed recursive fuel from root settings.
    static func derived<each Override>(
        recursion: Int,
        _ settings: ExhaustableSettings...,
        overriding overrides: repeat ReflectiveGenerator<each Override>
    ) -> ReflectiveGenerator<Output> {
        resolvedDerived(
            for: Output.self,
            settings: settings,
            rootRecursion: pinnedRootRecursion(recursion),
            overriding: repeat each overrides
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
    ///     .budget(.custom(recursion: 8, nodes: 80)),
    ///     .domain(.small),
    ///     overriding: .int(in: 0 ... 9)
    /// )
    /// ```
    ///
    /// With no settings, `gen()` uses the annotation's budget and domain. Root settings replace the corresponding annotation setting, while nested annotated types retain their own ceilings.
    ///
    /// Recursive fuel grows with Exhaust's size parameter and is divided among payload edges that participate in a type cycle. Constructors keep fixed weights while fuel remains, and constructors that can terminate without crossing a cycle remain available at zero. The node ceiling counts annotated values, standard containers, and opaque payloads; it does not bound memory or work inside an override. The domain controls default numeric magnitudes, collection lengths, and date ranges.
    ///
    /// Overrides match payload types, including occurrences inside standard containers. They replace built-in or derived payload generators but do not replace the root generator. Sets, dictionaries, and forward-only overrides can disable reflection.
    ///
    /// - Parameters:
    ///   - settings: Root budget and domain settings. The last occurrence of each setting wins.
    ///   - scaling: How recursive fuel grows with Exhaust's size parameter. Defaults to `.linear`.
    ///   - overrides: Generators matched to payload types.
    /// - Returns: A derived generator for this type.
    static func gen<each Override>(
        _ settings: ExhaustableSettings...,
        scaling: SizeScaling<Int> = .linear,
        overriding overrides: repeat ReflectiveGenerator<each Override>
    ) -> ReflectiveGenerator<Self> {
        resolvedDerived(
            for: Self.self,
            settings: settings,
            rootRecursion: drawnRootRecursion(scaling: scaling),
            overriding: repeat each overrides
        )
    }

    /// Builds the derived generator with fixed recursive fuel.
    ///
    /// ```swift
    /// let terms = Term.gen(
    ///     recursion: 4,
    ///     .domain(.small),
    ///     overriding: .int(in: 0 ... 3)
    /// )
    /// ```
    ///
    /// Unlike ``gen(_:scaling:overriding:)``, this overload does not draw or reduce a root recursive-budget choice. Constructor choices can still terminate before spending all available fuel.
    ///
    /// - Parameters:
    ///   - recursion: The fixed recursive fuel at the root.
    ///   - settings: Root budget and domain settings. A budget setting supplies the node ceiling; its recursive value is ignored.
    ///   - overrides: Generators matched to payload types.
    /// - Returns: A derived generator with fixed recursive fuel.
    static func gen<each Override>(
        recursion: Int,
        _ settings: ExhaustableSettings...,
        overriding overrides: repeat ReflectiveGenerator<each Override>
    ) -> ReflectiveGenerator<Self> {
        resolvedDerived(
            for: Self.self,
            settings: settings,
            rootRecursion: pinnedRootRecursion(recursion),
            overriding: repeat each overrides
        )
    }
}

// MARK: - Helpers

private func resolvedDerived<Value: __Exhaustable.Conformance, each Override>(
    for type: Value.Type,
    settings: [ExhaustableSettings],
    rootRecursion: (ExhaustableBudget) -> RootRecursionBudget,
    overriding overrides: repeat ReflectiveGenerator<each Override>
) -> ReflectiveGenerator<Value> {
    let descriptor = type.__generatorDescriptor
    let resolved = ResolvedExhaustableSettings(
        settings,
        budget: descriptor.budget,
        domain: descriptor.domain
    )
    return preparedGenerator(
        for: type,
        recursion: rootRecursion(resolved.budget),
        maximumNodes: resolved.budget.nodes,
        domain: resolved.domain,
        overrides: overrideTable(repeat each overrides)
    )
}

/// Builds the root policy that draws recursive fuel from the resolved budget.
private func drawnRootRecursion(
    scaling: SizeScaling<Int>
) -> (ExhaustableBudget) -> RootRecursionBudget {
    let erasedScaling = recursionScaling(scaling)
    return { budget in
        .drawn(ceiling: budget.recursion, scaling: erasedScaling)
    }
}

/// Builds the root policy that ignores the resolved recursive-fuel ceiling.
private func pinnedRootRecursion(
    _ recursion: Int
) -> (ExhaustableBudget) -> RootRecursionBudget {
    precondition(recursion >= 0, "Recursive fuel must be nonnegative")
    return { _ in .pinned(recursion) }
}

/// Returns the completed derivation for these arguments, building it on first request.
///
/// Building one costs several times what a whole property run draws from it, and the result is a pure function of the arguments below: a type's annotation is one declaration, so the same request always yields the same generator. A test file calling `T.gen(...)` once per test would otherwise pay that construction each time.
///
/// A request carrying `overriding:` is built every time. Generators are not `Hashable`, so an override cannot join the key, and treating two override sets as interchangeable would hand back a generator built from the wrong ones.
private func preparedGenerator<Value: __Exhaustable.Conformance>(
    for type: Value.Type,
    recursion: RootRecursionBudget,
    maximumNodes: Int,
    domain: ExhaustableDomain,
    overrides: [ObjectIdentifier: ReflectiveGenerator<Any>]
) -> ReflectiveGenerator<Value> {
    guard overrides.isEmpty else {
        return builtGenerator(
            for: type,
            recursion: recursion,
            maximumNodes: maximumNodes,
            domain: domain,
            overrides: overrides
        )
    }
    let key = DerivedGeneratorKey(
        type: ObjectIdentifier(type),
        recursion: RecursionKey(recursion),
        maximumNodes: maximumNodes,
        domain: domain
    )
    if let cached = derivedGenerators.withValue({ $0[key] }) as? ReflectiveGenerator<Value> {
        return cached
    }
    let generator = sharedBuilder(for: type).withValue { builder in
        rootGenerator(from: builder, for: type, recursion: recursion, maximumNodes: maximumNodes, domain: domain)
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
/// A builder caches its layers by type, recursive fuel, node allowance, and domain, so two requests that differ only in those share every layer they have in common. Building twenty node ceilings through separate builders cost 5003ms against 378ms through one.
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
    requiring { try GeneratorDerivationPlan(for: type, overrides: [:]) }
}

/// Builds one root layer set through an existing builder, reusing whatever layers it already holds.
private func rootGenerator<Value: __Exhaustable.Conformance>(
    from builder: BudgetedGeneratorDerivation,
    for type: Value.Type,
    recursion: RootRecursionBudget,
    maximumNodes: Int,
    domain: ExhaustableDomain
) -> ReflectiveGenerator<Value> {
    requiring { try builder.root(for: type, recursion: recursion, maximumNodes: maximumNodes, domain: domain) }
}

/// Builds a derivation that cannot be shared, because its overrides are part of what it produces. Keeps resolution, recursion, and node-budget diagnostics on one nonthrowing boundary, so a caller of `gen(...)` sees a precondition failure rather than an error to handle.
private func builtGenerator<Value: __Exhaustable.Conformance>(
    for type: Value.Type,
    recursion: RootRecursionBudget,
    maximumNodes: Int,
    domain: ExhaustableDomain,
    overrides: [ObjectIdentifier: ReflectiveGenerator<Any>]
) -> ReflectiveGenerator<Value> {
    requiring {
        let plan = try GeneratorDerivationPlan(for: type, overrides: overrides)
        return try BudgetedGeneratorDerivation(plan: plan).root(
            for: type,
            recursion: recursion,
            maximumNodes: maximumNodes,
            domain: domain
        )
    }
}

/// Keeps structural derivation errors at the nonthrowing generator API boundary, with the original diagnostic as the precondition message.
private func requiring<Value>(_ work: () throws -> Value) -> Value {
    do {
        return try work()
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
    let recursion: RecursionKey
    let maximumNodes: Int
    let domain: ExhaustableDomain
}

/// Mirrors ``RootRecursionBudget`` as a value that can key a dictionary.
private enum RecursionKey: Hashable, Sendable {
    case pinned(Int)
    case drawn(ceiling: Int, scaling: ScalingKey)

    init(_ recursion: RootRecursionBudget) {
        switch recursion {
            case let .pinned(recursion):
                self = .pinned(recursion)
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

/// Converts the public signed scaling to the unsigned representation used by recursion controls. Negative origins clamp to zero, which has the same effect as clamping them into the nonnegative recursion range.
private func recursionScaling(_ scaling: SizeScaling<Int>) -> SizeScaling<UInt64> {
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
