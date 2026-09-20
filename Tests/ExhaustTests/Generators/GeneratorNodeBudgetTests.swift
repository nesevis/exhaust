import Exhaust
import ExhaustCore
import Testing
@testable import ExhaustGenerators

@Suite("Derived structural node budgets")
struct GeneratorNodeBudgetTests {
    @Test("Wide recursive arrays obey one root budget", arguments: [2, 6, 16, 32])
    func recursiveArrays(maximumNodes: Int) throws {
        let generators = [
            BudgetRose.gen(.budget(.custom(recursion: 5, nodes: maximumNodes))),
            BudgetRose.gen(recursion: 5, .budget(.custom(recursion: 5, nodes: maximumNodes))),
        ]
        for generator in generators {
            var interpreter = ValueAndChoiceTreeInterpreter(generator.gen, seed: 42, sizeOverride: 100)
            var counts: [Int] = []
            for _ in 0 ..< 30 {
                let (value, _) = try #require(try interpreter.next())
                counts.append(value.nodes)
                #expect(value.nodes <= maximumNodes)
                #expect(value.depth <= 5)
                let reflected = try #require(try Interpreters.reflect(generator.gen, with: value))
                #expect(try Interpreters.replay(generator.gen, using: reflected) == value)
            }
            switch maximumNodes {
                case BudgetRose.minimumNodes:
                    // The allowance equals the smallest rose the derivation can build, so no draw can exceed it.
                    break
                default:
                    #expect(counts.contains { $0 > BudgetRose.minimumNodes }, "every draw stayed at the minimum, so the allowance was never used")
            }
        }
    }

