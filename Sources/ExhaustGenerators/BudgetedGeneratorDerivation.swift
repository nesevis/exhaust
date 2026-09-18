import Exhaustable
import ExhaustCore

/// Builds depth-limited derivations with an optional node allowance. A nil allowance retains ordinary container cardinalities while nested annotations can still impose a ceiling. Construction caches include the allocated allowance; sharing generators never replenishes the allowance of a value occurrence. Runtime closures retain completed layers, not this mutable builder.
final class BudgetedGeneratorDerivation {
    let plan: GeneratorDerivationPlan
    let budget: GeneratorNodeBudget
    private(set) var built: [NodeBudgetKey: Any] = [:]
    private(set) var containers: [NodeBudgetKey: ReflectiveGenerator<Any>] = [:]
    private var countedContainers: [CountedContainerKey: ReflectiveGenerator<Any>] = [:]

    init(plan: GeneratorDerivationPlan) {
        self.plan = plan
        budget = GeneratorNodeBudget(plan: plan)
    }

    /// Validates depth before node limits so an insufficient depth retains the plan's specific diagnostic. With a node ceiling, the 100 size slots reference shared completed generators; repeated allowances do not rebuild the graph.
    func root<Value: __Exhaustable.Conformance>(
        for type: Value.Type,
        depth: RootDepth,
        maximumNodes: Int?,
        stateSpace: GeneratorStateSpace = .full
    ) throws -> ReflectiveGenerator<Value> {
        _ = try plan.minimumDepth(for: type, at: depth.ceiling)
        if let maximumNodes, maximumNodes <= 0 {
            throw GeneratorDerivationError.invalidMaximumNodes(type: String(describing: type), nodes: maximumNodes)
        }
        guard let minimum = budget.minimumNodes(for: ObjectIdentifier(type), depth: depth.ceiling) else {
            throw GeneratorDerivationError.noFiniteConstructionWithinNodeLimits(type: String(describing: type), depth: depth.ceiling)
        }
        guard let maximumNodes else {
            return rootLayer(
                for: type,
                depth: depth,
                nodes: nil,
                stateSpace: stateSpace
            )
        }
        guard minimum <= maximumNodes else {
            throw GeneratorDerivationError.insufficientNodes(
                type: String(describing: type),
                minimum: minimum,
                requested: maximumNodes
            )
        }
        let span = maximumNodes - minimum
        return sizeIndexedLayers(
            // Divide before multiplying so even a ceiling near Int.max cannot overflow.
            key: { size in quantisedAllowance(minimum + (span / 100) * size + ((span % 100) * size) / 100, notBelow: minimum) },
            build: { allowance in
                rootLayer(
                    for: type,
                    depth: depth,
                    nodes: allowance,
                    stateSpace: stateSpace
                )
            }
        )
    }

    private func rootLayer<Value: __Exhaustable.Conformance>(
        for type: Value.Type,
        depth: RootDepth,
        nodes: Int?,
        stateSpace: GeneratorStateSpace
    ) -> ReflectiveGenerator<Value> {
        switch depth {
            case let .pinned(depth):
                return generator(for: type, depth: depth, nodes: nodes, stateSpace: stateSpace)
            case let .drawn(ceiling, scaling):
                let minimum = (0 ... ceiling).first { candidate in
                    guard let cost = budget.minimumNodes(for: ObjectIdentifier(type), depth: candidate) else {
                        return false
                    }
                    return nodes.map { cost <= $0 } ?? true
                }!
                let layers = (minimum ... ceiling).map { generator(for: type, depth: $0, nodes: nodes, stateSpace: stateSpace) }
                return Gen.chooseDepth(in: UInt64(minimum) ... UInt64(ceiling), scaling: scaling)._bound(
                    forward: { selected in layers[Int(selected) - minimum].gen.erase() },
                    backward: { (_: Value) in UInt64(ceiling) }
                ).wrapped(isReflective: layers.allSatisfy { $0.isReflective })
        }
    }

