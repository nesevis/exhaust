import Exhaust
import ExhaustCore
import Testing
@testable import ExhaustGenerators

@Suite("Derived numeric state spaces")
struct GeneratorStateSpaceTests {
    @Test("Numeric presets scale linearly and clip narrow integer types", arguments: [
        (GeneratorStateSpace.tiny, 10), (.small, 100), (.medium, 10000),
    ], [1, 25, 50, 100])
    func numericBounds(preset: (GeneratorStateSpace, Int), size: Int) throws {
        let (policy, magnitude) = preset
        let generator = StateSpaceNumbers.derivedGenerator(depth: 0, stateSpace: policy).resize(size)
        let samples = try #example(generator, count: 50, seed: 1337)
        #expect(samples.count == 50)
        for value in samples {
            expectIntegerBound(value.integer, magnitude: magnitude, size: size)
            expectIntegerBound(value.signed8, magnitude: magnitude, size: size)
            expectIntegerBound(value.signed16, magnitude: magnitude, size: size)
            expectIntegerBound(value.signed32, magnitude: magnitude, size: size)
            expectIntegerBound(value.signed64, magnitude: magnitude, size: size)
            expectIntegerBound(value.unsigned, magnitude: magnitude, size: size)
            expectIntegerBound(value.unsigned8, magnitude: magnitude, size: size)
            expectIntegerBound(value.unsigned16, magnitude: magnitude, size: size)
            expectIntegerBound(value.unsigned32, magnitude: magnitude, size: size)
            expectIntegerBound(value.unsigned64, magnitude: magnitude, size: size)
            #expect(abs(value.float) <= Float(magnitude) * Float(size) / 100)
            #expect(abs(value.double) <= Double(magnitude) * Double(size) / 100)
            try expectStateSpaceReplay(generator, value: value)
        }
    }

    @Test("Tiny integers reflect exactly the rounded size-scaled range up to ten", arguments: 1 ... 100)
    func tinySizeRamp(size: Int) throws {
        let generator = StateSpaceLeaf.derivedGenerator(depth: 0, stateSpace: .tiny).resize(size)
        let magnitude = Int((Double(size) / 10).rounded())
        for value in [-magnitude, 0, magnitude] {
            try expectStateSpaceReplay(generator, value: StateSpaceLeaf(value: value))
        }
        try expectStateSpaceRejection(generator, value: StateSpaceLeaf(value: magnitude + 1))
        try expectStateSpaceRejection(generator, value: StateSpaceLeaf(value: -magnitude - 1))
    }

    @Test("The full preset preserves primitive outputs and subsequent random draws", arguments: [UInt64(0), 42, 1337])
    func fullParity(seed: UInt64) throws {
        for maximumNodes in [Int?.none, 32] {
            let derived = StateSpaceLeaf.derivedGenerator(depth: 0, maximumNodes: maximumNodes, stateSpace: .full)
            let actual = try #example(#gen(derived, .uint64()), count: 100, seed: .numeric(seed))
            // The pre-preset builder retains a pick even for a product's single constructor.
            let reference = try #example(#gen(.oneOf(.int()), .uint64()), count: 100, seed: .numeric(seed))
            #expect(actual.count == 100)
            #expect(reference.count == 100)
            for (value, expected) in zip(actual, reference) {
                #expect(value.0.value == expected.0)
                #expect(value.1 == expected.1)
            }
        }
        #expect(StateSpaceLeaf.__generatorDescriptor.stateSpace == .full)
    }

    @Test("Annotations select defaults and both factory forms can override the root")
    func annotationAndFactoryPrecedence() throws {
        #expect(StateSpaceSmall.__generatorDescriptor.stateSpace == .small)
        let target = StateSpaceSmall(value: 500)
        try expectStateSpaceRejection(StateSpaceSmall.defaultGenerator, value: target)
        try expectStateSpaceReplay(StateSpaceSmall.derivedGenerator(stateSpace: .medium), value: target)
        try expectStateSpaceReplay(StateSpaceSmall.derivedGenerator(depth: 0, stateSpace: .full), value: target)
        for generator in [
            StateSpaceSmall.defaultGenerator,
            StateSpaceSmall.derivedGenerator(depth: 0),
            ReflectiveGenerator<StateSpaceSmall>.derived(depth: 0),
        ] {
            let samples = try #example(generator.resize(100), count: 100, seed: 1337)
            #expect(samples.count == 100)
            #expect(samples.allSatisfy { (-100 ... 100).contains($0.value) })
            #expect(samples.contains { abs($0.value) > 10 })
        }
    }

