import Exhaust
import ExhaustCore
import Testing

@Suite("Generator derivation")
struct GeneratorDerivationTests {
    @Test("The macro lists every case with its payload types in declaration order")
    func descriptorListsCases() {
        let constructors = Term.__generatorDescriptor.constructors
        #expect(constructors.map(\.name) == ["variable", "abstraction", "application", "typeAbstraction", "typeApplication"])
        #expect(constructors[0].payloadTypes.count == 1)
        #expect(ObjectIdentifier(constructors[0].payloadTypes[0]) == ObjectIdentifier(Int.self))
        #expect(ObjectIdentifier(constructors[1].payloadTypes[0]) == ObjectIdentifier(TermType.self))
        #expect(ObjectIdentifier(constructors[1].payloadTypes[1]) == ObjectIdentifier(Term.self))
        #expect(TermType.__generatorDescriptor.constructors[0].payloadTypes.isEmpty)
    }

    @Test("Embed and extract round-trip a case and reject another")
    func embedExtractRoundTrip() {
        let abstraction = Term.__generatorDescriptor.constructors[1]
        let value = abstraction.embed([TermType.top, Term.variable(3)])
        #expect(value == .abstraction(.top, .variable(3)))
        let extracted = abstraction.extract(value)
        #expect(extracted?.count == 2)
        #expect(extracted?[1] as? Term == .variable(3))
        #expect(abstraction.extract(.variable(0)) == nil)
    }

    @Test("A derived generator produces every case and respects the depth bound")
    func derivedGeneratorCoversCasesWithinDepth() throws {
        let generator = ReflectiveGenerator<Term>.derived(depth: 4, overriding: .int(in: 0 ... 3))
        let samples = try #example(generator, count: 500)
        var seen: Set<String> = []
        for sample in samples {
            #expect(sample.depth <= 4, "\(sample)")
            #expect(sample.indicesWithin(0 ... 3), "\(sample)")
            seen.formUnion(sample.caseNames)
        }
        #expect(seen == Set(Term.__generatorDescriptor.constructors.map(\.name)))
    }

    @Test("Depth zero keeps only the cases without a derived-type payload")
    func depthZeroIsBaseCasesOnly() throws {
        let generator = ReflectiveGenerator<Term>.derived(depth: 0, overriding: .int(in: 0 ... 3))
        let samples = try #example(generator, count: 50)
        for sample in samples {
            guard case .variable = sample else {
                Issue.record("Expected a variable at depth zero, got \(sample)")
                return
            }
        }
    }

    @Test("Depth zero prefers cases without associated values when the enum has any")
    func depthZeroPrefersPayloadFreeCases() throws {
        let generator = ReflectiveGenerator<TermType>.derived(depth: 0, overriding: .int(in: 0 ... 3))
        let samples = try #example(generator, count: 50)
        #expect(samples.allSatisfy { $0 == .top })
        let nested = ReflectiveGenerator<Term>.derived(depth: 1, overriding: .int(in: 0 ... 3))
        let nestedSamples = try #example(nested, count: 300)
        let types = nestedSamples.compactMap { sample -> TermType? in
            switch sample {
                case let .abstraction(type, _), let .typeAbstraction(type, _), let .typeApplication(_, type):
                    type
                case .variable, .application:
                    nil
            }
        }
        #expect(types.isEmpty == false)
        #expect(types.allSatisfy { $0 == .top })
    }

