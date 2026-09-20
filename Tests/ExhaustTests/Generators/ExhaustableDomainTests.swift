import Exhaust
import ExhaustCore
import ExhaustTestSupport
import Foundation
import Testing
@testable import ExhaustGenerators

@Suite("Derived domains")
struct ExhaustableDomainTests {
    @Test("Nested presets retain an operand no wider than either input")
    func presetLimit() {
        let preset = #gen(.element(from: ExhaustableDomain.allCases))
        let inputs = #gen(preset, preset)
        #exhaust(inputs) { policy, ceiling in
            let result = policy.limited(by: ceiling)
            #expect(result == policy || result == ceiling)
            #expect(result <= policy)
            #expect(result <= ceiling)
        }
    }

    @Test("Numeric presets wire exponential scaling into derived generators")
    func numericBounds() {
        let preset = #gen(.element(from: [ExhaustableDomain.tiny, .small, .medium]))
        let inputs = #gen(preset, .int(in: 1 ... 100), .uint64())
        #exhaust(inputs, .budget(.extensive)) { policy, size, seed in
            let magnitude = try #require(policy.numericMagnitude)
            let generator = StateSpaceNumbers.gen(recursion: 0, .domain(policy)).resize(size)
            var interpreter = ValueInterpreter(generator.gen, seed: seed, maxRuns: 1)
            let sample = try #require(try interpreter.next())
            #expect(exponentialSamplingContains(
                sample.signed,
                lowerBound: Int8(clamping: -magnitude),
                upperBound: Int8(clamping: magnitude),
                size: size
            ))
            #expect(exponentialSamplingContains(
                sample.unsigned,
                lowerBound: UInt8.zero,
                upperBound: UInt8(clamping: magnitude),
                size: size
            ))
            let floatingBound = Double(magnitude)
            #expect(exponentialSamplingContains(
                sample.floatingPoint,
                lowerBound: -floatingBound,
                upperBound: floatingBound,
                size: size
            ))
            try expectReflectionRoundTrip(generator.gen, value: sample)
        }
    }

    @Test("Tiny integers sample the rounded size-scaled range while reflecting beyond it", arguments: 1 ... 100)
    func tinySizeRamp(size: Int) throws {
        let generator = StateSpaceLeaf.gen(recursion: 0, .domain(.tiny)).resize(size)
        let magnitude = Int((Double(size) / 10).rounded())
        let samples = try #example(generator, count: 50, seed: 1337)
        #expect(samples.allSatisfy { (-magnitude ... magnitude).contains($0.value) })
        if size >= 50 {
            #expect(samples.contains { $0.value != 0 })
        }
        for value in [-magnitude, 0, magnitude] {
            try expectReflectionRoundTrip(generator.gen, value: StateSpaceLeaf(value: value))
        }
        try expectReflectionRoundTrip(generator.gen, value: StateSpaceLeaf(value: magnitude + 1))
        try expectReflectionRoundTrip(generator.gen, value: StateSpaceLeaf(value: -magnitude - 1))
    }

    @Test("The full preset preserves primitive outputs and subsequent random draws", arguments: [UInt64(0), 42, 1337])
    func fullParity(seed: UInt64) throws {
        for maximumNodes in [32, 100] {
            let derived = StateSpaceLeaf.gen(
                recursion: 0,
                .budget(.custom(recursion: 0, nodes: maximumNodes)),
                .domain(.full)
            )
            let actual = try #example(#gen(derived, .uint64()), count: 100, seed: .numeric(seed))
            // The pre-preset builder retains a pick even for a product's single constructor.
            let reference = try #example(#gen(.oneOf(.int()), .uint64()), count: 100, seed: .numeric(seed))
            for (value, expected) in zip(actual, reference) {
                #expect(value.0.value == expected.0)
                #expect(value.1 == expected.1)
            }
        }
        #expect(StateSpaceLeaf.__generatorDescriptor.domain == .full)
    }

    @Test("Annotations select defaults and both factory forms can override the root")
    func annotationAndFactoryPrecedence() throws {
        #expect(StateSpaceSmall.__generatorDescriptor.domain == .small)
        let target = StateSpaceSmall(value: 500)
        try expectReflectionRoundTrip(StateSpaceSmall.gen().gen, value: target)
        try expectReflectionRoundTrip(StateSpaceSmall.gen(.domain(.medium)).gen, value: target)
        try expectReflectionRoundTrip(StateSpaceSmall.gen(recursion: 0, .domain(.full)).gen, value: target)
        for generator in [
            StateSpaceSmall.gen(),
            StateSpaceSmall.gen(recursion: 0),
            ReflectiveGenerator<StateSpaceSmall>.derived(recursion: 0),
        ] {
            let samples = try #example(generator.resize(100), count: 100, seed: 1337)
            #expect(samples.allSatisfy { (-100 ... 100).contains($0.value) })
            #expect(samples.contains { abs($0.value) > 10 })
        }
    }

    @Test("Shared types and container recipes retain their path's preset", arguments: [100, 256])
    func inheritedDomains(maximumNodes: Int) throws {
        let generator = StateSpaceDiamond.gen(
            recursion: 4,
            .budget(.custom(recursion: 4, nodes: maximumNodes)),
            .domain(.small)
        ).resize(100)
        let target = StateSpaceDiamond(
            narrow: StateSpaceNarrow(leaf: StateSpaceLeaf(value: 10), values: [StateSpaceLeaf(value: -10)]),
            wider: StateSpaceWider(leaf: StateSpaceLeaf(value: 80), values: [StateSpaceLeaf(value: -80)]),
            direct: StateSpaceLeaf(value: 90)
        )
        try expectReflectionRoundTrip(generator.gen, value: target)
        let samples = try #example(generator, count: 100, seed: 1337)
        #expect(samples.contains { abs($0.wider.leaf.value) > 10 })
        for value in samples {
            #expect(abs(value.narrow.leaf.value) <= 10)
            #expect(value.narrow.values.count <= 10)
            #expect(value.narrow.values.allSatisfy { abs($0.value) <= 10 })
            #expect(abs(value.wider.leaf.value) <= 100)
            #expect(value.wider.values.count <= 10)
            #expect(value.wider.values.allSatisfy { abs($0.value) <= 100 })
            #expect(abs(value.direct.value) <= 100)
            try expectReflectionRoundTrip(generator.gen, value: value)
        }
    }

    @Test("Numeric overrides remain opaque to inherited and declared presets", arguments: [100, 128])
    func overridesWin(maximumNodes: Int) throws {
        let generator = StateSpaceDiamond.gen(
            recursion: 4,
            .budget(.custom(recursion: 4, nodes: maximumNodes)),
            .domain(.tiny),
            overriding: ReflectiveGenerator<Int>.just(777)
        ).resize(100)
        let samples = try #example(generator, count: 50, seed: 1337)
        for value in samples {
            #expect(value.direct.value == 777)
            #expect(value.narrow.leaf.value == 777)
            #expect(value.wider.leaf.value == 777)
            #expect(value.narrow.values.allSatisfy { $0.value == 777 })
            #expect(value.wider.values.allSatisfy { $0.value == 777 })
            try expectReflectionRoundTrip(generator.gen, value: value)
        }
    }

    @Test("Optional, set, and dictionary payloads inherit the domain policy", arguments: [100, 128])
    func standardContainers(maximumNodes: Int) throws {
        let generator = StateSpaceContainers.gen(.budget(.custom(recursion: 10, nodes: maximumNodes)), .domain(.tiny)).resize(100)
        let samples = try #example(generator, count: 50, seed: 1337)
        #expect(samples.contains { $0.optional != nil })
        #expect(samples.contains { $0.dictionary.isEmpty == false })
        #expect(samples.contains { $0.values.isEmpty == false })
        for value in samples {
            #expect(value.optional.map { abs($0) <= 10 } ?? true)
            #expect(value.values.count <= 10)
            #expect(value.values.allSatisfy { abs($0) <= 10 })
            #expect(value.dictionary.count <= 10)
            #expect(value.dictionary.allSatisfy { abs($0.key) <= 10 && abs($0.value.value) <= 10 })
            try expectReflectionRoundTrip(generator.gen, value: value)
        }
    }

    @Test("Sequence presets bound and scale default lengths", arguments: [
        (ExhaustableDomain.tiny, 10), (.small, 10), (.medium, 20),
    ], [25, 100])
    func sequenceBounds(preset: (ExhaustableDomain, Int), size: Int) throws {
        let (policy, maximumLength) = preset
        let scaledMaximum = sizeScaledMaximum(maximumLength, size: size)
        let generator = StateSpaceSequences.gen(
            recursion: 0,
            .budget(.custom(recursion: 0, nodes: 1000)),
            .domain(policy)
        ).resize(size)
        let samples = try #example(generator, count: 100, seed: 1337)
        for value in samples {
            #expect(value.names.count <= scaledMaximum)
            #expect(value.names.allSatisfy { $0.count <= scaledMaximum })
            #expect(value.bytes.count <= scaledMaximum)
            try expectReflectionRoundTrip(generator.gen, value: value)
        }

        let boundary = StateSpaceSequences(
            names: Array(
                repeating: String(repeating: "a", count: scaledMaximum),
                count: scaledMaximum
            ),
            bytes: Data(repeating: 0, count: scaledMaximum)
        )
        try expectReflectionRoundTrip(generator.gen, value: boundary)
        try expectReflectionRoundTrip(
            generator.gen,
            value: StateSpaceSequences(
                names: Array(repeating: "", count: scaledMaximum + 1),
                bytes: Data()
            )
        )
        try expectReflectionRoundTrip(
            generator.gen,
            value: StateSpaceSequences(
                names: [String(repeating: "a", count: scaledMaximum + 1)],
                bytes: Data()
            )
        )
        try expectReflectionRoundTrip(
            generator.gen,
            value: StateSpaceSequences(
                names: [],
                bytes: Data(repeating: 0, count: scaledMaximum + 1)
            )
        )
    }

    @Test("Tiny sequences sample structures beyond the former five-element ceiling")
    func expandedTinySequences() throws {
        let generator = StateSpaceSequences.gen(
            recursion: 0,
            .budget(.custom(recursion: 0, nodes: 1000)),
            .domain(.tiny)
        ).resize(100)
        let samples = try #example(generator, count: 100, seed: 1337)
        #expect(samples.contains { $0.names.count > 5 || $0.bytes.count > 5 })
    }

    @Test("Budgeted containers reflect beyond domain sampling bounds")
    func budgetedContainerReflection() throws {
        let generator = StateSpaceIntegerArray.gen(
            .budget(.custom(recursion: 10, nodes: 32)),
            .domain(.tiny)
        )
        let target = StateSpaceIntegerArray(values: Array(repeating: 500, count: 11))
        try expectReflectionRoundTrip(generator.gen, value: target)
        let reduced = try reduceFromReflection(
            generator.gen,
            startingAt: target,
            property: { $0.values.isEmpty }
        )
        #expect(reduced.values.count == 1)

        let samples = try #example(generator.resize(100), count: 100, seed: 1337)
        #expect(samples.allSatisfy { $0.values.count <= 10 })
    }

    @Test("Explicit sequence payload overrides retain their domains")
    func sequenceOverridesWin() throws {
        let name = String(repeating: "a", count: 30)
        let generator = StateSpaceSequences.gen(
            recursion: 0,
            .domain(.tiny),
            overriding: ReflectiveGenerator<String>.just(name)
        ).resize(100)
        let samples = try #example(generator, count: 50, seed: 1337)
        #expect(samples.contains { $0.names.isEmpty == false })
        for value in samples {
            #expect(value.names.count <= 10)
            #expect(value.names.allSatisfy { $0 == name })
            #expect(value.bytes.count <= 10)
            try expectReflectionRoundTrip(generator.gen, value: value)
        }
    }

    @Test("Explicit sequence override bounds remain strict")
    func explicitSequenceBounds() {
        let values = ReflectiveGenerator<[Int]>.array(.int(), length: 1 ... 10)
        let generator = StateSpaceIntegerArray.gen(
            .domain(.tiny),
            overriding: values
        )
        expectReflectionOutOfRange {
            _ = try Interpreters.reflect(generator.gen, with: StateSpaceIntegerArray(values: []))
        }
        expectReflectionOutOfRange {
            _ = try Interpreters.reflect(
                generator.gen,
                with: StateSpaceIntegerArray(values: Array(repeating: 0, count: 11))
            )
        }
    }

    @Test("Date collision presets use a fixed January 1, 2026 midpoint", arguments: [
        (ExhaustableDomain.tiny, 10), (.small, 100),
    ])
    func dateCollisionDomains(preset: (ExhaustableDomain, Int)) throws {
        let (policy, dayRadius) = preset
        let midpoint = Date(timeIntervalSince1970: 1_767_225_600)
        let lowerBound = midpoint.addingTimeInterval(TimeInterval(-dayRadius * 86400))
        let upperBound = midpoint.addingTimeInterval(TimeInterval(dayRadius * 86400))
        let generator = StateSpaceDate.gen(recursion: 0, .domain(policy))
        let samples = try #example(generator, count: 200, seed: 1337)
        #expect(Set(samples.map(\.value)).count <= dayRadius * 2 + 1)
        #expect(Set(samples.map(\.value)).count < samples.count)
        for value in samples {
            #expect((lowerBound ... upperBound).contains(value.value))
            #expect(value.value.timeIntervalSince(midpoint).truncatingRemainder(dividingBy: 86400) == 0)
            try expectReflectionRoundTrip(generator.gen, value: value)
        }
        try expectReflectionRoundTrip(generator.gen, value: StateSpaceDate(value: lowerBound))
        try expectReflectionRoundTrip(generator.gen, value: StateSpaceDate(value: upperBound))

        let outsideDate = upperBound.addingTimeInterval(86400)
        let dateGenerator = Date.defaultGenerator(domain: policy)
        let reflected = try #require(try Interpreters.reflect(dateGenerator.gen, with: outsideDate))
        #expect(try Interpreters.replay(dateGenerator.gen, using: reflected) == upperBound)
        #expect(try Interpreters.reflect(generator.gen, with: StateSpaceDate(value: outsideDate)) == nil)
    }

    @Test("Medium and full preserve default date outputs and subsequent random draws", arguments: [ExhaustableDomain.medium, .full], [UInt64(0), 42, 1337])
    func unrestrictedDateParity(policy: ExhaustableDomain, seed: UInt64) throws {
        let actual = try #example(
            #gen(Date.defaultGenerator(domain: policy), .uint64()),
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
            recursion: 0,
            .domain(.tiny),
            overriding: ReflectiveGenerator<Date>.just(expected)
        )
        let samples = try #example(generator, count: 20, seed: 1337)
        #expect(samples.allSatisfy { $0.value == expected })
        try expectReflectionRoundTrip(generator.gen, value: StateSpaceDate(value: expected))
    }

    @Test("The full preset preserves default sequence outputs and subsequent random draws", arguments: [UInt64(0), 42, 1337])
    func fullSequenceParity(seed: UInt64) throws {
        let actualStrings = try #example(
            #gen(String.defaultGenerator(domain: .full), .uint64()),
            count: 100,
            seed: .numeric(seed)
        )
        let referenceStrings = try #example(
            #gen(String.defaultGenerator, .uint64()),
            count: 100,
            seed: .numeric(seed)
        )
        let actualData = try #example(
            #gen(Data.defaultGenerator(domain: .full), .uint64()),
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
        let generator = StateSpaceLeaf.gen(.domain(.tiny))
        let reduced = try reduceFromReflection(
            generator.gen,
            startingAt: StateSpaceLeaf(value: 5000)
        ) { value in
            value.value < 5
        }
        #expect(reduced == StateSpaceLeaf(value: 5))
    }

    @Test("Reflection accepts values outside numeric sampling bounds", arguments: [
        (ExhaustableDomain.tiny, 10), (.small, 100), (.medium, 10000),
    ])
    func reflectedBounds(preset: (ExhaustableDomain, Int)) throws {
        let (policy, magnitude) = preset
        let generator = StateSpaceLeaf.gen(.domain(policy))
        for value in [-magnitude, 0, magnitude] {
            try expectReflectionRoundTrip(generator.gen, value: StateSpaceLeaf(value: value))
        }
        try expectReflectionRoundTrip(generator.gen, value: StateSpaceLeaf(value: magnitude + 1))
        try expectReflectionRoundTrip(generator.gen, value: StateSpaceLeaf(value: -magnitude - 1))
    }

    @Test("Examine and actual reflected output equality hold for recursive presets", arguments: ExhaustableDomain.allCases, [64, 100])
    func recursiveRoundTrips(policy: ExhaustableDomain, maximumNodes: Int) throws {
        let generator = StateSpaceTree.gen(.budget(.custom(recursion: 4, nodes: maximumNodes)), .domain(policy))
        let report = #examine(generator, .samples(50), .replay(1337), .suppress(.all)) { $0 == $1 }
        expectSuccessfulExamination(report, samples: 50)
        let samples = try #example(generator, count: 100, seed: 1337)
        for value in samples {
            try expectReflectionRoundTrip(generator.gen, value: value)
        }
    }

    @Test("Layers cache numeric policies separately without rebuilding repeated layers")
    func policySharing() throws {
        let plan = try GeneratorDerivationPlan(for: StateSpaceLeaf.self, overrides: [:])
        let builder = BudgetedGeneratorDerivation(plan: plan)
        _ = builder.generator(for: StateSpaceLeaf.self, recursion: 0, nodes: 2, domain: .tiny)
        _ = builder.generator(for: StateSpaceLeaf.self, recursion: 0, nodes: 2, domain: .small)
        #expect(builder.built.count == 2)
        _ = builder.generator(for: StateSpaceLeaf.self, recursion: 0, nodes: 2, domain: .tiny)
        #expect(builder.built.count == 2)
    }

    @Test("128-bit numeric presets wire exponential scaling into their low bits")
    func wideIntegerScaling() {
        if #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) {
            let preset = #gen(.element(from: [ExhaustableDomain.tiny, .small, .medium]))
            let inputs = #gen(preset, .int(in: 1 ... 100), .uint64())
            #exhaust(inputs, .budget(.extensive)) { policy, size, seed in
                let magnitude = try #require(policy.numericMagnitude)
                let signedGenerator = Int128.defaultGenerator(domain: policy).resize(size)
                let unsignedGenerator = UInt128.defaultGenerator(domain: policy).resize(size)
                var signedInterpreter = ValueInterpreter(signedGenerator.gen, seed: seed, maxRuns: 1)
                var unsignedInterpreter = ValueInterpreter(unsignedGenerator.gen, seed: seed, maxRuns: 1)
                let signed = try #require(try signedInterpreter.next())
                let unsigned = try #require(try unsignedInterpreter.next())
                let signedBits = UInt128(bitPattern: signed)
                let encodedSigned = (signedBits << 1) ^ UInt128(bitPattern: signed >> 127)
                #expect(encodedSigned >> 64 == 0)
                #expect(exponentialSamplingContains(
                    UInt64(truncatingIfNeeded: encodedSigned),
                    lowerBound: 0,
                    upperBound: UInt64(magnitude * 2),
                    size: size
                ))
                #expect(unsigned >> 64 == 0)
                #expect(exponentialSamplingContains(
                    UInt64(truncatingIfNeeded: unsigned),
                    lowerBound: 0,
                    upperBound: UInt64(magnitude),
                    size: size
                ))
            }
        }
    }

    @Test("128-bit numeric presets sample narrowly and reflect their full domains")
    func wideIntegers() throws {
        if #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) {
            let signed = Int128.defaultGenerator(domain: .small).resize(100)
            let unsigned = UInt128.defaultGenerator(domain: .small).resize(100)
            let signedSamples = try #example(signed, count: 100, seed: 1337)
            let unsignedSamples = try #example(unsigned, count: 100, seed: 1337)
            #expect(signedSamples.allSatisfy { (-100 ... 100).contains($0) })
            #expect(unsignedSamples.allSatisfy { $0 <= 100 })
            try expectReflectionRoundTrip(signed.gen, value: -100)
            try expectReflectionRoundTrip(signed.gen, value: Int128(Int.max))
            try expectReflectionRoundTrip(signed.gen, value: Int128.min)
            try expectReflectionRoundTrip(signed.gen, value: Int128.max)
            try expectReflectionRoundTrip(unsigned.gen, value: 100)
            try expectReflectionRoundTrip(unsigned.gen, value: UInt128(Int.max))
            try expectReflectionRoundTrip(unsigned.gen, value: UInt128.max)
        }
    }
}

// MARK: - Fixtures

@Exhaustable
private struct StateSpaceNumbers: Equatable {
    let signed: Int8
    let unsigned: UInt8
    let floatingPoint: Double
}

@Exhaustable
private struct StateSpaceLeaf: Equatable {
    let value: Int
}

@Exhaustable(.domain(.small))
private struct StateSpaceSmall: Equatable {
    let value: Int
}

@Exhaustable(.domain(.tiny))
private struct StateSpaceNarrow: Equatable {
    let leaf: StateSpaceLeaf
    let values: [StateSpaceLeaf]
}

@Exhaustable(.domain(.medium))
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

private func exponentialSamplingContains<Value: BitPatternConvertible>(
    _ value: Value,
    lowerBound: Value,
    upperBound: Value,
    size: Int
) -> Bool {
    Gen.applyScaling(
        min: lowerBound.bitPattern64,
        max: upperBound.bitPattern64,
        tag: Value.tag,
        scaling: .exponential(originBits: nil),
        size: UInt64(size)
    ).contains(value.bitPattern64)
}
