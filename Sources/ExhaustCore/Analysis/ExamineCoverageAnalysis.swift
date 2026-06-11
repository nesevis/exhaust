/// Coverage analysis for `#examine` — walks stored VACTI trees and computes aggregate quality metrics.
///
/// Each metric is computed independently from the flat set of stored trees. No per-node identity tracking is needed: observations are bucketed by TypeTag (for deciles) or structurally (for branches and sequences).
package enum ExamineCoverageAnalysis {
    /// Computes all coverage metrics from a batch of VACTI-generated ChoiceTrees.
    package static func analyze(trees: [ChoiceTree]) -> ExamineCoverageResult {
        guard trees.isEmpty == false else {
            return .empty
        }

        var decileAccumulator = DecileAccumulator()
        var branchAccumulator = BranchAccumulator()
        var sequenceAccumulator = SequenceAccumulator()
        var characterAccumulator = CharacterAccumulator()
        var complexityScores: [Double] = []
        complexityScores.reserveCapacity(trees.count)

        for tree in trees {
            var treeComplexity = 0
            walkTree(
                tree,
                insideSequenceElements: false,
                deciles: &decileAccumulator,
                branches: &branchAccumulator,
                sequences: &sequenceAccumulator,
                characters: &characterAccumulator,
                complexity: &treeComplexity
            )
            complexityScores.append(Double(treeComplexity))
        }

        return ExamineCoverageResult(
            numericCoverage: decileAccumulator.results(),
            branchCoverage: branchAccumulator.result(),
            sequenceLengthDeciles: sequenceAccumulator.result(),
            hasSequences: sequenceAccumulator.hasObservations,
            sequenceLengthMin: sequenceAccumulator.minLength,
            sequenceLengthMax: sequenceAccumulator.maxLength,
            sequenceLengthMean: sequenceAccumulator.meanLength,
            characterCoverage: characterAccumulator.results(),
            complexityDeciles: computeComplexityDeciles(complexityScores)
        )
    }
}

// MARK: - Result Type

/// Per-type coverage and descriptive statistics for a single numeric type observed during an ``#examine`` run.
public struct NumericTypeCoverage: Sendable {
    /// The Swift type name (for example "Int", "UInt8", "Double").
    public let type: String
    /// How many of 10 equal-width histogram bins received at least one observation.
    public let decilesCovered: Int
    /// Smallest decoded value observed across all samples.
    public let min: Double
    /// Largest decoded value observed across all samples.
    public let max: Double
    /// Arithmetic mean of all decoded values observed across all samples.
    public let mean: Double
}

/// Aggregate coverage metrics computed from a batch of VACTI trees.
package struct ExamineCoverageResult: Sendable {
    /// Per-type coverage and descriptive statistics for numeric parameters.
    package let numericCoverage: [NumericTypeCoverage]
    /// Fraction of all pick branch IDs observed out of all possible branches across all pick sites.
    package let branchCoverage: Double
    /// Minimum decile coverage across all sequence-length sites.
    package let sequenceLengthDeciles: Int
    /// Whether the generator contains sequence nodes.
    package let hasSequences: Bool
    /// Smallest observed sequence length.
    package let sequenceLengthMin: Int
    /// Largest observed sequence length.
    package let sequenceLengthMax: Int
    /// Mean observed sequence length.
    package let sequenceLengthMean: Double
    /// Per-domain character variety. Each entry reports the fraction of that domain covered and its total size.
    package let characterCoverage: [(domainSize: Int, variety: Double)]
    /// Deciles covered in the normalized per-tree complexity distribution.
    package let complexityDeciles: Int

    static let empty = ExamineCoverageResult(
        numericCoverage: [],
        branchCoverage: 1.0,
        sequenceLengthDeciles: 10,
        hasSequences: false,
        sequenceLengthMin: 0,
        sequenceLengthMax: 0,
        sequenceLengthMean: 0,
        characterCoverage: [],
        complexityDeciles: 10
    )
}

// MARK: - Tree Walk

