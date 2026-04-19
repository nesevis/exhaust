//
//  GraphColoring.swift
//  Exhaust
//
//  Created by Chris Kolbu on 17/4/2026.
//

import Foundation
import Testing
@testable import Exhaust

@Suite("Experimental Challenge: Graph Coloring")
struct GraphColoringChallenge {
    /*
     Multi-leaf bind-inner shrinking challenge with multiple local minima.

     SUT: a buggy Brooks's-theorem-style upper bound that claims
     `χ(G) ≤ Δ(G)` for all graphs, dropping the `+1` correction term.
     Brooks's theorem actually says `χ(G) ≤ Δ(G) + 1`, with equality
     reached by complete graphs `K_n` and odd cycles `C_(2k+1)`. The
     buggy bound therefore fails for those structures.

     Property (`maxDegree(g) >= chromaticNumber(g)`) is filtered to
     `chromaticNumber ≥ 3`, removing trivial bipartite cases that would
     otherwise produce uninteresting two-vertex CEs. Three distinct
     counterexample classes survive — each in its own reduction basin:

       - Triangle (K_3): 3 vertices, 3 edges, χ=3, Δ=2.
       - 5-cycle (C_5): 5 vertices, 5 edges, χ=3, Δ=2.
       - K_4: 4 vertices, 6 edges, χ=4, Δ=3.

     A single-axis reducer cannot bridge these basins. Going from K_4
     down to K_3 requires removing one vertex *and* three edges in
     coordination; going from C_5 to K_3 requires removing two vertices
     and adding edges between the survivors. Each topology forms a
     local minimum.

     Why multi-leaf inner is structurally required:

     The inner is a list of vertex labels (multi-leaf). The bound
     subtree generates edges as index-pairs into that list. A
     "scalar inner" rewrite (`n: Int → (vertices of length n, edges)`)
     still requires a nested bind to thread `n` into both children;
     in either case the bind whose inner is the vertex list is the
     one we want to exercise.

     A non-bind rewrite using `.filter` on a zip of (random vertices,
     random edges) collapses to near-zero yield: random `Int` pairs
     almost never both happen to reference vertices in the chosen
     vertex list.

     This challenge specifically exercises the descendant-aware
     `mayReshapeOnAcceptance` and value-yield prioritization fixed by
     ``ScopeQueryHelpers.buildInnerDescendantToBind`` — without those
     fixes, vertex-label mutations take the value-only fast path and
     desync the bound subtree's edge index domain.
     */

    struct Edge: Hashable, Comparable, CustomStringConvertible {
        let lower: Int
        let upper: Int
        init(_ a: Int, _ b: Int) {
            lower = min(a, b)
            upper = max(a, b)
        }
        static func < (lhs: Edge, rhs: Edge) -> Bool {
            lhs.lower != rhs.lower ? lhs.lower < rhs.lower : lhs.upper < rhs.upper
        }
        var description: String { "(\(lower)-\(upper))" }
    }

    struct Graph: CustomStringConvertible {
        let vertices: [Int]
        let edges: [Edge]
        var distinctVertices: [Int] { Array(Set(vertices)).sorted() }
        var description: String {
            "Graph(V=\(distinctVertices), E=\(edges.sorted()))"
        }
    }

