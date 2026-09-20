import Exhaust
import ExhaustCore
import ExhaustTestSupport
import Testing
@testable import ExhaustGenerators

@Suite("Resolved generator derivation")
struct GeneratorDerivationPlanTests {
    @Test("Acyclic products do not consume recursive fuel")
    func finiteProducts() throws {
        let plan = try GeneratorDerivationPlan(for: PlanEnvelope.self, overrides: [:])
        #expect(try plan.minimumRecursionBudget(for: PlanEnvelope.self, at: 3) == 0)
        #expect(try plan.minimumRecursionBudget(for: PlanEnvelope.self, at: 0) == 0)
        let generator = ReflectiveGenerator<PlanEnvelope>.derived(.budget(.custom(recursion: 3, nodes: 100)), overriding: .int(in: 0 ... 9))
        let samples = try #example(generator, count: 30)
        #expect(samples.allSatisfy { (0 ... 9).contains($0.payload.number) })
        let target = PlanEnvelope(payload: PlanLeaf(number: 7))
        try expectReflectionRoundTrip(generator.gen, value: target)
        try expectReflectionRoundTrip(PlanEnvelope.gen().gen, value: target)
        try expectReflectionRoundTrip(ReflectiveGenerator<PlanEnvelope>.derived(.budget(.custom(recursion: 1, nodes: 100))).gen, value: target)
    }

