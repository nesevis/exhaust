//
//  ProductSpaceEncoder.swift
//  Exhaust
//
//  Created by Chris Kolbu on 14/3/2026.
//

/// Precomputes midpoint values between a current value and a target for product-space enumeration.
///
/// Unlike ``BinarySearchStepper`` (which is feedback-driven), this computes all midpoints upfront so the product space can be enumerated as a batch.
struct BinarySearchLadder {
    /// Midpoint values in descending order: current first, target last.
    let values: [UInt64]

    /// Computes a ladder of halving midpoints from `current` down to `target`.
    ///
    /// - Parameters:
    ///   - current: The starting value (largest).
    ///   - target: The goal value (smallest).
    ///   - maxSteps: Maximum number of halving steps before appending the target.
    /// - Returns: A ladder with deduplicated values in descending order.
    static func compute(
        current: UInt64,
        target: UInt64,
        maxSteps: Int = 6
    ) -> BinarySearchLadder {
        guard current > target else {
            return BinarySearchLadder(values: [current])
        }

        var result = [current]
        result.reserveCapacity(maxSteps + 2)
        var value = current
        for _ in 0 ..< maxSteps {
            let midpoint = target + (value - target) / 2
            guard midpoint != value else { break }
            value = midpoint
            result.append(value)
        }
        if result.last != target {
            result.append(target)
        }
        return BinarySearchLadder(values: result)
    }
}

// MARK: - ProductSpaceBatchEncoder

/// Enumerates the joint product space of all bind-inner values for k <= 3 binds.
///
/// Computes per-axis ``BinarySearchLadder`` midpoints and builds their Cartesian product (or dependent product for nested binds), sorted shortlex. The scheduler's ``ReductionState/runBatch(_:decoder:targets:structureChanged:budget:)`` evaluates candidates in order and accepts the first one that preserves property failure.
struct ProductSpaceBatchEncoder: BatchEncoder {
    let name: EncoderName = .productSpaceBatch
    let phase = ReductionPhase.valueMinimization

    /// Set by the caller before invocation.
    var bindIndex: BindSpanIndex?

    /// Set by the caller before invocation. Used to determine enumeration order for dependent axes.
    var dag: ChoiceDependencyGraph?

    /// Holds pre-computed downstream domains for dependent axes.
    ///
    /// Outer key: downstream axis region index. Inner key: upstream bit pattern value. Value: downstream valid range for that upstream value. When set, dependent axes use per-upstream-value ladders instead of fixed Cartesian product.
    var dependentDomains: [Int: [UInt64: ClosedRange<UInt64>]]?

    func estimatedCost(sequence _: ChoiceSequence, bindIndex: BindSpanIndex?) -> Int? {
        guard let bindIndex, bindIndex.regions.isEmpty == false else { return nil }
        let axisCount = bindIndex.regions.count
        guard axisCount <= 3 else { return nil }
        // Worst case: (maxSteps + 2)^k, capped at 512.
        let ladderSize = 8 // maxSteps(6) + 2
        var product = 1
        for _ in 0 ..< axisCount {
            product *= ladderSize
            if product > 512 {
                return 512
            }
        }
        return product > 0 ? product : nil
    }

