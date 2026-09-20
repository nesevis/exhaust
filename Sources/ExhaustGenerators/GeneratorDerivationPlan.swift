import Exhaustable
import ExhaustCore

/// Records the resolver's decision once, so construction and recursive-fuel analysis follow the same dependencies.
indirect enum PayloadPlan {
    /// An `overriding:` generator, which wins over every other resolution and stays opaque to recursive-fuel and node analysis.
    case supplied(ReflectiveGenerator<Any>)

    /// A built-in leaf from Exhaust's catalogue of standard-library and Foundation generators. The domain selects its domain, so one type can back several completed leaves.
    case standard(any DefaultGenerable.Type)

    /// Another annotated type, named by identifier rather than by node so recursive and mutually recursive edges close without placeholders. Crossing this edge consumes fuel only when the edge stays in the current recursive component.
    case derivedType(ObjectIdentifier)

    /// A standard container whose children resolve through the same rules. The container terminates at its empty value, so it never blocks a construction even when no child fits.
    case container(DerivedContainerRecipe, children: [PayloadPlan])

    /// Keeps a bind boundary for every derived-type dependency, including those inside containers and those outside a recursive cycle.
    var containsDerivedType: Bool {
        switch self {
            case .supplied, .standard:
                false
            case .derivedType:
                true
            case let .container(_, children):
                children.contains { $0.containsDerivedType }
        }
    }

    /// Reports whether this payload crosses directly into another annotated type.
    var isDirectDerivedType: Bool {
        guard case .derivedType = self else {
            return false
        }
        return true
    }

    /// Visits every annotated type reachable through this payload without crossing another constructor boundary.
    func appendDerivedReferences(to references: inout [ObjectIdentifier]) {
        switch self {
            case .supplied, .standard:
                break
            case let .derivedType(reference):
                references.append(reference)
            case let .container(_, children):
                for child in children {
                    child.appendDerivedReferences(to: &references)
                }
        }
    }
}

/// Keeps payloads in declaration order; the matching constructor descriptor supplies the typed embed and extract closures.
struct ConstructorPlan {
    let payloads: [PayloadPlan]
}

/// Stores a completed declaration after resolving its payloads. Recursive edges name identifiers, so a node does not need mutable placeholders or references to other nodes.
///
/// The declaration's own ``__Exhaustable/TypeDescriptor`` is not kept. Its limits are copied out here because the graph reads them without knowing `Value`; its constructors are typed, so the builder reads them back from `Value.__generatorDescriptor` where `Value` is still static rather than storing them erased and casting.
struct TypeDerivationPlan {
    let type: any __Exhaustable.Conformance.Type
    let budget: ExhaustableBudget
    let domain: ExhaustableDomain
    let constructors: [ConstructorPlan]

    init<Value: __Exhaustable.Conformance>(
        type: Value.Type,
        descriptor: __Exhaustable.TypeDescriptor<Value>,
        constructors: [ConstructorPlan]
    ) {
        self.type = type
        budget = descriptor.budget
        domain = descriptor.domain
        self.constructors = constructors
    }
}

/// Resolves a finite dependency graph, then computes feasible recursive-fuel budgets without building generators for annotated types.
///
/// Only initialization mutates the graph. Supplied generators are opaque leaves: the plan does not prove that their filters succeed or that their own construction terminates. Standard containers have an empty construction independent of their contents.
///
/// The graph stores structure keyed by identity, never a payload type. Anything typed is recovered where that type is still static: an annotated type's constructors from `Value.__generatorDescriptor` in the builder, a container's element generators inside the closures on its ``DerivedContainerRecipe``. The one erasure that stays is ``BudgetedGeneratorDerivation/built``, whose values genuinely differ in type per key, so its cast reads a heterogeneous store rather than recovering a type the caller already knows.
final class GeneratorDerivationPlan {
    private(set) var types: [ObjectIdentifier: TypeDerivationPlan] = [:]
    private let overrides: [ObjectIdentifier: ReflectiveGenerator<Any>]
    private var resolved: [ObjectIdentifier: PayloadPlan] = [:]
    private var discoveryOrder: [ObjectIdentifier] = []
    private var minimumRecursionBudgets: [ObjectIdentifier: Int] = [:]
    private var componentByType: [ObjectIdentifier: Int] = [:]
    private var recursiveComponents: Set<Int> = []
    private var componentsReachingRecursiveComponent: Set<Int> = []

