//
//  GraphKleisliFibreEncoder.swift
//  Exhaust
//

// MARK: - Graph Kleisli Fibre Encoder

/// Jointly searches upstream bind-inner values and their downstream fibres along dependency edges.
///
/// For each dependency edge in the graph, modifies the bind-inner value (upstream) via binary search, lifts the modified sequence through the generator to re-derive the bound subtree, then searches the downstream fibre for a failing assignment using exhaustive enumeration or pairwise covering.
///
/// ## Covariant Sweep
///
/// Tracks upstream bit-pattern deltas between consecutive probes. When the delta is 1 (adjacent values in the search), convergence records from the previous downstream pass are validated at `floor - 1` and carried forward as warm starts. This dramatically reduces downstream search cost for smoothly-varying fibres. When the delta is larger than 1, the downstream cold-starts.
///
/// ## Structural Fingerprinting
///
/// Before and after each lift, computes a structural fingerprint of the sequence. If the structure changed (different fingerprint), convergence transfer is invalidated — the fibre's parameter count or shape may have changed, making cached convergence bounds stale.
///
/// - SeeAlso: ``KleisliComposition``, ``FibreCoveringEncoder``, ``GeneratorLift``
public struct GraphKleisliFibreEncoder<Output>: GraphEncoder {
    public let name: EncoderName = .graphKleisliFibre

    /// The generator, needed for lifting (re-materializing after upstream changes).
    private let gen: ReflectiveGenerator<Output>

    /// The property closure for filtering lift results.
    private let property: (Output) -> Bool

    public init(gen: ReflectiveGenerator<Output>, property: @escaping (Output) -> Bool) {
        self.gen = gen
        self.property = property
    }

    // MARK: - State

    private var sequence = ChoiceSequence()
    private var tree: ChoiceTree = .just

    /// Dependency edges extracted from the graph, ordered by topological depth.
    private var edges: [DependencyTarget] = []
    private var edgeIndex = 0

    /// Upstream binary search state for the current edge.
    private var upstreamStepper: BinarySearchStepper?
    private var upstreamNeedsFirstProbe = true
    private var upstreamSequenceIndex = 0
    private var upstreamTypeTag: TypeTag = .uint64
    private var upstreamValidRange: ClosedRange<UInt64>?
    private var upstreamIsRangeExplicit = false

    /// Downstream fibre search state.
    private var downstreamProbes: [ChoiceSequence] = []
    private var downstreamProbeIndex = 0

    /// Maximum upstream probes per dependency edge.
    private static var upstreamBudget: Int { 15 }

    /// Maximum downstream probes per lifted state.
    private static var downstreamBudget: Int { 128 }

    private var upstreamProbesUsed = 0
    private var savedUpstreamEntry: ChoiceSequenceValue?

    // MARK: - Covariant Sweep State

    /// Bit pattern of the previous upstream probe, for delta computation.
    private var previousUpstreamBitPattern: UInt64?

    /// Convergence records from the previous downstream pass (unvalidated).
    private var pendingTransferOrigins: [Int: ConvergedOrigin]?

    /// Structural fingerprint before lift, used to detect structural changes.
    private var preLiftFingerprint: UInt64 = 0

    private struct DependencyTarget {
        let upstreamNodeID: Int
        let downstreamNodeID: Int
        let upstreamSequenceIndex: Int
        let downstreamRange: ClosedRange<Int>
        let isStructurallyConstant: Bool
    }

    // MARK: - GraphEncoder

    public mutating func start(
        graph: ChoiceGraph,
        sequence: ChoiceSequence,
        tree: ChoiceTree
    ) {
        self.sequence = sequence
        self.tree = tree
        edgeIndex = 0
        edges = []
        resetUpstream()
        resetDownstream()

        // Extract dependency edges from the graph.
        for edge in graph.reductionEdges {
            let upstreamNode = graph.nodes[edge.upstreamNodeID]
            let downstreamNode = graph.nodes[edge.downstreamNodeID]
            guard let upstreamRange = upstreamNode.positionRange else { continue }
            guard let downstreamRange = downstreamNode.positionRange else { continue }

            // Only process edges where the upstream is a chooseBits leaf (reducible value).
            guard case .chooseBits = upstreamNode.kind else { continue }

            edges.append(DependencyTarget(
                upstreamNodeID: edge.upstreamNodeID,
                downstreamNodeID: edge.downstreamNodeID,
                upstreamSequenceIndex: upstreamRange.lowerBound,
                downstreamRange: downstreamRange,
                isStructurallyConstant: edge.isStructurallyConstant
            ))
        }
    }