    @Test("A derived generator reduces a counterexample to the smallest failing term")
    func derivedGeneratorReduces() throws {
        let generator = ReflectiveGenerator<Term>.derived(depth: 4, overriding: .int(in: 0 ... 3))
        var interpreter = ValueAndChoiceTreeInterpreter(generator.gen, materializePicks: true, seed: 11)
        let property: (Term) -> Bool = { $0.caseNames.contains("typeApplication") == false }
        var found: (value: Term, tree: ChoiceTree)?
        for _ in 0 ..< 2000 {
            let (value, tree) = try #require(try interpreter.next())
            if property(value) == false {
                found = (value, tree)
                break
            }
        }
        let counterexample = try #require(found)
        let start = ContinuousClock.now
        let result = try Interpreters.choiceGraphReduceCollectingStats(
            gen: generator.gen,
            tree: counterexample.tree,
            output: counterexample.value,
            config: Interpreters.ReducerConfiguration(maxStalls: 2),
            property: property
        )
        let elapsed = ContinuousClock.now - start
        let reduced = try #require(result.outcome.counterexample)
        #expect(reduced.1 == .typeApplication(.variable(0), .top), "\(reduced.1) after \(elapsed), \(result.stats.reductionProbes) probes")
        #expect(elapsed < .seconds(5), "\(elapsed), \(result.stats.reductionProbes) probes")
    }

    @Test("A struct derives through its stored properties and reflects")
    func structDerives() throws {
        let generator = ReflectiveGenerator<Binding>.derived(depth: 2, overriding: .int(in: 0 ... 3))
        let samples = try #example(generator, count: 200)
        #expect(samples.contains { $0.term.depth > 0 })
        #expect(samples.allSatisfy { $0.term.indicesWithin(0 ... 3) && $0.term.depth <= 2 })
        let target = Binding(name: "f", term: .abstraction(.top, .variable(1)), pinned: true)
        let tree = try #require(try Interpreters.reflect(generator.gen, with: target))
        let replayed = try #require(try Interpreters.replay(generator.gen, using: tree))
        #expect(replayed == target)
    }

    @Test("A custom payload generator is supplied explicitly and reflects")
    func customPayloadOverrideReflects() throws {
        let generator = ReflectiveGenerator<Account>.derived(depth: 1, overriding: Money.defaultGenerator)
        let samples = try #example(generator, count: 100)
        #expect(samples.allSatisfy { (0 ... 9).contains($0.balance.cents) })
        let target = Account(balance: Money(cents: 7), open: true)
        let tree = try #require(try Interpreters.reflect(generator.gen, with: target))
        let replayed = try #require(try Interpreters.replay(generator.gen, using: tree))
        #expect(replayed == target)
    }

    @Test("The drawn depth ramps with the size and is reducible")
    func drawnDepthRampsAndReduces() throws {
        let generator = ReflectiveGenerator<Term>.derived(overriding: .int(in: 0 ... 3))
        func deepest(atSize size: UInt64, samples: Int) throws -> Int {
            var interpreter = ValueAndChoiceTreeInterpreter(generator.gen, seed: 3, maxRuns: 10000, sizeOverride: size)
            var deepest = 0
            for _ in 0 ..< samples {
                let (value, _) = try #require(try interpreter.next())
                deepest = max(deepest, value.depth)
            }
            return deepest
        }
        let atSmall = try deepest(atSize: 5, samples: 200)
        let atMiddle = try deepest(atSize: 50, samples: 200)
        let atFull = try deepest(atSize: 100, samples: 400)
        #expect(atSmall <= 1)
        #expect(atMiddle > atSmall)
        #expect(atFull > atMiddle)
        #expect(atFull <= ReflectiveGenerator<Term>.defaultMaximumDepth)

        var interpreter = ValueAndChoiceTreeInterpreter(generator.gen, materializePicks: true, seed: 11, maxRuns: 10000, sizeOverride: 100)
        let property: (Term) -> Bool = { $0.caseNames.contains("typeApplication") == false }
        var found: (value: Term, tree: ChoiceTree)?
        for _ in 0 ..< 2000 {
            let (value, tree) = try #require(try interpreter.next())
            if property(value) == false {
                found = (value, tree)
                break
            }
        }
        let counterexample = try #require(found)
        let result = try Interpreters.choiceGraphReduceCollectingStats(
            gen: generator.gen,
            tree: counterexample.tree,
            output: counterexample.value,
            config: Interpreters.ReducerConfiguration(maxStalls: 2),
            property: property
        )
        let reduced = try #require(result.outcome.counterexample)
        #expect(reduced.1 == .typeApplication(.variable(0), .top), "\(reduced.1)")
    }

