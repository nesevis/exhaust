//
//  BindClassification.swift
//  Exhaust
//

// MARK: - Bind Classification

/// Classifies a bind site by how its bound subtree responds to variation in the upstream value.
///
/// Produced by ``ChoiceGraph/classifyBind(at:gen:baseSequence:fallbackTree:upstreamLeafNodeID:)``. Stored on ``BindMetadata/classification``. Read by expensive dependent-node encoders before dispatch.
package struct BindClassification: Equatable, Hashable, Sendable {
    /// Structural relationship between the bound subtrees lifted at the upstream range's low and high endpoints.
    public let topology: BindTopology

    /// Which of the two endpoint lifts succeeded.
    public let liftability: BindLiftability

    /// Creates a classification with the given topology and liftability verdicts.
    public init(topology: BindTopology, liftability: BindLiftability) {
        self.topology = topology
        self.liftability = liftability
    }
}

/// Shape-stability verdict from the classifier's two lifts.
package enum BindTopology: Equatable, Hashable, Sendable {
    /// The two lifted bound subtrees have the same skeleton — same node kinds and child counts at matching positions. Leaf-level descriptor differences (tag, width, range) do not break this verdict; they are the signal expensive encoders such as ``GraphComposedEncoder`` converge on.
    case identical
    /// The two lifted bound subtrees disagree on node kind or child count at some non-leaf position. Binary-search-style dependent-node encoders cannot converge because each upstream probe reshapes the downstream topology.
    case divergent
    /// The classifier could not produce a comparison: singleton upstream domain, both lifts threw, or the walk could not be performed.
    case unclassifiable
}

/// Reports which range endpoints the classifier was able to lift.
package enum BindLiftability: Equatable, Hashable, Sendable {
    /// Both endpoints materialized successfully.
    case both
    /// Only the low endpoint materialized.
    case lowOnly
    /// Only the high endpoint materialized.
    case highOnly
    /// Neither endpoint materialized.
    case neither
}

/// Snapshot of a bind site's upstream value and downstream topology at a given graph state. Compared across graph rebuilds to passively classify binds without materialisation probes.
package struct BindTopologyObservation: Equatable, Hashable, Sendable {
    /// Bit pattern of the upstream (inner) leaf at observation time.
    public let upstreamBitPattern: UInt64

    /// Topology fingerprint of the bound subtree at observation time.
    public let downstreamFingerprint: UInt64
}
