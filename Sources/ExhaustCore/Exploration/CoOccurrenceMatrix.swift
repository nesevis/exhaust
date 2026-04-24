import Foundation

/// Symmetric co-occurrence matrix recording how many samples matched each pair of directions.
///
/// The diagonal contains per-direction totals. Off-diagonal cells count samples that matched both directions. A separate counter tracks samples that matched no declared direction.
public struct CoOccurrenceMatrix: Sendable {
    /// The number of directions (matrix dimension).
    public let directionCount: Int

    /// Flat row-major storage. Element (i, j) is at index `i * directionCount + j`.
    public private(set) var cells: [Int]

    /// Samples that satisfied no declared direction.
    public var unmatchedCount: Int

    /// Creates a zero-filled matrix for the given number of directions.
    public init(directionCount: Int) {
        self.directionCount = directionCount
        self.cells = Array(repeating: 0, count: directionCount * directionCount)
        self.unmatchedCount = 0
    }

    /// Returns the count for the pair (i, j).
    public func count(direction indexA: Int, direction indexB: Int) -> Int {
        cells[indexA * directionCount + indexB]
    }

    /// Increments the count for a pair of directions. Maintains symmetry by updating both (i, j) and (j, i).
    public mutating func recordHit(direction indexA: Int, direction indexB: Int) {
        cells[indexA * directionCount + indexB] += 1
        if indexA != indexB {
            cells[indexB * directionCount + indexA] += 1
        }
    }

    /// Records a sample's full direction membership set. Updates diagonal entries and all pairwise off-diagonal cells.
    public mutating func recordSample(matchingDirections: [Int]) {
        if matchingDirections.isEmpty {
            unmatchedCount += 1
            return
        }
        for index in matchingDirections {
            cells[index * directionCount + index] += 1
        }
        for i in 0 ..< matchingDirections.count {
            for j in (i + 1) ..< matchingDirections.count {
                recordHit(direction: matchingDirections[i], direction: matchingDirections[j])
            }
        }
    }

    /// Total samples recorded in the matrix (sum of diagonal entries plus unmatched).
    public var totalSampleCount: Int {
        var diagonalSum = 0
        for index in 0 ..< directionCount {
            diagonalSum += cells[index * directionCount + index]
        }
        return diagonalSum + unmatchedCount
    }

    // MARK: - Diagnostics

    /// Computes pairwise mutual information normalized by the entropy of direction A. Returns pairs where `MI(A, B) / H(A) >= threshold`, sorted by descending normalized MI.
    public func entangledPairs(threshold: Double = 0.5) -> [(directionA: Int, directionB: Int, normalizedMutualInformation: Double)] {
        let totalSamples = totalSampleCount
        guard totalSamples > 0 else { return [] }

        var results: [(directionA: Int, directionB: Int, normalizedMutualInformation: Double)] = []
        let total = Double(totalSamples)

        for indexA in 0 ..< directionCount {
            let countA = cells[indexA * directionCount + indexA]
            guard countA > 0 else { continue }
            let probabilityA = Double(countA) / total
            let entropyA = -probabilityA * log2(probabilityA) - (1.0 - probabilityA) * log2(1.0 - probabilityA)
            guard entropyA > 1e-10 else { continue }

            for indexB in (indexA + 1) ..< directionCount {
                let countB = cells[indexB * directionCount + indexB]
                guard countB > 0 else { continue }
                let countAB = cells[indexA * directionCount + indexB]
                let mutualInformation = computeMutualInformation(
                    countA: countA,
                    countB: countB,
                    countAB: countAB,
                    total: totalSamples
                )
                let normalized = mutualInformation / entropyA
                if normalized >= threshold {
                    results.append((indexA, indexB, normalized))
                }
            }
        }

        return results.sorted { $0.normalizedMutualInformation > $1.normalizedMutualInformation }
    }

    /// Returns direction pairs with zero co-occurrence and their rule-of-three upper bounds on joint reach probability.
    public func infeasibleConjunctionEvidence(totalWarmupSamples: Int) -> [(directionA: Int, directionB: Int, ruleOfThreeUpperBound: Double)] {
        guard totalWarmupSamples > 0 else { return [] }
        var results: [(directionA: Int, directionB: Int, ruleOfThreeUpperBound: Double)] = []

        for indexA in 0 ..< directionCount {
            for indexB in (indexA + 1) ..< directionCount {
                if cells[indexA * directionCount + indexB] == 0 {
                    results.append((indexA, indexB, 3.0 / Double(totalWarmupSamples)))
                }
            }
        }

        return results
    }
}

// MARK: - Mutual Information

extension CoOccurrenceMatrix {
    private func computeMutualInformation(
        countA: Int,
        countB: Int,
        countAB: Int,
        total: Int
    ) -> Double {
        let totalDouble = Double(total)
        let probabilityA = Double(countA) / totalDouble
        let probabilityB = Double(countB) / totalDouble
        let probabilityAB = Double(countAB) / totalDouble
        let probabilityNotA = 1.0 - probabilityA
        let probabilityNotB = 1.0 - probabilityB

        var mutualInformation = 0.0

        if countAB > 0 {
            mutualInformation += probabilityAB * log2(probabilityAB / (probabilityA * probabilityB))
        }
        let countANotB = countA - countAB
        if countANotB > 0 {
            let probabilityANotB = Double(countANotB) / totalDouble
            mutualInformation += probabilityANotB * log2(probabilityANotB / (probabilityA * probabilityNotB))
        }
        let countNotAB = countB - countAB
        if countNotAB > 0 {
            let probabilityNotAB = Double(countNotAB) / totalDouble
            mutualInformation += probabilityNotAB * log2(probabilityNotAB / (probabilityNotA * probabilityB))
        }
        let countNotANotB = total - countA - countB + countAB
        if countNotANotB > 0 {
            let probabilityNotANotB = Double(countNotANotB) / totalDouble
            mutualInformation += probabilityNotANotB * log2(probabilityNotANotB / (probabilityNotA * probabilityNotB))
        }

        return max(0, mutualInformation)
    }
}
