import Foundation
import Testing
@testable import Exhaust

// swiftlint:disable type_body_length

/// Validates every first-party generator exposed on `ReflectiveGenerator` via `#examine`.
///
/// Each test exercises generation, reflection round-trip, and replay determinism
/// for a single generator (or small family of overloads). The `samples` count is
/// kept low (30–50) to keep CI fast while still exercising the pipeline.
@Suite("#examine first-party generators")
struct ExamineFirstPartyGeneratorsTests {
    // MARK: - Bool

    @Test func bool() {
        let report = #examine(.bool(), samples: 50)
        #expect(report.passed)
    }

    // MARK: - Signed integers

    @Test func int8WithRange() {
        let report = #examine(.int8(in: -50 ... 50), samples: 50)
        #expect(report.passed)
    }

    @Test func int8WithoutRange() {
        let report = #examine(.int8(), samples: 50)
        #expect(report.passed)
    }

    @Test func int16WithRange() {
        let report = #examine(.int16(in: -1000 ... 1000), samples: 50)
        #expect(report.passed)
    }

    @Test func int16WithoutRange() {
        let report = #examine(.int16(), samples: 50)
        #expect(report.passed)
    }

    @Test func int32WithRange() {
        let report = #examine(.int32(in: -100_000 ... 100_000), samples: 50)
        #expect(report.passed)
    }

    @Test func int32WithoutRange() {
        let report = #examine(.int32(), samples: 50)
        #expect(report.passed)
    }

    @Test func int64WithRange() {
        let report = #examine(.int64(in: -1_000_000 ... 1_000_000), samples: 50)
        #expect(report.passed)
    }

    @Test func int64WithoutRange() {
        let report = #examine(.int64(), samples: 50)
        #expect(report.passed)
    }

    @Test func intWithRange() {
        let report = #examine(.int(in: -500 ... 500), samples: 50)
        #expect(report.passed)
    }

    @Test func intWithoutRange() {
        let report = #examine(.int(), samples: 50)
        #expect(report.passed)
    }

    // MARK: - Unsigned integers

    @Test func uint8WithRange() {
        let report = #examine(.uint8(in: 0 ... 200), samples: 50)
        #expect(report.passed)
    }

    @Test func uint8WithoutRange() {
        let report = #examine(.uint8(), samples: 50)
        #expect(report.passed)
    }

    @Test func uint16WithRange() {
        let report = #examine(.uint16(in: 0 ... 5000), samples: 50)
        #expect(report.passed)
    }

    @Test func uint16WithoutRange() {
        let report = #examine(.uint16(), samples: 50)
        #expect(report.passed)
    }

    @Test func uint32WithRange() {
        let report = #examine(.uint32(in: 0 ... 100_000), samples: 50)
        #expect(report.passed)
    }

    @Test func uint32WithoutRange() {
        let report = #examine(.uint32(), samples: 50)
        #expect(report.passed)
    }

    @Test func uint64WithRange() {
        let report = #examine(.uint64(in: 0 ... 1_000_000), samples: 50)
        #expect(report.passed)
    }

    @Test func uint64WithoutRange() {
        let report = #examine(.uint64(), samples: 50)
        #expect(report.passed)
    }

    @Test func uintWithRange() {
        let report = #examine(.uint(in: 0 ... 1000), samples: 50)
        #expect(report.passed)
    }

    @Test func uintWithoutRange() {
        let report = #examine(.uint(), samples: 50)
        #expect(report.passed)
    }

    // MARK: - 128-bit integers

    @Test func int128() {
        let report = #examine(.int128(), samples: 30)
        #expect(report.passed)
    }

    @Test func uint128() {
        let report = #examine(.uint128(), samples: 30)
        #expect(report.passed)
    }

    // MARK: - Floating-point

    @Test func doubleWithRange() {
        let report = #examine(.double(in: -100.0 ... 100.0), samples: 50)
        #expect(report.passed)
    }

    @Test func doubleWithoutRange() {
        let report = #examine(.double(), samples: 50)
        #expect(report.passed)
    }