    func encode(
        sequence: ChoiceSequence,
        targets _: TargetSet
    ) -> any Sequence<ChoiceSequence> {
        guard let bindIndex else { return [] as [ChoiceSequence] }

        // Extract axes: bind-inner values that are not yet at their reduction target.
        let axes = extractAxes(from: sequence, bindIndex: bindIndex)
        guard axes.isEmpty == false else { return [] as [ChoiceSequence] }

        // Compute per-axis ladders (used for independent axes and as fallback).
        let ladders = axes.map { axis in
            BinarySearchLadder.compute(current: axis.currentBitPattern, target: axis.targetBitPattern)
        }

        // Determine enumeration order and dependency mapping from DAG topology.
        let enumerationOrder: [Int]
        var downstreamToUpstreamTuplePosition = [Int: Int]()
        if let dag {
            let topology = dag.bindInnerTopology()
            var regionToAxis = [Int: Int]()
            for (axisIndex, axis) in axes.enumerated() {
                regionToAxis[axis.regionIndex] = axisIndex
            }
            enumerationOrder = topology.compactMap { entry in
                regionToAxis[entry.regionIndex]
            }

            // Build downstream → upstream tuple position mapping for dependent axes.
            var regionToTuplePosition = [Int: Int]()
            for (tuplePosition, axisIndex) in enumerationOrder.enumerated() {
                regionToTuplePosition[axes[axisIndex].regionIndex] = tuplePosition
            }
            for entry in topology where entry.dependsOn.isEmpty == false {
                guard let upstreamTuplePosition = regionToTuplePosition[entry.regionIndex] else {
                    continue
                }
                for dependentNodeIndex in entry.dependsOn {
                    if case let .structural(.bindInner(regionIndex: downstreamRegion)) = dag.nodes[dependentNodeIndex].kind {
                        downstreamToUpstreamTuplePosition[downstreamRegion] = upstreamTuplePosition
                    }
                }
            }
        } else {
            enumerationOrder = Array(axes.indices)
        }

        // Build product: Cartesian for independent axes, dependent for axes with upstream dependencies.
        var tuples = [[UInt64]]()
        tuples.append([])
        for axisIndex in enumerationOrder {
            let axis = axes[axisIndex]
            let hasDependentDomain = dependentDomains?[axis.regionIndex] != nil
            let upstreamTuplePosition = downstreamToUpstreamTuplePosition[axis.regionIndex]

            if hasDependentDomain, let upstreamPosition = upstreamTuplePosition,
               let domains = dependentDomains?[axis.regionIndex]
            {
                // Dependent axis: per-upstream-value ladder.
                var expanded = [[UInt64]]()
                for existing in tuples {
                    let upstreamValue = existing[upstreamPosition]
                    let ladder: BinarySearchLadder
                    if let domain = domains[upstreamValue] {
                        // Compute ladder within the discovered domain.
                        let effectiveCurrent = min(domain.upperBound, axis.currentBitPattern)
                        let effectiveTarget = max(domain.lowerBound, axis.targetBitPattern)
                        if effectiveCurrent >= effectiveTarget {
                            ladder = BinarySearchLadder.compute(
                                current: effectiveCurrent, target: effectiveTarget
                            )
                        } else {
                            // Domain collapsed (target above current in new range). Use target only.
                            ladder = BinarySearchLadder(values: [effectiveTarget])
                        }
                    } else {
                        // Upstream value has no discovered domain (downstream axis may not exist for this upstream value). Skip this combination.
                        continue
                    }
                    for value in ladder.values {
                        var extended = existing
                        extended.append(value)
                        expanded.append(extended)
                    }
                }
                tuples = expanded
            } else {
                // Independent axis: fixed ladder (Cartesian product).
                let ladder = ladders[axisIndex]
                var expanded = [[UInt64]]()
                expanded.reserveCapacity(tuples.count * ladder.values.count)
                for existing in tuples {
                    for value in ladder.values {
                        var extended = existing
                        extended.append(value)
                        expanded.append(extended)
                    }
                }
                tuples = expanded
            }
        }

        // Build candidate sequences and sort shortlex.
        var candidates = [ChoiceSequence]()
        candidates.reserveCapacity(tuples.count)

        let tuplePositionToAxis = enumerationOrder

        for tuple in tuples {
            // Skip the identity tuple (all values unchanged).
            var isIdentity = true
            for (position, value) in tuple.enumerated() {
                let axisIndex = tuplePositionToAxis[position]
                if value != axes[axisIndex].currentBitPattern {
                    isIdentity = false
                    break
                }
            }
            if isIdentity { continue }

            var candidate = sequence
            for (position, value) in tuple.enumerated() {
                let axisIndex = tuplePositionToAxis[position]
                let axis = axes[axisIndex]
                candidate[axis.seqIdx] = .value(.init(
                    choice: ChoiceValue(axis.choiceTag.makeConvertible(bitPattern64: value), tag: axis.choiceTag),
                    validRange: axis.validRange,
                    isRangeExplicit: axis.isRangeExplicit
                ))
            }
            candidates.append(candidate)
        }

        // Sort shortlex: shorter first, then lexicographic.
        candidates.sort { $0.shortLexPrecedes($1) }
        return candidates
    }
}

// MARK: - ProductSpaceAdaptiveEncoder

/// Delta-debug coordinate halving for k > 3 bind-inner values.
///
/// Halves all active coordinates simultaneously, then uses delta-debugging to find the maximal accepted subset on rejection.
struct ProductSpaceAdaptiveEncoder: AdaptiveEncoder {
    let name: EncoderName = .productSpaceAdaptive
    let phase = ReductionPhase.valueMinimization

    /// Set by the caller before invocation.
    var bindIndex: BindSpanIndex?

    func estimatedCost(sequence _: ChoiceSequence, bindIndex: BindSpanIndex?) -> Int? {
        guard let bindIndex, bindIndex.regions.count > 3 else { return nil }
        let count = bindIndex.regions.count
        // O(k * log(range) * log(k)) — conservative estimate.
        let logK = count.bitWidth - count.leadingZeroBitCount
        return count * 64 * max(1, logK)
    }

    // MARK: - State