    @Test("Shared types and container recipes retain their path's preset", arguments: [Int?.none, 256])
    func inheritedDomains(maximumNodes: Int?) throws {
        let generator = StateSpaceDiamond.derivedGenerator(depth: 4, maximumNodes: maximumNodes, stateSpace: .small).resize(100)
        let target = StateSpaceDiamond(
            narrow: StateSpaceNarrow(leaf: StateSpaceLeaf(value: 10), values: [StateSpaceLeaf(value: -10)]),
            wider: StateSpaceWider(leaf: StateSpaceLeaf(value: 80), values: [StateSpaceLeaf(value: -80)]),
            direct: StateSpaceLeaf(value: 90)
        )
        try expectStateSpaceReplay(generator, value: target)
        let samples = try #example(generator, count: 100, seed: 1337)
        #expect(samples.count == 100)
        #expect(samples.contains { abs($0.wider.leaf.value) > 10 })
        for value in samples {
            #expect(abs(value.narrow.leaf.value) <= 10)
            #expect(value.narrow.values.allSatisfy { abs($0.value) <= 10 })
            #expect(abs(value.wider.leaf.value) <= 100)
            #expect(value.wider.values.allSatisfy { abs($0.value) <= 100 })
            #expect(abs(value.direct.value) <= 100)
            try expectStateSpaceReplay(generator, value: value)
        }
    }

    @Test("Numeric overrides remain opaque to inherited and declared presets", arguments: [Int?.none, 128])
    func overridesWin(maximumNodes: Int?) throws {
        let generator = StateSpaceDiamond.derivedGenerator(
            depth: 4,
            maximumNodes: maximumNodes,
            stateSpace: .tiny,
            overriding: ReflectiveGenerator<Int>.just(777)
        ).resize(100)
        let samples = try #example(generator, count: 50, seed: 1337)
        #expect(samples.count == 50)
        for value in samples {
            #expect(value.direct.value == 777)
            #expect(value.narrow.leaf.value == 777)
            #expect(value.wider.leaf.value == 777)
            #expect(value.narrow.values.allSatisfy { $0.value == 777 })
            #expect(value.wider.values.allSatisfy { $0.value == 777 })
            try expectStateSpaceReplay(generator, value: value)
        }
    }

    @Test("Optional, set, and dictionary payloads inherit the numeric policy", arguments: [Int?.none, 128])
    func standardContainers(maximumNodes: Int?) throws {
        let generator = StateSpaceContainers.derivedGenerator(maximumNodes: maximumNodes, stateSpace: .tiny).resize(100)
        let samples = try #example(generator, count: 50, seed: 1337)
        #expect(samples.count == 50)
        #expect(samples.contains { $0.optional != nil })
        #expect(samples.contains { $0.dictionary.isEmpty == false })
        #expect(samples.contains { $0.values.isEmpty == false })
        for value in samples {
            #expect(value.optional.map { abs($0) <= 10 } ?? true)
            #expect(value.values.allSatisfy { abs($0) <= 10 })
            #expect(value.dictionary.allSatisfy { abs($0.key) <= 10 && abs($0.value.value) <= 10 })
            try expectStateSpaceReplay(generator, value: value)
        }
    }

    @Test("Reflection rejects values outside the selected domain", arguments: [
        (GeneratorStateSpace.tiny, 10), (.small, 100), (.medium, 10000),
    ])
    func reflectedBounds(preset: (GeneratorStateSpace, Int)) throws {
        let (policy, magnitude) = preset
        let generator = StateSpaceLeaf.derivedGenerator(stateSpace: policy)
        for value in [-magnitude, 0, magnitude] {
            try expectStateSpaceReplay(generator, value: StateSpaceLeaf(value: value))
        }
        try expectStateSpaceRejection(generator, value: StateSpaceLeaf(value: magnitude + 1))
        try expectStateSpaceRejection(generator, value: StateSpaceLeaf(value: -magnitude - 1))
    }

    @Test("Examine and actual reflected output equality hold for recursive presets", arguments: GeneratorStateSpace.allCases, [Int?.none, 64])
    func recursiveRoundTrips(policy: GeneratorStateSpace, maximumNodes: Int?) throws {
        let generator = StateSpaceTree.derivedGenerator(maximumDepth: 4, maximumNodes: maximumNodes, stateSpace: policy)
        let report = #examine(generator, .samples(50), .replay(1337), .suppress(.all)) { $0 == $1 }
        #expect(report.passed, "\(report.failures)")
        #expect(report.reflectionSkipped == false)
        #expect(report.sampleCount == 50)
        #expect(report.valuesGenerated == 50)
        #expect(report.reflectionRoundTripSuccesses == 50)
        #expect(report.replayDeterminismSuccesses == 50)
        let samples = try #example(generator, count: 100, seed: 1337)
        #expect(samples.count == 100)
        for value in samples {
            try expectStateSpaceReplay(generator, value: value)
        }
    }