    @Test func floatWithRange() {
        let report = #examine(.float(in: -10.0 ... 10.0), samples: 50)
        #expect(report.passed)
    }

    @Test func floatWithoutRange() {
        let report = #examine(.float(), samples: 50)
        #expect(report.passed)
    }

    // MARK: - Decimal

    @Test func decimal() {
        let report = #examine(.decimal(in: -100 ... 100, precision: 4), samples: 50)
        #expect(report.passed)
    }

    // MARK: - Strings and characters

    @Test func character() {
        let report = #examine(.character(), samples: 50)
        #expect(report.passed)
    }

    @Test func characterInRange() {
        let report = #examine(.character(in: "a" ... "z"), samples: 50)
        #expect(report.passed)
    }

    @Test func characterFromCharacterSet() {
        let report = #examine(.character(from: .alphanumerics), samples: 50)
        #expect(report.passed)
    }

    @Test func string() {
        let report = #examine(.string(), samples: 30)
        #expect(report.passed)
    }

    @Test func stringWithLength() {
        let report = #examine(.string(length: 1 ... 10), samples: 30)
        #expect(report.passed)
    }

    @Test func asciiString() {
        let report = #examine(.asciiString(), samples: 30)
        #expect(report.passed)
    }

    @Test func asciiStringWithLength() {
        let report = #examine(.asciiString(length: 1 ... 10), samples: 30)
        #expect(report.passed)
    }

    @Test func stringFromCharacterSet() {
        let report = #examine(.string(from: .letters, length: 1 ... 8), samples: 30)
        #expect(report.passed)
    }

    // MARK: - UUID

    @Test func uuid() {
        let report = #examine(.uuid(), samples: 50)
        #expect(report.passed)
    }

    // MARK: - Date

    @Test func dateInRange() {
        let now = Date()
        let report = #examine(
            .date(between: now ... now.addingTimeInterval(86400 * 365), interval: .hours(1)),
            samples: 30
        )
        #expect(report.passed)
    }

    @Test func dateWithinSpanOfAnchor() {
        let report = #examine(
            .date(within: .days(30), of: Date(), interval: .minutes(15)),
            samples: 30
        )
        #expect(report.passed)
    }

    // MARK: - Collections: array

    @Test func arrayDefaultLength() {
        let report = #examine(.int(in: 0 ... 100).array(), samples: 30)
        #expect(report.passed)
    }

    @Test func arrayWithLengthRange() {
        let report = #examine(.int(in: 0 ... 50).array(length: 1 ... 5), samples: 30)
        #expect(report.passed)
    }

    @Test func arrayWithFixedLength() {
        let report = #examine(.int(in: 0 ... 50).array(length: 3), samples: 30)
        #expect(report.passed)
    }

    @Test func arrayStaticFactory() {
        let report = #examine(ReflectiveGenerator.array(.int(in: 0 ... 10), length: 2 ... 4), samples: 30)
        #expect(report.passed)
    }

    // MARK: - Collections: set

    @Test func setDefaultCount() {
        let report = #examine(.int(in: 0 ... 100).set(), samples: 1)
        #expect(report.passed)
    }

    @Test func setWithCountRange() {
        // Why is this passing?
        let report = #examine(.int(in: 0 ... 100).set(count: 1 ... 5), samples: 10)
        #expect(report.passed)
    }

    @Test func setWithFixedCount() {
        let report = #examine(.int(in: 0 ... 100).set(count: 3), samples: 10)
        #expect(report.passed)
    }

    // MARK: - Collections: dictionary

    @Test func dictionary() {
        let report = #examine(
            ReflectiveGenerator.dictionary(.int(in: 0 ... 100), .int(in: 0 ... 100)),
            samples: 5
        )
        #expect(report.passed)
    }

    // MARK: - Collections: element

    @Test func elementFromArray() {
        let report = #examine(.element(from: [10, 20, 30, 40, 50]), samples: 50)
        #expect(report.passed)
    }

    // MARK: - Collections: slice

    @Test func slice() {
        withKnownIssue("Slice uses a forward-only transform — reflection not supported") {
            let report = #examine(
                #gen(.slice(.int(in: 0 ... 50).array(length: 3 ... 6))),
                samples: 30
            )
            #expect(report.passed)
        }
    }

    // MARK: - Collections: shuffled

    @Test func shuffled() {
        withKnownIssue("Shuffled uses a forward-only transform — reflection not supported") {
            let report = #examine(
                .int(in: 0 ... 10).array(length: 4).shuffled(),
                samples: 30
            )
            #expect(report.passed)
        }
    }

    // MARK: - Optional

    @Test func optional() {
        let report = #examine(.int(in: 0 ... 100).optional(), samples: 50)
        #expect(report.passed)
    }

    // MARK: - oneOf

    @Test func oneOfGenerators() {
        let report = #examine(
            ReflectiveGenerator.oneOf(.int(in: 0 ... 10), .int(in: 90 ... 100)),
            samples: 50
        )
        #expect(report.passed)
    }