    private struct CoordinateState {
        let seqIdx: Int
        let validRange: ClosedRange<UInt64>?
        let isRangeExplicit: Bool
        let choiceTag: TypeTag
        var lo: UInt64 // target
        var hi: UInt64 // current
    }

    private enum SearchPhase {
        case halveAll
        case deltaDebug(partitions: [[Int]], partitionIndex: Int)
        case converged
    }

    private var coordinates: [CoordinateState] = []
    private var searchPhase: SearchPhase = .converged
    private var sequence = ChoiceSequence()
    private var savedEntries: [Int: ChoiceSequenceValue] = [:]

    // MARK: - AdaptiveEncoder

    mutating func start(sequence: ChoiceSequence, targets _: TargetSet, convergedOrigins _: [Int: ConvergedOrigin]?) {
        self.sequence = sequence
        coordinates = []
        savedEntries = [:]
        searchPhase = .converged

        guard let bindIndex else { return }

        let axes = extractAxes(from: sequence, bindIndex: bindIndex)
        guard axes.isEmpty == false else { return }

        coordinates = axes.map { axis in
            CoordinateState(
                seqIdx: axis.seqIdx,
                validRange: axis.validRange,
                isRangeExplicit: axis.isRangeExplicit,
                choiceTag: axis.choiceTag,
                lo: axis.targetBitPattern,
                hi: axis.currentBitPattern
            )
        }
        searchPhase = .halveAll
    }

    mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        // Restore saved entries on rejection.
        if lastAccepted {
            // Acceptance changes sequence structure — indices are stale.
            return nil
        }

        restoreSavedEntries()

        switch searchPhase {
        case .halveAll:
            return probeHalveAll()

        case let .deltaDebug(partitions, partitionIndex):
            return probeDeltaDebug(
                partitions: partitions,
                partitionIndex: partitionIndex
            )

        case .converged:
            return nil
        }
    }

    // MARK: - Probe Phases

    private mutating func probeHalveAll() -> ChoiceSequence? {
        // Halve all coordinates toward their targets.
        var anyChanged = false
        savedEntries.removeAll(keepingCapacity: true)

        for index in coordinates.indices {
            let coord = coordinates[index]
            guard coord.lo < coord.hi else { continue }
            let midpoint = coord.lo + (coord.hi - coord.lo) / 2
            if midpoint != coord.hi {
                anyChanged = true
                savedEntries[index] = sequence[coord.seqIdx]
                sequence[coord.seqIdx] = .value(.init(
                    choice: ChoiceValue(coord.choiceTag.makeConvertible(bitPattern64: midpoint), tag: coord.choiceTag),
                    validRange: coord.validRange,
                    isRangeExplicit: coord.isRangeExplicit
                ))
            }
        }

        guard anyChanged else {
            searchPhase = .converged
            return nil
        }

        // On rejection, enter delta-debug phase.
        let activeIndices = savedEntries.keys.sorted()
        if activeIndices.count <= 1 {
            // Single coordinate — no point in delta debugging.
            searchPhase = .converged
        } else {
            let mid = activeIndices.count / 2
            let firstHalf = Array(activeIndices[..<mid])
            let secondHalf = Array(activeIndices[mid...])
            searchPhase = .deltaDebug(partitions: [firstHalf, secondHalf], partitionIndex: 0)
        }
        return sequence
    }

    private mutating func probeDeltaDebug(
        partitions: [[Int]],
        partitionIndex: Int
    ) -> ChoiceSequence? {
        guard partitionIndex < partitions.count else {
            // All partitions tried — try subdividing if possible.
            let allIndices = partitions.flatMap(\.self)
            if allIndices.count <= 2 {
                searchPhase = .converged
                return nil
            }
            // Subdivide: split each partition further.
            var newPartitions = [[Int]]()
            for partition in partitions {
                if partition.count <= 1 {
                    newPartitions.append(partition)
                } else {
                    let mid = partition.count / 2
                    newPartitions.append(Array(partition[..<mid]))
                    newPartitions.append(Array(partition[mid...]))
                }
            }
            // If subdivision didn't produce more partitions, converge.
            if newPartitions.count == partitions.count {
                searchPhase = .converged
                return nil
            }
            searchPhase = .deltaDebug(partitions: newPartitions, partitionIndex: 0)
            return nextProbe(lastAccepted: false)
        }

        let partition = partitions[partitionIndex]
        savedEntries.removeAll(keepingCapacity: true)

        // Try halving only the coordinates in this partition.
        var anyChanged = false
        for coordIndex in partition {
            let coord = coordinates[coordIndex]
            guard coord.lo < coord.hi else { continue }
            let midpoint = coord.lo + (coord.hi - coord.lo) / 2
            if midpoint != coord.hi {
                anyChanged = true
                savedEntries[coordIndex] = sequence[coord.seqIdx]
                sequence[coord.seqIdx] = .value(.init(
                    choice: ChoiceValue(coord.choiceTag.makeConvertible(bitPattern64: midpoint), tag: coord.choiceTag),
                    validRange: coord.validRange,
                    isRangeExplicit: coord.isRangeExplicit
                ))
            }
        }

        guard anyChanged else {
            // This partition has no reducible coordinates, try next.
            searchPhase = .deltaDebug(partitions: partitions, partitionIndex: partitionIndex + 1)
            return nextProbe(lastAccepted: false)
        }

        searchPhase = .deltaDebug(partitions: partitions, partitionIndex: partitionIndex + 1)
        return sequence
    }

    // MARK: - Helpers

    private mutating func restoreSavedEntries() {
        for (coordIndex, saved) in savedEntries {
            sequence[coordinates[coordIndex].seqIdx] = saved
        }
        savedEntries.removeAll(keepingCapacity: true)
    }
}