    @Test("A type's own maximumDepth bounds it wherever it nests")
    func macroMaximumDepthBoundsNesting() throws {
        #expect(Shallow.__generatorDescriptor.maximumDepth == 2)
        let generator = ReflectiveGenerator<Shallow>.derived()
        var interpreter = ValueAndChoiceTreeInterpreter(generator.gen, seed: 5, maxRuns: 10000, sizeOverride: 100)
        var deepest = 0
        for _ in 0 ..< 300 {
            let (value, _) = try #require(try interpreter.next())
            deepest = max(deepest, value.depth)
        }
        #expect(deepest == 2)
        let nested = ReflectiveGenerator<Holder>.derived(depth: 6)
        var holderInterpreter = ValueAndChoiceTreeInterpreter(nested.gen, seed: 5, maxRuns: 10000, sizeOverride: 100)
        var deepestHeld = 0
        for _ in 0 ..< 300 {
            let (value, _) = try #require(try holderInterpreter.next())
            deepestHeld = max(deepestHeld, value.inner.depth)
        }
        #expect(deepestHeld == 2)
    }

    @Test("An @Exhaustable type exposes its derived generator")
    func annotatedTypeExposesDefaultGenerator() throws {
        let generator = ReflectiveGenerator<Wrapper>.derived(depth: 2, overriding: .int(in: 0 ... 3))
        let samples = try #example(generator, count: 100)
        #expect(samples.contains { $0.inner.depth > 0 })
        let direct = Term.defaultGenerator
        let directSamples = try #example(direct, count: 20)
        #expect(directSamples.allSatisfy { $0.indicesWithin(Int.min ... Int.max) })
    }

    @Test("A final class derives through its stored properties and reflects")
    func finalClassDerives() throws {
        let generator = ReflectiveGenerator<Node>.derived(depth: 2, overriding: .int(in: 0 ... 3))
        let samples = try #example(generator, count: 100)
        #expect(samples.contains { $0.term.depth > 0 })
        let target = Node(term: .abstraction(.top, .variable(2)), weight: 3)
        let tree = try #require(try Interpreters.reflect(generator.gen, with: target))
        let replayed = try #require(try Interpreters.replay(generator.gen, using: tree))
        #expect(replayed.term == target.term)
        #expect(replayed.weight == target.weight)
        #expect(replayed !== target)
    }

    @Test("Containers of an annotated type need no conformance from the user")
    func containersOfAnnotatedTypesResolve() throws {
        let generator = ReflectiveGenerator<Forest>.derived(maximumDepth: 3)
        let samples = try #example(generator, count: 200)
        #expect(samples.contains { $0.trees.isEmpty == false })
        #expect(samples.contains { $0.best != nil })
        #expect(samples.contains { $0.nested.isEmpty == false })
        #expect(samples.allSatisfy { $0.trees.allSatisfy { $0.depth <= 3 } })

        let target = Forest(trees: [.leaf, .node(.leaf, .leaf)], best: .leaf, nested: [[.leaf]])
        let tree = try #require(try Interpreters.reflect(generator.gen, with: target))
        let replayed = try #require(try Interpreters.replay(generator.gen, using: tree))
        #expect(replayed == target)
    }

    @Test("A derived generator reflects a value and replays it")
    func derivedGeneratorReflects() throws {
        let generator = ReflectiveGenerator<Term>.derived(depth: 4, overriding: .int(in: 0 ... 3))
        let target: Term = .application(.abstraction(.arrow(.top, .top), .variable(0)), .typeApplication(.variable(1), .top))
        let tree = try #require(try Interpreters.reflect(generator.gen, with: target))
        let replayed = try #require(try Interpreters.replay(generator.gen, using: tree))
        #expect(replayed == target)
    }
}