    /// Builds one layer: a uniform pick over the constructors that fit this depth and allowance.
    ///
    /// A constructor drops out when any payload is unconstructible here, or when the allowance cannot cover its children's minima. At depth zero a type with payload-free cases offers only those, so recursion terminates on a case that carries no structure rather than on whichever payload happens to bottom out. Arms whose payloads reach another derived type are wrapped in `lazy`, which keeps the recursive layer from being constructed while this one is still being built. Layers are cached by type, depth, allowance, and state space, so a shared child generator is built once and reused wherever those four agree.
    func generator<Value: __Exhaustable.Conformance>(
        for type: Value.Type,
        depth: Int,
        nodes: Int?,
        stateSpace: GeneratorStateSpace = .full
    ) -> ReflectiveGenerator<Value> {
        let key = NodeBudgetKey(type: ObjectIdentifier(type), depth: depth, nodes: nodes, stateSpace: stateSpace)
        if let existing = built[key] as? ReflectiveGenerator<Value> {
            return existing
        }
        let typePlan = plan.types[key.type]!
        let descriptor = Value.__generatorDescriptor
        let preferPayloadFree = depth == 0 && typePlan.constructors.contains { $0.payloads.isEmpty }
        let arms = typePlan.constructors.enumerated().compactMap { index, entry -> ReflectiveGenerator<Value>? in
            guard preferPayloadFree == false || entry.payloads.isEmpty,
                  let minima = budget.minimumNodes(for: entry.payloads, depth: depth)
            else {
                return nil
            }
            let allowances: [Int?] = switch nodes {
                case let .some(limit):
                    budget.split(limit - 1, minima: minima)?.map(Optional.some) ?? []
                case .none:
                    Array(repeating: nil, count: minima.count)
            }
            guard allowances.count == entry.payloads.count else {
                return nil
            }
            let children = zip(entry.payloads, allowances).map {
                payloadGenerator(for: $0, depth: depth, nodes: $1, stateSpace: stateSpace)
            }
            return arm(
                descriptor.constructors[index],
                children: children,
                recursive: entry.payloads.contains { $0.containsDerivedType }
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

    private func arm<Value>(
        _ entry: __Exhaustable.ConstructorDescriptor<Value>,
        children: [ReflectiveGenerator<Any>],
        recursive: Bool
    ) -> ReflectiveGenerator<Value> {
        if children.isEmpty {
            return Gen.contramap(
                { (value: Value) throws -> Value in
                    guard entry.extract(value) != nil else {
                        throw ReflectionError.couldNotMapInputToGenerator
                    }
                    return value
                },
                Gen.just(entry.embed([]))
            ).wrapped(isReflective: true)
        }
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
        )
        guard recursive else {
            return result
        }
        let deferred = ReflectiveGenerator<Value>.lazy { result }
        return deferred.gen.wrapped(isReflective: result.isReflective)
    }

    private func payloadGenerator(
        for payload: PayloadPlan,
        depth: Int,
        nodes: Int?,
        stateSpace: GeneratorStateSpace
    ) -> ReflectiveGenerator<Any> {
        switch payload {
            case let .supplied(generator):
                return generator
            case let .standard(type):
                return plan.defaultGenerator(for: type, stateSpace: stateSpace)
            case let .derivedType(reference):
                let child = plan.types[reference]!
                let remaining = child.maximumDepth.map { min($0, depth - 1) } ?? (depth - 1)
                return erasedGenerator(
                    for: child.type,
                    depth: remaining,
                    nodes: capped(nodes, at: child.maximumNodes),
                    stateSpace: stateSpace.limited(by: child.stateSpace)
                )
            case let .container(recipe, children):
                return container(recipe, children: children, depth: depth, nodes: nodes, stateSpace: stateSpace)
        }
    }

    /// Chooses cardinality before assigning the per-entry allowance. Every occurrence is charged even when it uses a shared child generator. Dictionary entries reserve costs for both key and value.
    private func container(
        _ recipe: DerivedContainerRecipe,
        children: [PayloadPlan],
        depth: Int,
        nodes: Int?,
        stateSpace: GeneratorStateSpace
    ) -> ReflectiveGenerator<Any> {
        let key = NodeBudgetKey(type: ObjectIdentifier(recipe.type), depth: depth, nodes: nodes, stateSpace: stateSpace)
        if let existing = containers[key] {
            return existing
        }
        let result = buildContainer(recipe, children: children, depth: depth, nodes: nodes, stateSpace: stateSpace)
        containers[key] = result
        return result
    }

    /// Preserves the built-in container choice under `.full` when there is no node allowance. State spaces cap sampling, while budgeted reflective containers retain every node-feasible layer and empty-only layers keep their reflection path.
    private func buildContainer(
        _ recipe: DerivedContainerRecipe,
        children: [PayloadPlan],
        depth: Int,
        nodes: Int?,
        stateSpace: GeneratorStateSpace
    ) -> ReflectiveGenerator<Any> {
        let minima = budget.minimumNodes(for: children, depth: depth)
        guard let nodes else {
            guard let minima, sumNodes(minima) != nil else {
                return recipe.empty.wrapped(isReflective: true)
            }
            let generators = children.map { payloadGenerator(for: $0, depth: depth, nodes: nil, stateSpace: stateSpace) }
            let cardinality: ContainerCardinality = stateSpace.defaultSequenceLengthMaximum
                .map { .within(min($0, recipe.maximumCount ?? $0)) } ?? .sizeScaled
            return recipe.build(cardinality, generators.map { $0.gen }).wrapped(
                isReflective: recipe.isReflective && generators.allSatisfy { $0.isReflective }
            )
        }
        var layers = [recipe.empty.wrapped(isReflective: true)]
        var maximumGeneratedCount = 0
        if let minima, let minimum = sumNodes(minima) {
            let maximumReflectableCount = min(
                recipe.maximumCount ?? Int.max,
                (nodes - 1) / minimum
            )
            maximumGeneratedCount = min(
                stateSpace.defaultSequenceLengthMaximum ?? maximumReflectableCount,
                maximumReflectableCount
            )
            let maximumBuiltCount = switch recipe.isReflective {
                case true: maximumReflectableCount
                case false: maximumGeneratedCount
            }
            for count in 0 ..< maximumBuiltCount {
                let elementCount = count + 1
                let allowances = budget.split(quantisedAllowance((nodes - 1) / elementCount, notBelow: minimum), minima: minima)!
                let key = CountedContainerKey(
                    type: ObjectIdentifier(recipe.type),
                    count: elementCount,
                    depth: depth,
                    allowances: allowances,
                    stateSpace: stateSpace
                )
                switch countedContainers[key] {
                    case let .some(existing):
                        layers.append(existing)
                        continue
                    case .none:
                        break
                }
                let generators = zip(children, allowances).map { payloadGenerator(for: $0, depth: depth, nodes: $1, stateSpace: stateSpace) }
                let layer = recipe.build(.exactly(elementCount), generators.map { $0.gen }).wrapped(
                    isReflective: recipe.isReflective && generators.allSatisfy { $0.isReflective }
                )
                countedContainers[key] = layer
                layers.append(layer)
            }
        }
        return recipe.selectCount(maximumGeneratedCount, layers.map { $0.gen }).wrapped(
            isReflective: layers.allSatisfy { $0.isReflective }
        )
    }

    private func erasedGenerator(
        for type: (some __Exhaustable.Conformance).Type,
        depth: Int,
        nodes: Int?,
        stateSpace: GeneratorStateSpace
    ) -> ReflectiveGenerator<Any> {
        generator(for: type, depth: depth, nodes: nodes, stateSpace: stateSpace).erasedForDerivation()
    }
}

/// Couples depth scaling to a drawn root, so a pinned root never carries an unused scaling policy.
enum RootDepth {
    /// Builds one depth layer without recording a root depth choice.
    case pinned(Int)

    /// Records a reducible depth choice from the minimum feasible layer through the ceiling.
    case drawn(ceiling: Int, scaling: SizeScaling<UInt64>)

    /// Supplies the full-size depth for validation and minimum-node analysis in either mode.
    var ceiling: Int {
        switch self {
            case let .pinned(depth):
                depth
            case let .drawn(ceiling, _):
                ceiling
        }
    }
}

/// Separates layers that share a type and depth but have different structural allowances or numeric domains.
struct NodeBudgetKey: Hashable {
    let type: ObjectIdentifier
    let depth: Int
    let nodes: Int?
    let stateSpace: GeneratorStateSpace
}

/// Shares identical counted recipes across different enclosing container allowances without rounding either budget.
private struct CountedContainerKey: Hashable {
    let type: ObjectIdentifier
    let count: Int
    let depth: Int
    let allowances: [Int]
    let stateSpace: GeneratorStateSpace
}

// MARK: - Helpers

private func capped(_ allowance: Int?, at ceiling: Int?) -> Int? {
    [allowance, ceiling].compactMap { $0 }.min()
}