    private var defaults: [DefaultGeneratorKey: ReflectiveGenerator<Any>] = [:]
    private var activeSpecializations: [DeclarationKey: [Any.Type]] = [:]

    /// Bounds eager graph discovery, not generated value recursion. Exact type repeats close through `resolved` before this limit applies.
    static let maximumActiveSpecializations = 32

    init(
        for type: (some __Exhaustable.Conformance).Type,
        overrides: [ObjectIdentifier: ReflectiveGenerator<Any>]
    ) throws {
        self.overrides = overrides
        try register(type)
        analyzeRecursiveComponents()
        analyzeRecursionBudgets()
    }

    /// Retrieves a registered dependency. Every symbolic derived-type edge must resolve before recursive-fuel analysis or generator construction begins.
    func plan(for reference: ObjectIdentifier) -> TypeDerivationPlan {
        guard let entry = types[reference] else {
            preconditionFailure("Every derived-type reference must have a registered construction plan: \(reference)")
        }
        return entry
    }

    /// Shares built-in leaves by type and effective domain without applying that domain to explicit overrides.
    func defaultGenerator(for type: any DefaultGenerable.Type, domain: ExhaustableDomain) -> ReflectiveGenerator<Any> {
        let key = DefaultGeneratorKey(type: ObjectIdentifier(type), domain: domain)
        if let existing = defaults[key] {
            return existing
        }
        let generator = makeDefaultGenerator(for: type, domain: domain)
        defaults[key] = generator
        return generator
    }

    /// Rejects an impossible root or an insufficient recursive budget before any generator layers are built.
    func minimumRecursionBudget(
        for type: (some __Exhaustable.Conformance).Type,
        at recursionBudget: Int
    ) throws -> Int {
        guard let minimum = minimumRecursionBudgets[ObjectIdentifier(type)] else {
            throw GeneratorDerivationError.noFiniteConstruction(
                type: String(describing: type),
                dependencyPath: blockingPath(from: ObjectIdentifier(type))
            )
        }
        guard recursionBudget >= minimum else {
            throw GeneratorDerivationError.insufficientRecursionBudget(
                type: String(describing: type),
                minimum: minimum,
                requested: recursionBudget
            )
        }
        return minimum
    }

    /// Returns one recursion allowance per payload, or `nil` when a required cycle edge cannot reach a finite child construction.
    func recursionAllowances(
        for payloads: [PayloadPlan],
        from source: ObjectIdentifier,
        budget: Int
    ) -> [PayloadRecursionAllowance]? {
        let widths = payloads.map { recursiveWidth(of: $0, from: source) }
        let totalWidth = widths.reduce(0, +)
        let recursiveShare = switch (budget, totalWidth) {
            case (_, 0): budget
            case (0, _): 0
            case let (budget, width): (budget - 1) / width
        }
        let allowances = widths.map { width in
            PayloadRecursionAllowance(
                source: source,
                inherited: budget,
                recursive: width > 0 ? recursiveShare : budget
            )
        }
        for (payload, allowance) in zip(payloads, allowances) {
            guard requiredPayloadFits(payload, allowance: allowance) else {
                return nil
            }
        }
        return allowances
    }

    /// Counts cycle-participating derived routes through one payload occurrence. Containers contribute their per-entry routes; cardinality is applied when their counted layer is built.
    func recursiveWidth(of payload: PayloadPlan, from source: ObjectIdentifier) -> Int {
        switch payload {
            case .supplied, .standard:
                0
            case let .derivedType(target):
                isRecursiveEdge(from: source, to: target) ? 1 : 0
            case let .container(_, children):
                children.reduce(0) { $0 + recursiveWidth(of: $1, from: source) }
        }
    }

    /// Reports whether the type can reach any recursive strongly connected component.
    func canReachRecursiveComponent(_ type: Any.Type) -> Bool {
        guard let component = componentByType[ObjectIdentifier(type)] else {
            return false
        }
        return componentsReachingRecursiveComponent.contains(component)
    }

