import Exhaust
import ExhaustCore
import Testing

@Suite("Derived generator public API")
struct DerivedGeneratorAPITests {
    @Test("An annotated type's generator can be passed directly to example")
    func samplesDefaultGenerator() throws {
        let samples = try #example(DefaultFirst.defaultGenerator, count: 20)
        #expect(samples.count == 20)
        let generator = DefaultFirst.defaultGenerator
        let target = DefaultFirst(number: 42)
        let tree = try #require(try Interpreters.reflect(generator.gen, with: target))
        #expect(try Interpreters.replay(generator.gen, using: tree) == target)
    }

    @Test("Three derived generators compose directly through gen and retain reflection")
    func combinesDefaultGenerators() throws {
        let generator = #gen(
            DefaultFirst.defaultGenerator,
            DefaultSecond.defaultGenerator,
            DefaultThird.defaultGenerator
        )
        let samples = try #example(generator, count: 20)
        #expect(samples.count == 20)
        let target = (DefaultFirst(number: 42), DefaultSecond(enabled: true), DefaultThird(letter: "a"))
        let tree = try #require(try Interpreters.reflect(generator.gen, with: target))
        let replayed = try #require(try Interpreters.replay(generator.gen, using: tree))
        #expect(replayed == target)
    }

    @Test("The type-level default factories preserve the existing policy and random stream", arguments: [UInt64(0), 1, 42])
    func defaultFactoryParity(seed: UInt64) throws {
        let reference = ReflectiveGenerator<ConfiguredTree>.derived()
        try expectMatchingRandomStream(ConfiguredTree.defaultGenerator, reference: reference, seed: seed)
        try expectMatchingRandomStream(ConfiguredTree.derivedGenerator(), reference: reference, seed: seed)
    }

    @Test("The type-level factory forwards the root ceiling and scaling", arguments: [UInt64(0), 1, 42])
    func configurableFactoryParity(seed: UInt64) throws {
        let generator = ConfiguredTree.derivedGenerator(maximumDepth: 3, scaling: .constant)
        let reference = ReflectiveGenerator<ConfiguredTree>.derived(maximumDepth: 3, scaling: .constant)
        try expectMatchingRandomStream(generator, reference: reference, seed: seed)
        // This exceeds the root annotation's default ceiling but fits the explicit root ceiling and all nested ceilings.
        let target: ConfiguredTree = .node(.node(.node(.leaf)))
        let tree = try #require(try Interpreters.reflect(generator.gen, with: target))
        #expect(try Interpreters.replay(generator.gen, using: tree) == target)
    }

    @Test("The type-level pinned factory retains its depth and random stream", arguments: [0, 1, 3])
    func pinnedFactoryParity(depth: Int) throws {
        let generator = ConfiguredTree.derivedGenerator(depth: depth)
        let reference = ReflectiveGenerator<ConfiguredTree>.derived(depth: depth)
        try expectMatchingRandomStream(generator, reference: reference, seed: 42)
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
                ConfiguredProduct.derivedGenerator(overriding: .uint8(in: 7 ... 7), .just(true))
            case true:
                ConfiguredProduct.derivedGenerator(depth: 0, overriding: .uint8(in: 7 ... 7), .just(true))
        }
        let generator = #gen(configured, DefaultThird.defaultGenerator)
        let samples = try #example(generator, count: 20)
        #expect(samples.count == 20)
        #expect(samples.allSatisfy { $0.0 == ConfiguredProduct(number: 7, enabled: true) })
        let target = (ConfiguredProduct(number: 7, enabled: true), DefaultThird(letter: "a"))
        let tree = try #require(try Interpreters.reflect(generator.gen, with: target))
        let replayed = try #require(try Interpreters.replay(generator.gen, using: tree))
        #expect(replayed == target)
    }

    @Test("Examine validates the default derived generator")
    func examinesDefaultGenerator() {
        let report = #examine(
            ConfiguredTree.defaultGenerator,
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
        let generator = ConfiguredTree.derivedGenerator(maximumDepth: 3, scaling: .constant)
        let report = #examine(generator, .samples(50), .replay(42), .suppress(.logs)) { first, second in
            first == second
        }
        expectSuccessfulExamination(report, samples: 50)
    }

    @Test("Examine validates pinned derived generators", arguments: [0, 1, 3])
    func examinesPinnedGenerator(depth: Int) {
        let report = #examine(
            ConfiguredTree.derivedGenerator(depth: depth),
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
                ConfiguredProduct.derivedGenerator(overriding: .uint8(in: 7 ... 7), .just(true))
            case true:
                ConfiguredProduct.derivedGenerator(depth: 0, overriding: .uint8(in: 7 ... 7), .just(true))
        }
        let generator = #gen(configured, DefaultThird.derivedGenerator(depth: 0))
        let report = #examine(generator, .samples(50), .replay(42), .suppress(.logs)) { first, second in
            first == second
        }
        expectSuccessfulExamination(report, samples: 50)
    }

    @Test("Derived and handwritten generators compose through an initializer")
    func combinesWithHandwrittenGenerator() throws {
        let generator = #gen(DefaultFirst.defaultGenerator, DefaultSecond.defaultGenerator, .int(in: 0 ... 9)) {
            DefaultComposition(first: $0, second: $1, count: $2)
        }
        let samples = try #example(generator, count: 20)
        #expect(samples.count == 20)
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

// MARK: - Helpers

/// Requires the entire requested run to pass reflection and replay checks, without accepting skipped validation or partial generation.
private func expectSuccessfulExamination(_ report: ExamineReport, samples: Int) {
    #expect(report.passed, "\(report.failures)")
    #expect(report.reflectionSkipped == false)
    #expect(report.sampleCount == samples)
    #expect(report.valuesGenerated == samples)
    #expect(report.reflectionRoundTripSuccesses == samples)
    #expect(report.replayDeterminismSuccesses == samples)
}

/// Compares both generated values and the next random draw so forwarding cannot silently change random consumption. A small size makes ignored scaling arguments observable.
private func expectMatchingRandomStream<Value: Equatable>(
    _ generator: ReflectiveGenerator<Value>,
    reference: ReflectiveGenerator<Value>,
    seed: UInt64
) throws {
    var actualInterpreter = ValueAndChoiceTreeInterpreter(
        Gen.zip(generator.gen, Gen.choose(in: UInt64.min ... UInt64.max)),
        seed: seed,
        sizeOverride: 1
    )
    var referenceInterpreter = ValueAndChoiceTreeInterpreter(
        Gen.zip(reference.gen, Gen.choose(in: UInt64.min ... UInt64.max)),
        seed: seed,
        sizeOverride: 1
    )
    for _ in 0 ..< 50 {
        let actual = try #require(try actualInterpreter.next())
        let expected = try #require(try referenceInterpreter.next())
        #expect(actual.0.0 == expected.0.0)
        #expect(actual.0.1 == expected.0.1)
    }
}
