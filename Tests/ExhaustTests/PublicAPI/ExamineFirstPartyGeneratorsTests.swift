import Exhaust
import ExhaustCore
import Foundation
import Testing

/// Every factory overload shares the same generation, reflection and replay contract.
@Suite("#examine first-party generators")
struct ExamineFirstPartyGeneratorsTests {
    @Test("Generation, reflection and replay agree", arguments: GeneratorCase.all)
    private func generatorContract(fixture: GeneratorCase) {
        let report = fixture.examine()
        #expect(report.passed)
        #expect(report.valuesGenerated == report.sampleCount)
        #expect(report.valuesGenerated > 0)
        #expect(report.reflectionRoundTripSuccesses == report.valuesGenerated)
        #expect(report.replayDeterminismSuccesses == report.valuesGenerated)
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func int128() {
        let report = #examine(.int128(), .samples(30)) { first, second in StructuralEquality.structurallyEqual(first, second) }
        #expect(report.passed)
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func uint128() {
        let report = #examine(.uint128(), .samples(30)) { first, second in StructuralEquality.structurallyEqual(first, second) }
        #expect(report.passed)
    }

    @Test func setDefaultCount() {
        let report = #examine(.int(in: 0 ... 100).set(), .samples(1), .skipReflection) { first, second in StructuralEquality.structurallyEqual(first, second) }
        expectSkippedReflection(report)
    }

    @Test func setWithCountRange() {
        let report = #examine(.int(in: 0 ... 100).set(count: 1 ... 5), .samples(10), .skipReflection) { first, second in StructuralEquality.structurallyEqual(first, second) }
        expectSkippedReflection(report)
    }

    @Test func setWithFixedCount() {
        let report = #examine(.int(in: 0 ... 100).set(count: 3), .samples(10), .skipReflection) { first, second in StructuralEquality.structurallyEqual(first, second) }
        expectSkippedReflection(report)
    }

    @Test func dictionary() {
        let report = #examine(
            .dictionary(.int(in: 0 ... 100), .int(in: 0 ... 100)),
            .samples(5),
            .skipReflection
        ) { first, second in StructuralEquality.structurallyEqual(first, second) }
        expectSkippedReflection(report)
    }

    @Test func dictionaryWithCountRange() {
        let report = #examine(
            .dictionary(.int(in: 0 ... 100), .int(in: 0 ... 100), count: 1 ... 5),
            .samples(10),
            .skipReflection
        ) { first, second in StructuralEquality.structurallyEqual(first, second) }
        expectSkippedReflection(report)
    }

    @Test func dictionaryWithFixedCount() {
        let report = #examine(
            .dictionary(.int(in: 0 ... 100), .int(in: 0 ... 100), count: 3),
            .samples(10),
            .skipReflection
        ) { first, second in StructuralEquality.structurallyEqual(first, second) }
        expectSkippedReflection(report)
    }

    @Test func dictionaryCountStaysWithinBoundsAndDedupesKeys() throws {
        let values = try #example(
            .dictionary(.int(in: 0 ... 1000), .bool(), count: 2 ... 5),
            count: 50,
            seed: 42
        )
        #expect(values.count == 50)
        #expect(values.allSatisfy { $0.count <= 5 }, "Key dedup can shrink a dictionary but never grow it")
        #expect(values.contains { $0.count >= 2 }, "At least some dictionaries should reach the requested range")
    }

    @Test func sliceOfGenerator() {
        let report = #examine(
            #gen(.slice(of: .int(in: 0 ... 50).array(length: 3 ... 6))),
            .samples(30), .suppress(.issueReporting)
        ) { first, second in StructuralEquality.structurallyEqual(first, second) }
        expectForwardOnly(report)
    }

    @Test func shuffled() {
        let report = #examine(
            .int(in: 0 ... 10).array(length: 4).shuffled(),
            .samples(30), .suppress(.issueReporting)
        ) { first, second in StructuralEquality.structurallyEqual(first, second) }
        expectForwardOnly(report)
    }

    @Test func boundBidirectional() {
        let generator = ReflectiveGenerator<Int>.int(in: 1 ... 10).bound(
            forward: { limit in
                ReflectiveGenerator<Int>.int(in: 0 ... limit).mapped(
                    forward: { (limit, $0) }, backward: { $0.1 }
                )
            },
            backward: { $0.0 }
        )
        let report = #examine(generator, .samples(30)) { $0 == $1 }
        #expect(report.passed)
        #expect(report.valuesGenerated == 30)
        #expect(report.replayDeterminismSuccesses == 30)
    }

    @Test("unique(by:) deduplicates by hashable key path")
    func uniqueByHashable() {
        let items = [
            KeyPathFixture(id: 1, label: .init(value: "alpha")),
            KeyPathFixture(id: 2, label: .init(value: "beta")),
            KeyPathFixture(id: 3, label: .init(value: "gamma")),
            KeyPathFixture(id: 4, label: .init(value: "delta")),
        ]
        let report = #examine(
            .element(from: items, id: \KeyPathFixture.id)
                .unique(by: \KeyPathFixture.id),
            .samples(50)
        ) { first, second in StructuralEquality.structurallyEqual(first, second) }
        #expect(report.passed)
    }
}