    /// Reports whether the edge lies inside a recursive strongly connected component.
    func isRecursiveEdge(from source: ObjectIdentifier, to target: ObjectIdentifier) -> Bool {
        guard let sourceComponent = componentByType[source],
              sourceComponent == componentByType[target]
        else {
            return false
        }
        return recursiveComponents.contains(sourceComponent)
    }

    /// Seeds terminating types first and propagates minimum recursion budgets until no requirement changes.
    private func analyzeRecursionBudgets() {
        var changed = true
        while changed {
            changed = false
            for reference in discoveryOrder {
                let typePlan = plan(for: reference)
                let minimum = typePlan.constructors.compactMap {
                    minimumRecursionBudget(for: $0.payloads, from: reference)
                }.min()
                if minimum != minimumRecursionBudgets[reference] {
                    minimumRecursionBudgets[reference] = minimum
                    changed = true
                }
            }
        }
    }

    /// Computes the least budget whose equal recursive shares satisfy every required direct derived payload. Empty containers add width when fuel is available but remain valid base constructions at zero.
    private func minimumRecursionBudget(
        for payloads: [PayloadPlan],
        from source: ObjectIdentifier
    ) -> Int? {
        let totalWidth = payloads.reduce(0) { $0 + recursiveWidth(of: $1, from: source) }
        var requiredRecursiveShare: Int?
        var inheritedMinimum = 0
        for payload in payloads {
            guard case let .derivedType(target) = payload,
                  let childMinimum = minimumRecursionBudgets[target],
                  childMinimum <= plan(for: target).budget.recursion
            else {
                if case .derivedType = payload {
                    return nil
                }
                continue
            }
            switch isRecursiveEdge(from: source, to: target) {
                case true:
                    requiredRecursiveShare = max(requiredRecursiveShare ?? 0, childMinimum)
                case false:
                    inheritedMinimum = max(inheritedMinimum, childMinimum)
            }
        }
        let recursiveMinimum: Int
        switch requiredRecursiveShare {
            case let .some(requiredShare):
                let (product, overflow) = totalWidth.multipliedReportingOverflow(by: requiredShare)
                guard overflow == false else {
                    return nil
                }
                let (required, additionOverflow) = product.addingReportingOverflow(1)
                guard additionOverflow == false else {
                    return nil
                }
                recursiveMinimum = required
            case .none:
                recursiveMinimum = 0
        }
        return max(recursiveMinimum, inheritedMinimum)
    }

    /// Validates only required direct derived payloads. A container can always choose its empty construction and validates its children when a positive counted layer is built.
    private func requiredPayloadFits(
        _ payload: PayloadPlan,
        allowance: PayloadRecursionAllowance
    ) -> Bool {
        guard case let .derivedType(target) = payload,
              let minimum = minimumRecursionBudgets[target]
        else {
            return payload.isDirectDerivedType == false
        }
        let isRecursive = isRecursiveEdge(from: allowance.source, to: target)
        guard isRecursive == false || allowance.inherited > 0 else {
            return false
        }
        let selected = isRecursive ? allowance.recursive : allowance.inherited
        return minimum <= min(selected, plan(for: target).budget.recursion)
    }

