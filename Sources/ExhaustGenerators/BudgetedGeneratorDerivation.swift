import Exhaustable
import ExhaustCore

/// Builds recursion-limited derivations under a structural-node ceiling. Construction caches include the allocated allowance; sharing generators never replenishes the allowance of a value occurrence. Runtime closures retain completed layers, not this mutable builder.
final class BudgetedGeneratorDerivation {
    let plan: GeneratorDerivationPlan
    let budget: GeneratorNodeBudget
    private(set) var built: [NodeBudgetKey: Any] = [:]
    private(set) var containers: [ContainerBudgetKey: ReflectiveGenerator<Any>] = [:]
    private var countedContainers: [CountedContainerKey: ReflectiveGenerator<Any>] = [:]

    init(plan: GeneratorDerivationPlan) {
        self.plan = plan
        budget = GeneratorNodeBudget(plan: plan)
    }

    /// Validates recursion before node limits so an insufficient recursion retains the plan's specific diagnostic. The 100 size slots reference shared completed generators; repeated allowances do not rebuild the graph.
    func root<Value: __Exhaustable.Conformance>(
        for type: Value.Type,
        recursion: RootRecursionBudget,
        maximumNodes: Int,
        domain: ExhaustableDomain = .full
    ) throws -> ReflectiveGenerator<Value> {
        _ = try plan.minimumRecursionBudget(for: type, at: recursion.ceiling)
        guard maximumNodes > 0 else {
            throw GeneratorDerivationError.invalidNodeBudget(type: String(describing: type), nodes: maximumNodes)
        }
        guard let minimum = budget.minimumNodes(for: ObjectIdentifier(type), recursion: recursion.ceiling) else {
            throw GeneratorDerivationError.noFiniteConstructionWithinNodeBudget(type: String(describing: type), recursion: recursion.ceiling)
        }
        guard minimum <= maximumNodes else {
            throw GeneratorDerivationError.insufficientNodeBudget(
                type: String(describing: type),
                minimum: minimum,
                requested: maximumNodes
            )
        }
        let span = maximumNodes - minimum
        return sizeIndexedLayers(
            // Divide before multiplying so even a ceiling near Int.max cannot overflow.
            key: { size in minimum + (span / 100) * size + ((span % 100) * size) / 100 },
            build: { allowance in
                rootLayer(
                    for: type,
                    recursion: recursion,
                    nodes: allowance,
                    domain: domain
                )
            }
        )
    }

    private func rootLayer<Value: __Exhaustable.Conformance>(
        for type: Value.Type,
        recursion: RootRecursionBudget,
        nodes: Int,
        domain: ExhaustableDomain
    ) -> ReflectiveGenerator<Value> {
        switch recursion {
            case let .pinned(recursion):
                return generator(for: type, recursion: recursion, nodes: nodes, domain: domain)
            case let .drawn(ceiling, scaling):
                guard let minimum = (0 ... ceiling).first(where: { candidate in
                    guard let cost = budget.minimumNodes(for: ObjectIdentifier(type), recursion: candidate) else {
                        return false
                    }
                    return cost <= nodes
                }) else {
                    preconditionFailure("A validated root allowance must admit a recursion at or below its ceiling")
                }
                let layers = (minimum ... ceiling).map { generator(for: type, recursion: $0, nodes: nodes, domain: domain) }
                return Gen.chooseDepth(in: UInt64(minimum) ... UInt64(ceiling), scaling: scaling)._bound(
                    forward: { selected in layers[Int(selected) - minimum].gen.erase() },
                    backward: { (_: Value) in UInt64(ceiling) }
                ).wrapped(isReflective: layers.allSatisfy { $0.isReflective })
        }
    }