private extension ExamineCoverageAnalysis {
    static func walkTree(
        _ tree: ChoiceTree,
        insideSequenceElements: Bool,
        deciles: inout DecileAccumulator,
        branches: inout BranchAccumulator,
        sequences: inout SequenceAccumulator,
        characters: inout CharacterAccumulator,
        complexity: inout Int
    ) {
        switch tree {
            case let .choice(value, metadata):
                guard let range = metadata.validRange, range.upperBound > range.lowerBound else { break }
                let tag = value.tag
                let domainSize = range.upperBound - range.lowerBound

                switch tag {
                    case .character:
                        characters.record(bitPattern: value.bitPattern64, range: range)
                    case .depthControl, .laneControl:
                        break
                    case .double, .float, .float16:
                        let decodedValue = value.decodedDoubleValue
                        let lowerValue = ChoiceValue(range.lowerBound, tag: tag).decodedDoubleValue
                        let upperValue = ChoiceValue(range.upperBound, tag: tag).decodedDoubleValue
                        let span = upperValue - lowerValue
                        guard span > 0 else { break }
                        let normalized = (decodedValue - lowerValue) / span
                        deciles.record(tag: tag, normalized: min(max(normalized, 0), 1), decodedValue: decodedValue)
                    case .int, .int8, .int16, .int32, .int64:
                        if domainSize < 10 { break }
                        let decodedValue = Double(value.decodedSignedValue)
                        let lowerValue = Double(ChoiceValue(range.lowerBound, tag: tag).decodedSignedValue)
                        let upperValue = Double(ChoiceValue(range.upperBound, tag: tag).decodedSignedValue)
                        let span = upperValue - lowerValue
                        guard span > 0 else { break }
                        let normalized = (decodedValue - lowerValue) / span
                        deciles.record(tag: tag, normalized: min(max(normalized, 0), 1), decodedValue: decodedValue)
                    default:
                        if domainSize < 10 {
                            break
                        }
                        let decodedValue = Double(value.bitPattern64)
                        let normalized = Double(value.bitPattern64 - range.lowerBound) / Double(domainSize)
                        deciles.record(tag: tag, normalized: normalized, decodedValue: decodedValue)
                }

                if insideSequenceElements == false {
                    complexity += 1
                }

            case let .sequence(length, elements, metadata):
                if let range = metadata.validRange {
                    sequences.record(length: length, range: range)
                }
                complexity += Int(length)
                for element in elements {
                    walkTree(
                        element,
                        insideSequenceElements: true,
                        deciles: &deciles,
                        branches: &branches,
                        sequences: &sequences,
                        characters: &characters,
                        complexity: &complexity
                    )
                }

            case let .branch(branchData):
                branches.record(
                    fingerprint: branchData.fingerprint,
                    id: branchData.id,
                    branchCount: branchData.branchCount
                )
                walkTree(
                    branchData.choice,
                    insideSequenceElements: insideSequenceElements,
                    deciles: &deciles,
                    branches: &branches,
                    sequences: &sequences,
                    characters: &characters,
                    complexity: &complexity
                )

            case let .group(children, _):
                for child in children {
                    walkTree(
                        child,
                        insideSequenceElements: insideSequenceElements,
                        deciles: &deciles,
                        branches: &branches,
                        sequences: &sequences,
                        characters: &characters,
                        complexity: &complexity
                    )
                }

            case let .bind(_, inner, bound):
                walkTree(
                    inner,
                    insideSequenceElements: insideSequenceElements,
                    deciles: &deciles,
                    branches: &branches,
                    sequences: &sequences,
                    characters: &characters,
                    complexity: &complexity
                )
                walkTree(
                    bound,
                    insideSequenceElements: insideSequenceElements,
                    deciles: &deciles,
                    branches: &branches,
                    sequences: &sequences,
                    characters: &characters,
                    complexity: &complexity
                )

            case let .resize(_, choices):
                for child in choices {
                    walkTree(
                        child,
                        insideSequenceElements: insideSequenceElements,
                        deciles: &deciles,
                        branches: &branches,
                        sequences: &sequences,
                        characters: &characters,
                        complexity: &complexity
                    )
                }

            case .just, .getSize:
                break
        }
    }
}

// MARK: - Decile Accumulator

private struct DecileAccumulator {
    private var buckets: [Int: [Bool]] = [:]
    private var decodedValues: [Int: [Double]] = [:]

    mutating func record(tag: TypeTag, normalized: Double, decodedValue: Double) {
        let bucket = min(Int(normalized * 10), 9)
        let key = tag.discriminator
        if buckets[key] == nil {
            buckets[key] = [Bool](repeating: false, count: 10)
        }
        buckets[key]![bucket] = true
        decodedValues[key, default: []].append(decodedValue)
    }

