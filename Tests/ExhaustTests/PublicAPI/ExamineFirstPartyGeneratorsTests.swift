import Exhaust
import Foundation
import Testing

// swiftlint:disable type_body_length

/// Validates every first-party generator exposed on `Generator` via `#examine`.
///
/// Each test exercises generation, reflection round-trip, and replay determinism
/// for a single generator (or small family of overloads). The `samples` count is
/// kept low (30–50) to keep CI fast while still exercising the pipeline.
@Suite("#examine first-party generators")
struct ExamineFirstPartyGeneratorsTests {
    // MARK: - Bool

    @Test func bool() {
        let report = #examine(.bool(), .budget(50))
        #expect(report.passed)
    }

    // MARK: - Signed integers

    @Test func int8WithRange() {
        let report = #examine(.int8(in: -50 ... 50), .budget(50))
        #expect(report.passed)
    }

    @Test func int8WithoutRange() {
        let report = #examine(.int8(), .budget(50))
        #expect(report.passed)
    }

    @Test func int16WithRange() {
        let report = #examine(.int16(in: -1000 ... 1000), .budget(50))
        #expect(report.passed)
    }

    @Test func int16WithoutRange() {
        let report = #examine(.int16(), .budget(50))
        #expect(report.passed)
    }

    @Test func int32WithRange() {
        let report = #examine(.int32(in: -100_000 ... 100_000), .budget(50))
        #expect(report.passed)
    }

    @Test func int32WithoutRange() {
        let report = #examine(.int32(), .budget(50))
        #expect(report.passed)
    }

    @Test func int64WithRange() {
        let report = #examine(.int64(in: -1_000_000 ... 1_000_000), .budget(50))
        #expect(report.passed)
    }

    @Test func int64WithoutRange() {
        let report = #examine(.int64(), .budget(50))
        #expect(report.passed)
    }

    @Test func intWithRange() {
        let report = #examine(.int(in: -500 ... 500), .budget(50))
        #expect(report.passed)
    }

    @Test func intWithoutRange() {
        let report = #examine(.int(), .budget(50))
        #expect(report.passed)
    }

    // MARK: - Unsigned integers

    @Test func uint8WithRange() {
        let report = #examine(.uint8(in: 0 ... 200), .budget(50))
        #expect(report.passed)
    }

    @Test func uint8WithoutRange() {
        let report = #examine(.uint8(), .budget(50))
        #expect(report.passed)
    }

    @Test func uint16WithRange() {
        let report = #examine(.uint16(in: 0 ... 5000), .budget(50))
        #expect(report.passed)
    }

    @Test func uint16WithoutRange() {
        let report = #examine(.uint16(), .budget(50))
        #expect(report.passed)
    }

    @Test func uint32WithRange() {
        let report = #examine(.uint32(in: 0 ... 100_000), .budget(50))
        #expect(report.passed)
    }

    @Test func uint32WithoutRange() {
        let report = #examine(.uint32(), .budget(50))
        #expect(report.passed)
    }

    @Test func uint64WithRange() {
        let report = #examine(.uint64(in: 0 ... 1_000_000), .budget(50))
        #expect(report.passed)
    }

    @Test func uint64WithoutRange() {
        let report = #examine(.uint64(), .budget(50))
        #expect(report.passed)
    }

    @Test func uintWithRange() {
        let report = #examine(.uint(in: 0 ... 1000), .budget(50))
        #expect(report.passed)
    }

    @Test func uintWithoutRange() {
        let report = #examine(.uint(), .budget(50))
        #expect(report.passed)
    }