    @Test("Root construction preserves recursion diagnostics with and without a node ceiling", arguments: [Int?.none, 4], [false, true])
    func rootRecursionDiagnostics(maximumNodes: Int?, pinned: Bool) throws {
        let plan = try GeneratorDerivationPlan(for: PlanEnvelope.self, overrides: [:])
        let builder = BudgetedGeneratorDerivation(plan: plan)
        #expect(throws: GeneratorDerivationError.insufficientRecursionBudget(type: "PlanEnvelope", minimum: 0, requested: -1)) {
            try builder.root(
                for: PlanEnvelope.self,
                recursion: pinned ? .pinned(-1) : .drawn(ceiling: -1, scaling: .linear),
                maximumNodes: maximumNodes
            )
        }
        #expect(builder.built.isEmpty)
        let cyclePlan = try GeneratorDerivationPlan(for: PlanCycleFirst.self, overrides: [:])
        let cycleBuilder = BudgetedGeneratorDerivation(plan: cyclePlan)
        #expect(throws: GeneratorDerivationError.noFiniteConstruction(
            type: "PlanCycleFirst",
            dependencyPath: ["PlanCycleFirst", "PlanCycleSecond", "PlanCycleFirst"]
        )) {
            try cycleBuilder.root(
                for: PlanCycleFirst.self,
                recursion: pinned ? .pinned(10) : .drawn(ceiling: 10, scaling: .linear),
                maximumNodes: maximumNodes
            )
        }
        #expect(cycleBuilder.built.isEmpty)
    }

    @Test("Acyclic constructors remain available at zero recursive fuel")
    func filtersInfeasibleCases() throws {
        let generator = ReflectiveGenerator<PlanUnevenSum>.derived(
            recursion: 0,
            overriding: .int(in: 7 ... 7)
        )
        let samples = try #example(generator, count: 20)
        #expect(samples.contains { $0 == .shallow(PlanLeaf(number: 7)) })
        #expect(samples.contains { $0 == .deep(PlanEnvelope(payload: PlanLeaf(number: 7))) })
        try expectReflectionRoundTrip(
            generator.gen,
            value: .deep(PlanEnvelope(payload: PlanLeaf(number: 7)))
        )
    }

    @Test("Invalid annotations and unresolved payloads produce specific diagnostics")
    func resolutionDiagnostics() {
        #expect(throws: GeneratorDerivationError.invalidRecursionBudget(type: "PlanNegativeRecursion", recursion: -1)) {
            try GeneratorDerivationPlan(for: PlanNegativeRecursion.self, overrides: [:])
        }
        #expect(throws: GeneratorDerivationError.unsupportedPayload(type: "PlanUnsupportedValue")) {
            try GeneratorDerivationPlan(for: PlanUnsupportedHolder.self, overrides: [:])
        }
    }

    @Test("A user-named generator affects payload resolution only through an explicit override")
    func customGeneratorRequiresOverride() throws {
        let generator = ReflectiveGenerator<PlanCustomDefaultHolder>.derived(recursion: 1, overriding: .int(in: 7 ... 7))
        let samples = try #example(generator, count: 10)
        #expect(samples.allSatisfy { $0.value.number == 7 })
        let overridden = ReflectiveGenerator<PlanCustomDefaultHolder>.derived(
            recursion: 0,
            overriding: PlanCustomDefault.defaultGenerator
        )
        let overriddenSamples = try #example(overridden, count: 10)
        #expect(overriddenSamples.allSatisfy { $0.value.number == 99 })
    }

    @Test("Mutually recursive types propagate a finite minimum through the cycle")
    func mutualRecursion() throws {
        let plan = try GeneratorDerivationPlan(for: PlanFirst.self, overrides: [:])
        #expect(plan.types.count == 2)
        #expect(try plan.minimumRecursionBudget(for: PlanFirst.self, at: 4) == 1)
        #expect(try plan.minimumRecursionBudget(for: PlanSecond.self, at: 4) == 0)
        let base = ReflectiveGenerator<PlanFirst>.derived(recursion: 1)
        let samples = try #example(base, count: 10)
        #expect(samples.allSatisfy { $0 == .second(.leaf) })
        let generator = ReflectiveGenerator<PlanFirst>.derived(.budget(.custom(recursion: 4, nodes: 100)))
        try expectReflectionRoundTrip(generator.gen, value: .second(.first(.second(.leaf))))
    }

    @Test("An empty container supplies the exit from a mutual recursion cycle")
    func mutualContainerRecursion() throws {
        let plan = try GeneratorDerivationPlan(for: PlanContainerFirst.self, overrides: [:])
        #expect(plan.types.count == 2)
        #expect(try plan.minimumRecursionBudget(for: PlanContainerFirst.self, at: 2) == 0)
        #expect(try plan.minimumRecursionBudget(for: PlanContainerSecond.self, at: 2) == 1)
        let base = ReflectiveGenerator<PlanContainerFirst>.derived(recursion: 1)
        let samples = try #example(base, count: 10)
        #expect(samples.allSatisfy { $0.children.isEmpty })
        try expectReflectionRoundTrip(
            ReflectiveGenerator<PlanContainerFirst>.derived(.budget(.custom(recursion: 2, nodes: 100))).gen,
            value: PlanContainerFirst(children: [.first(PlanContainerFirst(children: []))])
        )
    }

    @Test("A cycle with no exit reports its dependency path before construction")
    func impossibleCycle() throws {
        let plan = try GeneratorDerivationPlan(for: PlanCycleFirst.self, overrides: [:])
        #expect(plan.types.count == 2)
        #expect(throws: GeneratorDerivationError.noFiniteConstruction(
            type: "PlanCycleFirst",
            dependencyPath: ["PlanCycleFirst", "PlanCycleSecond", "PlanCycleFirst"]
        )) {
            try plan.minimumRecursionBudget(for: PlanCycleFirst.self, at: 10)
        }
    }

    @Test("A nested zero budget permits required acyclic products")
    func nestedCeiling() throws {
        let plan = try GeneratorDerivationPlan(for: PlanCeilingHolder.self, overrides: [:])
        #expect(try plan.minimumRecursionBudget(for: PlanCeilingHolder.self, at: 0) == 0)
        let required = ReflectiveGenerator<PlanCeilingHolder>.derived(recursion: 0)
        let requiredSamples = try #example(required, count: 10)
        #expect(requiredSamples.count == 10)
        let optional = ReflectiveGenerator<PlanOptionalCeilingHolder>.derived(
            .budget(.custom(recursion: 3, nodes: 100))
        )
        let optionalSamples = try #example(optional, count: 1000, seed: 1337)
        let presentValues = optionalSamples.count(where: { $0.value != nil })
        #expect((180 ... 220).contains(presentValues), "\(presentValues) of \(optionalSamples.count) optional values were present")
    }

    @Test("An override is an opaque leaf even when its output is annotated")
    func annotatedOverrideTerminates() throws {
        let supplied = ReflectiveGenerator<PlanLeaf>.just(PlanLeaf(number: 42))
        let plan = try GeneratorDerivationPlan(
            for: PlanEnvelope.self,
            overrides: [ObjectIdentifier(PlanLeaf.self): supplied.erasedForDerivation()]
        )
        #expect(plan.types.count == 1)
        #expect(try plan.minimumRecursionBudget(for: PlanEnvelope.self, at: 0) == 0)
        let generator = ReflectiveGenerator<PlanEnvelope>.derived(recursion: 0, overriding: supplied)
        let samples = try #example(generator, count: 10)
        #expect(samples.allSatisfy { $0.payload.number == 42 })
        try expectReflectionRoundTrip(generator.gen, value: PlanEnvelope(payload: PlanLeaf(number: 42)))
    }

    @Test("Array recursion terminates at an empty container without negative layers")
    func recursiveArray() throws {
        let plan = try GeneratorDerivationPlan(for: PlanArrayTree.self, overrides: [:])
        let derivation = BudgetedGeneratorDerivation(plan: plan)
        let base = derivation.generator(for: PlanArrayTree.self, recursion: 0, nodes: nil)
        #expect(try plan.minimumRecursionBudget(for: PlanArrayTree.self, at: 0) == 0)
        #expect(derivation.built.count == 1)
        #expect(derivation.built.keys.allSatisfy { $0.recursion >= 0 })
        let samples = try #example(base, count: 10)
        #expect(samples.allSatisfy { $0 == .children([]) })
        try expectReflectionRoundTrip(base.gen, value: .children([]))
        let children: [PlanArrayTree] = [.children([])]
        #expect(throws: ReflectionError.couldNotReflectOnZipElement(String(describing: children))) {
            try Interpreters.reflect(base.gen, with: .children(children))
        }
        try expectReflectionRoundTrip(
            ReflectiveGenerator<PlanArrayTree>.derived(.budget(.custom(recursion: 2, nodes: 100))).gen,
            value: .children([.children([.children([])])])
        )
    }

    @Test("Container recursion reduces to the smallest nonempty tree")
    func reducesRecursiveContainer() throws {
        let generator = ReflectiveGenerator<PlanArrayTree>.derived(.budget(.custom(recursion: 2, nodes: 100)))
        let value: PlanArrayTree = .children([.children([]), .children([])])
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

    @Test("Optional, set, and dictionary recursion have empty base constructions")
    func otherRecursiveContainers() throws {
        let optional = ReflectiveGenerator<PlanOptionalTree>.derived(recursion: 0)
        let set = ReflectiveGenerator<PlanSetTree>.derived(recursion: 0)
        let dictionary = ReflectiveGenerator<PlanDictionaryTree>.derived(recursion: 0)
        #expect(try #example(optional, count: 10).allSatisfy { $0 == .child(nil) })
        #expect(try #example(set, count: 10).allSatisfy { $0 == .children([]) })
        #expect(try #example(dictionary, count: 10).allSatisfy { $0 == .children([:]) })
        try expectReflectionRoundTrip(optional.gen, value: .child(nil))
        try expectReflectionRoundTrip(set.gen, value: .children([]))
        try expectReflectionRoundTrip(dictionary.gen, value: .children([:]))
        let optionalChild: PlanOptionalTree? = .child(nil)
        let setChildren: Set<PlanSetTree> = [.children([])]
        let dictionaryChildren: [PlanDictionaryTree: PlanDictionaryTree] = [.children([:]): .children([:])]
        #expect(throws: ReflectionError.inputWasOutOfGeneratorRange("1", range: "0...0")) {
            try Interpreters.reflect(optional.gen, with: .child(optionalChild))
        }
        #expect(throws: ReflectionError.inputWasOutOfGeneratorRange("1", range: "0...0")) {
            try Interpreters.reflect(set.gen, with: .children(setChildren))
        }
        #expect(throws: ReflectionError.inputWasOutOfGeneratorRange("1", range: "0...0")) {
            try Interpreters.reflect(dictionary.gen, with: .children(dictionaryChildren))
        }
        try expectReflectionRoundTrip(
            ReflectiveGenerator<PlanOptionalTree>.derived(recursion: 1).gen,
            value: .child(.child(nil))
        )
        try expectReflectionRoundTrip(
            ReflectiveGenerator<PlanSetTree>.derived(recursion: 1).gen,
            value: .children([.children([])])
        )
        try expectReflectionRoundTrip(
            ReflectiveGenerator<PlanDictionaryTree>.derived(recursion: 1).gen,
            value: .children([.children([:]): .children([:])])
        )
    }

    @Test("Nested containers preserve fuel across acyclic derived edges")
    func nestedContainers() throws {
        let base = ReflectiveGenerator<PlanNestedContainers>.derived(recursion: 0)
        try expectReflectionRoundTrip(base.gen, value: PlanNestedContainers(values: [[], []]))
        let target = PlanNestedContainers(values: [[.children([])]])
        try expectReflectionRoundTrip(base.gen, value: target)
        let recursiveTarget = PlanNestedContainers(values: [[.children([.children([])])]])
        #expect(throws: ReflectionError.inputWasOutOfGeneratorRange("1", range: "0...0")) {
            try Interpreters.reflect(base.gen, with: recursiveTarget)
        }
        try expectReflectionRoundTrip(
            ReflectiveGenerator<PlanNestedContainers>.derived(recursion: 1).gen,
            value: recursiveTarget
        )
    }

    @Test("Empty fallback rejects nonempty reflection targets without Equatable")
    func nonEquatableEmptyContainers() throws {
        let array = ReflectiveGenerator<PlanNonEquatableTree>.derived(recursion: 0)
        #expect(try Interpreters.reflect(array.gen, with: .children([])) != nil)
        let children: [PlanNonEquatableTree] = [.children([])]
        #expect(throws: ReflectionError.inputWasOutOfGeneratorRange("1", range: "0...0")) {
            try Interpreters.reflect(array.gen, with: .children(children))
        }
        let optional = ReflectiveGenerator<PlanNonEquatableOptional>.derived(recursion: 0)
        #expect(try Interpreters.reflect(optional.gen, with: .child(nil)) != nil)
        let child: PlanNonEquatableOptional? = .child(nil)
        #expect(throws: ReflectionError.inputWasOutOfGeneratorRange("1", range: "0...0")) {
            try Interpreters.reflect(optional.gen, with: .child(child))
        }
    }

    @Test("Element overrides apply to every standard container and nested containers")
    func containerOverrides() throws {
        // Use an explicit rejection error so this checks resolver routing independently of empty-pick reflection behavior.
        let supplied = Gen.contramap(
            { (input: Int) throws -> Int in
                guard input == 7 else {
                    throw ReflectionError.couldNotMapInputToGenerator
                }
                return input
            },
            Gen.just(7)
        ).wrapped(isReflective: true)
        let generator = ReflectiveGenerator<PlanIntegerContainers>.derived(recursion: 0, overriding: supplied)
        let target = PlanIntegerContainers(direct: 7, array: [7], optional: 7, set: [7], dictionary: [7: 7], nested: [[7]])
        try expectReflectionRoundTrip(generator.gen, value: target)
        let samples = try #example(generator.resize(1), count: 20)
        for sample in samples {
            #expect(sample.direct == 7)
            #expect(sample.array.allSatisfy { $0 == 7 })
            #expect(sample.optional == nil || sample.optional == 7)
            #expect(sample.set.allSatisfy { $0 == 7 })
            #expect(sample.dictionary.allSatisfy { $0.key == 7 && $0.value == 7 })
            #expect(sample.nested.allSatisfy { $0.allSatisfy { $0 == 7 } })
        }
        let outsideOverride = [
            PlanIntegerContainers(direct: 7, array: [8], optional: 7, set: [7], dictionary: [7: 7], nested: [[7]]),
            PlanIntegerContainers(direct: 7, array: [7], optional: 8, set: [7], dictionary: [7: 7], nested: [[7]]),
            PlanIntegerContainers(direct: 7, array: [7], optional: 7, set: [8], dictionary: [7: 7], nested: [[7]]),
            PlanIntegerContainers(direct: 7, array: [7], optional: 7, set: [7], dictionary: [8: 7], nested: [[7]]),
            PlanIntegerContainers(direct: 7, array: [7], optional: 7, set: [7], dictionary: [7: 8], nested: [[7]]),
            PlanIntegerContainers(direct: 7, array: [7], optional: 7, set: [7], dictionary: [7: 7], nested: [[8]]),
        ]
        for value in outsideOverride {
            #expect(throws: ReflectionError.couldNotMapInputToGenerator) {
                try Interpreters.reflect(generator.gen, with: value)
            }
        }
    }

    @Test("An exact container override precedes its element override")
    func exactContainerOverride() throws {
        let generator = ReflectiveGenerator<PlanArrayHolder>.derived(
            recursion: 0,
            overriding: ReflectiveGenerator<[Int]>.just([99]), .int(in: 7 ... 7)
        )
        let samples = try #example(generator, count: 10)
        #expect(samples.allSatisfy { $0.values == [99] })
    }

    @Test("Ordinary recursion preserves values and the following random draw", arguments: [UInt64(0), 1, 42])
    func preservesRandomStream(seed: UInt64) throws {
        let plan = try GeneratorDerivationPlan(for: PlanBinaryTree.self, overrides: [:])
        let builder = BudgetedGeneratorDerivation(plan: plan)
        let derived = try builder.root(
            for: PlanBinaryTree.self,
            recursion: .pinned(4),
            maximumNodes: nil
        )
        let reference = referenceBinaryTree(recursion: 4)
        try expectMatchingRandomStream(
            derived.gen,
            reference: reference.gen,
            seed: seed,
            size: nil,
            draws: 100
        )
    }

    @Test("Every recursive-fuel layer is shared across sibling occurrences and root requests")
    func sharesLayers() throws {
        let plan = try GeneratorDerivationPlan(for: PlanBinaryTree.self, overrides: [:])
        let derivation = BudgetedGeneratorDerivation(plan: plan)
        _ = derivation.generator(for: PlanBinaryTree.self, recursion: 6, nodes: nil)
        #expect(derivation.plan.types.count == 1)
        #expect(derivation.built.count == 4)
        #expect(Set(derivation.built.keys.map(\.recursion)) == [0, 2, 6])
        for recursion in 0 ... 6 {
            _ = derivation.generator(for: PlanBinaryTree.self, recursion: recursion, nodes: nil)
        }
        #expect(derivation.built.count == 12)
    }
}

