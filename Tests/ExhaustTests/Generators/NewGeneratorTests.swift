//
//  NewGeneratorTests.swift
//  Exhaust
//

import Foundation
import Testing
@testable import Exhaust

// MARK: - Float16 Generator

#if arch(arm64) || arch(arm64_32)
    @Suite("Float16 Generator")
    struct Float16GeneratorTests {
        @Test("Generated values are within range")
        func valuesWithinRange() {
            let gen = #gen(.float16(in: Float16(-1.0) ... Float16(1.0)))
            let values = #example(gen, count: 50, seed: 42)

            for value in values {
                #expect(value >= Float16(-1.0))
                #expect(value <= Float16(1.0))
                #expect(value.isFinite)
            }
        }

        @Test("Full-range generation excludes NaN and infinity")
        func fullRangeFinite() {
            let gen = #gen(.float16())
            let values = #example(gen, count: 100, seed: 42)

            for value in values {
                #expect(value.isFinite)
            }
        }

        @Test("Deterministic: same seed produces same values")
        func deterministic() {
            let gen = #gen(.float16(in: Float16(0) ... Float16(100)))

            let values1 = #example(gen, count: 20, seed: 99)
            let values2 = #example(gen, count: 20, seed: 99)
            #expect(values1 == values2)
        }

        @Test("Shrinks toward threshold")
        func shrinksTowardThreshold() throws {
            let gen = #gen(.float16(in: Float16(0) ... Float16(100)))

            let output = try #require(
                #exhaust(gen, .suppressIssueReporting) { value in value < Float16(50) }
            )

            #expect(output == Float16(50))
        }
    }
#endif

// MARK: - CGFloat Generator

@Suite("CGFloat Generator")
struct CGFloatGeneratorTests {
    @Test("Generated values are within range")
    func valuesWithinRange() {
        let gen = #gen(.cgfloat(in: 0.0 ... 320.0))
        let values = #example(gen, count: 50, seed: 42)

        for value in values {
            #expect(value >= 0.0)
            #expect(value <= 320.0)
        }
    }

    @Test("Full-range generation produces finite values")
    func fullRangeFinite() {
        let gen = #gen(.cgfloat())
        let values = #example(gen, count: 50, seed: 42)

        for value in values {
            #expect(value.isFinite)
        }
    }

    @Test("Deterministic: same seed produces same values")
    func deterministic() {
        let gen = #gen(.cgfloat(in: -100.0 ... 100.0))

        let values1 = #example(gen, count: 20, seed: 99)
        let values2 = #example(gen, count: 20, seed: 99)
        #expect(values1 == values2)
    }
}

// MARK: - Data Generator

@Suite("Data Generator")
struct DataGeneratorTests {
    @Test("Size-scaled generation produces non-empty data")
    func sizeScaledGeneration() {
        let gen = #gen(.data())
        let values = #example(gen, count: 20, seed: 42)

        #expect(values.isEmpty == false)
    }

    @Test("Fixed-length generation produces correct size")
    func fixedLength() {
        let gen = #gen(.data(length: 32))
        let values = #example(gen, count: 10, seed: 42)

        for value in values {
            #expect(value.count == 32)
        }
    }

    @Test("Range-length generation stays within bounds")
    func rangeLengthWithinBounds() {
        let gen = #gen(.data(length: 16 ... 64))
        let values = #example(gen, count: 30, seed: 42)

        for value in values {
            #expect(value.count >= 16)
            #expect(value.count <= 64)
        }
    }

    @Test("Byte values span full range")
    func byteValueRange() {
        let gen = #gen(.data(length: 256))
        let values = #example(gen, count: 10, seed: 42)
        let allBytes = Set(values.flatMap(\.self))

        // With 2560 random bytes, we should cover most of 0...255
        #expect(allBytes.count > 200)
    }

    @Test("Deterministic: same seed produces same data")
    func deterministic() {
        let gen = #gen(.data(length: 16 ... 32))

        let values1 = #example(gen, count: 10, seed: 99)
        let values2 = #example(gen, count: 10, seed: 99)
        #expect(values1 == values2)
    }

    @Test("Shrinks data length toward zero")
    func shrinksLength() throws {
        let gen = #gen(.data(length: 0 ... 100))

        let output = try #require(
            #exhaust(gen, .suppressIssueReporting) { data in data.count < 10 }
        )

        #expect(output.count == 10)
    }
}

// MARK: - Result Generator

@Suite("Result Generator")
struct ResultGeneratorTests {
    enum TestError: Error, Hashable {
        case notFound
        case timeout
        case forbidden
    }

    @Test("Generates both success and failure cases")
    func generatesBothCases() {
        let gen: ReflectiveGenerator<Result<Int, TestError>> = .result(
            success: .int(in: 0 ... 100),
            failure: .element(from: [TestError.notFound, TestError.timeout, TestError.forbidden])
        )
        let values = #example(gen, count: 50, seed: 42)

        let hasSuccess = values.contains { result in
            if case .success = result { return true }
            return false
        }
        let hasFailure = values.contains { result in
            if case .failure = result { return true }
            return false
        }

        #expect(hasSuccess)
        #expect(hasFailure)
    }

