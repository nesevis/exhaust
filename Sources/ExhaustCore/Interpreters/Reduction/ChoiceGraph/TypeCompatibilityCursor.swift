/// Streams compatibility edges in sequence-then-zip discovery order without retaining the cross products.
///
/// Zip children retain only the leaf prefixes the existing lookahead permits: 51 leaves on the first side and 50 on the second. This asymmetry preserves the prior builder's inclusive first-side cutoff. Prepared descriptors are immutable and do not retain the graph's mutable node storage.
///
/// - Complexity: O(C + A · W) retained descriptors, where C is the heterogeneous sequences' direct leaf count, A is the number of zip-child links, and W is the lookahead. Exhaustive zip enumeration remains quadratic in child-group count.
struct TypeCompatibilityCursor: Sendable {
    private struct Leaf: Sendable {
        let nodeID: Int
        let tag: TypeTag
    }

    private struct ZipChild: Sendable {
        let leaves: [Leaf]
        let homogeneousTag: TypeTag?
    }

    /// Tracks only the current subtree prefix while memoization avoids revisiting it for enclosing zip contexts.
    private struct PrefixFrame {
        let nodeID: Int
        var nextChild = 0
        var leaves: [Leaf] = []
    }

    private let sequenceGroups: [[Leaf]]
    private let zipGroups: [[ZipChild]]
    private var sequenceIndex = 0
    private var sequenceFirst = 0
    private var sequenceSecond = 1
    private var zipIndex = 0
    private var firstGroup = 0
    private var secondGroup = 1
    private var firstLeaf = 0
    private var secondLeaf = 0

    /// Counts the entire prepared stream without constructing its edges, even after the cursor advances.
    let edgeCount: Int
    let preparedLeafCount: Int

    /// Prepares decision contexts once, sharing memoized leaf prefixes across nested zip slots.
    init(graph: ChoiceGraph) {
        var sequences: [[Leaf]] = []
        var zips: [[ZipChild]] = []
        var leafPrefixes: [Int: [Leaf]] = [:]
        for nodeID in graph.liveNodeIDs {
            let node = graph.nodes[nodeID]
            switch node.kind {
                case let .sequence(metadata) where metadata.elementTypeTag == nil:
                    let leaves = node.children.compactMap { childID -> Leaf? in
                        guard childID < graph.nodes.count,
                              graph.nodes[childID].positionRange != nil,
                              case let .chooseBits(metadata) = graph.nodes[childID].kind
                        else {
                            return nil
                        }
                        return Leaf(nodeID: childID, tag: metadata.typeTag)
                    }
                    if leaves.count >= 2 {
                        sequences.append(leaves)
                    }
                case .zip where node.children.count >= 2:
                    zips.append(node.children.map { childID in
                        let tag: TypeTag? = switch graph.nodes[childID].kind {
                            case let .sequence(metadata):
                                metadata.elementTypeTag
                            default:
                                nil
                        }
                        return ZipChild(leaves: Self.leafPrefix(under: childID, graph: graph, cache: &leafPrefixes), homogeneousTag: tag)
                    })
                default:
                    continue
            }
        }
        sequenceGroups = sequences
        zipGroups = zips
        edgeCount = Self.countEdges(sequences: sequences, zips: zips)
        preparedLeafCount = sequences.reduce(0) { $0 + $1.count }
            + zips.reduce(0) { total, children in
                total + children.reduce(0) { $0 + $1.leaves.count }
            }
    }

    /// Memoizes depth-first prefixes so nested zip contexts do not repeat containment walks. Child lists are consumed incrementally, avoiding a temporary stack of every sibling beneath a wide sequence.
    private static func leafPrefix(under rootID: Int, graph: ChoiceGraph, cache: inout [Int: [Leaf]]) -> [Leaf] {
        if let leaves = cache[rootID] {
            return leaves
        }
        let limit = SchedulerTuning.maxPairLookahead + 1
        var stack = [PrefixFrame(nodeID: rootID)]
        while var frame = stack.popLast() {
            guard frame.nodeID < graph.nodes.count,
                  graph.nodes[frame.nodeID].positionRange != nil
            else {
                cache[frame.nodeID] = []
                continue
            }
            let node = graph.nodes[frame.nodeID]
            if case let .chooseBits(metadata) = node.kind {
                cache[frame.nodeID] = [Leaf(nodeID: frame.nodeID, tag: metadata.typeTag)]
                continue
            }
            guard frame.leaves.count < limit, frame.nextChild < node.children.count else {
                cache[frame.nodeID] = frame.leaves
                continue
            }
            let childID = node.children[frame.nextChild]
            if let leaves = cache[childID] {
                frame.leaves.append(contentsOf: leaves.prefix(limit - frame.leaves.count))
                frame.nextChild += 1
                stack.append(frame)
            } else {
                stack.append(frame)
                stack.append(PrefixFrame(nodeID: childID))
            }
        }
        return cache[rootID] ?? []
    }