    public mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        // Inner loop: exhaust downstream probes for current lift.
        if downstreamProbeIndex < downstreamProbes.count {
            if lastAccepted {
                // Downstream probe accepted — update base sequence and tree.
                let accepted = downstreamProbes[downstreamProbeIndex - 1]
                sequence = accepted
                if case let .success(_, freshTree, _) = Materializer.materialize(
                    gen, prefix: sequence, mode: .exact, fallbackTree: tree
                ) {
                    tree = freshTree
                }
            }

            let probe = downstreamProbes[downstreamProbeIndex]
            downstreamProbeIndex += 1
            return probe
        }

        // Harvest convergence records from exhausted downstream for transfer.
        if downstreamProbes.isEmpty == false {
            harvestDownstreamConvergence()
        }

        // Advance to next upstream probe or next edge.
        while edgeIndex < edges.count {
            if let probe = advanceUpstream(lastAccepted: lastAccepted) {
                return probe
            }
            edgeIndex += 1
            resetUpstream()
            resetDownstream()
            if edgeIndex < edges.count {
                initializeUpstream()
            }
        }

        return nil
    }

    // MARK: - Upstream

    private mutating func initializeUpstream() {
        let edge = edges[edgeIndex]
        upstreamSequenceIndex = edge.upstreamSequenceIndex
        upstreamProbesUsed = 0
        upstreamNeedsFirstProbe = true
        previousUpstreamBitPattern = nil
        pendingTransferOrigins = nil

        guard let value = sequence[upstreamSequenceIndex].value else { return }
        upstreamTypeTag = value.choice.tag
        upstreamValidRange = value.validRange
        upstreamIsRangeExplicit = value.isRangeExplicit

        let currentBitPattern = value.choice.bitPattern64
        let targetBitPattern = value.choice.reductionTarget(
            in: value.isRangeExplicit ? value.validRange : nil
        )

        guard currentBitPattern != targetBitPattern, currentBitPattern > targetBitPattern else {
            upstreamStepper = nil
            return
        }

        upstreamStepper = BinarySearchStepper(lo: targetBitPattern, hi: currentBitPattern)
    }

    private mutating func advanceUpstream(lastAccepted: Bool) -> ChoiceSequence? {
        guard upstreamProbesUsed < Self.upstreamBudget else { return nil }

        // Process feedback from previous downstream pass.
        if lastAccepted, let saved = savedUpstreamEntry {
            savedUpstreamEntry = nil
            _ = saved
        } else if let saved = savedUpstreamEntry {
            sequence[upstreamSequenceIndex] = saved
            savedUpstreamEntry = nil
        }

        let probeValue: UInt64?
        if upstreamNeedsFirstProbe {
            upstreamNeedsFirstProbe = false
            initializeUpstream()
            guard var stepper = upstreamStepper else { return nil }
            let value = stepper.start()
            upstreamStepper = stepper
            guard let bitPattern = value else { return nil }
            return tryUpstreamValue(bitPattern)
        } else {
            guard var stepper = upstreamStepper else { return nil }
            let value = stepper.advance(lastAccepted: lastAccepted)
            upstreamStepper = stepper
            guard let bitPattern = value else { return nil }
            return tryUpstreamValue(bitPattern)
        }
    }

    private mutating func tryUpstreamValue(_ bitPattern: UInt64) -> ChoiceSequence? {
        upstreamProbesUsed += 1

        // Compute upstream delta for covariant sweep.
        let upstreamDelta: UInt64?
        if let previousBitPattern = previousUpstreamBitPattern {
            upstreamDelta = bitPattern > previousBitPattern
                ? bitPattern - previousBitPattern
                : previousBitPattern - bitPattern
        } else {
            upstreamDelta = nil
        }
        previousUpstreamBitPattern = bitPattern

        // Save current entry for rollback.
        savedUpstreamEntry = sequence[upstreamSequenceIndex]

        // Compute structural fingerprint before lift.
        preLiftFingerprint = structuralFingerprint(of: sequence)

        // Set the upstream value.
        sequence[upstreamSequenceIndex] = .value(.init(
            choice: ChoiceValue(
                upstreamTypeTag.makeConvertible(bitPattern64: bitPattern),
                tag: upstreamTypeTag
            ),
            validRange: upstreamValidRange,
            isRangeExplicit: upstreamIsRangeExplicit
        ))

        // Lift: materialize with the modified upstream to get new bound content.
        let lift = GeneratorLift(
            gen: gen,
            mode: .guided(fallbackTree: tree)
        )
        guard let liftResult = lift.lift(sequence) else {
            if let saved = savedUpstreamEntry {
                sequence[upstreamSequenceIndex] = saved
                savedUpstreamEntry = nil
            }
            return nil
        }

        // Check structural fingerprint after lift.
        let postLiftFingerprint = structuralFingerprint(of: liftResult.sequence)
        let structureChanged = preLiftFingerprint != postLiftFingerprint

        // Covariant convergence transfer: when upstream delta is 1 and structure
        // is unchanged, carry forward the previous downstream's convergence records.
        let warmStartOrigins: [Int: ConvergedOrigin]?
        if upstreamDelta == 1, structureChanged == false, let pending = pendingTransferOrigins {
            warmStartOrigins = pending
        } else {
            warmStartOrigins = nil
        }

        // Build downstream fibre probes scoped to the bound region.
        let edge = edges[edgeIndex]
        let downstreamLower = min(edge.downstreamRange.lowerBound, max(0, liftResult.sequence.count - 1))
        let downstreamUpper = min(edge.downstreamRange.upperBound, max(0, liftResult.sequence.count - 1))
        let scopedRange = downstreamLower <= downstreamUpper ? downstreamLower ... downstreamUpper : 0 ... 0
        downstreamProbes = buildDownstreamProbes(
            liftedSequence: liftResult.sequence,
            downstreamRange: scopedRange,
            warmStartOrigins: warmStartOrigins
        )
        downstreamProbeIndex = 0

        if downstreamProbeIndex < downstreamProbes.count {
            let probe = downstreamProbes[downstreamProbeIndex]
            downstreamProbeIndex += 1
            return probe
        }

        // No downstream probes — the lifted state itself is the probe.
        return liftResult.sequence
    }

    // MARK: - Convergence Transfer

    /// Harvests convergence records from exhausted downstream probes for transfer to the next iteration.
    private mutating func harvestDownstreamConvergence() {
        // The downstream probes are enumerated value assignments. The last probe's
        // position values represent the convergence frontier. Extract value positions
        // and their bit patterns as convergence records.
        guard let lastProbe = downstreamProbes.last else {
            pendingTransferOrigins = nil
            return
        }

        var records: [Int: ConvergedOrigin] = [:]
        for index in 0 ..< lastProbe.count {
            guard let value = lastProbe[index].value,
                  let range = value.validRange
            else { continue }
            let domainSize = range.upperBound &- range.lowerBound &+ 1
            guard domainSize > 1 else { continue }
            records[index] = ConvergedOrigin(
                bound: value.choice.bitPattern64,
                signal: .monotoneConvergence,
                configuration: .binarySearchSemanticSimplest,
                cycle: 0
            )
        }
        pendingTransferOrigins = records.isEmpty ? nil : records
    }

    // MARK: - Downstream Fibre

    /// Builds downstream probes by enumerating or covering the fibre of value positions in the bound region.
    ///
    /// Only positions within `downstreamRange` are considered — the upstream (bind-inner) value and positions outside the bound subtree are excluded. When `warmStartOrigins` is provided (covariant transfer), positions whose current value matches the warm-start bound are skipped.
    private func buildDownstreamProbes(
        liftedSequence: ChoiceSequence,
        downstreamRange: ClosedRange<Int>,
        warmStartOrigins: [Int: ConvergedOrigin]?
    ) -> [ChoiceSequence] {
        var valuePositions: [(index: Int, domainLower: UInt64, domainSize: UInt64, tag: TypeTag, validRange: ClosedRange<UInt64>?, isRangeExplicit: Bool)] = []

        for index in downstreamRange where index < liftedSequence.count {
            guard let value = liftedSequence[index].value,
                  let range = value.validRange
            else { continue }
            let domainSize = range.upperBound &- range.lowerBound &+ 1
            guard domainSize > 1 else { continue }

            // Skip positions at their warm-start convergence floor.
            if let origins = warmStartOrigins,
               let origin = origins[index],
               value.choice.bitPattern64 == origin.bound
            {
                continue
            }

            valuePositions.append((
                index: index,
                domainLower: range.lowerBound,
                domainSize: domainSize,
                tag: value.choice.tag,
                validRange: value.validRange,
                isRangeExplicit: value.isRangeExplicit
            ))
        }

        guard valuePositions.isEmpty == false else { return [] }

        // Compute total fibre space.
        var totalSpace: UInt64 = 1
        for position in valuePositions {
            let (product, overflow) = totalSpace.multipliedReportingOverflow(by: position.domainSize)
            if overflow {
                totalSpace = UInt64.max
                break
            }
            totalSpace = product
        }

        // When any single domain exceeds the covering threshold, the pairwise
        // covering array becomes prohibitively expensive. Fall back to a single
        // all-targets probe (batch-zero the downstream fibre).
        let maxDomainSize = valuePositions.map(\.domainSize).max() ?? 0
        let coveringDomainThreshold: UInt64 = 16
        if maxDomainSize > coveringDomainThreshold, totalSpace > 128 {
            var candidate = liftedSequence
            for position in valuePositions {
                let targetBitPattern = position.domainLower
                candidate[position.index] = .value(.init(
                    choice: ChoiceValue(
                        position.tag.makeConvertible(bitPattern64: targetBitPattern),
                        tag: position.tag
                    ),
                    validRange: position.validRange,
                    isRangeExplicit: position.isRangeExplicit
                ))
            }
            return [candidate]
        }

        var probes: [ChoiceSequence] = []
        let budget = min(Int(min(totalSpace, UInt64(Self.downstreamBudget))), Self.downstreamBudget)

        if totalSpace <= 128 {
            // Exhaustive: enumerate all assignments via mixed-radix counting.
            let count = Int(totalSpace)
            for rowIndex in 0 ..< count {
                var candidate = liftedSequence
                var remaining = rowIndex
                for position in valuePositions.reversed() {
                    let valueIndex = UInt64(remaining % Int(position.domainSize))
                    remaining /= Int(position.domainSize)
                    let bitPattern = position.domainLower + valueIndex
                    candidate[position.index] = .value(.init(
                        choice: ChoiceValue(
                            position.tag.makeConvertible(bitPattern64: bitPattern),
                            tag: position.tag
                        ),
                        validRange: position.validRange,
                        isRangeExplicit: position.isRangeExplicit
                    ))
                }
                probes.append(candidate)
                if probes.count >= budget { break }
            }
        } else {
            // Pairwise covering via pull-based generator.
            let domainSizes = valuePositions.map(\.domainSize)
            guard domainSizes.count >= 2 else { return [] }
            var generator = PullBasedCoveringArrayGenerator(domainSizes: domainSizes, strength: 2)

            var pullCount = 0
            while pullCount < budget, let row = generator.next() {
                var candidate = liftedSequence
                for (offset, position) in valuePositions.enumerated() {
                    guard offset < row.values.count else { break }
                    let bitPattern = position.domainLower + row.values[offset]
                    candidate[position.index] = .value(.init(
                        choice: ChoiceValue(
                            position.tag.makeConvertible(bitPattern64: bitPattern),
                            tag: position.tag
                        ),
                        validRange: position.validRange,
                        isRangeExplicit: position.isRangeExplicit
                    ))
                }
                probes.append(candidate)
                pullCount += 1
            }
            generator.deallocate()
        }

        return probes
    }

    // MARK: - Reset Helpers

    private mutating func resetUpstream() {
        upstreamStepper = nil
        upstreamNeedsFirstProbe = true
        upstreamProbesUsed = 0
        savedUpstreamEntry = nil
        previousUpstreamBitPattern = nil
        pendingTransferOrigins = nil
    }

    private mutating func resetDownstream() {
        downstreamProbes = []
        downstreamProbeIndex = 0
    }

    // MARK: - Structural Fingerprint

    /// Computes a lightweight structural fingerprint from the sequence's marker entries.
    ///
    /// Only considers structural entries (bind, group, sequence markers) — value entries are ignored. A change in fingerprint indicates the fibre's structure changed, invalidating convergence transfer.
    private func structuralFingerprint(of sequence: ChoiceSequence) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for index in 0 ..< sequence.count {
            let entry = sequence[index]
            let marker: UInt64 = switch entry {
            case .bind: 1
            case .group: 2
            case .sequence: 3
            default: 0
            }
            if marker != 0 {
                hash = (hash ^ UInt64(index)) &* 1_099_511_628_211
                hash = (hash ^ marker) &* 6_364_136_223_846_793_005
            }
        }
        return hash
    }
}