// MARK: - Fixtures

@Exhaustable
private struct PlanLeaf: Equatable {
    let number: Int
}

@Exhaustable
private struct PlanEnvelope: Equatable {
    let payload: PlanLeaf
}

@Exhaustable
private enum PlanUnevenSum: Equatable {
    case shallow(PlanLeaf)
    case deep(PlanEnvelope)
}

@Exhaustable(.budget(.custom(recursion: -1, nodes: 100)))
private enum PlanNegativeRecursion {
    case leaf
}

private struct PlanUnsupportedValue {}

@Exhaustable
private struct PlanUnsupportedHolder {
    let value: PlanUnsupportedValue
}

@Exhaustable
private struct PlanCustomDefault {
    let number: Int

    static var defaultGenerator: ReflectiveGenerator<PlanCustomDefault> {
        .just(PlanCustomDefault(number: 99))
    }
}

@Exhaustable
private struct PlanCustomDefaultHolder {
    let value: PlanCustomDefault
}

@Exhaustable
private indirect enum PlanFirst: Equatable {
    case second(PlanSecond)
}

@Exhaustable
private indirect enum PlanSecond: Equatable {
    case leaf
    case first(PlanFirst)
}

@Exhaustable
private struct PlanContainerFirst: Equatable {
    let children: [PlanContainerSecond]
}

