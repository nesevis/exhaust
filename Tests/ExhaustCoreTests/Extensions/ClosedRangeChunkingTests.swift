//
//  ClosedRangeChunkingTests.swift
//  ExhaustCoreTests
//

import ExhaustCore
import ExhaustTestSupport
import Testing

@Suite("ClosedRange.split(into:)")
struct ClosedRangeChunkingTests {
    // MARK: - Boundary Tests

    @Test("Returns empty when chunks is zero")
    func returnsEmptyForZeroChunks() {
        #expect((UInt64(0) ... 100).split(into: 0).isEmpty)
    }

    @Test("Returns the original range when chunks is one")
    func returnsOriginalRangeForOneChunk() {
        let range = UInt64(10) ... 50
        #expect(range.split(into: 1) == [range])
    }

    @Test("Full UInt64 range splits into two equal halves")
    func fullRangeSplitsIntoTwoEqualHalves() {
        let result = (UInt64.min ... UInt64.max).split(into: 2)
        #expect(result.count == 2)
        #expect(result[0] == UInt64.min ... UInt64.max / 2)
        #expect(result[1] == UInt64.max / 2 + 1 ... UInt64.max)
    }

    @Test("Full UInt64 range distributes remainder into the first chunk when splitting into three")
    func fullRangeSplitsIntoThreeWithRemainder() {
        // 2^64 = 3 * (UInt64.max / 3) + 1, so the first chunk gets one extra element.
        let result = (UInt64.min ... UInt64.max).split(into: 3)
        #expect(result.count == 3)
        let baseSize = UInt64.max / 3
        #expect(result[0] == UInt64.min ... baseSize)
        #expect(result[1] == baseSize + 1 ... baseSize * 2)
        #expect(result[2].upperBound == UInt64.max)
    }

    @Test("Requesting more chunks than elements returns one chunk per element")
    func moreChunksThanElementsReturnsSingleElementChunks() {
        let result = (UInt64(0) ... 2).split(into: 100)
        #expect(result == [UInt64(0) ... 0, 1 ... 1, 2 ... 2])
    }

    @Test("Single-element range always returns one chunk")
    func singleElementRangeReturnsOneChunk() {
        let range = UInt64(42) ... 42
        #expect(range.split(into: 10) == [range])
    }

    @Test("Splitting produces a balanced contiguous partition of the entire range")
    func partitionContract() throws {
        try exhaustCheck(rangeAndChunksGen) { range, chunks in
            let result = range.split(into: chunks)
            let distance = range.upperBound - range.lowerBound
            // Compare before adding one so the full UInt64 domain cannot overflow.
            let expectedCount = distance >= UInt64(chunks - 1) ? chunks : Int(distance) + 1
            guard result.count == expectedCount,
                  result.first?.lowerBound == range.lowerBound,
                  result.last?.upperBound == range.upperBound
            else {
                return false
            }
            let contained = result.allSatisfy {
                $0.lowerBound >= range.lowerBound && $0.upperBound <= range.upperBound
                    && $0.lowerBound <= $0.upperBound
            }
            let contiguous = zip(result, result.dropFirst()).allSatisfy { current, next in
                current.upperBound < UInt64.max && next.lowerBound == current.upperBound + 1
            }
            let sizes = result.map { $0.upperBound - $0.lowerBound }
            return contained && contiguous && sizes.max()! - sizes.min()! <= 1
                && zip(sizes, sizes.dropFirst()).allSatisfy { $0 >= $1 }
        }
    }
}

// MARK: - Helpers

private var rangeAndChunksGen: Generator<(ClosedRange<UInt64>, Int)> {
    let rangeGen = Gen.zip(
        Gen.choose(in: UInt64.min ... UInt64.max),
        Gen.choose(in: UInt64.min ... UInt64.max)
    ).map { Swift.min($0.0, $0.1) ... Swift.max($0.0, $0.1) }
    let chunksGen: Generator<Int> = Gen.choose(in: 1 ... 50)
    return Gen.zip(rangeGen, chunksGen)
}