    @Test("A budgeted rose tree never exceeds its node or depth ceiling", arguments: [2, 6, 16, 32])
    func recursiveArraysStayWithinBudget(maximumNodes: Int) {
        #exhaust(BudgetRose.gen(.budget(.custom(recursion: 5, nodes: maximumNodes)))) { tree in
            tree.nodes <= maximumNodes && tree.depth <= 5
        }
    }

    @Test("Recursive fuel admits the known four-node heap witness exactly at its support threshold")
    func recursiveSupportThreshold() throws {
        let witness = BudgetHeap.node(
            0,
            .empty,
            .node(
                0,
                .node(0, .empty, .empty),
                .node(1, .empty, .empty)
            )
        )
        let supported = BudgetHeap.gen(
            recursion: 7,
            .budget(.custom(recursion: 7, nodes: 100))
        )
        let reflected = try #require(try Interpreters.reflect(supported.gen, with: witness))
        #expect(try Interpreters.replay(supported.gen, using: reflected) == witness)

        let unsupported = BudgetHeap.gen(
            recursion: 6,
            .budget(.custom(recursion: 6, nodes: 100))
        )
        #expect(throws: ReflectionError.couldNotMapInputToGenerator) {
            try Interpreters.reflect(unsupported.gen, with: witness)
        }
    }

    @Test("The root allowance ramps container-driven nodes with size", arguments: [UInt64(1), 25, 50, 100])
    func sizeRamping(size: UInt64) throws {
        let generator = BudgetRose.gen(recursion: 5, .budget(.custom(recursion: 5, nodes: 32)))
        var interpreter = ValueAndChoiceTreeInterpreter(generator.gen, seed: 42, sizeOverride: size)
        let allowance = BudgetRose.minimumNodes + Int(30 * size / 100)
        let maximumChildCount = UInt64(max(0, (allowance - BudgetRose.minimumNodes) / BudgetRose.minimumNodes))
        var counts: [Int] = []
        for _ in 0 ..< 30 {
            let (value, tree) = try #require(try interpreter.next())
            counts.append(value.nodes)
            #expect(value.nodes <= allowance)
            #expect(unsignedChoiceRanges(in: tree).contains(0 ... maximumChildCount))
        }
        // Exponential cardinality scaling keeps the size-25 samples empty even though their declared container layer already admits children. At larger sizes, deterministic sampling also exercises that support.
        if size >= 50 {
            #expect(counts.contains { $0 > BudgetRose.minimumNodes }, "every draw stayed at the minimum, so the ramped allowance was never used")
        }
    }

    @Test("Product minima are reserved before splitting the remaining allowance")
    func productMinimum() throws {
        let plan = try GeneratorDerivationPlan(for: BudgetPair.self, overrides: [:])
        let builder = BudgetedGeneratorDerivation(plan: plan)
        #expect(throws: GeneratorDerivationError.insufficientNodeBudget(type: "BudgetPair", minimum: 5, requested: 4)) {
            try builder.root(for: BudgetPair.self, recursion: .drawn(ceiling: 2, scaling: .linear), maximumNodes: 4)
        }
        let generator = BudgetPair.gen(.budget(.custom(recursion: 2, nodes: 5)), overriding: .int(in: 7 ... 7))
        let report = #examine(generator, .samples(20), .replay(42), .suppress(.logs)) { first, second in first == second }
        expectSuccessfulExamination(report, samples: 20)
        let samples = try #example(generator, count: 20)
        #expect(samples.allSatisfy { $0.first.number == 7 && $0.second.number == 7 })
    }

    @Test("The depth draw starts at a layer affordable under the node ceiling")
    func affordableDepth() throws {
        let generator = BudgetUneven.gen(.budget(.custom(recursion: 4, nodes: 4)), overriding: .int(in: 7 ... 7))
        let samples = try #example(generator, count: 20)
        #expect(samples.allSatisfy { $0 == .wrapped(BudgetWrapper(value: BudgetLeaf(number: 7))) })
        for value in samples {
            let tree = try #require(try Interpreters.reflect(generator.gen, with: value))
            #expect(try Interpreters.replay(generator.gen, using: tree) == value)
        }
    }

    @Test("Nested annotations cap their share and root arguments override only the root")
    func annotationCeilings() throws {
        #expect(BudgetCapped.__generatorDescriptor.budget.nodes == 7)
        let samples = try #example(BudgetCapped.gen(), count: 30)
        #expect(samples.allSatisfy { $0.nodes <= 7 })
        let smaller = try #example(BudgetCapped.gen(.budget(.custom(recursion: 10, nodes: 3))), count: 30)
        #expect(smaller.allSatisfy { $0.nodes <= 3 })
        let target = BudgetCapped.full(depth: 3)
        #expect(target.nodes == 15)
        let expanded = BudgetCapped.gen(.budget(.custom(recursion: 10, nodes: 15)))
        let tree = try #require(try Interpreters.reflect(expanded.gen, with: target))
        #expect(try Interpreters.replay(expanded.gen, using: tree) == target)
        #expect(throws: ReflectionError.couldNotMapInputToGenerator) {
            try Interpreters.reflect(BudgetCapped.gen().gen, with: target)
        }
        let holder = BudgetCappedHolder.gen(.budget(.custom(recursion: 10, nodes: 31)))
        let held = try #example(holder, count: 30)
        #expect(held.allSatisfy { $0.first.nodes <= 7 && $0.second.nodes <= 7 })
        let unbounded = try #example(BudgetCappedHolder.gen(), count: 20)
        #expect(unbounded.allSatisfy { $0.first.nodes <= 7 && $0.second.nodes <= 7 })
    }

    @Test("An incompatible nested annotation diagnoses a required payload but permits an empty optional")
    func impossibleNestedBudget() throws {
        let plan = try GeneratorDerivationPlan(for: BudgetImpossibleHolder.self, overrides: [:])
        let builder = BudgetedGeneratorDerivation(plan: plan)
        #expect(throws: GeneratorDerivationError.noFiniteConstructionWithinNodeBudget(type: "BudgetImpossibleHolder", recursion: 3)) {
            try builder.root(for: BudgetImpossibleHolder.self, recursion: .drawn(ceiling: 3, scaling: .linear), maximumNodes: 20)
        }
        let values = try #example(BudgetOptionalImpossible.gen(), count: 20)
        #expect(values.allSatisfy { $0.value == nil })
    }

    @Test("Invalid node limits are reported before layer construction")
    func invalidLimits() throws {
        #expect(throws: GeneratorDerivationError.invalidNodeBudget(type: "BudgetInvalid", nodes: 0)) {
            try GeneratorDerivationPlan(for: BudgetInvalid.self, overrides: [:])
        }
        let plan = try GeneratorDerivationPlan(for: BudgetLeaf.self, overrides: [:])
        let builder = BudgetedGeneratorDerivation(plan: plan)
        #expect(throws: GeneratorDerivationError.invalidNodeBudget(type: "BudgetLeaf", nodes: -1)) {
            try builder.root(for: BudgetLeaf.self, recursion: .pinned(0), maximumNodes: -1)
        }
    }

    @Test("Every container shares its allowance among its contents")
    func standardContainers() throws {
        let generator = BudgetContainers.gen(recursion: 0, .budget(.custom(recursion: 0, nodes: 24)), overriding: .int(in: 7 ... 7))
        let samples = try #example(generator, count: 30)
        for value in samples {
            #expect(value.nodes <= 24)
            #expect(value.array.allSatisfy { $0 == 7 })
            #expect(value.optional == nil || value.optional == 7)
            #expect(value.set.allSatisfy { $0 == 7 })
            #expect(value.dictionary.allSatisfy { $0.key == 7 && $0.value == 7 })
            #expect(value.nested.allSatisfy { $0.allSatisfy { $0 == 7 } })
            let tree = try #require(try Interpreters.reflect(generator.gen, with: value))
            #expect(try Interpreters.replay(generator.gen, using: tree) == value)
        }
        let empty = try #example(BudgetContainers.gen(recursion: 0, .budget(.custom(recursion: 0, nodes: 6))), count: 10)
        #expect(empty.allSatisfy { $0.nodes == 6 })
    }

    @Test("Mutual recursion and recursive optionals, sets, and dictionaries conserve nodes")
    func recursiveFamilies() throws {
        let mutual = BudgetMutualFirst.gen(.budget(.custom(recursion: 5, nodes: 6)))
        let optional = BudgetOptional.gen(.budget(.custom(recursion: 4, nodes: 10)))
        let set = BudgetSet.gen(recursion: 3, .budget(.custom(recursion: 3, nodes: 18)))
        let dictionary = BudgetDictionary.gen(recursion: 3, .budget(.custom(recursion: 3, nodes: 18)))
        try checkBudget(mutual, maximumNodes: 6, minimumNodes: 2, nodes: { $0.nodes })
        try checkBudget(optional, maximumNodes: 10, minimumNodes: 2, nodes: { $0.nodes })
        try checkBudget(set, maximumNodes: 18, minimumNodes: 2, nodes: { $0.nodes })
        try checkBudget(dictionary, maximumNodes: 18, minimumNodes: 2, nodes: { $0.nodes })
    }

    @Test("Exact overrides remain opaque one-node leaves")
    func opaqueOverrides() throws {
        let supplied = Array(repeating: 7, count: 100)
        let generator = BudgetArrayHolder.gen(.budget(.custom(recursion: 10, nodes: 2)), overriding: .just(supplied))
        let values = try #example(generator, count: 10)
        #expect(values.allSatisfy { $0.values == supplied })
        let target = BudgetArrayHolder(values: supplied)
        let tree = try #require(try Interpreters.reflect(generator.gen, with: target))
        #expect(try Interpreters.replay(generator.gen, using: tree) == target)
    }

    @Test("Layer sharing includes the node allowance without conflating different budgets")
    func sharing() throws {
        let plan = try GeneratorDerivationPlan(for: BudgetBinary.self, overrides: [:])
        let builder = BudgetedGeneratorDerivation(plan: plan)
        _ = builder.generator(for: BudgetBinary.self, recursion: 4, nodes: 15)
        let count = builder.built.count
        _ = builder.generator(for: BudgetBinary.self, recursion: 4, nodes: 15)
        #expect(builder.built.count == count)
        _ = builder.generator(for: BudgetBinary.self, recursion: 4, nodes: 7)
        #expect(builder.built.keys.contains(NodeBudgetKey(type: ObjectIdentifier(BudgetBinary.self), recursion: 4, nodes: 15, domain: .full)))
        #expect(builder.built.keys.contains(NodeBudgetKey(type: ObjectIdentifier(BudgetBinary.self), recursion: 4, nodes: 7, domain: .full)))
        _ = builder.generator(for: BudgetBinary.self, recursion: 4, nodes: nil)
        #expect(builder.built.keys.contains(NodeBudgetKey(type: ObjectIdentifier(BudgetBinary.self), recursion: 4, nodes: nil, domain: .full)))
        #expect(builder.built.keys.count(where: { $0.nodes == nil }) == 1)
        let unboundedCount = builder.built.count
        _ = builder.generator(for: BudgetBinary.self, recursion: 4, nodes: nil)
        #expect(builder.built.count == unboundedCount)
    }

    @Test("Acyclic and budget-forced containers are cached across sibling fields", arguments: [
        (depth: 0, maximumNodes: Int?.none),
        (depth: 0, maximumNodes: 3),
        (depth: 1, maximumNodes: 3),
    ])
    func sharesEmptyContainers(configuration: (depth: Int, maximumNodes: Int?)) throws {
        let plan = try GeneratorDerivationPlan(for: BudgetEmptyPair.self, overrides: [:])
        let builder = BudgetedGeneratorDerivation(plan: plan)
        let generator = try builder.root(
            for: BudgetEmptyPair.self,
            recursion: .pinned(configuration.depth),
            maximumNodes: configuration.maximumNodes
        )
        let key = ContainerBudgetKey(
            type: ObjectIdentifier([BudgetRose].self),
            recursionAllowance: PayloadRecursionAllowance(
                source: ObjectIdentifier(BudgetEmptyPair.self),
                inherited: configuration.depth,
                recursive: configuration.depth
            ),
            nodes: configuration.maximumNodes.map { ($0 - 1) / 2 },
            domain: .full
        )
        let cached = try #require(builder.containers[key])
        #expect(cached.isReflective)
        let empty = BudgetEmptyPair(first: [], second: [])
        let nonempty = BudgetEmptyPair(first: [.children([])], second: [])
        let samples = try #example(generator, count: 20, seed: 42)
        switch configuration.maximumNodes {
            case .none:
                #expect(builder.containers.count == 2)
                #expect(builder.built.count == 2)
                #expect(samples.contains { $0 != empty })
                let reflected = try #require(try Interpreters.reflect(generator.gen, with: nonempty))
                #expect(try Interpreters.replay(generator.gen, using: reflected) == nonempty)
            case .some:
                #expect(builder.containers.count == 1)
                #expect(builder.built.count == 1)
                #expect(samples.allSatisfy { $0 == empty })
                #expect(throws: ReflectionError.inputWasOutOfGeneratorRange("1", range: "0...0")) {
                    try Interpreters.reflect(generator.gen, with: nonempty)
                }
        }
        let reflected = try #require(try Interpreters.reflect(generator.gen, with: empty))
        #expect(try Interpreters.replay(generator.gen, using: reflected) == empty)
    }

    @Test("Budgeted binary trees and recursive arrays pass examine")
    func examinesBudgetedGenerators() {
        let binary = #examine(
            BudgetBinary.gen(.budget(.custom(recursion: 4, nodes: 15))),
            .samples(30),
            .replay(42),
            .suppress(.logs)
        ) { first, second in first == second }
        expectSuccessfulExamination(binary, samples: 30)
        let arrays = #examine(
            BudgetRose.gen(recursion: 2, .budget(.custom(recursion: 2, nodes: 12))),
            .samples(30),
            .replay(42),
            .suppress(.logs)
        ) { first, second in first == second }
        expectSuccessfulExamination(arrays, samples: 30)
        let ramped = #examine(
            BudgetRose.gen(.budget(.custom(recursion: 3, nodes: 12))),
            .samples(30),
            .replay(42),
            .suppress(.logs)
        ) { first, second in first == second }
        expectSuccessfulExamination(ramped, samples: 30)
    }

    @Test("Reduction can decrease collection cardinality under a conserved budget")
    func reduction() throws {
        let generator = BudgetRose.gen(recursion: 2, .budget(.custom(recursion: 2, nodes: 12)))
        let value = BudgetRose.children([.children([]), .children([])])
        let tree = try #require(try Interpreters.reflect(generator.gen, with: value))
        let result = try Interpreters.choiceGraphReduceCollectingStats(
            gen: generator.gen,
            tree: tree,
            output: value,
            config: Interpreters.ReducerConfiguration(maxStalls: 2),
            property: { value in
                switch value {
                    case let .children(children):
                        children.isEmpty
                }
            }
        )
        let reduced = try #require(result.outcome.counterexample)
        #expect(reduced.1 == .children([.children([])]))
    }
}

