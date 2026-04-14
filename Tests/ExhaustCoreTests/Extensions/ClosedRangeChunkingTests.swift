//
//  ClosedRangeChunkingTests.swift
//  ExhaustCoreTests
//

import ExhaustCore
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

    // MARK: - Property Tests

    @Test("Sub-ranges are contiguous and exactly cover the original range")
    func subRangesAreContiguousAndCoverOriginalRange() throws {
        try exhaustCheck(rangeAndChunksGen) { range, chunks in
            let result = range.split(into: chunks)
            guard !result.isEmpty else { return true }
            guard result.first?.lowerBound == range.lowerBound else { return false }
            guard result.last?.upperBound == range.upperBound else { return false }
            return zip(result, result.dropFirst()).allSatisfy { current, next in
                next.lowerBound == current.upperBound &+ 1
            }
        }
    }

    @Test("All sub-ranges are non-empty")
    func allSubRangesAreNonEmpty() throws {
        try exhaustCheck(rangeAndChunksGen) { range, chunks in
            range.split(into: chunks).allSatisfy { $0.lowerBound <= $0.upperBound }
        }
    }

    @Test("Sub-ranges differ in size by at most one")
    func subRangesAreBalanced() throws {
        try exhaustCheck(rangeAndChunksGen) { range, chunks in
            let result = range.split(into: chunks)
            guard result.count >= 2 else { return true }
            // Use upperBound - lowerBound as a proxy for size - 1 to avoid overflow
            // on full-range sub-ranges. The balance invariant holds either way.
            let proxySizes = result.map { $0.upperBound - $0.lowerBound }
            return proxySizes.max()! - proxySizes.min()! <= 1
        }
    }

    @Test("Result count does not exceed requested chunk count")
    func resultCountDoesNotExceedRequestedChunks() throws {
        try exhaustCheck(rangeAndChunksGen) { range, chunks in
            range.split(into: chunks).count <= chunks
        }
    }

    @Test("All sub-ranges are contained within the original range")
    func subRangesAreContainedInOriginalRange() throws {
        try exhaustCheck(rangeAndChunksGen) { range, chunks in
            range.split(into: chunks).allSatisfy { subRange in
                subRange.lowerBound >= range.lowerBound &&
                    subRange.upperBound <= range.upperBound
            }
        }
    }
}

// MARK: - Helpers

private var rangeAndChunksGen: ReflectiveGenerator<(ClosedRange<UInt64>, Int)> {
    let rangeGen = Gen.zip(
        Gen.choose(in: UInt64.min ... UInt64.max),
        Gen.choose(in: UInt64.min ... UInt64.max)
    )._map { Swift.min($0.0, $0.1) ... Swift.max($0.0, $0.1) }
    let chunksGen: ReflectiveGenerator<Int> = Gen.choose(in: 1 ... 50)
    return Gen.zip(rangeGen, chunksGen)
}

private func exhaustCheck<A, B>(
    _ gen: ReflectiveGenerator<(A, B)>,
    maxIterations: UInt64 = 200,
    seed: UInt64 = 42,
    property: (A, B) -> Bool
) throws {
    var iter = ValueInterpreter(gen, seed: seed, maxRuns: maxIterations)
    while let value = try iter.next() {
        #expect(property(value.0, value.1), "Property failed for value: \(value)")
    }
}