// MARK: - Fixtures

private struct GeneratorCase: Sendable, CustomTestStringConvertible {
    let name: String
    let examine: @Sendable () -> ExamineReport

    var testDescription: String {
        name
    }

    init(_ name: String, _ generator: ReflectiveGenerator<some Any>, samples: Int = 50) {
        self.name = name
        examine = {
            #examine(generator, .samples(samples)) { first, second in
                StructuralEquality.structurallyEqual(first, second)
            }
        }
    }

    static var all: [GeneratorCase] {
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        let keyedItems = [
            KeyPathFixture(id: 1, label: .init(value: "alpha")),
            KeyPathFixture(id: 2, label: .init(value: "beta")),
            KeyPathFixture(id: 3, label: .init(value: "gamma")),
            KeyPathFixture(id: 4, label: .init(value: "delta")),
        ]
        return [
            .init("bool", .bool()),
            .init("int8WithRange", .int8(in: -50 ... 50)),
            .init("int8WithoutRange", .int8()),
            .init("int16WithRange", .int16(in: -1000 ... 1000)),
            .init("int16WithoutRange", .int16()),
            .init("int32WithRange", .int32(in: -100_000 ... 100_000)),
            .init("int32WithoutRange", .int32()),
            .init("int64WithRange", .int64(in: -1_000_000 ... 1_000_000)),
            .init("int64WithoutRange", .int64()),
            .init("intWithRange", .int(in: -500 ... 500)),
            .init("intWithoutRange", .int()),
            .init("uint8WithRange", .uint8(in: 0 ... 200)),
            .init("uint8WithoutRange", .uint8()),
            .init("uint16WithRange", .uint16(in: 0 ... 5000)),
            .init("uint16WithoutRange", .uint16()),
            .init("uint32WithRange", .uint32(in: 0 ... 100_000)),
            .init("uint32WithoutRange", .uint32()),
            .init("uint64WithRange", .uint64(in: 0 ... 1_000_000)),
            .init("uint64WithoutRange", .uint64()),
            .init("uintWithRange", .uint(in: 0 ... 1000)),
            .init("uintWithoutRange", .uint()),
            .init("doubleWithRange", .double(in: -100.0 ... 100.0)),
            .init("doubleWithoutRange", .double()),
            .init("floatWithRange", .float(in: -10.0 ... 10.0)),
            .init("floatWithoutRange", .float()),
            .init("decimal", .decimal(in: -100 ... 100, precision: 4)),
            .init("character", .character()),
            .init("characterFromScalarRange", .character(from: CharacterSet(charactersIn: "a" ... "z"))),
            .init("characterFromCharacterSet", .character(from: .alphanumerics)),
            .init("string", .string(), samples: 30),
            .init("stringWithLength", .string(length: 1 ... 10), samples: 30),
            .init("asciiString", .asciiString(), samples: 30),
            .init("asciiStringWithLength", .asciiString(length: 1 ... 10), samples: 30),
            .init("stringFromCharacterSet", .string(from: .letters, length: 1 ... 8), samples: 30),
            .init("characterVariadicUnion", .character(from: .decimalDigits, .letters), samples: 30),
            .init("uuid", .uuid()),
            .init("dateInRange", .date(between: epoch ... epoch.addingTimeInterval(86400 * 365), interval: .hours(1)), samples: 30),
            .init("dateWithinSpanOfAnchor", .date(within: .days(30), of: Date(timeIntervalSince1970: 1_700_000_000), interval: .minutes(15)), samples: 30),
            .init("arrayDefaultLength", .int(in: 0 ... 100).array(), samples: 30),
            .init("arrayWithLengthRange", .int(in: 0 ... 50).array(length: 1 ... 5), samples: 30),
            .init("arrayWithFixedLength", .int(in: 0 ... 50).array(length: 3), samples: 30),
            .init("arrayStaticFactory", .array(.int(in: 0 ... 10), length: 2 ... 4), samples: 30),
            .init("elementFromArrayHashable", .element(from: [10, 20, 30, 40, 50])),
            .init("elementFromArrayEquatable", .element(from: [KeyPathFixture.EquatableOnly(value: "alpha"), .init(value: "beta")])),
            .init("elementFromArrayByHashableKeyPath", .element(from: keyedItems, id: \KeyPathFixture.id)),
            .init("elementFromArrayByEquatableKeyPath", .element(from: keyedItems, id: \KeyPathFixture.label)),
            .init("sliceOfFixedCollection", .slice(of: [10, 20, 30, 40, 50]), samples: 30),
            .init("optional", .int(in: 0 ... 100).optional()),
            .init("oneOfGenerators", .oneOf(.int(in: 0 ... 10), .int(in: 90 ... 100))),
            .init("oneOfWeighted", .oneOf(weighted: (3, .int(in: 0 ... 10)), (1, .int(in: 90 ... 100)))),
            .init("just", .just(42), samples: 30),
            .init("simd2", .simd2(.float(in: -1 ... 1)), samples: 30),
            .init("simd3", .simd3(.float(in: -1 ... 1)), samples: 30),
            .init("simd4", .simd4(.float(in: -1 ... 1)), samples: 30),
            .init("simd8", .simd8(.float(in: -1 ... 1)), samples: 30),
            .init("simd16", .simd16(.float(in: -1 ... 1)), samples: 30),
            .init("simd32", .simd32(.float(in: -1 ... 1)), samples: 30),
            .init("simd64", .simd64(.float(in: -1 ... 1)), samples: 30),
            .init("simd2PerLane", .simd2(.double(in: 0 ... 10), .double(in: -10 ... 0)), samples: 30),
            .init("simd3PerLane", .simd3(.float(in: 0 ... 1), .float(in: 1 ... 2), .float(in: 2 ... 3)), samples: 30),
            .init("simd4PerLane", .simd4(.int32(in: 0 ... 10), .int32(in: 10 ... 20), .int32(in: 20 ... 30), .int32(in: 30 ... 40)), samples: 30),
            .init("mappedBidirectional", .int(in: 0 ... 100).mapped(forward: { String($0) }, backward: { Int($0) ?? 0 })),
            .init("filter", .int(in: 0 ... 100).filter { $0 % 2 == 0 }, samples: 30),
            .init("resize", .int(in: 0 ... 100).resize(50), samples: 30),
        ]
    }
}

