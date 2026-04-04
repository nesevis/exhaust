//
//  GraphKleisliFibreEncoder.swift
//  Exhaust
//

// MARK: - Graph Kleisli Fibre Encoder

/// Jointly searches upstream bind-inner values and their downstream fibres along dependency edges.
///
/// For each dependency edge in the graph, modifies the bind-inner value (upstream) via binary search, lifts the modified sequence through the generator to re-derive the bound subtree, then searches the downstream fibre for a failing assignment using exhaustive enumeration or pairwise covering.
///
/// This is the graph-based counterpart of ``KleisliComposition``. The graph provides the dependency edges with typed leaf sets directly, eliminating the edge discovery and scope computation.
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

    private struct DependencyTarget {
        let upstreamNodeID: Int
        let downstreamNodeID: Int
        let upstreamSequenceIndex: Int
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
            guard let upstreamRange = upstreamNode.positionRange else { continue }

            // Only process edges where the upstream is a chooseBits leaf (reducible value).
            guard case .chooseBits = upstreamNode.kind else { continue }

            edges.append(DependencyTarget(
                upstreamNodeID: edge.upstreamNodeID,
                downstreamNodeID: edge.downstreamNodeID,
                upstreamSequenceIndex: upstreamRange.lowerBound,
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
                // Re-materialize tree from accepted sequence.
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
            // Upstream change was productive — keep the accepted sequence.
            savedUpstreamEntry = nil
            _ = saved // Discard the saved rollback entry.
        } else if let saved = savedUpstreamEntry {
            // Rollback upstream change.
            sequence[upstreamSequenceIndex] = saved
            savedUpstreamEntry = nil
        }

        let probeValue: UInt64?
        if upstreamNeedsFirstProbe {
            upstreamNeedsFirstProbe = false
            probeValue = upstreamStepper?.start()
            if probeValue == nil { return nil }
            initializeUpstream()
            probeValue.map { _ in () } // Just to use probeValue.
            // Re-get from stepper since initializeUpstream may have reset it.
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

        // Save current entry for rollback.
        savedUpstreamEntry = sequence[upstreamSequenceIndex]

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
            // Lift rejected — rollback and try next upstream.
            if let saved = savedUpstreamEntry {
                sequence[upstreamSequenceIndex] = saved
                savedUpstreamEntry = nil
            }
            return nil
        }

        // Build downstream fibre probes from the lifted state.
        downstreamProbes = buildDownstreamProbes(liftedSequence: liftResult.sequence)
        downstreamProbeIndex = 0

        if downstreamProbeIndex < downstreamProbes.count {
            let probe = downstreamProbes[downstreamProbeIndex]
            downstreamProbeIndex += 1
            return probe
        }

        // No downstream probes — the lifted state itself is the probe.
        return liftResult.sequence
    }

    // MARK: - Downstream Fibre

    /// Builds downstream probes by enumerating or covering the fibre of value positions in the lifted sequence.
    private func buildDownstreamProbes(liftedSequence: ChoiceSequence) -> [ChoiceSequence] {
        // Collect all value positions in the downstream (bound) region.
        var valuePositions: [(index: Int, domainLower: UInt64, domainSize: UInt64, tag: TypeTag, validRange: ClosedRange<UInt64>?, isRangeExplicit: Bool)] = []

        for index in 0 ..< liftedSequence.count {
            guard let value = liftedSequence[index].value,
                  let range = value.validRange
            else { continue }
            let domainSize = range.upperBound &- range.lowerBound &+ 1
            guard domainSize > 1 else { continue }
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
    }

    private mutating func resetDownstream() {
        downstreamProbes = []
        downstreamProbeIndex = 0
    }
}