    /// Accumulates earlier first-side leaves by homogeneous tag, subtracting the group products that enumeration skips.
    private static func countEdges(sequences: [[Leaf]], zips: [[ZipChild]]) -> Int {
        let lookahead = SchedulerTuning.maxPairLookahead
        var count = 0
        for leaves in sequences {
            for index in leaves.indices {
                count += min(lookahead, leaves.count - index - 1)
            }
        }
        for children in zips {
            var earlierLeafCount = 0
            var earlierCountByTag: [TypeTag: Int] = [:]
            for child in children {
                let skippedCount = child.homogeneousTag.map { earlierCountByTag[$0, default: 0] } ?? 0
                count += (earlierLeafCount - skippedCount) * min(child.leaves.count, lookahead)
                earlierLeafCount += child.leaves.count
                if let tag = child.homogeneousTag {
                    earlierCountByTag[tag, default: 0] += child.leaves.count
                }
            }
        }
        return count
    }

    /// Advances the bounded sibling window before moving to the next parent context.
    private mutating func nextSequenceEdge() -> TypeCompatibilityEdge? {
        while sequenceIndex < sequenceGroups.count {
            let leaves = sequenceGroups[sequenceIndex]
            guard sequenceFirst + 1 < leaves.count else {
                sequenceIndex += 1
                sequenceFirst = 0
                sequenceSecond = 1
                continue
            }
            let limit = min(leaves.count, sequenceFirst + 1 + SchedulerTuning.maxPairLookahead)
            guard sequenceSecond < limit else {
                sequenceFirst += 1
                sequenceSecond = sequenceFirst + 1
                continue
            }
            let first = leaves[sequenceFirst]
            let second = leaves[sequenceSecond]
            sequenceSecond += 1
            return Self.edge(first, second)
        }
        return nil
    }

    /// Advances leaf pairs within a child-group pair, then advances that group pair without storing its remaining edges.
    private mutating func nextZipEdge() -> TypeCompatibilityEdge? {
        while zipIndex < zipGroups.count {
            let children = zipGroups[zipIndex]
            guard firstGroup + 1 < children.count else {
                zipIndex += 1
                firstGroup = 0
                secondGroup = 1
                firstLeaf = 0
                secondLeaf = 0
                continue
            }
            guard secondGroup < children.count else {
                firstGroup += 1
                secondGroup = firstGroup + 1
                firstLeaf = 0
                secondLeaf = 0
                continue
            }
            let first = children[firstGroup]
            let second = children[secondGroup]
            let skipsHomogeneousPair = first.homogeneousTag != nil && first.homogeneousTag == second.homogeneousTag
            guard skipsHomogeneousPair == false,
                  firstLeaf < first.leaves.count,
                  second.leaves.isEmpty == false
            else {
                secondGroup += 1
                firstLeaf = 0
                secondLeaf = 0
                continue
            }
            let secondLimit = min(second.leaves.count, SchedulerTuning.maxPairLookahead)
            guard secondLeaf < secondLimit else {
                firstLeaf += 1
                secondLeaf = 0
                continue
            }
            let edge = Self.edge(first.leaves[firstLeaf], second.leaves[secondLeaf])
            secondLeaf += 1
            return edge
        }
        return nil
    }

    private static func edge(_ first: Leaf, _ second: Leaf) -> TypeCompatibilityEdge {
        TypeCompatibilityEdge(nodeA: first.nodeID, nodeB: second.nodeID, typeTag: first.tag == second.tag ? first.tag : nil)
    }
}

extension TypeCompatibilityCursor: ScopeCursor {
    mutating func next(lastAccepted _: Bool) -> TypeCompatibilityEdge? {
        nextSequenceEdge() ?? nextZipEdge()
    }
}