private struct KeyPathFixture {
    let id: Int
    let label: EquatableOnly

    struct EquatableOnly: Equatable {
        let value: String
    }
}

private func expectForwardOnly(_ report: ExamineReport, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(report.valuesGenerated == report.sampleCount, sourceLocation: sourceLocation)
    #expect(report.valuesGenerated > 0, sourceLocation: sourceLocation)
    #expect(report.replayDeterminismSuccesses == report.valuesGenerated, sourceLocation: sourceLocation)
    #expect(report.reflectionRoundTripSuccesses == 0, sourceLocation: sourceLocation)
    #expect(report.failures.count == 1, sourceLocation: sourceLocation)
    guard case .forwardOnlyTransform = report.failures.first else {
        Issue.record("Expected the forward-only reflection diagnostic", sourceLocation: sourceLocation)
        return
    }
}

private func expectSkippedReflection(_ report: ExamineReport, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(report.passed, sourceLocation: sourceLocation)
    #expect(report.reflectionSkipped, sourceLocation: sourceLocation)
    #expect(report.valuesGenerated == report.sampleCount, sourceLocation: sourceLocation)
    #expect(report.valuesGenerated > 0, sourceLocation: sourceLocation)
    #expect(report.replayDeterminismSuccesses == report.valuesGenerated, sourceLocation: sourceLocation)
    #expect(report.reflectionRoundTripSuccesses == 0, sourceLocation: sourceLocation)
}