@Exhaustable
private indirect enum PlanContainerSecond: Equatable {
    case first(PlanContainerFirst)
}

@Exhaustable
private indirect enum PlanCycleFirst {
    case second(PlanCycleSecond)
}

@Exhaustable
private indirect enum PlanCycleSecond {
    case first(PlanCycleFirst)
}

@Exhaustable(.budget(.custom(recursion: 0, nodes: 100)))
private struct PlanCappedProduct: Equatable {
    let leaf: PlanLeaf
}

@Exhaustable
private struct PlanCeilingHolder {
    let value: PlanCappedProduct
}

@Exhaustable
private struct PlanOptionalCeilingHolder {
    let value: PlanCappedProduct?
}

@Exhaustable
private indirect enum PlanArrayTree: Equatable {
    case children([PlanArrayTree])
}

@Exhaustable
private indirect enum PlanOptionalTree: Equatable {
    case child(PlanOptionalTree?)
}

@Exhaustable
private indirect enum PlanSetTree: Hashable {
    case children(Set<PlanSetTree>)
}

@Exhaustable
private indirect enum PlanDictionaryTree: Hashable {
    case children([PlanDictionaryTree: PlanDictionaryTree])
}

@Exhaustable
private struct PlanNestedContainers: Equatable {
    let values: [[PlanArrayTree]]
}