    /// Builds one layer as a uniform pick over the constructors that fit its recursive and node allowances.
    ///
    /// Constructors retain fixed weights while recursive fuel is positive. A constructor drops out when a required cycle edge cannot construct its child from the equal share assigned to that edge, or when the node allowance cannot cover its payload minima. At zero fuel, constructors without required cycle edges remain available; recursive containers can still produce their empty value. Only arms that can traverse a cycle receive a lazy boundary, keeping nonrecursive annotated products transparent to screening. Layers are cached by type, recursive fuel, node allowance, and domain.
    func generator<Value: __Exhaustable.Conformance>(
        for type: Value.Type,
        recursion: Int,
        nodes: Int,
        domain: ExhaustableDomain = .full
    ) -> ReflectiveGenerator<Value> {
        let key = NodeBudgetKey(
            type: ObjectIdentifier(type),
            recursion: recursion,
            nodes: nodes,
            domain: domain
        )
        if let existing = built[key] as? ReflectiveGenerator<Value> {
            return existing
        }
        let typePlan = plan.plan(for: key.type)
        let descriptor = Value.__generatorDescriptor
        let arms = typePlan.constructors.enumerated().compactMap { index, entry -> ReflectiveGenerator<Value>? in
            guard let recursionAllowances = plan.recursionAllowances(
                for: entry.payloads,
                from: key.type,
                budget: recursion
            ),
                let minima = budget.minimumNodes(
                    for: entry.payloads,
                    recursionAllowances: recursionAllowances
                )
            else {
                return nil
            }
            guard let nodeAllowances = budget.split(nodes - 1, minima: minima) else {
                return nil
            }
            let children = entry.payloads.indices.map { payloadIndex in
                payloadGenerator(
                    for: entry.payloads[payloadIndex],
                    recursionAllowance: recursionAllowances[payloadIndex],
                    nodes: nodeAllowances[payloadIndex],
                    domain: domain
                )
            }
            return arm(
                descriptor.constructors[index],
                children: children,
                recursive: entry.payloads.contains { plan.recursiveWidth(of: $0, from: key.type) > 0 }
            )
        }
        precondition(arms.isEmpty == false, "The budget plan must supply a constructible case")
        let result = ReflectiveGenerator<Value>.oneOf(
            arms,
            fileID: descriptor.fileID,
            line: descriptor.line,
            column: descriptor.column
        )
        built[key] = result
        return result
    }

    /// Packs a constructor's children, embedding a value per draw rather than reusing one built here.
    ///
    /// A payload-free constructor takes the same path as any other, with no children to zip. Embedding once and replaying that value would hand every draw the same class instance.
    private func arm<Value>(
        _ entry: __Exhaustable.ConstructorDescriptor<Value>,
        children: [ReflectiveGenerator<Any>],
        recursive: Bool
    ) -> ReflectiveGenerator<Value> {
        let result = Gen.zippedReflective(
            ContiguousArray(children.map { $0.gen }),
            pack: { entry.embed($0) },
            unpack: { value in
                guard let payloads = entry.extract(value) else {
                    throw ReflectionError.couldNotMapInputToGenerator
                }
                return payloads
            },
            isReflective: children.allSatisfy { $0.isReflective }
                && (children.isEmpty == false || isPayloadFreeReflectable(Value.self))
        )
        guard recursive else {
            return result
        }
        let deferred = ReflectiveGenerator<Value>.lazy { result }
        return deferred.gen.wrapped(isReflective: result.isReflective)
    }

    private func payloadGenerator(
        for payload: PayloadPlan,
        recursionAllowance: PayloadRecursionAllowance,
        nodes: Int,
        domain: ExhaustableDomain
    ) -> ReflectiveGenerator<Any> {
        switch payload {
            case let .supplied(generator):
                return generator
            case let .standard(type):
                return plan.defaultGenerator(for: type, domain: domain)
            case let .derivedType(reference):
                let child = plan.plan(for: reference)
                let selected = plan.isRecursiveEdge(from: recursionAllowance.source, to: reference)
                    ? recursionAllowance.recursive
                    : recursionAllowance.inherited
                return erasedGenerator(
                    for: child.type,
                    recursion: min(selected, child.budget.recursion),
                    nodes: min(nodes, child.budget.nodes),
                    domain: domain.limited(by: child.domain)
                )
            case let .container(recipe, children):
                return container(
                    recipe,
                    children: children,
                    recursionAllowance: recursionAllowance,
                    nodes: nodes,
                    domain: domain
                )
        }
    }

