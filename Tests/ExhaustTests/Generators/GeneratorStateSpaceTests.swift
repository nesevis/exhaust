import Exhaust
import ExhaustCore
import ExhaustTestSupport
import Foundation
import Testing
@testable import ExhaustGenerators

@Suite("Derived state spaces")
struct GeneratorStateSpaceTests {
    @Test("Nested presets retain an operand no wider than either input")
    func presetLimit() {
        let preset = #gen(.element(from: GeneratorStateSpace.allCases))
        let inputs = #gen(preset, preset)
        #exhaust(inputs) { policy, ceiling in
            let result = policy.limited(by: ceiling)
            #expect(result == policy || result == ceiling)
            #expect(result <= policy)
            #expect(result <= ceiling)
        }
    }

    @Test("Numeric presets scale linearly and clip narrow integer types", arguments: [
        (GeneratorStateSpace.tiny, 10), (.small, 100), (.medium, 10000),
    ], [1, 25, 50, 100])
    func numericBounds(preset: (GeneratorStateSpace, Int), size: Int) throws {
        let (policy, magnitude) = preset
        let generator = StateSpaceNumbers.gen(depth: 0, stateSpace: policy).resize(size)
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

    @Test("Tiny integers sample the rounded size-scaled range while reflecting beyond it", arguments: 1 ... 100)
    func tinySizeRamp(size: Int) throws {
        let generator = StateSpaceLeaf.gen(depth: 0, stateSpace: .tiny).resize(size)
        let magnitude = Int((Double(size) / 10).rounded())
        for value in [-magnitude, 0, magnitude] {
            try expectStateSpaceReplay(generator, value: StateSpaceLeaf(value: value))
        }
        try expectStateSpaceReplay(generator, value: StateSpaceLeaf(value: magnitude + 1))
        try expectStateSpaceReplay(generator, value: StateSpaceLeaf(value: -magnitude - 1))
    }

    @Test("The full preset preserves primitive outputs and subsequent random draws", arguments: [UInt64(0), 42, 1337])
    func fullParity(seed: UInt64) throws {
        for maximumNodes in [Int?.none, 32] {
            let derived = StateSpaceLeaf.gen(depth: 0, maximumNodes: maximumNodes, stateSpace: .full)
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
        try expectStateSpaceReplay(StateSpaceSmall.gen(), value: target)
        try expectStateSpaceReplay(StateSpaceSmall.gen(stateSpace: .medium), value: target)
        try expectStateSpaceReplay(StateSpaceSmall.gen(depth: 0, stateSpace: .full), value: target)
        for generator in [
            StateSpaceSmall.gen(),
            StateSpaceSmall.gen(depth: 0),
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
        let generator = StateSpaceDiamond.gen(depth: 4, maximumNodes: maximumNodes, stateSpace: .small).resize(100)
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
            #expect(value.narrow.values.count <= 5)
            #expect(value.narrow.values.allSatisfy { abs($0.value) <= 10 })
            #expect(abs(value.wider.leaf.value) <= 100)
            #expect(value.wider.values.count <= 10)
            #expect(value.wider.values.allSatisfy { abs($0.value) <= 100 })
            #expect(abs(value.direct.value) <= 100)
            try expectStateSpaceReplay(generator, value: value)
        }
    }

    @Test("Numeric overrides remain opaque to inherited and declared presets", arguments: [Int?.none, 128])
    func overridesWin(maximumNodes: Int?) throws {
        let generator = StateSpaceDiamond.gen(
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

    @Test("Optional, set, and dictionary payloads inherit the state-space policy", arguments: [Int?.none, 128])
    func standardContainers(maximumNodes: Int?) throws {
        let generator = StateSpaceContainers.gen(maximumNodes: maximumNodes, stateSpace: .tiny).resize(100)
        let samples = try #example(generator, count: 50, seed: 1337)
        #expect(samples.count == 50)
        #expect(samples.contains { $0.optional != nil })
        #expect(samples.contains { $0.dictionary.isEmpty == false })
        #expect(samples.contains { $0.values.isEmpty == false })
        for value in samples {
            #expect(value.optional.map { abs($0) <= 10 } ?? true)
            #expect(value.values.count <= 5)
            #expect(value.values.allSatisfy { abs($0) <= 10 })
            #expect(value.dictionary.count <= 5)
            #expect(value.dictionary.allSatisfy { abs($0.key) <= 10 && abs($0.value.value) <= 10 })
            try expectStateSpaceReplay(generator, value: value)
        }
    }

    @Test("Sequence presets bound and scale default lengths", arguments: [
        (GeneratorStateSpace.tiny, 5), (.small, 10), (.medium, 20),
    ], [25, 100])
    func sequenceBounds(preset: (GeneratorStateSpace, Int), size: Int) throws {
        let (policy, maximumLength) = preset
        let scaledMaximum = sizeScaledMaximum(maximumLength, size: size)
        let generator = StateSpaceSequences.gen(depth: 0, stateSpace: policy).resize(size)
        let samples = try #example(generator, count: 100, seed: 1337)
        #expect(samples.count == 100)
        for value in samples {
            #expect(value.names.count <= scaledMaximum)
            #expect(value.names.allSatisfy { $0.count <= scaledMaximum })
            #expect(value.bytes.count <= scaledMaximum)
            try expectStateSpaceReplay(generator, value: value)
        }

        let boundary = StateSpaceSequences(
            names: Array(
                repeating: String(repeating: "a", count: scaledMaximum),
                count: scaledMaximum
            ),
            bytes: Data(repeating: 0, count: scaledMaximum)
        )
        try expectStateSpaceReplay(generator, value: boundary)
        try expectStateSpaceReplay(
            generator,
            value: StateSpaceSequences(
                names: Array(repeating: "", count: scaledMaximum + 1),
                bytes: Data()
            )
        )
        try expectStateSpaceReplay(
            generator,
            value: StateSpaceSequences(
                names: [String(repeating: "a", count: scaledMaximum + 1)],
                bytes: Data()
            )
        )
        try expectStateSpaceReplay(
            generator,
            value: StateSpaceSequences(
                names: [],
                bytes: Data(repeating: 0, count: scaledMaximum + 1)
            )
        )
    }

    @Test("Budgeted containers reflect beyond state-space sampling bounds")
    func budgetedContainerReflection() throws {
        let generator = StateSpaceIntegerArray.gen(
            maximumNodes: 32,
            stateSpace: .tiny
        )
        let target = StateSpaceIntegerArray(values: Array(repeating: 500, count: 6))
        try expectStateSpaceReplay(generator, value: target)
        let reduced = try reduceFromReflection(
            generator.gen,
            startingAt: target,
            property: { $0.values.isEmpty }
        )
        #expect(reduced.values.count == 1)

        let samples = try #example(generator.resize(100), count: 100, seed: 1337)
        #expect(samples.count == 100)
        #expect(samples.allSatisfy { $0.values.count <= 5 })
    }

    @Test("Explicit sequence payload overrides retain their domains")
    func sequenceOverridesWin() throws {
        let name = String(repeating: "a", count: 30)
        let generator = StateSpaceSequences.gen(
            depth: 0,
            stateSpace: .tiny,
            overriding: ReflectiveGenerator<String>.just(name)
        ).resize(100)
        let samples = try #example(generator, count: 50, seed: 1337)
        #expect(samples.count == 50)
        #expect(samples.contains { $0.names.isEmpty == false })
        for value in samples {
            #expect(value.names.count <= 5)
            #expect(value.names.allSatisfy { $0 == name })
            #expect(value.bytes.count <= 5)
            try expectStateSpaceReplay(generator, value: value)
        }
    }

    @Test("Explicit sequence override bounds remain strict")
    func explicitSequenceBounds() {
        let values = ReflectiveGenerator<[Int]>.array(.int(), length: 1 ... 10)
        let generator = StateSpaceIntegerArray.gen(
            stateSpace: .tiny,
            overriding: values
        )
        expectStateSpaceRejection(generator, value: StateSpaceIntegerArray(values: []))
        expectStateSpaceRejection(
            generator,
            value: StateSpaceIntegerArray(values: Array(repeating: 0, count: 11))
        )
    }

    @Test("Date collision presets use a fixed January 1, 2026 midpoint", arguments: [
        (GeneratorStateSpace.tiny, 10), (.small, 100),
    ])
    func dateCollisionDomains(preset: (GeneratorStateSpace, Int)) throws {
        let (policy, dayRadius) = preset
        let midpoint = Date(timeIntervalSince1970: 1_767_225_600)
        let lowerBound = midpoint.addingTimeInterval(TimeInterval(-dayRadius * 86400))
        let upperBound = midpoint.addingTimeInterval(TimeInterval(dayRadius * 86400))
        let generator = StateSpaceDate.gen(depth: 0, stateSpace: policy)
        let samples = try #example(generator, count: 200, seed: 1337)
        #expect(samples.count == 200)
        #expect(Set(samples.map(\.value)).count <= dayRadius * 2 + 1)
        #expect(Set(samples.map(\.value)).count < samples.count)
        for value in samples {
            #expect((lowerBound ... upperBound).contains(value.value))
            #expect(value.value.timeIntervalSince(midpoint).truncatingRemainder(dividingBy: 86400) == 0)
            try expectStateSpaceReplay(generator, value: value)
        }
        try expectStateSpaceReplay(generator, value: StateSpaceDate(value: lowerBound))
        try expectStateSpaceReplay(generator, value: StateSpaceDate(value: upperBound))

        let outsideDate = upperBound.addingTimeInterval(86400)
        let dateGenerator = Date.defaultGenerator(stateSpace: policy)
        let reflected = try #require(try Interpreters.reflect(dateGenerator.gen, with: outsideDate))
        #expect(try Interpreters.replay(dateGenerator.gen, using: reflected) == upperBound)
        #expect(try Interpreters.reflect(generator.gen, with: StateSpaceDate(value: outsideDate)) == nil)
    }

    @Test("Medium and full preserve default date outputs and subsequent random draws", arguments: [GeneratorStateSpace.medium, .full], [UInt64(0), 42, 1337])
    func unrestrictedDateParity(policy: GeneratorStateSpace, seed: UInt64) throws {
        let actual = try #example(
            #gen(Date.defaultGenerator(stateSpace: policy), .uint64()),
            count: 100,
            seed: .numeric(seed)
        )
        let reference = try #example(
            #gen(Date.defaultGenerator, .uint64()),
            count: 100,
            seed: .numeric(seed)
        )
        #expect(actual.count == reference.count)
        for (value, expected) in zip(actual, reference) {
            #expect(value.0 == expected.0)
            #expect(value.1 == expected.1)
        }
    }

    @Test("Explicit date payload overrides retain their domains")
    func dateOverridesWin() throws {
        let expected = Date.distantFuture
        let generator = StateSpaceDate.gen(
            depth: 0,
            stateSpace: .tiny,
            overriding: ReflectiveGenerator<Date>.just(expected)
        )
        let samples = try #example(generator, count: 20, seed: 1337)
        #expect(samples.count == 20)
        #expect(samples.allSatisfy { $0.value == expected })
        try expectStateSpaceReplay(generator, value: StateSpaceDate(value: expected))
    }

    @Test("The full preset preserves default sequence outputs and subsequent random draws", arguments: [UInt64(0), 42, 1337])
    func fullSequenceParity(seed: UInt64) throws {
        let actualStrings = try #example(
            #gen(String.defaultGenerator(stateSpace: .full), .uint64()),
            count: 100,
            seed: .numeric(seed)
        )
        let referenceStrings = try #example(
            #gen(String.defaultGenerator, .uint64()),
            count: 100,
            seed: .numeric(seed)
        )
        let actualData = try #example(
            #gen(Data.defaultGenerator(stateSpace: .full), .uint64()),
            count: 100,
            seed: .numeric(seed)
        )
        let referenceData = try #example(
            #gen(Data.defaultGenerator, .uint64()),
            count: 100,
            seed: .numeric(seed)
        )
        #expect(actualStrings.count == referenceStrings.count)
        for (actual, reference) in zip(actualStrings, referenceStrings) {
            #expect(actual.0 == reference.0)
            #expect(actual.1 == reference.1)
        }
        #expect(actualData.count == referenceData.count)
        for (actual, reference) in zip(actualData, referenceData) {
            #expect(actual.0 == reference.0)
            #expect(actual.1 == reference.1)
        }
    }

    @Test("Values outside sampling bounds remain reducible")
    func reflectedReduction() throws {
        let generator = StateSpaceLeaf.gen(stateSpace: .tiny)
        let reduced = try reduceFromReflection(
            generator.gen,
            startingAt: StateSpaceLeaf(value: 5000)
        ) { value in
            value.value < 5
        }
        #expect(reduced == StateSpaceLeaf(value: 5))
    }

    @Test("Reflection accepts values outside numeric sampling bounds", arguments: [
        (GeneratorStateSpace.tiny, 10), (.small, 100), (.medium, 10000),
    ])
    func reflectedBounds(preset: (GeneratorStateSpace, Int)) throws {
        let (policy, magnitude) = preset
        let generator = StateSpaceLeaf.gen(stateSpace: policy)
        for value in [-magnitude, 0, magnitude] {
            try expectStateSpaceReplay(generator, value: StateSpaceLeaf(value: value))
        }
        try expectStateSpaceReplay(generator, value: StateSpaceLeaf(value: magnitude + 1))
        try expectStateSpaceReplay(generator, value: StateSpaceLeaf(value: -magnitude - 1))
    }

    @Test("Examine and actual reflected output equality hold for recursive presets", arguments: GeneratorStateSpace.allCases, [Int?.none, 64])
    func recursiveRoundTrips(policy: GeneratorStateSpace, maximumNodes: Int?) throws {
        let generator = StateSpaceTree.gen(maximumDepth: 4, maximumNodes: maximumNodes, stateSpace: policy)
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

    @Test("128-bit numeric presets sample narrowly and reflect their full domains")
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
            try expectStateSpaceReplay(signed, value: Int128(Int.max))
            try expectStateSpaceReplay(signed, value: Int128.min)
            try expectStateSpaceReplay(signed, value: Int128.max)
            try expectStateSpaceReplay(unsigned, value: 100)
            try expectStateSpaceReplay(unsigned, value: UInt128(Int.max))
            try expectStateSpaceReplay(unsigned, value: UInt128.max)
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
private struct StateSpaceSequences: Equatable {
    let names: [String]
    let bytes: Data
}

@Exhaustable
private struct StateSpaceIntegerArray: Equatable {
    let values: [Int]
}

@Exhaustable
private struct StateSpaceDate: Equatable {
    let value: Date
}

@Exhaustable
private indirect enum StateSpaceTree: Equatable {
    case empty
    case node(Int, StateSpaceTree, StateSpaceTree)
}

// MARK: - Helpers

private func sizeScaledMaximum(_ maximum: Int, size: Int) -> Int {
    min(maximum, Int((Double(maximum + 1) * Double(size) / 100).rounded()))
}

private func expectIntegerBound<Value: FixedWidthInteger>(_ value: Value, magnitude: Int, size: Int) {
    let lower = Int((Double(Int(Value(clamping: -magnitude))) * Double(size) / 100).rounded())
    let upper = Int((Double(Int(Value(clamping: magnitude))) * Double(size) / 100).rounded())
    #expect((Value(clamping: lower) ... Value(clamping: upper)).contains(value))
}

private func expectStateSpaceReplay<Value: Equatable>(_ generator: ReflectiveGenerator<Value>, value: Value) throws {
    let tree = try #require(try Interpreters.reflect(generator.gen, with: value))
    #expect(try Interpreters.replay(generator.gen, using: tree) == value)
}

private func expectStateSpaceRejection<Value>(_ generator: ReflectiveGenerator<Value>, value: Value) {
    do {
        _ = try Interpreters.reflect(generator.gen, with: value)
        Issue.record("Expected reflection to reject the value as out of range")
    } catch let error as ReflectionError {
        guard case .inputWasOutOfGeneratorRange = error else {
            Issue.record("Expected inputWasOutOfGeneratorRange, got \(error)")
            return
        }
    } catch {
        Issue.record("Expected inputWasOutOfGeneratorRange, got \(error)")
    }
}