// MARK: - Fixtures

@Exhaustable
private indirect enum BudgetRose: Equatable {
    case children([BudgetRose])

    /// The node cost of `.children([])`, the smallest rose a derivation can build.
    static let minimumNodes = 2

    var nodes: Int {
        switch self {
            case let .children(children):
                2 + children.reduce(0) { $0 + $1.nodes }
        }
    }

    var depth: Int {
        switch self {
            case let .children(children):
                children.map { $0.depth + 1 }.max() ?? 0
        }
    }
}

@Exhaustable
private struct BudgetEmptyPair: Equatable {
    let first: [BudgetRose]
    let second: [BudgetRose]
}

@Exhaustable
private indirect enum BudgetBinary: Equatable {
    case leaf
    case branch(BudgetBinary, BudgetBinary)
}

@Exhaustable
private indirect enum BudgetHeap: Equatable {
    case empty
    case node(Int, BudgetHeap, BudgetHeap)
}

@Exhaustable
private struct BudgetLeaf: Equatable {
    let number: Int
}

@Exhaustable
private struct BudgetPair: Equatable {
    let first: BudgetLeaf
    let second: BudgetLeaf
}

@Exhaustable
private struct BudgetWrapper: Equatable {
    let value: BudgetLeaf
}

@Exhaustable
private enum BudgetUneven: Equatable {
    case wide(Int, Int, Int, Int)
    case wrapped(BudgetWrapper)
}