    /// Finds recursive components and records their reverse reachability as Tarjan closes them in successor-first order.
    private func analyzeRecursiveComponents() {
        let adjacency = Dictionary(uniqueKeysWithValues: discoveryOrder.map { reference in
            var targets: [ObjectIdentifier] = []
            for constructor in plan(for: reference).constructors {
                for payload in constructor.payloads {
                    payload.appendDerivedReferences(to: &targets)
                }
            }
            return (reference, Array(Set(targets)))
        })
        var nextIndex = 0
        var indices: [ObjectIdentifier: Int] = [:]
        var lowLinks: [ObjectIdentifier: Int] = [:]
        var stack: [ObjectIdentifier] = []
        var onStack: Set<ObjectIdentifier> = []
        var nextComponent = 0

        func visit(_ reference: ObjectIdentifier) {
            indices[reference] = nextIndex
            lowLinks[reference] = nextIndex
            nextIndex += 1
            stack.append(reference)
            onStack.insert(reference)

            for target in adjacency[reference, default: []] {
                switch indices[target] {
                    case .none:
                        visit(target)
                        lowLinks[reference] = min(lowLinks[reference]!, lowLinks[target]!)
                    case let .some(targetIndex) where onStack.contains(target):
                        lowLinks[reference] = min(lowLinks[reference]!, targetIndex)
                    case .some:
                        break
                }
            }

            guard lowLinks[reference] == indices[reference] else {
                return
            }
            var members: [ObjectIdentifier] = []
            while let member = stack.popLast() {
                onStack.remove(member)
                componentByType[member] = nextComponent
                members.append(member)
                if member == reference {
                    break
                }
            }
            let component = nextComponent
            let isRecursive = members.count > 1 || adjacency[reference, default: []].contains(reference)
            if isRecursive {
                recursiveComponents.insert(component)
            }
            let reachesRecursiveComponent = isRecursive || members.contains { member in
                adjacency[member, default: []].contains { target in
                    guard let targetComponent = componentByType[target] else {
                        preconditionFailure("Tarjan must close every successor component first")
                    }
                    return componentsReachingRecursiveComponent.contains(targetComponent)
                }
            }
            if reachesRecursiveComponent {
                componentsReachingRecursiveComponent.insert(component)
            }
            nextComponent += 1
        }

        for reference in discoveryOrder where indices[reference] == nil {
            visit(reference)
        }
    }

    /// Publishes the symbolic reference before descending, so self-recursion and mutual recursion close graph edges instead of recursing indefinitely.
    private func register<Value: __Exhaustable.Conformance>(_ type: Value.Type) throws {
        let reference = ObjectIdentifier(type)
        guard resolved[reference] == nil else {
            return
        }
        let descriptor = Value.__generatorDescriptor
        guard descriptor.budget.recursion >= 0 else {
            throw GeneratorDerivationError.invalidRecursionBudget(
                type: String(describing: type),
                recursion: descriptor.budget.recursion
            )
        }
        guard descriptor.budget.nodes > 0 else {
            throw GeneratorDerivationError.invalidNodeBudget(
                type: String(describing: type),
                nodes: descriptor.budget.nodes
            )
        }
        let declaration = DeclarationKey(
            fileID: String(describing: descriptor.fileID),
            line: descriptor.line,
            column: descriptor.column
        )
        let active = activeSpecializations[declaration, default: []]
        guard active.count < Self.maximumActiveSpecializations else {
            throw GeneratorDerivationError.specializationLimitExceeded(
                type: String(describing: active[0]),
                limit: Self.maximumActiveSpecializations
            )
        }
        activeSpecializations[declaration, default: []].append(type)
        defer {
            activeSpecializations[declaration]?.removeLast()
            if activeSpecializations[declaration]?.isEmpty == true {
                activeSpecializations.removeValue(forKey: declaration)
            }
        }
        resolved[reference] = .derivedType(reference)
        discoveryOrder.append(reference)
        let constructors = try descriptor.constructors.map { entry in
            try ConstructorPlan(payloads: entry.payloadTypes.map { try resolve($0) })
        }
        types[reference] = TypeDerivationPlan(
            type: type,
            descriptor: descriptor,
            constructors: constructors
        )
    }

    /// Overrides win even for the root type when it occurs as a payload. Structural containers resolve their children through this same path, preserving element overrides and nested annotations.
    private func resolve(_ type: Any.Type) throws -> PayloadPlan {
        let reference = ObjectIdentifier(type)
        if let override = overrides[reference] {
            return .supplied(override)
        }
        if let existing = resolved[reference] {
            return existing
        }
        if let generableType = type as? any __Exhaustable.Conformance.Type {
            try register(generableType)
            return .derivedType(reference)
        }
        if let container = type as? any DerivedContainer.Type {
            let recipe = container.derivationRecipe
            let children = try recipe.childTypes.map { try resolve($0) }
            let payload = PayloadPlan.container(recipe, children: children)
            resolved[reference] = payload
            return payload
        }
        if let generable = type as? any DefaultGenerable.Type {
            let payload = PayloadPlan.standard(generable)
            resolved[reference] = payload
            return payload
        }
        throw GeneratorDerivationError.unsupportedPayload(type: String(describing: type))
    }

