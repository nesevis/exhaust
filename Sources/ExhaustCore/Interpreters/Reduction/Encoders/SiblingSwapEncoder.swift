/// Swaps same-shaped siblings within group nodes to achieve shortlex-minimal ordering.
///
/// Detects structurally identical siblings via shape comparison (same node kinds at matching depths, ignoring values and siteIDs), then tries pairwise swaps. Applies to any zip of same-typed generators — recursive trees, flat tuples of arrays, and similar structures. Sits in base descent alongside promote and pivot because early structural reordering can unlock further reductions in subsequent cycles.
struct SiblingSwapEncoder: ComposableEncoder {
    let name = EncoderName.swapSiblings
    let phase = ReductionPhase.structuralDeletion

    // MARK: - State

    private var candidates: [ChoiceSequence] = []
    private var candidateIndex = 0

    // MARK: - ComposableEncoder

    func estimatedCost(
        sequence: ChoiceSequence,
        tree _: ChoiceTree,
        positionRange _: ClosedRange<Int>,
        context _: ReductionContext
    ) -> Int? {
        guard sequence.isEmpty == false else { return nil }
        return 5
    }

    mutating func start(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        positionRange _: ClosedRange<Int>,
        context _: ReductionContext
    ) {
        candidateIndex = 0
        candidates = Self.swapCandidates(tree: tree, sequence: sequence)
    }

    mutating func nextProbe(lastAccepted _: Bool) -> ChoiceSequence? {
        guard candidateIndex < candidates.count else { return nil }
        let candidate = candidates[candidateIndex]
        candidateIndex += 1
        return candidate
    }

    // MARK: - Candidate Generation

    private static func swapCandidates(
        tree: ChoiceTree,
        sequence: ChoiceSequence
    ) -> [ChoiceSequence] {
        var candidates: [ChoiceSequence] = []

        for element in tree.walk() {
            guard case let .group(children, _) = element.node,
                  children.count >= 2
            else {
                continue
            }

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

    /// Finds pairs of children that are candidates for swapping.
    ///
    /// Groups children by depth-augmented siteID when branches are present, falling back to
    /// structural shape matching for branchless children (plain sequences, values). Empty
    /// sequences are wildcards that merge into the first populated sequence group.
    private static func findSwappablePairs(
        in children: [ChoiceTree]
    ) -> [(Int, Int)] {
        // Collect all groups (keyed by an opaque Int tag to unify siteID and shape groups).
        var groups: [[Int]] = []
        var siteIDToGroup: [UInt64: Int] = [:]
        var shapeToGroup: [StructuralShape: Int] = [:]
        var emptySequenceIndices: [Int] = []

        for (index, child) in children.enumerated() {
            // Try siteID first (works for children with branch structure).
            if let siteID = rootBranchSiteID(child) {
                if let groupIndex = siteIDToGroup[siteID] {
                    groups[groupIndex].append(index)
                } else {
                    siteIDToGroup[siteID] = groups.count
                    groups.append([index])
                }
                continue
            }

            // Fallback: structural shape.
            let shape = structuralShape(of: child)
            if shape.kind == .sequence, shape.children.isEmpty {
                emptySequenceIndices.append(index)
                continue
            }

            if let groupIndex = shapeToGroup[shape] {
                groups[groupIndex].append(index)
            } else {
                shapeToGroup[shape] = groups.count
                groups.append([index])
            }
        }

        // Merge empty sequences into the first populated sequence group (siteID or shape).
        if emptySequenceIndices.isEmpty == false {
            let sequenceGroup = shapeToGroup.first(where: { $0.key.kind == .sequence })?.value
            if let groupIndex = sequenceGroup {
                groups[groupIndex].append(contentsOf: emptySequenceIndices)
            } else if emptySequenceIndices.count >= 2 {
                groups.append(emptySequenceIndices)
            }
        }

        var pairs: [(Int, Int)] = []
        for indices in groups where indices.count >= 2 {
            for i in 0 ..< indices.count {
                for j in (i + 1) ..< indices.count {
                    pairs.append((indices[i], indices[j]))
                }
            }
        }
        return pairs
    }

    // MARK: - siteID Extraction

    /// Extracts the root branch siteID from a subtree.
    ///
    /// Recursively descends through `.selected`, `.group`, and `.bind` wrappers to find the first branch siteID. Returns `nil` for subtrees that don't start with a branch.
    private static func rootBranchSiteID(_ tree: ChoiceTree) -> UInt64? {
        switch tree.unwrapped {
        case let .branch(siteID, _, _, _, _):
            return siteID
        case let .group(children, _):
            if let first = children.first?.unwrapped,
               case let .branch(siteID, _, _, _, _) = first
            {
                return siteID
            }
            if let first = children.first {
                return rootBranchSiteID(first)
            }
            return nil
        case let .bind(inner: _, bound):
            return rootBranchSiteID(bound)
        case let .sequence(_, elements, _):
            return elements.first.flatMap { rootBranchSiteID($0) }
        case let .resize(_, choices):
            return choices.first.flatMap { rootBranchSiteID($0) }
        default:
            return nil
        }
    }

    // MARK: - Structural Shape

    /// A lightweight description of a subtree's node-kind skeleton, ignoring values and siteIDs.
    private enum NodeKind: Hashable {
        case choice
        case just
        case sequence
        case branch(branchCount: Int)
        case group(childCount: Int)
        case getSize
        case resize
        case bind
    }

    /// A recursive shape descriptor: the node kind plus the shapes of all children.
    private struct StructuralShape: Hashable {
        let kind: NodeKind
        let children: [StructuralShape]
    }

    /// Computes the structural shape of a subtree up to a bounded depth.
    ///
    /// Stops descending at depth 3 to keep comparison cost bounded for deep recursive trees. Unwraps `.selected` wrappers transparently.
    private static func structuralShape(of tree: ChoiceTree, depth: Int = 0) -> StructuralShape {
        let maxDepth = 3
        let kind: NodeKind
        let childTrees: [ChoiceTree]

        switch tree {
        case .choice:
            return StructuralShape(kind: .choice, children: [])
        case .just:
            return StructuralShape(kind: .just, children: [])
        case .getSize:
            return StructuralShape(kind: .getSize, children: [])
        case let .sequence(_, elements, _):
            // Element count is runtime content, not generator structure.
            // Use first element's shape as the type signature so sequences
            // of the same element type match regardless of length.
            // Empty sequences get no children — paired with any same-kind
            // populated sequence via wildcard matching in findSwappablePairs.
            if let first = elements.first {
                return StructuralShape(kind: .sequence, children: [structuralShape(of: first, depth: depth + 1)])
            }
            return StructuralShape(kind: .sequence, children: [])
        case let .branch(_, _, _, branchIDs, choice):
            kind = .branch(branchCount: branchIDs.count)
            childTrees = [choice]
        case let .group(children, _):
            kind = .group(childCount: children.count)
            childTrees = children
        case let .resize(_, choices):
            kind = .resize
            childTrees = choices
        case let .bind(inner, bound):
            kind = .bind
            childTrees = [inner, bound]
        case let .selected(inner):
            return structuralShape(of: inner, depth: depth)
        }

        guard depth < maxDepth else {
            return StructuralShape(kind: kind, children: [])
        }

        let childShapes = childTrees.map { structuralShape(of: $0, depth: depth + 1) }
        return StructuralShape(kind: kind, children: childShapes)
    }
}