@Exhaustable(.budget(.custom(recursion: 3, nodes: 7)))
private indirect enum BudgetCapped: Equatable {
    case leaf
    case branch(BudgetCapped, BudgetCapped)

    var nodes: Int {
        switch self {
            case .leaf:
                1
            case let .branch(first, second):
                1 + first.nodes + second.nodes
        }
    }

    static func full(depth: Int) -> Self {
        depth == 0 ? .leaf : .branch(full(depth: depth - 1), full(depth: depth - 1))
    }
}

@Exhaustable
private struct BudgetCappedHolder {
    let first: BudgetCapped
    let second: BudgetCapped
}

@Exhaustable(.budget(.custom(recursion: 10, nodes: 1)))
private struct BudgetImpossible {
    let number: Int
}

@Exhaustable
private struct BudgetImpossibleHolder {
    let value: BudgetImpossible
}

@Exhaustable
private struct BudgetOptionalImpossible {
    let value: BudgetImpossible?
}

@Exhaustable(.budget(.custom(recursion: 10, nodes: 0)))
private enum BudgetInvalid { case leaf }

@Exhaustable
private struct BudgetContainers: Equatable {
    let array: [Int]
    let optional: Int?
    let set: Set<Int>
    let dictionary: [Int: Int]
    let nested: [[Int]]

