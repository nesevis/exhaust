//
//  GraphSiblingSwapEncoder.swift
//  Exhaust
//

// MARK: - Graph Sibling Swap Encoder

/// Swaps same-shaped siblings within zip nodes to achieve shortlex-minimal ordering.
///
/// For each zip node in the graph, groups its children by structural kind and tries pairwise content swaps. A swap is accepted if the resulting sequence is shortlex-smaller. Runs in the structural phase alongside pivot and deletion because early reordering normalises the counterexample and can unlock further deletions.
///
/// This is the graph-based counterpart of ``SiblingSwapEncoder``.
public struct GraphSiblingSwapEncoder: GraphEncoder {
    public let name: EncoderName = .graphSiblingSwap

    // MARK: - State

    private var candidates: [ChoiceSequence] = []
    private var candidateIndex = 0

    // MARK: - GraphEncoder

    public mutating func start(
        graph: ChoiceGraph,
        sequence: ChoiceSequence,
        tree: ChoiceTree
    ) {
        candidateIndex = 0
        candidates = Self.buildCandidates(graph: graph, tree: tree, sequence: sequence)
    }

    public mutating func nextProbe(lastAccepted _: Bool) -> ChoiceSequence? {
        guard candidateIndex < candidates.count else { return nil }
        let candidate = candidates[candidateIndex]
        candidateIndex += 1
        return candidate
    }

    // MARK: - Candidate Generation

    /// Builds swap candidates from zip nodes in the graph.
    ///
    /// For each zip node, groups children by structural kind and tries pairwise swaps. Uses the tree for actual content swapping (the graph provides the grouping, the tree provides the manipulation).
    private static func buildCandidates(
        graph: ChoiceGraph,
        tree: ChoiceTree,
        sequence: ChoiceSequence
    ) -> [ChoiceSequence] {
        var candidates: [ChoiceSequence] = []

        // Walk the tree to find group nodes (zips), using graph metadata for grouping.
        for element in tree.walk() {
            guard case let .group(children, _) = element.node,
                  children.count >= 2
            else { continue }

            // Skip pick sites (groups containing branches).
            if children.contains(where: \.unwrapped.isBranch) { continue }

            let swappablePairs = findSwappablePairs(in: children)
            guard swappablePairs.isEmpty == false else { continue }

            for (indexA, indexB) in swappablePairs {
                var swappedChildren = children
                swappedChildren[indexA] = children[indexB]
                swappedChildren[indexB] = children[indexA]

                var candidateTree = tree
                candidateTree[element.fingerprint] = .group(swappedChildren)
                let candidateSequence = ChoiceSequence.flatten(candidateTree)

                if candidateSequence.shortLexPrecedes(sequence) {
                    candidates.append(candidateSequence)
                }
            }
        }

        return candidates
    }

    /// Groups children by structural kind and returns pairs of same-kind siblings.
    ///
    /// Uses a lightweight shape comparison: node kind at the root plus first-element shape for sequences. Empty sequences are wildcards that merge into the first populated sequence group.
    private static func findSwappablePairs(
        in children: [ChoiceTree]
    ) -> [(Int, Int)] {
        var groups: [[Int]] = []
        var kindToGroup: [ShapeKey: Int] = [:]
        var emptySequenceIndices: [Int] = []

        for (index, child) in children.enumerated() {
            let key = shapeKey(of: child)
            if key == .emptySequence {
                emptySequenceIndices.append(index)
                continue
            }
            if let groupIndex = kindToGroup[key] {
                groups[groupIndex].append(index)
            } else {
                kindToGroup[key] = groups.count
                groups.append([index])
            }
        }

        // Merge empty sequences into the first populated sequence group.
        if emptySequenceIndices.isEmpty == false {
            let sequenceGroup = kindToGroup.first(where: {
                if case .sequence = $0.key { return true }
                return false
            })?.value
            if let groupIndex = sequenceGroup {
                groups[groupIndex].append(contentsOf: emptySequenceIndices)
            } else if emptySequenceIndices.count >= 2 {
                groups.append(emptySequenceIndices)
            }
        }

        var pairs: [(Int, Int)] = []
        for indices in groups where indices.count >= 2 {
            for indexI in 0 ..< indices.count {
                for indexJ in (indexI + 1) ..< indices.count {
                    pairs.append((indices[indexI], indices[indexJ]))
                }
            }
        }
        return pairs
    }

    // MARK: - Shape Key

    /// Lightweight shape discriminant for grouping siblings.
    private enum ShapeKey: Hashable {
        case value
        case sequence(elementKind: String)
        case emptySequence
        case group(childCount: Int)
        case bind
        case branch(branchCount: Int)
        case other
    }

    private static func shapeKey(of tree: ChoiceTree) -> ShapeKey {
        switch tree.unwrapped {
        case .choice:
            return .value
        case let .sequence(_, elements, _):
            if elements.isEmpty { return .emptySequence }
            return .sequence(elementKind: elementKindString(elements[0]))
        case let .group(children, _):
            if children.contains(where: \.unwrapped.isBranch) {
                return .branch(branchCount: children.count)
            }
            return .group(childCount: children.count)
        case .bind:
            return .bind
        case let .branch(_, _, _, branchIDs, _):
            return .branch(branchCount: branchIDs.count)
        default:
            return .other
        }
    }

    private static func elementKindString(_ tree: ChoiceTree) -> String {
        switch tree.unwrapped {
        case .choice: "choice"
        case .sequence: "sequence"
        case .group: "group"
        case .bind: "bind"
        case .branch: "branch"
        default: "other"
        }
    }
}
