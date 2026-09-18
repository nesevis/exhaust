import Exhaustable
import ExhaustCore

/// Records the resolver's decision once, so construction and depth analysis follow the same dependencies.
indirect enum PayloadPlan {
    /// An `overriding:` generator, which wins over every other resolution and stays opaque to depth and node analysis.
    case supplied(ReflectiveGenerator<Any>)

    /// A built-in leaf from Exhaust's catalogue of standard-library and Foundation generators. The state space selects its domain, so one type can back several completed leaves.
    case standard(any DefaultGenerable.Type)

    /// Another annotated type, named by identifier rather than by node so recursive and mutually recursive edges close without placeholders. Crossing this edge costs one unit of depth.
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
    let maximumDepth: Int?
    let maximumNodes: Int?
    let stateSpace: GeneratorStateSpace
    let constructors: [ConstructorPlan]

    init<Value: __Exhaustable.Conformance>(
        type: Value.Type,
        descriptor: __Exhaustable.TypeDescriptor<Value>,
        constructors: [ConstructorPlan]
    ) {
        self.type = type
        maximumDepth = descriptor.maximumDepth
        maximumNodes = descriptor.maximumNodes
        stateSpace = descriptor.stateSpace
        self.constructors = constructors
    }
}

/// Resolves a finite dependency graph, then computes constructible depths without building generators for annotated types.
///
/// Only initialization mutates the graph. Supplied generators are opaque leaves: the plan does not prove that their filters succeed or that their own construction terminates. Standard containers have an empty construction independent of their contents.
///
/// The graph stores structure keyed by identity, never a payload type. Anything typed is recovered where that type is still static: an annotated type's constructors from `Value.__generatorDescriptor` in the builder, a container's element generators inside the closures on its ``DerivedContainerRecipe``. The one erasure that stays is ``BudgetedGeneratorDerivation/built``, whose values genuinely differ in type per key, so its cast reads a heterogeneous store rather than recovering a type the caller already knows.
final class GeneratorDerivationPlan {
    private(set) var types: [ObjectIdentifier: TypeDerivationPlan] = [:]
    private let overrides: [ObjectIdentifier: ReflectiveGenerator<Any>]
    private var resolved: [ObjectIdentifier: PayloadPlan] = [:]
    private var discoveryOrder: [ObjectIdentifier] = []
    private var minimumDepths: [ObjectIdentifier: Int] = [:]
    private var defaults: [DefaultGeneratorKey: ReflectiveGenerator<Any>] = [:]
    private var activeSpecializations: [DeclarationKey: [Any.Type]] = [:]

    /// Bounds eager graph discovery, not generated value depth. Exact type repeats close through `resolved` before this limit applies.
    static let maximumActiveSpecializations = 32

    init(
        for type: (some __Exhaustable.Conformance).Type,
        overrides: [ObjectIdentifier: ReflectiveGenerator<Any>]
    ) throws {
        self.overrides = overrides
        try register(type)
        analyzeDepths()
    }

    /// Shares built-in leaves by type and effective state space without applying that state space to explicit overrides.
    func defaultGenerator(for type: any DefaultGenerable.Type, stateSpace: GeneratorStateSpace) -> ReflectiveGenerator<Any> {
        let key = DefaultGeneratorKey(type: ObjectIdentifier(type), stateSpace: stateSpace)
        if let existing = defaults[key] {
            return existing
        }
        let generator = makeDefaultGenerator(for: type, stateSpace: stateSpace)
        defaults[key] = generator
        return generator
    }

    /// Rejects an impossible root or an insufficient requested depth before any generator layers are built.
    func minimumDepth(
        for type: (some __Exhaustable.Conformance).Type,
        at depth: Int
    ) throws -> Int {
        guard let minimum = minimumDepths[ObjectIdentifier(type)] else {
            throw GeneratorDerivationError.noFiniteConstruction(
                type: String(describing: type),
                dependencyPath: blockingPath(from: ObjectIdentifier(type))
            )
        }
        guard depth >= minimum else {
            throw GeneratorDerivationError.insufficientDepth(
                type: String(describing: type),
                minimum: minimum,
                requested: depth
            )
        }
        return minimum
    }

    /// Computes a product's requirement. An empty product needs no depth; one impossible payload makes the entire product impossible.
    func minimumDepth(for payloads: [PayloadPlan]) -> Int? {
        var minimum = 0
        for payload in payloads {
            guard let required = minimumDepth(for: payload) else {
                return nil
            }
            minimum = max(minimum, required)
        }
        return minimum
    }