    // MARK: - 128-bit integers

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func int128() {
        let report = #examine(.int128(), .budget(30))
        #expect(report.passed)
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func uint128() {
        let report = #examine(.uint128(), .budget(30))
        #expect(report.passed)
    }

    // MARK: - Floating-point

    @Test func doubleWithRange() {
        let report = #examine(.double(in: -100.0 ... 100.0), .budget(50))
        #expect(report.passed)
    }

    @Test func doubleWithoutRange() {
        let report = #examine(.double(), .budget(50))
        #expect(report.passed)
    }

    @Test func floatWithRange() {
        let report = #examine(.float(in: -10.0 ... 10.0), .budget(50))
        #expect(report.passed)
    }

    @Test func floatWithoutRange() {
        let report = #examine(.float(), .budget(50))
        #expect(report.passed)
    }

    // MARK: - Decimal

    @Test func decimal() {
        let report = #examine(.decimal(in: -100 ... 100, precision: 4), .budget(50))
        #expect(report.passed)
    }

    // MARK: - Strings and characters

    @Test func character() {
        let report = #examine(.character(), .budget(50))
        #expect(report.passed)
    }

    @Test func characterFromScalarRange() {
        let report = #examine(.character(from: CharacterSet(charactersIn: "a" ... "z")), .budget(50))
        #expect(report.passed)
    }

    @Test func characterFromCharacterSet() {
        let report = #examine(.character(from: .alphanumerics), .budget(50))
        #expect(report.passed)
    }

    @Test func string() {
        let report = #examine(.string(), .budget(30))
        #expect(report.passed)
    }

    @Test func stringWithLength() {
        let report = #examine(.string(length: 1 ... 10), .budget(30))
        #expect(report.passed)
    }

    @Test func asciiString() {
        let report = #examine(.asciiString(), .budget(30))
        #expect(report.passed)
    }

    @Test func asciiStringWithLength() {
        let report = #examine(.asciiString(length: 1 ... 10), .budget(30))
        #expect(report.passed)
    }

    @Test func stringFromCharacterSet() {
        let report = #examine(.string(from: .letters, length: 1 ... 8), .budget(30))
        #expect(report.passed)
    }

    @Test func characterVariadicUnion() {
        let report = #examine(.character(from: .decimalDigits, .letters), .budget(30))
        #expect(report.passed)
    }

    // MARK: - UUID

    @Test func uuid() {
        let report = #examine(.uuid(), .budget(50))
        #expect(report.passed)
    }

    // MARK: - Date

    @Test func dateInRange() {
        let now = Date()
        let report = #examine(
            .date(between: now ... now.addingTimeInterval(86400 * 365), interval: .hours(1)),
            .budget(30)
        )
        #expect(report.passed)
    }