// MARK: - Fixtures

@Exhaustable
private indirect enum TermType: Equatable {
    case top
    case variable(Int)
    case arrow(TermType, TermType)
    case forAll(TermType, TermType)
}

@Exhaustable
private indirect enum Term: Equatable {
    case variable(Int)
    case abstraction(TermType, Term)
    case application(Term, Term)
    case typeAbstraction(TermType, Term)
    case typeApplication(Term, TermType)
}

@Exhaustable
private struct Binding: Equatable {
    var name: String
    let term: Term
    var pinned: Bool = false
    var label: String {
        name.uppercased()
    }
}

@Exhaustable(maximumDepth: 2)
private indirect enum Shallow {
    case leaf
    case node(Shallow)

    var depth: Int {
        switch self {
            case .leaf:
                0
            case let .node(child):
                1 + child.depth
        }
    }
}

@Exhaustable
private struct Holder {
    let inner: Shallow
}

/// Holds a derived enum without an override, so the payload uses its generated descriptor.
@Exhaustable
private struct Wrapper: Equatable {
    let inner: Term
}

@Exhaustable
private final class Node {
    let term: Term
    var weight: Int
}

@Exhaustable
private indirect enum Sapling: Equatable {
    case leaf
    case node(Sapling, Sapling)

    var depth: Int {
        switch self {
            case .leaf:
                0
            case let .node(left, right):
                1 + max(left.depth, right.depth)
        }
    }
}

/// An array, an optional, and a nested array of an annotated type, none of which the user conforms to anything.
@Exhaustable
private struct Forest: Equatable {
    let trees: [Sapling]
    let best: Sapling?
    let nested: [[Sapling]]
}

private struct Money: Equatable {
    let cents: Int

    static var defaultGenerator: ReflectiveGenerator<Money> {
        #gen(.int(in: 0 ... 9)) { Money(cents: $0) }
    }
}

@Exhaustable
private struct Account: Equatable {
    let balance: Money
    let open: Bool
}

private extension TermType {
    var depth: Int {
        switch self {
            case .top, .variable:
                0
            case let .arrow(left, right), let .forAll(left, right):
                1 + max(left.depth, right.depth)
        }
    }

    func indicesWithin(_ range: ClosedRange<Int>) -> Bool {
        switch self {
            case .top:
                true
            case let .variable(index):
                range.contains(index)
            case let .arrow(left, right), let .forAll(left, right):
                left.indicesWithin(range) && right.indicesWithin(range)
        }
    }
}

private extension Term {
    var depth: Int {
        switch self {
            case .variable:
                0
            case let .abstraction(type, body), let .typeAbstraction(type, body):
                1 + max(type.depth, body.depth)
            case let .application(function, argument):
                1 + max(function.depth, argument.depth)
            case let .typeApplication(function, type):
                1 + max(function.depth, type.depth)
        }
    }

    func indicesWithin(_ range: ClosedRange<Int>) -> Bool {
        switch self {
            case let .variable(index):
                range.contains(index)
            case let .abstraction(type, body), let .typeAbstraction(type, body):
                type.indicesWithin(range) && body.indicesWithin(range)
            case let .application(function, argument):
                function.indicesWithin(range) && argument.indicesWithin(range)
            case let .typeApplication(function, type):
                function.indicesWithin(range) && type.indicesWithin(range)
        }
    }

    var caseNames: Set<String> {
        switch self {
            case .variable:
                Set(["variable"])
            case let .abstraction(_, body):
                Set(["abstraction"]).union(body.caseNames)
            case let .application(function, argument):
                Set(["application"]).union(function.caseNames).union(argument.caseNames)
            case let .typeAbstraction(_, body):
                Set(["typeAbstraction"]).union(body.caseNames)
            case let .typeApplication(function, _):
                Set(["typeApplication"]).union(function.caseNames)
        }
    }
}