    /// Charges depth only when crossing into another derived type. Containers pass the budget through and can terminate without crossing any child edge.
    private func minimumDepth(for payload: PayloadPlan) -> Int? {
        switch payload {
            case .supplied, .standard, .container:
                return 0
            case let .derivedType(reference):
                let child = types[reference]!
                guard let minimum = minimumDepths[reference],
                      child.maximumDepth.map({ minimum <= $0 }) ?? true
                else {
                    return nil
                }
                return minimum + 1
        }
    }

    /// Seeds terminating types first and propagates their depths until no requirement changes. Types with no finite construction have no entry in the depth table.
    private func analyzeDepths() {
        var changed = true
        while changed {
            changed = false
            for reference in discoveryOrder {
                let typePlan = types[reference]!
                let minimum = typePlan.constructors.compactMap { minimumDepth(for: $0.payloads) }.min()
                if minimum != minimumDepths[reference] {
                    minimumDepths[reference] = minimum
                    changed = true
                }
            }
        }
    }

    /// Publishes the symbolic reference before descending, so self-recursion and mutual recursion close graph edges instead of recursing indefinitely.
    private func register<Value: __Exhaustable.Conformance>(_ type: Value.Type) throws {
        let reference = ObjectIdentifier(type)
        guard resolved[reference] == nil else {
            return
        }
        let descriptor = Value.__generatorDescriptor
        if let maximumDepth = descriptor.maximumDepth, maximumDepth < 0 {
            throw GeneratorDerivationError.invalidMaximumDepth(type: String(describing: type), depth: maximumDepth)
        }
        if let maximumNodes = descriptor.maximumNodes, maximumNodes <= 0 {
            throw GeneratorDerivationError.invalidMaximumNodes(type: String(describing: type), nodes: maximumNodes)
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

    /// Follows one blocking dependency in declaration order until it reaches a cycle, an empty type descriptor, or an incompatible declared ceiling.
    private func blockingPath(from root: ObjectIdentifier) -> [String] {
        var path: [String] = []
        var visited: Set<ObjectIdentifier> = []
        var current = root
        while true {
            let typePlan = types[current]!
            path.append(String(describing: typePlan.type))
            guard visited.insert(current).inserted else {
                return path
            }
            if let minimum = minimumDepths[current], let ceiling = typePlan.maximumDepth, minimum > ceiling {
                path.append("requires depth \(minimum), but declares maximumDepth \(ceiling)")
                return path
            }
            let blocking = typePlan.constructors.lazy.flatMap(\.payloads).first { minimumDepth(for: $0) == nil }
            guard case let .derivedType(reference) = blocking else {
                return path
            }
            current = reference
        }
    }
}

/// Reports structural failures separately from generator construction so diagnostics can be tested without crashing a process.
enum GeneratorDerivationError: Error, Equatable, CustomStringConvertible {
    case unsupportedPayload(type: String)
    case invalidMaximumDepth(type: String, depth: Int)
    case invalidMaximumNodes(type: String, nodes: Int)
    case insufficientNodes(type: String, minimum: Int, requested: Int)
    case noFiniteConstructionWithinNodeLimits(type: String, depth: Int)
    case insufficientDepth(type: String, minimum: Int, requested: Int)
    case noFiniteConstruction(type: String, dependencyPath: [String])
    case specializationLimitExceeded(type: String, limit: Int)

    var description: String {
        switch self {
            case let .unsupportedPayload(type):
                "Cannot derive a generator for payload \(type): supply a generator through overriding: or annotate the type with @Exhaustable."
            case let .invalidMaximumDepth(type, depth):
                "Cannot derive a generator for \(type): maximumDepth must be non-negative, got \(depth)."
            case let .invalidMaximumNodes(type, nodes):
                "Cannot derive a generator for \(type): maximumNodes must be positive, got \(nodes)."
            case let .insufficientNodes(type, minimum, requested):
                "Cannot derive a generator for \(type): minimum structural node count is \(minimum), but maximumNodes is \(requested)."
            case let .noFiniteConstructionWithinNodeLimits(type, depth):
                "Cannot derive a generator for \(type) at depth \(depth): no finite construction within the nested node limits."
            case let .insufficientDepth(type, minimum, requested):
                "Cannot derive a generator for \(type) at depth \(requested): minimum constructible depth is \(minimum)."
            case let .noFiniteConstruction(type, dependencyPath):
                "Cannot derive a generator for \(type): no finite construction within the declared depth limits. Dependency path: \(dependencyPath.joined(separator: " -> "))."
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

private struct DefaultGeneratorKey: Hashable {
    let type: ObjectIdentifier
    let stateSpace: GeneratorStateSpace
}

private func makeDefaultGenerator<Value: DefaultGenerable>(
    for _: Value.Type,
    stateSpace: GeneratorStateSpace
) -> ReflectiveGenerator<Any> {
    Value.defaultGenerator(stateSpace: stateSpace).erasedForDerivation()
}