@Exhaustable
private indirect enum PlanNonEquatableTree {
    case children([PlanNonEquatableTree])
}

@Exhaustable
private indirect enum PlanNonEquatableOptional {
    case child(PlanNonEquatableOptional?)
}

@Exhaustable
private struct PlanIntegerContainers: Equatable {
    let direct: Int
    let array: [Int]
    let optional: Int?
    let set: Set<Int>
    let dictionary: [Int: Int]
    let nested: [[Int]]
}

@Exhaustable
private struct PlanArrayHolder {
    let values: [Int]
}

@Exhaustable
private indirect enum PlanBinaryTree: Equatable {
    case leaf
    case branch(PlanBinaryTree, PlanBinaryTree)
}

// MARK: - Helpers

/// Matches the original recursive distribution using ordinary combinators, without the derivation planner or its payload resolver.
private func referenceBinaryTree(recursion: Int) -> ReflectiveGenerator<PlanBinaryTree> {
    guard recursion > 0 else {
        return .oneOf([.just(.leaf)])
    }
    let child = referenceBinaryTree(recursion: (recursion - 1) / 2)
    let branch = Gen.zip(child.gen, child.gen)
        .map { PlanBinaryTree.branch($0.0, $0.1) }
        .wrapped(isReflective: false)
    return .oneOf([.just(.leaf), .lazy { branch }])
}
