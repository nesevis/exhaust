import Exhaust
import ExhaustCore
import ExhaustTestSupport
import Testing

@Suite("Derived generator public API")
struct DerivedGeneratorAPITests {
    @Test("An annotated type's generator can be passed directly to example")
    func samplesDefaultGenerator() throws {
        let samples = try #example(DefaultFirst.gen(), count: 20)
        #expect(samples.count == 20)
        let generator = DefaultFirst.gen()
        let target = DefaultFirst(number: 42)
        let tree = try #require(try Interpreters.reflect(generator.gen, with: target))
        #expect(try Interpreters.replay(generator.gen, using: tree) == target)
    }

    @Test("Three derived generators compose directly through gen and retain reflection")
    func combinesDefaultGenerators() throws {
        let generator = #gen(
            DefaultFirst.gen(),
            DefaultSecond.gen(),
            DefaultThird.gen()
        )
        let samples = try #example(generator, count: 20)
        #expect(samples.count == 20)
        let target = (DefaultFirst(number: 42), DefaultSecond(enabled: true), DefaultThird(letter: "a"))
        let tree = try #require(try Interpreters.reflect(generator.gen, with: target))
        let replayed = try #require(try Interpreters.replay(generator.gen, using: tree))
        #expect(replayed == target)
    }

    @Test("Omitted and explicit default arguments preserve the existing policy and random stream", arguments: [UInt64(0), 1, 42])
    func defaultFactoryParity(seed: UInt64) throws {
        let reference = ReflectiveGenerator<ConfiguredTree>.derived()
        try expectMatchingRandomStream(ConfiguredTree.gen().gen, reference: reference.gen, seed: seed, size: 1, draws: 50)
        try expectMatchingRandomStream(
            ConfiguredTree.gen(maximumDepth: nil, maximumNodes: nil, stateSpace: nil, scaling: .linear).gen,
            reference: reference.gen,
            seed: seed,
            size: 1,
            draws: 50
        )
    }

    @Test("The type-level factory forwards the root ceiling and scaling", arguments: [UInt64(0), 1, 42])
    func configurableFactoryParity(seed: UInt64) throws {
        let generator = ConfiguredTree.gen(maximumDepth: 3, scaling: .constant)
        let reference = ReflectiveGenerator<ConfiguredTree>.derived(maximumDepth: 3, scaling: .constant)
        try expectMatchingRandomStream(generator.gen, reference: reference.gen, seed: seed, size: 1, draws: 50)
        // This exceeds the root annotation's default ceiling but fits the explicit root ceiling and all nested ceilings.
        let target: ConfiguredTree = .node(.node(.node(.leaf)))
        let tree = try #require(try Interpreters.reflect(generator.gen, with: target))
        #expect(try Interpreters.replay(generator.gen, using: tree) == target)
    }

    @Test("The type-level pinned factory retains its depth and random stream", arguments: [0, 1, 3])
    func pinnedFactoryParity(depth: Int) throws {
        let generator = ConfiguredTree.gen(depth: depth)
        let reference = ReflectiveGenerator<ConfiguredTree>.derived(depth: depth)
        try expectMatchingRandomStream(generator.gen, reference: reference.gen, seed: 42, size: 1, draws: 50)
        var target: ConfiguredTree = .leaf
        for _ in 0 ..< depth {
            target = .node(target)
        }
        let tree = try #require(try Interpreters.reflect(generator.gen, with: target))
        #expect(try Interpreters.replay(generator.gen, using: tree) == target)
    }

    @Test("Both type-level overloads forward heterogeneous overrides and compose through gen", arguments: [false, true])
    func configuredComposition(pinned: Bool) throws {
        let configured = switch pinned {
            case false:
                ConfiguredProduct.gen(overriding: .uint8(in: 7 ... 7), .just(true))
            case true:
                ConfiguredProduct.gen(depth: 0, overriding: .uint8(in: 7 ... 7), .just(true))
        }
        let generator = #gen(configured, DefaultThird.gen())
        let samples = try #example(generator, count: 20)
        #expect(samples.allSatisfy { $0.0 == ConfiguredProduct(number: 7, enabled: true) })
        let target = (ConfiguredProduct(number: 7, enabled: true), DefaultThird(letter: "a"))
        let tree = try #require(try Interpreters.reflect(generator.gen, with: target))
        let replayed = try #require(try Interpreters.replay(generator.gen, using: tree))
        #expect(replayed == target)
    }

    @Test("A configured type-level gen call composes inline with a primitive generator")
    func inlineConfiguredComposition() throws {
        let generator = #gen(DefaultFirst.gen(overriding: .uint8(in: 7 ... 7)), .int(in: 0 ... 9))
        let samples = try #example(generator, count: 20)
        #expect(samples.allSatisfy { $0.0 == DefaultFirst(number: 7) && (0 ... 9).contains($0.1) })
        let target = (DefaultFirst(number: 7), 4)
        let reflected = try #require(try Interpreters.reflect(generator.gen, with: target))
        let replayed = try #require(try Interpreters.replay(generator.gen, using: reflected))
        #expect(replayed == target)
    }

    @Test("Examine validates the default derived generator")
    func examinesDefaultGenerator() {
        let report = #examine(
            ConfiguredTree.gen(),
            .samples(50),
            .replay(42),
            .suppress(.logs)
        ) { first, second in
            first == second
        }
        expectSuccessfulExamination(report, samples: 50)
    }

    @Test("Examine validates the configurable size-ramped generator")
    func examinesRampedGenerator() {
        let generator = ConfiguredTree.gen(maximumDepth: 3, scaling: .constant)
        let report = #examine(generator, .samples(50), .replay(42), .suppress(.logs)) { first, second in
            first == second
        }
        expectSuccessfulExamination(report, samples: 50)
    }

    @Test("Examine validates pinned derived generators", arguments: [0, 1, 3])
    func examinesPinnedGenerator(depth: Int) {
        let report = #examine(
            ConfiguredTree.gen(depth: depth),
            .samples(50),
            .replay(42),
            .suppress(.logs)
        ) { first, second in
            first == second
        }
        expectSuccessfulExamination(report, samples: 50)
    }

    @Test("Examine validates composed generators with heterogeneous overrides", arguments: [false, true])
    func examinesConfiguredComposition(pinned: Bool) {
        let configured = switch pinned {
            case false:
                ConfiguredProduct.gen(overriding: .uint8(in: 7 ... 7), .just(true))
            case true:
                ConfiguredProduct.gen(depth: 0, overriding: .uint8(in: 7 ... 7), .just(true))
        }
        let generator = #gen(configured, DefaultThird.gen(depth: 0))
        let report = #examine(generator, .samples(50), .replay(42), .suppress(.logs)) { first, second in
            first == second
        }
        expectSuccessfulExamination(report, samples: 50)
    }

    @Test("Derived and handwritten generators compose through an initializer")
    func combinesWithHandwrittenGenerator() throws {
        let generator = #gen(DefaultFirst.gen(), DefaultSecond.gen(), .int(in: 0 ... 9)) {
            DefaultComposition(first: $0, second: $1, count: $2)
        }
        let samples = try #example(generator, count: 20)
        #expect(samples.allSatisfy { (0 ... 9).contains($0.count) })
        let target = DefaultComposition(first: DefaultFirst(number: 42), second: DefaultSecond(enabled: true), count: 7)
        let tree = try #require(try Interpreters.reflect(generator.gen, with: target))
        let replayed = try #require(try Interpreters.replay(generator.gen, using: tree))
        #expect(replayed == target)
    }
}

// MARK: - Fixtures

@Exhaustable
private struct DefaultFirst: Equatable {
    let number: UInt8
}

@Exhaustable
private struct DefaultSecond: Equatable {
    let enabled: Bool
}

@Exhaustable
private struct DefaultThird: Equatable {
    let letter: Character
}

private struct DefaultComposition: Equatable {
    let first: DefaultFirst
    let second: DefaultSecond
    let count: Int
}

@Exhaustable(maximumDepth: 2)
private indirect enum ConfiguredTree: Equatable {
    case leaf
    case node(ConfiguredTree)
}

@Exhaustable
private struct ConfiguredProduct: Equatable {
    let number: UInt8
    let enabled: Bool
}