    @Test func dateWithinSpanOfAnchor() {
        let report = #examine(
            .date(within: .days(30), of: Date(), interval: .minutes(15)),
            .budget(30)
        )
        #expect(report.passed)
    }

    // MARK: - Collections: array

    @Test func arrayDefaultLength() {
        let report = #examine(.int(in: 0 ... 100).array(), .budget(30))
        #expect(report.passed)
    }

    @Test func arrayWithLengthRange() {
        let report = #examine(.int(in: 0 ... 50).array(length: 1 ... 5), .budget(30))
        #expect(report.passed)
    }

    @Test func arrayWithFixedLength() {
        let report = #examine(.int(in: 0 ... 50).array(length: 3), .budget(30))
        #expect(report.passed)
    }

    @Test func arrayStaticFactory() {
        let report = #examine(.array(.int(in: 0 ... 10), length: 2 ... 4), .budget(30))
        #expect(report.passed)
    }

    // MARK: - Collections: set

    @Test func setDefaultCount() {
        let report = #examine(.int(in: 0 ... 100).set(), .budget(1), .reflection(.silent))
        #expect(report.valuesGenerated == 1)
    }

    @Test func setWithCountRange() {
        let report = #examine(.int(in: 0 ... 100).set(count: 1 ... 5), .budget(10), .reflection(.silent))
        #expect(report.valuesGenerated == 10)
    }

    @Test func setWithFixedCount() {
        let report = #examine(.int(in: 0 ... 100).set(count: 3), .budget(10), .reflection(.silent))
        #expect(report.valuesGenerated == 10)
    }

    // MARK: - Collections: dictionary

    @Test func dictionary() {
        let report = #examine(
            .dictionary(.int(in: 0 ... 100), .int(in: 0 ... 100)),
            .budget(5),
            .reflection(.silent)
        )
        #expect(report.valuesGenerated == 5)
    }

    @Test func dictionaryWithCountRange() {
        let report = #examine(
            .dictionary(.int(in: 0 ... 100), .int(in: 0 ... 100), count: 1 ... 5),
            .budget(10),
            .reflection(.silent)
        )
        #expect(report.valuesGenerated == 10)
    }

    @Test func dictionaryWithFixedCount() {
        let report = #examine(
            .dictionary(.int(in: 0 ... 100), .int(in: 0 ... 100), count: 3),
            .budget(10),
            .reflection(.silent)
        )
        #expect(report.valuesGenerated == 10)
    }

    @Test func dictionaryCountStaysWithinBoundsAndDedupesKeys() throws {
        let values = try #example(
            .dictionary(.int(in: 0 ... 1000), .bool(), count: 2 ... 5),
            count: 50,
            seed: 42
        )
        #expect(values.allSatisfy { $0.count <= 5 }, "Key dedup can shrink a dictionary but never grow it")
        #expect(values.contains { $0.count >= 2 }, "At least some dictionaries should reach the requested range")
    }

    // MARK: - Collections: element

    @Test("element(from:) Hashable")
    func elementFromArrayHashable() {
        let report = #examine(.element(from: [10, 20, 30, 40, 50]), .budget(50))
        #expect(report.passed)
    }

    @Test("element(from:) Equatable, non-Hashable")
    func elementFromArrayEquatable() {
        let report = #examine(.element(from: [1.0, 2.5, 3.14, 0.0, -1.0]), .budget(50))
        #expect(report.passed)
    }

    @Test("element(from:id:) Hashable key path")
    func elementFromArrayByHashableKeyPath() {
        let items = [
            KeyPathFixture(id: 1, label: .init(value: "alpha")),
            KeyPathFixture(id: 2, label: .init(value: "beta")),
            KeyPathFixture(id: 3, label: .init(value: "gamma")),
            KeyPathFixture(id: 4, label: .init(value: "delta")),
        ]
        let report = #examine(.element(from: items, id: \KeyPathFixture.id), .budget(50))
        #expect(report.passed)
    }

    @Test("element(from:id:) Equatable key path")
    func elementFromArrayByEquatableKeyPath() {
        let items = [
            KeyPathFixture(id: 1, label: .init(value: "alpha")),
            KeyPathFixture(id: 2, label: .init(value: "beta")),
            KeyPathFixture(id: 3, label: .init(value: "gamma")),
        ]
        let report = #examine(.element(from: items, id: \KeyPathFixture.label), .budget(50))
        #expect(report.passed)
    }

    // MARK: - Collections: slice

    @Test func sliceOfGenerator() {
        withKnownIssue("slice(of: gen) uses a forward-only bind — reflection not supported") {
            let report = #examine(
                #gen(.slice(of: .int(in: 0 ... 50).array(length: 3 ... 6))),
                .budget(30)
            )
            #expect(report.passed)
        }
    }

    @Test func sliceOfFixedCollection() {
        let report = #examine(
            .slice(of: [10, 20, 30, 40, 50]),
            .budget(30)
        )
        #expect(report.passed)
    }

    // MARK: - Collections: shuffled

    @Test func shuffled() {
        withKnownIssue("Shuffled uses a forward-only transform — reflection not supported") {
            let report = #examine(
                .int(in: 0 ... 10).array(length: 4).shuffled(),
                .budget(30)
            )
            #expect(report.passed)
        }
    }

    // MARK: - Optional

    @Test func optional() {
        let report = #examine(.int(in: 0 ... 100).optional(), .budget(50))
        #expect(report.passed)
    }

    // MARK: - oneOf

    @Test func oneOfGenerators() {
        let report = #examine(
            .oneOf(.int(in: 0 ... 10), .int(in: 90 ... 100)),
            .budget(50)
        )
        #expect(report.passed)
    }

    @Test func oneOfWeighted() {
        let report = #examine(
            .oneOf(weighted: (3, .int(in: 0 ... 10)), (1, .int(in: 90 ... 100))),
            .budget(50)
        )
        #expect(report.passed)
    }

    // MARK: - just

    @Test func just() {
        let report = #examine(.just(42), .budget(30))
        #expect(report.passed)
    }

    // MARK: - SIMD vectors

    @Test func simd2() {
        let report = #examine(.simd2(.float(in: -1 ... 1)), .budget(30))
        #expect(report.passed)
    }

    @Test func simd3() {
        let report = #examine(.simd3(.float(in: -1 ... 1)), .budget(30))
        #expect(report.passed)
    }

    @Test func simd4() {
        let report = #examine(.simd4(.float(in: -1 ... 1)), .budget(30))
        #expect(report.passed)
    }

    @Test func simd8() {
        let report = #examine(.simd8(.float(in: -1 ... 1)), .budget(30))
        #expect(report.passed)
    }

    @Test func simd16() {
        let report = #examine(.simd16(.float(in: -1 ... 1)), .budget(30))
        #expect(report.passed)
    }

    @Test func simd32() {
        let report = #examine(.simd32(.float(in: -1 ... 1)), .budget(30))
        #expect(report.passed)
    }

    @Test func simd64() {
        let report = #examine(.simd64(.float(in: -1 ... 1)), .budget(30))
        #expect(report.passed)
    }

    @Test func simd2PerLane() {
        let report = #examine(
            .simd2(.double(in: 0 ... 10), .double(in: -10 ... 0)),
            .budget(30)
        )
        #expect(report.passed)
    }

    @Test func simd3PerLane() {
        let report = #examine(
            .simd3(.float(in: 0 ... 1), .float(in: 1 ... 2), .float(in: 2 ... 3)),
            .budget(30)
        )
        #expect(report.passed)
    }

    @Test func simd4PerLane() {
        let report = #examine(
            .simd4(
                .int32(in: 0 ... 10),
                .int32(in: 10 ... 20),
                .int32(in: 20 ... 30),
                .int32(in: 30 ... 40)
            ),
            .budget(30)
        )
        #expect(report.passed)
    }

    // MARK: - Combinators

    @Test func mappedBidirectional() {
        let report = #examine(
            .int(in: 0 ... 100).mapped(
                forward: { String($0) },
                backward: { Int($0) ?? 0 }
            ),
            .budget(50)
        )
        #expect(report.passed)
    }

    @Test func boundBidirectional() {
        // Intermittent: the replay non-determinism only bites when a sample hits n == bound value.
        withKnownIssue("Bound with data-dependent inner range — replay non-determinism", isIntermittent: true) {
            let report = #examine(
                .int(in: 1 ... 10).bound(
                    forward: { n in .int(in: 0 ... n) },
                    backward: { $0 }
                ),
                .budget(30)
            )
            #expect(report.passed)
        }
    }

    @Test func filter() {
        let report = #examine(
            .int(in: 0 ... 100).filter { $0 % 2 == 0 },
            .budget(30)
        )
        #expect(report.passed)
    }

    @Test func resize() {
        let report = #examine(.int(in: 0 ... 100).resize(50), .budget(30))
        #expect(report.passed)
    }

    // MARK: - Unique

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
            .budget(50)
        )
        #expect(report.passed)
    }
}

// MARK: - Helpers

private enum Direction: CaseIterable, Equatable {
    case north, south, east, west
}

private enum DirectionNonEquatable: CaseIterable {
    case north, south, east, west
}

private struct KeyPathFixture {
    let id: Int
    let label: EquatableOnly

    struct EquatableOnly: Equatable {
        let value: String
    }
}

// swiftlint:enable type_body_length