    func results() -> [NumericTypeCoverage] {
        buckets.sorted(by: { $0.key < $1.key }).compactMap { discriminator, hits in
            guard let name = typeTagName(for: discriminator) else { return nil }
            let covered = hits.count(where: { $0 })
            let values = decodedValues[discriminator] ?? []
            let minValue = values.min() ?? 0
            let maxValue = values.max() ?? 0
            let meanValue = values.isEmpty ? 0 : values.reduce(0.0) { $0 + $1 / Double(values.count) }
            return NumericTypeCoverage(
                type: name,
                decilesCovered: covered,
                min: minValue,
                max: maxValue,
                mean: meanValue
            )
        }
    }

    private func typeTagName(for discriminator: Int) -> String? {
        switch discriminator {
            case 0: "UInt"
            case 1: "UInt64"
            case 2: "UInt32"
            case 3: "UInt16"
            case 4: "UInt8"
            case 5: "Int"
            case 6: "Int64"
            case 7: "Int32"
            case 8: "Int16"
            case 9: "Int8"
            case 10: "Double"
            case 11: "Float"
            case 12: "Float16"
            case 13: "Date"
            case 14: "bits"
            default: nil
        }
    }
}

// MARK: - Branch Accumulator

private struct BranchAccumulator {
    private var observedBranches: Set<UInt64> = []
    private var siteBranchCounts: [UInt64: UInt64] = [:]

    mutating func record(fingerprint: UInt64, id: UInt64, branchCount: UInt64) {
        let key = fingerprint &* 31 &+ id
        observedBranches.insert(key)
        siteBranchCounts[fingerprint] = branchCount
    }

    func result() -> Double {
        let totalBranches = siteBranchCounts.values.reduce(0 as UInt64, +)
        guard totalBranches > 0 else { return 1.0 }
        return Double(observedBranches.count) / Double(totalBranches)
    }
}

// MARK: - Sequence Accumulator

private struct SequenceAccumulator {
    private var sites: [ClosedRange<UInt64>: [UInt64]] = [:]

    mutating func record(length: UInt64, range: ClosedRange<UInt64>) {
        sites[range, default: []].append(length)
    }

    var hasObservations: Bool {
        sites.isEmpty == false
    }

    var minLength: Int {
        sites.values.flatMap(\.self).map { Int($0) }.min() ?? 0
    }

    var maxLength: Int {
        sites.values.flatMap(\.self).map { Int($0) }.max() ?? 0
    }

    var meanLength: Double {
        let allLengths = sites.values.flatMap(\.self)
        guard allLengths.isEmpty == false else { return 0 }
        return Double(allLengths.map { Int($0) }.reduce(0, +)) / Double(allLengths.count)
    }

    func result() -> Int {
        guard sites.isEmpty == false else { return 10 }
        var worstDeciles = 10
        for (range, lengths) in sites {
            let span = range.upperBound - range.lowerBound
            guard span > 0 else { continue }
            var buckets = [Bool](repeating: false, count: 10)
            for length in lengths {
                let normalized = Double(length - range.lowerBound) / Double(span)
                let bucket = min(Int(normalized * 10), 9)
                buckets[bucket] = true
            }
            let covered = buckets.count(where: { $0 })
            worstDeciles = min(worstDeciles, covered)
        }
        return worstDeciles
    }
}

// MARK: - Character Accumulator

private struct CharacterAccumulator {
    private var sites: [ClosedRange<UInt64>: Set<UInt64>] = [:]

    mutating func record(bitPattern: UInt64, range: ClosedRange<UInt64>) {
        sites[range, default: []].insert(bitPattern)
    }

    var hasObservations: Bool {
        sites.isEmpty == false
    }

    func results() -> [(domainSize: Int, variety: Double)] {
        sites.map { range, uniqueValues in
            let domainSize = range.upperBound - range.lowerBound + 1
            return (domainSize: Int(domainSize), variety: Double(uniqueValues.count) / Double(domainSize))
        }.sorted { $0.domainSize < $1.domainSize }
    }
}

// MARK: - Complexity Deciles

private func computeComplexityDeciles(_ scores: [Double]) -> Int {
    guard scores.count >= 2 else { return 10 }
    let minScore = scores.min()!
    let maxScore = scores.max()!
    let range = maxScore - minScore
    guard range > 0 else { return 10 }

    var buckets = [Bool](repeating: false, count: 10)
    for score in scores {
        let normalized = (score - minScore) / range
        let bucket = min(Int(normalized * 10), 9)
        buckets[bucket] = true
    }
    return buckets.count(where: { $0 })
}