//    @Test func oneOfCaseIterableEquatable() {
//        let report = #examine(.array(Direction.allCases), samples: 50)
//        #expect(report.passed)
//    }
//
//    @Test func oneOfCaseIterableNonEquatable() {
//        let report = #examine(.array(DirectionNonEquatable.allCases), samples: 50)
//        #expect(report.passed)
//    }

    @Test func oneOfWeighted() {
        let report = #examine(
            ReflectiveGenerator.oneOf(weighted: (3, .int(in: 0 ... 10)), (1, .int(in: 90 ... 100))),
            samples: 50
        )
        #expect(report.passed)
    }

    // MARK: - just

    @Test func just() {
        let report = #examine(.just(42), samples: 30)
        #expect(report.passed)
    }

    // MARK: - SIMD vectors

    @Test func simd2() {
        let report = #examine(.simd2(.float(in: -1 ... 1)), samples: 30)
        #expect(report.passed)
    }

    @Test func simd3() {
        let report = #examine(.simd3(.float(in: -1 ... 1)), samples: 30)
        #expect(report.passed)
    }

    @Test func simd4() {
        let report = #examine(.simd4(.float(in: -1 ... 1)), samples: 30)
        #expect(report.passed)
    }

    @Test func simd8() {
        let report = #examine(.simd8(.float(in: -1 ... 1)), samples: 30)
        #expect(report.passed)
    }

    @Test func simd16() {
        let report = #examine(.simd16(.float(in: -1 ... 1)), samples: 30)
        #expect(report.passed)
    }

    @Test func simd32() {
        let report = #examine(.simd32(.float(in: -1 ... 1)), samples: 30)
        #expect(report.passed)
    }

    @Test func simd64() {
        let report = #examine(.simd64(.float(in: -1 ... 1)), samples: 30)
        #expect(report.passed)
    }

    @Test func simd2PerLane() {
        let report = #examine(
            .simd2(.double(in: 0 ... 10), .double(in: -10 ... 0)),
            samples: 30
        )
        #expect(report.passed)
    }

    @Test func simd3PerLane() {
        let report = #examine(
            .simd3(.float(in: 0 ... 1), .float(in: 1 ... 2), .float(in: 2 ... 3)),
            samples: 30
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
            samples: 30
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
            samples: 50
        )
        #expect(report.passed)
    }

    @Test(.disabled("Flaky if it happens to hit n == $0"))
    func boundBidirectional() {
        withKnownIssue("Bound with data-dependent inner range — replay non-determinism") {
            let report = #examine(
                .int(in: 1 ... 10).bound(
                    forward: { n in .int(in: 0 ... n) },
                    backward: { $0 }
                ),
                samples: 30
            )
            #expect(report.passed)
        }
    }

    @Test func filter() {
        let report = #examine(
            .int(in: 0 ... 100).filter { $0 % 2 == 0 },
            samples: 30
        )
        #expect(report.passed)
    }

    @Test func resize() {
        let report = #examine(.int(in: 0 ... 100).resize(50), samples: 30)
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

// swiftlint:enable type_body_length
