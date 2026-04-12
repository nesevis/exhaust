//
//  NoveltyTracker.swift
//  Exhaust
//

/// Two-tier novelty scoring for exploration.
///
/// - Tier 1: branch-path fingerprints (structural novelty) — the vector of `(fingerprint, branchID)` pairs at each pick site, hashed to a `UInt64`.
/// - Tier 2: full `ChoiceSequence` deduplication (value-level novelty).
public struct NoveltyTracker {
    /// Tier 1: branch-path fingerprint hashes (structural novelty).
    private var seenBranchPaths: Set<UInt64> = []
    /// Tier 2: full sequence deduplication (value-level novelty).
    private var seenSequences: Set<ChoiceSequence> = []

    public init() {}

    /// Score a (tree, sequence) pair. Higher = more novel.
    ///
    /// Returns `0.0` if the branch path has been seen AND the full sequence has been seen. Otherwise returns a positive score:
    /// - Branch-path hash unseen: 1.0 + sequence bonus
    /// - Branch-path hash seen but full sequence unseen: 0.5
    public mutating func score(tree: ChoiceTree, sequence: ChoiceSequence) -> Double {
        let branchPath = Self.branchPathHash(of: tree)
        let branchPathIsNew = seenBranchPaths.insert(branchPath).inserted
        let sequenceIsNew = seenSequences.insert(sequence).inserted

        if branchPathIsNew {
            // High novelty: unseen structural path
            return sequenceIsNew ? 1.5 : 1.0
        } else if sequenceIsNew {
            // Medium novelty: same structure, new values
            return 0.5
        } else {
            // Duplicate
            return 0.0
        }
    }

    /// Extract a structural fingerprint from a ChoiceTree by walking pick sites and hashing their `(fingerprint, branchID)` vectors.
    public static func branchPathHash(of tree: ChoiceTree) -> UInt64 {
        var hasher = Hasher()
        branchPathHashHelper(tree, hasher: &hasher)
        let h = hasher.finalize()
        return UInt64(bitPattern: Int64(h))
    }

    private static func branchPathHashHelper(_ tree: ChoiceTree, hasher: inout Hasher) {
        switch tree {
        case .choice, .just, .getSize:
            break
        case let .branch(fingerprint, _, id, _, choice):
            hasher.combine(fingerprint)
            hasher.combine(id)
            branchPathHashHelper(choice, hasher: &hasher)
        case let .sequence(_, elements, _):
            for element in elements {
                branchPathHashHelper(element, hasher: &hasher)
            }
        case let .group(array, _):
            for element in array {
                branchPathHashHelper(element, hasher: &hasher)
            }
        case let .bind(inner, bound):
            branchPathHashHelper(inner, hasher: &hasher)
            branchPathHashHelper(bound, hasher: &hasher)
        case let .resize(_, choices):
            for choice in choices {
                branchPathHashHelper(choice, hasher: &hasher)
            }
        case let .selected(inner):
            branchPathHashHelper(inner, hasher: &hasher)
        }
    }
}
