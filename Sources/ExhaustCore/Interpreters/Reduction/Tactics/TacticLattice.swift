//
//  TacticLattice.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/3/2026.
//

/// A DAG of shrink tactics ordered by dominance (the paper's 2-cells).
///
/// When a dominant tactic succeeds at a given bind depth, all tactics it dominates are
/// skipped for the current cycle at that depth. On the next outer cycle (after other depths
/// have been processed), all tactics become eligible again — this avoids over-pruning while
/// still gaining the O(1) skip benefit within a cycle.
public struct TacticLattice<Tactic> {
    /// A node in the dominance DAG.
    public struct Node {
        public let tactic: Tactic
        /// Indices of tactics this one dominates (try self before these).
        public let dominates: [Int]

        public init(tactic: Tactic, dominates: [Int] = []) {
            self.tactic = tactic
            self.dominates = dominates
        }
    }

    public let nodes: [Node]

    public init(nodes: [Node]) {
        self.nodes = nodes
    }

    /// Creates a traversal that yields tactics in dominance order, supporting pruning.
    public func orderedTraversal() -> TacticTraversal<Tactic> {
        TacticTraversal(nodes: nodes)
    }
}

/// Iterator over a ``TacticLattice`` that supports dominance-based pruning.
///
/// Yields tactics from most dominant to least dominant. When ``markSucceeded()`` is called
/// after a tactic succeeds, all tactics it dominates are skipped for the remainder of this
/// traversal.
public struct TacticTraversal<Tactic>: IteratorProtocol {
    private let nodes: [TacticLattice<Tactic>.Node]
    private var currentIndex: Int = 0
    private var pruned: Set<Int> = []
    private var lastReturnedIndex: Int?

    init(nodes: [TacticLattice<Tactic>.Node]) {
        self.nodes = nodes
    }

    public mutating func next() -> Tactic? {
        while currentIndex < nodes.count {
            let index = currentIndex
            currentIndex += 1
            if pruned.contains(index) {
                continue
            }
            lastReturnedIndex = index
            return nodes[index].tactic
        }
        return nil
    }

    /// Mark the last-returned tactic as successful — prune everything it dominates.
    public mutating func markSucceeded() {
        guard let index = lastReturnedIndex else { return }
        for dominated in nodes[index].dominates {
            pruned.insert(dominated)
        }
    }

    /// Reset pruning state for a new cycle.
    public mutating func reset() {
        currentIndex = 0
        pruned.removeAll()
        lastReturnedIndex = nil
    }
}
