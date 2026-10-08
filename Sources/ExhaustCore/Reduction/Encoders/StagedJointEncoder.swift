/// Consumes the sequential two-, three-, and four-way scopes of staged joint search.
///
/// Stops after the first acceptance, because every group's addresses and domain samples belong to the original checkpoint. The scheduler unlocks each higher-order scope only after the lower stage stalls.
struct StagedJointEncoder: GraphEncoder {
    let name: EncoderName = .stagedJointSearch
    private var base = ChoiceSequence()
    private var cursor: StagedPairSearchCursor?
    private var jointCursor: NumericJointSearchCursor?
    private var probeBudget = 0
    private var emitted = 0
    /// Admission for the most recent probe. ``ProbeSession`` folds it into the probe's decoder selection.
    private(set) var admission: DecoderAdmission = .standard

    mutating func start(scope: EncoderInput) {
        base = scope.baseSequence
        emitted = 0
        cursor = nil
        jointCursor = nil
        switch scope.transformation.operation {
            case let .exchange(.stagedNumericPairs(pairs, probeBudget)):
                cursor = StagedPairSearchCursor(pairs: pairs)
                self.probeBudget = probeBudget
            case let .exchange(.numericJoint(groups, probeBudget)):
                jointCursor = NumericJointSearchCursor(groups: groups)
                self.probeBudget = probeBudget
            default:
                probeBudget = 0
        }
    }

    mutating func nextProbe(into candidate: inout ChoiceSequence, lastAccepted: Bool) -> EncoderProbe? {
        guard let probe = nextSparseProbe(lastAccepted: lastAccepted) else { return nil }
        candidate = base
        probe.write(into: &candidate)
        return probe.mutation
    }

    /// Advances the same probe stream without constructing a sequence. The session checks its hash before writing uncached edits.
    mutating func nextSparseProbe(lastAccepted: Bool) -> Probe? {
        guard lastAccepted == false, emitted < probeBudget else {
            return nil
        }
        if jointCursor != nil {
            guard let proposal = jointCursor?.next() else { return nil }
            emitted += 1
            admission = .numericJoint(proposal.leaves)
            return Probe(leaves: proposal.leaves, patterns: proposal.patterns)
        }
        guard let proposal = cursor?.next() else {
            return nil
        }
        emitted += 1
        admission = .numericPair(proposal.pair)
        return Probe(
            leaves: [proposal.pair.source, proposal.pair.sink],
            patterns: [proposal.sourceBitPattern, proposal.sinkBitPattern]
        )
    }

    /// Positions belong to one immutable checkpoint and are distinct within each two-, three-, or four-way proposal.
    struct Probe {
        let leaves: [NumericPairQuery.Leaf]
        let patterns: [UInt64]

        /// Zero stays zero under rescaling, so only actual movements enter acceptance handling and coupling history. Admission still checks every leaf in the coordinated scope.
        var mutation: EncoderProbe {
            .leafValues(leaves.indices.compactMap { index in
                let leaf = leaves[index]
                guard patterns[index] != leaf.choice.bitPattern64 else { return nil }
                return LeafChange(
                    leafNodeID: leaf.nodeID,
                    newValue: ChoiceValue(patterns[index], tag: leaf.choice.tag),
                    mayReshape: leaf.mayReshapeOnAcceptance
                )
            })
        }

        /// Updates the checkpoint hash in O(arity), without scanning or copying the complete sequence.
        func hash(baseHash: UInt64, baseSequence: ChoiceSequence) -> UInt64 {
            baseSequence.withUnsafeBufferPointer { buffer in
                var hash = baseHash
                for index in leaves.indices {
                    let position = leaves[index].position
                    let original = buffer[position]
                    hash ^= ZobristHash.contribution(at: position, original)
                    hash ^= ZobristHash.contribution(at: position, original.withBitPattern(patterns[index]))
                }
                return hash
            }
        }

        func write(into candidate: inout ChoiceSequence) {
            candidate.withUnsafeMutableBufferPointer { buffer in
                for index in leaves.indices {
                    let position = leaves[index].position
                    buffer[position] = buffer[position].withBitPattern(patterns[index])
                }
            }
        }

        /// Restores only the previous scope's entries before the reusable buffer receives another proposal.
        func restore(into candidate: inout ChoiceSequence, baseSequence: ChoiceSequence) {
            candidate.withUnsafeMutableBufferPointer { buffer in
                for leaf in leaves {
                    buffer[leaf.position] = baseSequence[leaf.position]
                }
            }
        }
    }
}