    @Test("Success values are within range")
    func successValuesInRange() {
        let gen: ReflectiveGenerator<Result<Int, TestError>> = .result(
            success: .int(in: 10 ... 20),
            failure: .element(from: [TestError.notFound])
        )
        let values = #example(gen, count: 50, seed: 42)

        for value in values {
            if case let .success(number) = value {
                #expect(number >= 10)
                #expect(number <= 20)
            }
        }
    }

    @Test("Deterministic: same seed produces same results")
    func deterministic() {
        let gen: ReflectiveGenerator<Result<Int, TestError>> = .result(
            success: .int(in: 0 ... 100),
            failure: .element(from: [TestError.notFound, TestError.timeout])
        )

        let values1 = #example(gen, count: 20, seed: 99)
        let values2 = #example(gen, count: 20, seed: 99)

        for (first, second) in zip(values1, values2) {
            switch (first, second) {
            case let (.success(lhs), .success(rhs)):
                #expect(lhs == rhs)
            case let (.failure(lhs), .failure(rhs)):
                #expect(lhs == rhs)
            default:
                Issue.record("Mismatched Result cases across seeds")
            }
        }
    }
}

// MARK: - ClosedRange Generator

@Suite("ClosedRange Generator")
struct ClosedRangeGeneratorTests {
    @Test("Lower bound is at most upper bound")
    func boundsOrdered() {
        let gen = #gen(.closedRange(.int(in: 0 ... 100)))
        let values = #example(gen, count: 50, seed: 42)

        for range in values {
            #expect(range.lowerBound <= range.upperBound)
        }
    }

    @Test("Bounds stay within source generator range")
    func boundsWithinSourceRange() {
        let gen = #gen(.closedRange(.int(in: -50 ... 50)))
        let values = #example(gen, count: 50, seed: 42)

        for range in values {
            #expect(range.lowerBound >= -50)
            #expect(range.upperBound <= 50)
        }
    }

    @Test("Deterministic: same seed produces same ranges")
    func deterministic() {
        let gen = #gen(.closedRange(.int(in: 0 ... 100)))

        let values1 = #example(gen, count: 20, seed: 99)
        let values2 = #example(gen, count: 20, seed: 99)
        #expect(values1 == values2)
    }
}

// MARK: - Range Generator

@Suite("Range Generator")
struct RangeGeneratorTests {
    @Test("Lower bound is at most upper bound")
    func boundsOrdered() {
        let gen = #gen(.range(.int(in: 0 ... 100)))
        let values = #example(gen, count: 50, seed: 42)

        for range in values {
            #expect(range.lowerBound <= range.upperBound)
        }
    }

    @Test("Bounds stay within source generator range")
    func boundsWithinSourceRange() {
        let gen = #gen(.range(.double(in: 0.0 ... 1.0)))
        let values = #example(gen, count: 50, seed: 42)

        for range in values {
            #expect(range.lowerBound >= 0.0)
            #expect(range.upperBound <= 1.0)
        }
    }

    @Test("Can produce empty ranges when bounds are equal")
    func canProduceEmptyRanges() {
        // With a very narrow source range, equal bounds become likely
        let gen = #gen(.range(.int(in: 0 ... 2)))
        let values = #example(gen, count: 100, seed: 42)

        let hasEmpty = values.contains { $0.isEmpty }
        #expect(hasEmpty)
    }

    @Test("Deterministic: same seed produces same ranges")
    func deterministic() {
        let gen = #gen(.range(.int(in: 0 ... 100)))

        let values1 = #example(gen, count: 20, seed: 99)
        let values2 = #example(gen, count: 20, seed: 99)
        #expect(values1 == values2)
    }
}

// MARK: - URL Generator

@Suite("URL Generator")
struct URLGeneratorTests {
    @Test("Generated URLs are valid")
    func validURLs() {
        let gen = #gen(.url())
        let values = #example(gen, count: 30, seed: 42)

        for url in values {
            #expect(url.scheme == "http" || url.scheme == "https")
            #expect(url.host?.isEmpty == false)
        }
    }

    @Test("Generated URLs have correct structure")
    func correctStructure() {
        let gen = #gen(.url())
        let values = #example(gen, count: 30, seed: 42)

        for url in values {
            let string = url.absoluteString
            #expect(string.hasPrefix("http://") || string.hasPrefix("https://"))

            // Host should have at least two labels (for example "abc.def")
            let host = url.host ?? ""
            let labels = host.split(separator: ".")
            #expect(labels.count >= 2)
            #expect(labels.count <= 3)
        }
    }

    @Test("Deterministic: same seed produces same URLs")
    func deterministic() {
        let gen = #gen(.url())

        let values1 = #example(gen, count: 20, seed: 99)
        let values2 = #example(gen, count: 20, seed: 99)
        #expect(values1 == values2)
    }
}
