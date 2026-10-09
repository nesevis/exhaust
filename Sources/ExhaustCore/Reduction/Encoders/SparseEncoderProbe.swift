/// Describes distinct leaf edits against an immutable checkpoint so a session can reject cached probes before copying or writing its candidate buffer.
struct SparseEncoderProbe {
    let leaves: [ReductionLeaf]
    let patterns: [UInt64]

    /// Only actual movements enter acceptance handling and coupling history; unchanged leaves remain available for hashing and restoring the buffer.
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

    /// Writes patterns at checkpoint positions while preserving each entry's tag and wrappers.
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