    /// Chooses cardinality before dividing recursive fuel and node allowance among entries. Dictionary entries reserve shares for both key and value.
    private func container(
        _ recipe: DerivedContainerRecipe,
        children: [PayloadPlan],
        recursionAllowance: PayloadRecursionAllowance,
        nodes: Int,
        domain: ExhaustableDomain
    ) -> ReflectiveGenerator<Any> {
        let key = ContainerBudgetKey(
            type: ObjectIdentifier(recipe.type),
            recursionAllowance: recursionAllowance,
            nodes: nodes,
            domain: domain
        )
        if let existing = containers[key] {
            return existing
        }
        let result = buildContainer(
            recipe,
            children: children,
            recursionAllowance: recursionAllowance,
            nodes: nodes,
            domain: domain
        )
        containers[key] = result
        return result
    }

    /// Retains every node-feasible cardinality for reflection while the domain can narrow which layers sampling selects.
    private func buildContainer(
        _ recipe: DerivedContainerRecipe,
        children: [PayloadPlan],
        recursionAllowance: PayloadRecursionAllowance,
        nodes: Int,
        domain: ExhaustableDomain
    ) -> ReflectiveGenerator<Any> {
        let maximumCountFromNodes = max(0, (nodes - 1) / max(1, children.count))
        let maximumReflectableCount = min(recipe.maximumCount ?? maximumCountFromNodes, maximumCountFromNodes)
        let hasRecursiveRoutes = children.contains {
            plan.recursiveWidth(of: $0, from: recursionAllowance.source) > 0
        }
        let maximumGeneratedCount = switch (hasRecursiveRoutes, recursionAllowance.inherited) {
            case (true, 0): 0
            case _:
                min(
                    domain.defaultSequenceLengthMaximum ?? maximumReflectableCount,
                    maximumReflectableCount
                )
        }
        let maximumBuiltCount = recipe.isReflective ? maximumReflectableCount : maximumGeneratedCount
        if let native = buildNativeContainer(
            recipe,
            children: children,
            recursionAllowance: recursionAllowance,
            domain: domain,
            maximumGeneratedCount: maximumGeneratedCount,
            maximumBuiltCount: maximumBuiltCount
        ) {
            return native
        }
        return buildLayeredContainer(
            recipe,
            children: children,
            recursionAllowance: recursionAllowance,
            nodes: nodes,
            domain: domain,
            maximumGeneratedCount: maximumGeneratedCount,
            maximumBuiltCount: maximumBuiltCount
        )
    }

    /// Uses a native sequence only when every child ignores per-entry recursive and node allowances, exposing element parameters without a count bind.
    private func buildNativeContainer(
        _ recipe: DerivedContainerRecipe,
        children: [PayloadPlan],
        recursionAllowance: PayloadRecursionAllowance,
        domain: ExhaustableDomain,
        maximumGeneratedCount: Int,
        maximumBuiltCount: Int
    ) -> ReflectiveGenerator<Any>? {
        guard maximumBuiltCount > 0,
              recipe.maximumCount == nil,
              children.allSatisfy({ payload in
                  switch payload {
                      case .supplied, .standard: true
                      case .derivedType, .container: false
                  }
              })
        else {
            return nil
        }
        let generators = children.map {
            payloadGenerator(
                for: $0,
                recursionAllowance: recursionAllowance,
                nodes: 1,
                domain: domain
            )
        }
        return recipe.build(
            .bounded(sampling: maximumGeneratedCount, reflecting: maximumBuiltCount),
            generators.map { $0.gen }
        ).wrapped(isReflective: recipe.isReflective && generators.allSatisfy { $0.isReflective })
    }