    @Test("Unbounded and bounded layers cache numeric policies separately without rebuilding repeated layers")
    func policySharing() throws {
        let plan = try GeneratorDerivationPlan(for: StateSpaceLeaf.self, overrides: [:])
        let plain = BudgetedGeneratorDerivation(plan: plan)
        _ = plain.generator(for: StateSpaceLeaf.self, depth: 0, nodes: nil, stateSpace: .tiny)
        _ = plain.generator(for: StateSpaceLeaf.self, depth: 0, nodes: nil, stateSpace: .small)
        #expect(plain.built.count == 2)
        _ = plain.generator(for: StateSpaceLeaf.self, depth: 0, nodes: nil, stateSpace: .tiny)
        #expect(plain.built.count == 2)
        let budgeted = BudgetedGeneratorDerivation(plan: plain.plan)
        _ = budgeted.generator(for: StateSpaceLeaf.self, depth: 0, nodes: 2, stateSpace: .tiny)
        _ = budgeted.generator(for: StateSpaceLeaf.self, depth: 0, nodes: 2, stateSpace: .small)
        #expect(budgeted.built.count == 2)
        _ = budgeted.generator(for: StateSpaceLeaf.self, depth: 0, nodes: 2, stateSpace: .tiny)
        #expect(budgeted.built.count == 2)
    }

    @Test("128-bit numeric presets reject unrepresentable backward mappings")
    func wideIntegers() throws {
        if #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) {
            let signed = Int128.defaultGenerator(stateSpace: .small).resize(100)
            let unsigned = UInt128.defaultGenerator(stateSpace: .small).resize(100)
            let signedSamples = try #example(signed, count: 100, seed: 1337)
            let unsignedSamples = try #example(unsigned, count: 100, seed: 1337)
            #expect(signedSamples.count == 100)
            #expect(unsignedSamples.count == 100)
            #expect(signedSamples.allSatisfy { (-100 ... 100).contains($0) })
            #expect(unsignedSamples.allSatisfy { $0 <= 100 })
            try expectStateSpaceReplay(signed, value: -100)
            try expectStateSpaceReplay(unsigned, value: 100)
            try expectStateSpaceRejection(signed, value: Int128.max)
            try expectStateSpaceRejection(unsigned, value: UInt128.max)
        }
    }
}

// MARK: - Fixtures

@Exhaustable
private struct StateSpaceNumbers: Equatable {
    let integer: Int
    let signed8: Int8
    let signed16: Int16
    let signed32: Int32
    let signed64: Int64
    let unsigned: UInt
    let unsigned8: UInt8
    let unsigned16: UInt16
    let unsigned32: UInt32
    let unsigned64: UInt64
    let float: Float
    let double: Double
}

@Exhaustable
private struct StateSpaceLeaf: Equatable {
    let value: Int
}

@Exhaustable(stateSpace: .small)
private struct StateSpaceSmall: Equatable {
    let value: Int
}

@Exhaustable(stateSpace: .tiny)
private struct StateSpaceNarrow: Equatable {
    let leaf: StateSpaceLeaf
    let values: [StateSpaceLeaf]
}

@Exhaustable(stateSpace: .medium)
private struct StateSpaceWider: Equatable {
    let leaf: StateSpaceLeaf
    let values: [StateSpaceLeaf]
}

@Exhaustable
private struct StateSpaceDiamond: Equatable {
    let narrow: StateSpaceNarrow
    let wider: StateSpaceWider
    let direct: StateSpaceLeaf
}

@Exhaustable
private struct StateSpaceContainers: Equatable {
    let optional: Int?
    let values: Set<Int>
    let dictionary: [Int: StateSpaceLeaf]
}

@Exhaustable
private indirect enum StateSpaceTree: Equatable {
    case empty
    case node(Int, StateSpaceTree, StateSpaceTree)
}

// MARK: - Helpers

private func expectIntegerBound<Value: FixedWidthInteger>(_ value: Value, magnitude: Int, size: Int) {
    let lower = Int((Double(Int(Value(clamping: -magnitude))) * Double(size) / 100).rounded())
    let upper = Int((Double(Int(Value(clamping: magnitude))) * Double(size) / 100).rounded())
    #expect((Value(clamping: lower) ... Value(clamping: upper)).contains(value))
}

private func expectStateSpaceReplay<Value: Equatable>(_ generator: ReflectiveGenerator<Value>, value: Value) throws {
    let tree = try #require(try Interpreters.reflect(generator.gen, with: value))
    #expect(try Interpreters.replay(generator.gen, using: tree) == value)
}

private func expectStateSpaceRejection<Value>(_ generator: ReflectiveGenerator<Value>, value: Value) throws {
    do {
        let reflected = try Interpreters.reflect(generator.gen, with: value)
        #expect(reflected == nil)
    } catch is ReflectionError {
        // A rejected nested payload can throw instead of returning nil.
    }
}