    var nodes: Int {
        6 + array.count + (optional == nil ? 0 : 1) + set.count + 2 * dictionary.count
            + nested.reduce(0) { $0 + 1 + $1.count }
    }
}

@Exhaustable
private struct BudgetArrayHolder: Equatable {
    let values: [Int]
}

@Exhaustable
private indirect enum BudgetMutualFirst: Equatable {
    case next(BudgetMutualSecond)

    var nodes: Int {
        switch self {
            case let .next(child):
                1 + child.nodes
        }
    }
}

@Exhaustable
private indirect enum BudgetMutualSecond: Equatable {
    case leaf
    case next(BudgetMutualFirst)

    var nodes: Int {
        switch self {
            case .leaf:
                1
            case let .next(child):
                1 + child.nodes
        }
    }
}

@Exhaustable
private indirect enum BudgetOptional: Equatable {
    case child(BudgetOptional?)

    var nodes: Int {
        switch self {
            case let .child(child):
                2 + (child?.nodes ?? 0)
        }
    }
}

@Exhaustable
private indirect enum BudgetSet: Hashable {
    case children(Set<BudgetSet>)

    var nodes: Int {
        switch self {
            case let .children(children):
                2 + children.reduce(0) { $0 + $1.nodes }
        }
    }
}

@Exhaustable
private indirect enum BudgetDictionary: Hashable {
    case children([BudgetDictionary: BudgetDictionary])

    var nodes: Int {
        switch self {
            case let .children(children):
                2 + children.reduce(0) { $0 + $1.key.nodes + $1.value.nodes }
        }
    }
}