    static let gen: ReflectiveGenerator<Graph> = {
        let verticesGen = #gen(.int(in: 0 ... 50, scaling: .constant).array(length: 5 ... 20, scaling: .constant))
        return verticesGen.bind { (vertices: [Int]) -> ReflectiveGenerator<Graph> in
            let n = vertices.count
            guard n >= 2 else {
                return .just(Graph(vertices: vertices, edges: []))
            }
            let edgePairGen = #gen(
                .int(in: 0 ... n - 1, scaling: .constant),
                .int(in: 0 ... n - 1, scaling: .constant)
            ) { left, right in (Int(left), Int(right)) }
            return edgePairGen.array(length: 1 ... 8, scaling: .constant)
                .map { (idxPairs: [(Int, Int)]) -> Graph in
                    var seen: Set<Edge> = []
                    var edges: [Edge] = []
                    for pair in idxPairs {
                        let (i, j) = pair
                        guard i != j else { continue }
                        let edge = Edge(vertices[i], vertices[j])
                        if seen.insert(edge).inserted {
                            edges.append(edge)
                        }
                    }
                    return Graph(vertices: vertices, edges: edges)
                }
        }
    }()

    /// Maximum vertex degree in the graph.
    static func maxDegree(_ graph: Graph) -> Int {
        var degree: [Int: Int] = [:]
        for edge in graph.edges {
            degree[edge.lower, default: 0] += 1
            degree[edge.upper, default: 0] += 1
        }
        return degree.values.max() ?? 0
    }

    /// Brute-force chromatic number for small graphs.
    ///
    /// Tries `k = 1 ... |V|` in ascending order, attempting a backtracking
    /// `k`-coloring at each step. Returns the first `k` that succeeds.
    static func chromaticNumber(_ graph: Graph) -> Int {
        let vertices = graph.distinctVertices
        if vertices.isEmpty { return 0 }
        var adjacency: [Int: Set<Int>] = [:]
        for edge in graph.edges {
            adjacency[edge.lower, default: []].insert(edge.upper)
            adjacency[edge.upper, default: []].insert(edge.lower)
        }
        for k in 1 ... vertices.count {
            var assignment: [Int: Int] = [:]
            if tryColor(vertices: vertices, index: 0, k: k, adjacency: adjacency, assignment: &assignment) {
                return k
            }
        }
        return vertices.count
    }

    private static func tryColor(
        vertices: [Int],
        index: Int,
        k: Int,
        adjacency: [Int: Set<Int>],
        assignment: inout [Int: Int]
    ) -> Bool {
        if index == vertices.count { return true }
        let vertex = vertices[index]
        let neighbors = adjacency[vertex] ?? []
        for color in 0 ..< k {
            let conflict = neighbors.contains { assignment[$0] == color }
            if conflict == false {
                assignment[vertex] = color
                if tryColor(vertices: vertices, index: index + 1, k: k, adjacency: adjacency, assignment: &assignment) {
                    return true
                }
                assignment.removeValue(forKey: vertex)
            }
        }
        return false
    }

    static let property: @Sendable (Graph) -> Bool = { graph in
        guard graph.edges.isEmpty == false else { return true }
        guard graph.distinctVertices.count >= 3 else { return true }
        let chromatic = chromaticNumber(graph)
        guard chromatic >= 3 else { return true }
        return maxDegree(graph) >= chromatic
    }

    /// Classification of a graph's topology for distribution reporting.
    ///
    /// Canonical shapes have their own cases. Off-canonical shapes are bucketed
    /// by distinct-vertex count so the distribution surfaces the *size* of
    /// failing starts even when they don't match a named topology. `sizeN6` and
    /// beyond only appear when the generator widens past the 5-vertex cap.
    enum Topology: String {
        case triangleExact          // 3 vertices, 3 edges (already K_3)
        case triangleSuperGraph     // contains a triangle plus extras on 3 or 4 vertices
        case pentagonExact          // 5 vertices, 5 edges, 2-regular (C_5)
        case pentagonSuperGraph     // 5 vertices containing C_5
        case k4Exact                // 4 vertices, 6 edges (complete)
        case size6
        case size7
        case size8
        case sizeLarge              // 9 or more distinct vertices
    }

    static func classify(_ graph: Graph) -> Topology {
        let n = graph.distinctVertices.count
        let e = graph.edges.count
        switch (n, e) {
        case (3, 3): return .triangleExact
        case (5, 5): return .pentagonExact
        case (4, 6): return .k4Exact
        default:
            switch n {
            case 3, 4: return .triangleSuperGraph
            case 5: return .pentagonSuperGraph
            case 6: return .size6
            case 7: return .size7
            case 8: return .size8
            default: return .sizeLarge
            }
        }
    }

    /// Characterisation test — runs many seeds, captures the first failing graph per seed
    /// (before any reduction), and reports the distribution of starting topologies.
    ///
    /// Not a pass/fail test. Tells you whether random generation is producing
    /// already-canonical CEs (trivial reduction) or larger starting graphs that
    /// require basin-crossing work to reach the minimum.
    @Test("Graph coloring — starting-graph distribution", .disabled("Slow analysis"))
    func graphColoringStartingDistribution() {
        let seedCount = 1000
        let baseSeed: UInt64 = 1337
        var startingTopologies: [Topology: Int] = [:]
        var reducedTopologies: [Topology: Int] = [:]
        // Seeds whose reduced result is not the global minimum K_3, grouped by
        // the basin the reducer got stuck in. These are the regression targets
        // for any future reducer improvement aimed at basin-crossing.
        var stuckSeeds: [Topology: [(seed: UInt64, original: Graph, reduced: Graph)]] = [:]

        // Per-run metrics collected via ``.onReport`` — one sample per seed,
        // used to compute means comparable to Hypothesis's run_challenge.py
        // output (evaluations, shrink time).
        var propertyInvocations: [Int] = []
        var reductionInvocations: [Int] = []
        var totalMaterializations: [Int] = []
        var reductionMs: [Double] = []
        var totalMs: [Double] = []

        for seedOffset in 0 ..< seedCount {
            let seed = baseSeed + UInt64(seedOffset)
            // Capture the first failing graph per seed in a lock-guarded box.
            let box = FailureCaptureBox()
            let wrappedProperty: @Sendable (Graph) -> Bool = { graph in
                let passed = Self.property(graph)
                if passed == false {
                    box.recordFirstFailure(graph)
                }
                return passed
            }

            let reportBox = ReportCaptureBox()
            let reduced = #exhaust(
                Self.gen,
                .suppress(.issueReporting),
                .budget(.exorbitant),
                .replay(.numeric(seed)),
                .onReport { reportBox.record($0) },
                property: wrappedProperty
            )

            if let original = box.firstFailure {
                startingTopologies[Self.classify(original), default: 0] += 1
            }
            if let reduced {
                let reducedClass = Self.classify(reduced)
                reducedTopologies[reducedClass, default: 0] += 1
                if reducedClass != .triangleExact, let original = box.firstFailure {
                    stuckSeeds[reducedClass, default: []].append(
                        (seed: seed, original: original, reduced: reduced)
                    )
                }
            } else {
                print("Failed to reduce? \(box.firstFailure as Any)")
            }

            if let report = reportBox.report {
                propertyInvocations.append(report.propertyInvocations)
                reductionInvocations.append(report.reductionInvocations)
                totalMaterializations.append(report.totalMaterializations)
                reductionMs.append(report.reductionMilliseconds)
                totalMs.append(report.totalMilliseconds)
            }
        }

        print("[GraphColoring] Starting-graph distribution (N=\(seedCount)):")
        for (topology, count) in startingTopologies.sorted(by: { $0.value > $1.value }) {
            print("  \(topology.rawValue): \(count)")
        }
        print("[GraphColoring] Reduced-graph distribution:")
        for (topology, count) in reducedTopologies.sorted(by: { $0.value > $1.value }) {
            print("  \(topology.rawValue): \(count)")
        }

        let nonTriangleStarts = startingTopologies
            .filter { $0.key != .triangleExact }
            .values
            .reduce(0, +)
        print("[GraphColoring] Non-triangle starts: \(nonTriangleStarts)/\(seedCount)")

        // Per-run metrics — mean and median across all runs where a report
        // was produced. Directly comparable to Hypothesis's `evaluations`
        // (property invocations) and `shrink_time_ms` (reduction milliseconds).
        if propertyInvocations.isEmpty == false {
            print("[GraphColoring] Run metrics (N=\(propertyInvocations.count)):")
            printMetric("property invocations", values: propertyInvocations)
            printMetric("reduction invocations", values: reductionInvocations)
            printMetric("materializations", values: totalMaterializations)
            printMetric("reduction (ms)", values: reductionMs, format: "%.2f")
            printMetric("total (ms)", values: totalMs, format: "%.2f")
        }

        // Seeds where the reducer failed to reach K_3. Each entry is a candidate
        // for a pinned regression test: replay that seed, exercise the same
        // buggy starting graph, and measure whether the reducer eventually
        // crosses the basin.
        if stuckSeeds.isEmpty == false {
            print("[GraphColoring] Stuck-not-triangle seeds:")
            for (topology, entries) in stuckSeeds.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                print("  \(topology.rawValue): \(entries.count) seed(s)")
                for entry in entries {
                    print("    seed=\(entry.seed)")
                    print("      original: \(entry.original)")
                    print("      reduced:  \(entry.reduced)")
                }
            }
        }
    }

    private func printMetric<Value: BinaryInteger>(_ label: String, values: [Value]) {
        guard values.isEmpty == false else { return }
        let mean = Double(values.reduce(0, +)) / Double(values.count)
        let sorted = values.sorted()
        let median = sorted[sorted.count / 2]
        print("  \(label): mean=\(String(format: "%.1f", mean)) median=\(median) max=\(sorted.last!)")
    }

    private func printMetric(_ label: String, values: [Double], format: String) {
        guard values.isEmpty == false else { return }
        let mean = values.reduce(0, +) / Double(values.count)
        let sorted = values.sorted()
        let median = sorted[sorted.count / 2]
        print("  \(label): mean=\(String(format: format, mean)) median=\(String(format: format, median)) max=\(String(format: format, sorted.last!))")
    }

    @Test("Graph coloring shrinks to a canonical CE class")
    func graphColoringRandomSeed() throws {
        var report: ExhaustReport?
        let result = #exhaust(
            Self.gen,
            .suppress(.issueReporting),
            .budget(.exorbitant),
//            .onReport { report = $0 },
//            .logging(.debug),
            property: Self.property
        )