    /// Follows one required direct dependency in declaration order until it reaches a cycle or an empty type descriptor.
    private func blockingPath(from root: ObjectIdentifier) -> [String] {
        var path: [String] = []
        var visited: Set<ObjectIdentifier> = []
        var current = root
        while true {
            let typePlan = plan(for: current)
            path.append(String(describing: typePlan.type))
            guard visited.insert(current).inserted else {
                return path
            }
            let blocking = typePlan.constructors.lazy
                .flatMap(\.payloads)
                .compactMap(blockingReference)
                .first
            guard let blocking else {
                return path
            }
            current = blocking
        }
    }

    /// Returns the first derived dependency whose type has no finite recursive construction.
    private func blockingReference(in payload: PayloadPlan) -> ObjectIdentifier? {
        switch payload {
            case .supplied, .standard:
                nil
            case let .derivedType(reference):
                minimumRecursionBudgets[reference] == nil ? reference : nil
            case .container:
                nil
        }
    }
}

/// Reports structural failures separately from generator construction so diagnostics can be tested without crashing a process.
enum GeneratorDerivationError: Error, Equatable, CustomStringConvertible {
    case unsupportedPayload(type: String)
    case invalidRecursionBudget(type: String, recursion: Int)
    case invalidNodeBudget(type: String, nodes: Int)
    case insufficientNodeBudget(type: String, minimum: Int, requested: Int)
    case noFiniteConstructionWithinNodeBudget(type: String, recursion: Int)
    case insufficientRecursionBudget(type: String, minimum: Int, requested: Int)
    case noFiniteConstruction(type: String, dependencyPath: [String])
    case specializationLimitExceeded(type: String, limit: Int)

    var description: String {
        switch self {
            case let .unsupportedPayload(type):
                "Cannot derive a generator for payload \(type): supply a generator through overriding: or annotate the type with @Exhaustable."
            case let .invalidRecursionBudget(type, recursion):
                "Cannot derive a generator for \(type): recursive fuel must be nonnegative, got \(recursion)."
            case let .invalidNodeBudget(type, nodes):
                "Cannot derive a generator for \(type): the node ceiling must be positive, got \(nodes)."
            case let .insufficientNodeBudget(type, minimum, requested):
                "Cannot derive a generator for \(type): minimum structural node count is \(minimum), but the node ceiling is \(requested)."
            case let .noFiniteConstructionWithinNodeBudget(type, recursion):
                "Cannot derive a generator for \(type) with recursive fuel \(recursion): no finite construction fits the nested node ceilings."
            case let .insufficientRecursionBudget(type, minimum, requested):
                "Cannot derive a generator for \(type): minimum recursive fuel is \(minimum), but the budget supplies \(requested)."
            case let .noFiniteConstruction(type, dependencyPath):
                "Cannot derive a generator for \(type): no finite construction exists through the recursive type graph. Dependency path: \(dependencyPath.joined(separator: " -> "))."
            case let .specializationLimitExceeded(type, limit):
                "Cannot derive a generator for \(type): more than \(limit) distinct specializations of the same declaration on one dependency path. Recursive generic arguments may expand without bound; supply an override to terminate the dependency."
        }
    }
}

// MARK: - Helpers

/// Groups specializations by their original annotation, including types nested in a generic declaration. Concrete metatype identifiers still distinguish resolved nodes and generator layers.
private struct DeclarationKey: Hashable {
    let fileID: String
    let line: UInt
    let column: UInt
}

/// Carries one constructor's inherited budget and its equal share for edges returning to the source recursive component.
struct PayloadRecursionAllowance: Hashable {
    let source: ObjectIdentifier
    let inherited: Int
    let recursive: Int
}

private struct DefaultGeneratorKey: Hashable {
    let type: ObjectIdentifier
    let domain: ExhaustableDomain
}

private func makeDefaultGenerator<Value: DefaultGenerable>(
    for _: Value.Type,
    domain: ExhaustableDomain
) -> ReflectiveGenerator<Any> {
    Value.defaultGenerator(domain: domain).erasedForDerivation()
}
