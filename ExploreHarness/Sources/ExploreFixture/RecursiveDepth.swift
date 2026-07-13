// The recursion-depth-gate archetype (matrix fixture MX2c, "RecursiveDepth"): pins mutator and reducer behavior on deep recursive shapes — the shape class the reducer has historically broken on, per the self-fuzzing target ranking.
//
// ## Shape Coordinates
//
// Trigger class: recursion-depth gate. Coverage surface: honestly bucket-laddered on NODE COUNT — any traversal executes fixture code per node, so hit-count buckets rung the node count regardless of authorial intent (the SF6 constraint has no branchless escape for tree walks). Depth itself lights no edge below the gate, and node count only loosely correlates with depth on binary trees, so the depth signal is weak but not zero; the registry coordinates say "node-count laddered" rather than claiming flatness. Vocabulary: one `.recursive` tree generator. Argument domain: node tags 0...9, irrelevant to the trigger. Length scale: depth 7 of a 0...8 depthRange.
//
// ## Ground-Truth Registry
//
// Fault RD (depth gate):
//     Trigger: actual tree depth >= 7 (a tip counts as depth 0, a node as 1 + the deeper child).
//     Trigger variable: the recursion depth of `depthOf`.
//     Minimal: a left-spine chain of 7 nodes over a tip.
//     Effect: throws RecursiveDepthError.
//
// Single planted fault; tags feed nothing.
//
// ## Blind Rate (deliberately probable)
//
// Monte Carlo over the generator's semantics (drawn depth budget uniform 0...8, tip probability 1/3 per layer after the MX2e retune): actual depth >= 7 occurs in ~11% of attempts — a reliably-found no-regression sentinel for the recursive-shape class (MX4b's sign-test set) whose real work is downstream: every discovery hands the reducer a deep recursive counterexample to collapse. At the original 1:1 weighting (critical branching, ~3.9% blind under the uniform model) the runtime's size ramp starved five of 20 seeds of any deep tree before the coverage plateau ended their runs; the pinned rate below is the 2:1 geometry.
//
// Pinned baseline (MX2e, 2026-07-12, seeds 1-20, 10 s, defaults): 19/20.

import Exhaust

/// A binary tree with tagged nodes; the planted fault gates on its depth.
public indirect enum SkewTree: Sendable, Equatable {
    case tip
    case node(left: SkewTree, right: SkewTree, tag: Int)
}

/// A pure function faulting on trees of depth seven or more.
public enum RecursiveDepth {
    /// Measures tree depth and faults at the gate.
    ///
    /// - Throws: ``RecursiveDepthError`` when the tree's depth is 7 or more.
    public static func measure(_ tree: SkewTree) throws -> Int {
        let depth = depthOf(tree)
        // Fault RD: lights nothing below the gate.
        if depth >= 7 {
            throw RecursiveDepthError()
        }
        return depth
    }

    private static func depthOf(_ tree: SkewTree) -> Int {
        switch tree {
            case .tip:
                return 0
            case let .node(left, right, _):
                return 1 + max(depthOf(left), depthOf(right))
        }
    }
}

/// Fault RD's observable effect.
public struct RecursiveDepthError: Error, Equatable, Sendable {
    public init() {}
}

/// The generator and ground-truth minimal reproducer for ``RecursiveDepth``.
public enum RecursiveDepthFixture {
    /// A binary tree over depth budgets 0...8: each layer is a tip or, twice as often, a node with two recursive children and a 0...9 tag. The 2:1 node weighting is a calibration constant (MX2e, 2026-07-12): at 1:1 the branching process is critical, five of 20 seeds never generated a deep tree before the coverage plateau ended the run, and fault RD landed mid-window at 15/20.
    public static var treeGenerator: ReflectiveGenerator<SkewTree> {
        .recursive(baseValue: .tip, depthRange: 0 ... 8) { recurse, _ in
            .oneOf(weighted:
                (1, .just(.tip)),
                (2, #gen(recurse(), recurse(), .int(in: 0 ... 9)) { left, right, tag in
                    SkewTree.node(left: left, right: right, tag: tag)
                }))
        }
    }

    /// Fault RD's minimal form: a left-spine chain of seven nodes.
    public static let reproducerRD: SkewTree = {
        var tree = SkewTree.tip
        for _ in 0 ..< 7 {
            tree = .node(left: tree, right: .tip, tag: 0)
        }
        return tree
    }()
}