    /// Shares completed count-specific layers by their exact recursive and node allowances. Reflection can retain more layers than sampling selects.
    private func buildLayeredContainer(
        _ recipe: DerivedContainerRecipe,
        children: [PayloadPlan],
        recursionAllowance: PayloadRecursionAllowance,
        nodes: Int,
        domain: ExhaustableDomain,
        maximumGeneratedCount: Int,
        maximumBuiltCount: Int
    ) -> ReflectiveGenerator<Any> {
        var layers = [recipe.empty.wrapped(isReflective: true)]
        for elementIndex in 0 ..< maximumBuiltCount {
            let elementCount = elementIndex + 1
            let entryRecursionAllowance = PayloadRecursionAllowance(
                source: recursionAllowance.source,
                inherited: recursionAllowance.inherited,
                recursive: recursionAllowance.recursive / elementCount
            )
            let recursionAllowances = Array(repeating: entryRecursionAllowance, count: children.count)
            guard let minima = budget.minimumNodes(
                for: children,
                recursionAllowances: recursionAllowances
            ),
                let nodeAllowances = budget.split((nodes - 1) / elementCount, minima: minima)
            else {
                break
            }
            let key = CountedContainerKey(
                type: ObjectIdentifier(recipe.type),
                count: elementCount,
                recursionAllowance: entryRecursionAllowance,
                nodeAllowances: nodeAllowances,
                domain: domain
            )
            switch countedContainers[key] {
                case let .some(existing):
                    layers.append(existing)
                    continue
                case .none:
                    break
            }
            let generators = children.indices.map { childIndex in
                payloadGenerator(
                    for: children[childIndex],
                    recursionAllowance: recursionAllowances[childIndex],
                    nodes: nodeAllowances[childIndex],
                    domain: domain
                )
            }
            let layer = recipe.build(.exactly(elementCount), generators.map { $0.gen }).wrapped(
                isReflective: recipe.isReflective && generators.allSatisfy { $0.isReflective }
            )
            countedContainers[key] = layer
            layers.append(layer)
        }
        let builtMaximum = layers.count - 1
        let sampledMaximum = min(maximumGeneratedCount, builtMaximum)
        return recipe.selectCount(sampledMaximum, layers.map { $0.gen }).wrapped(
            isReflective: layers.allSatisfy { $0.isReflective }
        )
    }

    private func erasedGenerator(
        for type: (some __Exhaustable.Conformance).Type,
        recursion: Int,
        nodes: Int,
        domain: ExhaustableDomain
    ) -> ReflectiveGenerator<Any> {
        generator(for: type, recursion: recursion, nodes: nodes, domain: domain).erasedForDerivation()
    }
}

/// Couples recursion scaling to a drawn root, so a pinned root never carries an unused scaling policy.
enum RootRecursionBudget {
    /// Builds one recursion layer without recording a root recursion choice.
    case pinned(Int)

    /// Records a reducible recursion choice from the minimum feasible layer through the ceiling.
    case drawn(ceiling: Int, scaling: SizeScaling<UInt64>)

    /// Supplies the full-size recursion for validation and minimum-node analysis in either mode.
    var ceiling: Int {
        switch self {
            case let .pinned(recursion):
                recursion
            case let .drawn(ceiling, _):
                ceiling
        }
    }
}

/// Separates layers that share a type and recursion but have different structural allowances or numeric domains.
struct NodeBudgetKey: Hashable {
    let type: ObjectIdentifier
    let recursion: Int
    let nodes: Int
    let domain: ExhaustableDomain
}

/// Separates container layers reached from different recursive components and allowance shares.
struct ContainerBudgetKey: Hashable {
    let type: ObjectIdentifier
    let recursionAllowance: PayloadRecursionAllowance
    let nodes: Int
    let domain: ExhaustableDomain
}

/// Shares identical counted recipes across different enclosing container allowances without rounding either budget.
private struct CountedContainerKey: Hashable {
    let type: ObjectIdentifier
    let count: Int
    let recursionAllowance: PayloadRecursionAllowance
    let nodeAllowances: [Int]
    let domain: ExhaustableDomain
}

// MARK: - Helpers

/// Reports whether reflection can recognize a value a payload-free constructor rebuilds.
///
/// Reflection picks an arm by comparing the value it rebuilt against the target, and a rebuild produces a fresh instance. A payload-free class carries nothing to compare: `Mirror` exposes no children, so the two instances match only if the type's own `==` ignores identity, which is not knowable here. An `Equatable` conformance is not enough of an answer, because an identity-based `==` would claim reflection this arm cannot deliver. Structs and enum cases compare by shape or case name and stay reflectable.
///
/// Decided from the metatype: asking an instance would mean constructing and discarding one before any sample is drawn, which a `deinit` observes.
private func isPayloadFreeReflectable(_ type: (some Any).Type) -> Bool {
    type is AnyClass == false
}
