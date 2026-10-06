/// Streams compatibility edges in sequence-then-zip discovery order without retaining the cross products.
///
/// Zip children retain only the leaf prefixes the existing lookahead permits: 51 leaves on the first side and 50 on the second. The first-side cutoff is inclusive, while the second-side cutoff is exclusive. Prepared descriptors are immutable and do not retain the graph's mutable node storage.
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

    /// Records every active leaf once in preorder, so each subtree's leaves form one contiguous interval and nested zip slots share a single walk.
    private struct PreorderFrame {
        let nodeID: Int
        var nextChild = 0
    }

    private struct PreorderLeaves {
        private var leaves: [Leaf] = []
        private var intervalStarts: [Int]
        private var intervalEnds: [Int]

        /// Visits each active node once; inactive subtrees keep empty intervals, matching a walk that stops at nodes without positions.
        init(graph: ChoiceGraph) {
            intervalStarts = [Int](repeating: 0, count: graph.nodes.count)
            intervalEnds = [Int](repeating: 0, count: graph.nodes.count)
            for rootID in graph.nodes.indices where graph.nodes[rootID].parent == nil {
                var stack = [PreorderFrame(nodeID: rootID)]
                while var frame = stack.popLast() {
                    let node = graph.nodes[frame.nodeID]
                    guard node.positionRange != nil else {
                        continue
                    }
                    if frame.nextChild == 0 {
                        intervalStarts[frame.nodeID] = leaves.count
                        if case let .chooseBits(metadata) = node.kind {
                            leaves.append(Leaf(nodeID: frame.nodeID, tag: metadata.typeTag))
                            intervalEnds[frame.nodeID] = leaves.count
                            continue
                        }
                    }
                    guard frame.nextChild < node.children.count else {
                        intervalEnds[frame.nodeID] = leaves.count
                        continue
                    }
                    let childID = node.children[frame.nextChild]
                    frame.nextChild += 1
                    stack.append(frame)
                    if childID < graph.nodes.count {
                        stack.append(PreorderFrame(nodeID: childID))
                    }
                }
            }
        }

        func prefix(under nodeID: Int, limit: Int) -> [Leaf] {
            guard nodeID < intervalStarts.count else {
                return []
            }
            let start = intervalStarts[nodeID]
            return Array(leaves[start ..< min(intervalEnds[nodeID], start + limit)])
        }
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

    /// Prepares decision contexts once, walking leaf order only when a zip needs cross-slot prefixes.
    init(graph: ChoiceGraph) {
        var sequences: [[Leaf]] = []
        var zips: [[ZipChild]] = []
        var preorderLeaves: PreorderLeaves?
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
                    let leafOrder = preorderLeaves ?? PreorderLeaves(graph: graph)
                    preorderLeaves = leafOrder
                    zips.append(node.children.map { childID in
                        let tag: TypeTag? = switch graph.nodes[childID].kind {
                            case let .sequence(metadata):
                                metadata.elementTypeTag
                            default:
                                nil
                        }
                        return ZipChild(leaves: leafOrder.prefix(under: childID, limit: SchedulerTuning.maxPairLookahead + 1), homogeneousTag: tag)
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
    mutating func next() -> TypeCompatibilityEdge? {
        nextSequenceEdge() ?? nextZipEdge()
    }
}