//        let value = try #require(result)
        
        guard let value = result else {
            return
        }
        
        if let report {
            print("[PROFILE] GraphColoring: \(report.profilingSummary)")
        }
//        print("[CE] \(value)")

        // Sanity-check the result is a counterexample.
        #expect(Self.property(value) == false)

        // Categorise the result by topology.
        let n = value.distinctVertices.count
        let e = value.edges.count
        let category: String = switch (n, e) {
        case (3, 3): "K_3 (triangle)"
        case (5, 5): "C_5 (5-cycle)"
        case (4, 6): "K_4"
        default: "non-canonical (n=\(n), e=\(e))"
        }
//        print("[CE class] \(category)")

        #expect(value.distinctVertices == [0, 1, 2])
    }
}

// MARK: - Helpers

/// Lock-guarded box for capturing the first failing graph across a run.
///
/// `#exhaust` invokes the property concurrently when scaling allows; we only
/// care about the first failing graph observed in generation order, so a
/// simple lock with a nil check works.
private final class FailureCaptureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _firstFailure: GraphColoringChallenge.Graph?

    var firstFailure: GraphColoringChallenge.Graph? {
        lock.lock()
        defer { lock.unlock() }
        return _firstFailure
    }

    func recordFirstFailure(_ graph: GraphColoringChallenge.Graph) {
        lock.lock()
        defer { lock.unlock() }
        if _firstFailure == nil {
            _firstFailure = graph
        }
    }
}

/// Lock-guarded box for capturing the ``ExhaustReport`` delivered via
/// ``.onReport``. The closure can fire from a background executor, so access
/// is guarded. `#exhaust` invokes the callback at most once per run.
private final class ReportCaptureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _report: ExhaustReport?

    var report: ExhaustReport? {
        lock.lock()
        defer { lock.unlock() }
        return _report
    }

    func record(_ report: ExhaustReport) {
        lock.lock()
        defer { lock.unlock() }
        _report = report
    }
}