// MARK: - Helpers

/// Collects declared unsigned choice ranges so container support can be checked independently from size-scaled sampling.
private func unsignedChoiceRanges(in tree: ChoiceTree) -> [ClosedRange<UInt64>] {
    switch tree {
        case let .choice(value, metadata):
            guard value.tag == .uint64, let validRange = metadata.validRange else {
                return []
            }
            return [validRange]
        case let .branch(branch):
            return unsignedChoiceRanges(in: branch.choice)
        case let .group(children, _, _):
            return children.flatMap { unsignedChoiceRanges(in: $0) }
        case let .sequence(elements, _):
            return elements.flatMap { unsignedChoiceRanges(in: $0) }
        case let .bind(_, inner, bound):
            return unsignedChoiceRanges(in: inner) + unsignedChoiceRanges(in: bound)
        case let .resize(_, choices):
            return choices.flatMap { unsignedChoiceRanges(in: $0) }
        case .just, .getSize:
            return []
    }
}

/// Checks the hard ceiling against the value, then checks reflected replay rather than requiring identical choices after set or dictionary deduplication.
private func checkBudget<Value: Equatable>(
    _ generator: ReflectiveGenerator<Value>,
    maximumNodes: Int,
    minimumNodes: Int,
    nodes: (Value) -> Int
) throws {
    var interpreter = ValueAndChoiceTreeInterpreter(generator.gen, seed: 42, sizeOverride: 100)
    var counts: [Int] = []
    for _ in 0 ..< 30 {
        let (value, _) = try #require(try interpreter.next())
        counts.append(nodes(value))
        #expect(nodes(value) <= maximumNodes)
        let tree = try #require(try Interpreters.reflect(generator.gen, with: value))
        #expect(try Interpreters.replay(generator.gen, using: tree) == value)
    }
    #expect(counts.contains { $0 > minimumNodes }, "every draw stayed at the minimum \(minimumNodes), so the allowance of \(maximumNodes) was never used")
}