// MARK: - Shared Axis Extraction

/// State for a single bind-inner axis eligible for product-space search.
struct AxisState {
    let regionIndex: Int
    let seqIdx: Int
    let validRange: ClosedRange<UInt64>?
    let isRangeExplicit: Bool
    let choiceTag: TypeTag
    let currentBitPattern: UInt64
    let targetBitPattern: UInt64
}

/// Extracts bind-inner axes that are not yet at their reduction target.
///
/// Shared between ``ProductSpaceBatchEncoder``, ``ProductSpaceAdaptiveEncoder``, and the dependent domain computation in ``ReductionState``.
func extractAxes(
    from sequence: ChoiceSequence,
    bindIndex: BindSpanIndex
) -> [AxisState] {
    var axes = [AxisState]()
    for (regionIndex, region) in bindIndex.regions.enumerated() {
        for index in region.innerRange where index < sequence.count {
            guard let value = sequence[index].value else { continue }
            let currentBitPattern = value.choice.bitPattern64
            let isWithinRecordedRange = value.isRangeExplicit && value.choice.fits(in: value.validRange)
            let targetBitPattern: UInt64 = if isWithinRecordedRange {
                value.choice.reductionTarget(in: value.validRange)
            } else {
                value.choice.semanticSimplest.bitPattern64
            }
            guard currentBitPattern != targetBitPattern, currentBitPattern > targetBitPattern else {
                continue
            }
            axes.append(AxisState(
                regionIndex: regionIndex,
                seqIdx: index,
                validRange: value.validRange,
                isRangeExplicit: value.isRangeExplicit,
                choiceTag: value.choice.tag,
                currentBitPattern: currentBitPattern,
                targetBitPattern: targetBitPattern
            ))
        }
    }
    return axes
}

// MARK: - PrecomputedBatchEncoder

/// Wraps a pre-built array of candidate sequences as a ``BatchEncoder``.
///
/// Used by Tier 2 salted retries to iterate candidates in largest-fibre-first order instead of the encoder's default shortlex ordering.
struct PrecomputedBatchEncoder: BatchEncoder {
    let name: EncoderName
    let phase: ReductionPhase
    let candidates: [ChoiceSequence]

    func estimatedCost(sequence _: ChoiceSequence, bindIndex _: BindSpanIndex?) -> Int? {
        candidates.isEmpty ? nil : candidates.count
    }

    func encode(
        sequence _: ChoiceSequence,
        targets _: TargetSet
    ) -> any Sequence<ChoiceSequence> {
        candidates
    }
}

// MARK: - Largest-Fibre Sorting

/// Sorts candidates by the sum of bind-inner bit patterns descending (largest fibre first).
///
/// Larger inner values have wider downstream domains, giving PRNG more room to find a failure during salted materialization.
func sortByLargestFibreFirst(
    _ candidates: [ChoiceSequence],
    bindIndex: BindSpanIndex,
    cap: Int = 5
) -> [ChoiceSequence] {
    let sorted = candidates.sorted { lhs, rhs in
        bindInnerSum(of: lhs, bindIndex: bindIndex) > bindInnerSum(of: rhs, bindIndex: bindIndex)
    }
    return Array(sorted.prefix(cap))
}

/// Computes the sum of bind-inner bit patterns in a candidate sequence.
private func bindInnerSum(
    of candidate: ChoiceSequence,
    bindIndex: BindSpanIndex
) -> UInt64 {
    var total: UInt64 = 0
    for region in bindIndex.regions {
        for index in region.innerRange where index < candidate.count {
            if let value = candidate[index].value {
                total = total &+ value.choice.bitPattern64
            }
        }
    }
    return total
}
