import Exhaust

// MARK: - Types

/// Edge between two distinct vertex labels, stored with the smaller label first so equal (canonical) edges compare equal regardless of construction order.
struct GraphColoringEdge: Hashable, Comparable, CustomStringConvertible {
    let lower: Int
    let upper: Int
    init(_ a: Int, _ b: Int) {
        lower = min(a, b)
        upper = max(a, b)
    }
    static func < (lhs: GraphColoringEdge, rhs: GraphColoringEdge) -> Bool {
        lhs.lower != rhs.lower ? lhs.lower < rhs.lower : lhs.upper < rhs.upper
    }
    var description: String { "(\(lower)-\(upper))" }
}

/// Multi-leaf bind-inner challenge output: a vertex label list plus a deduplicated edge list referencing those labels.
struct GraphColoringGraph: CustomStringConvertible {
    let vertices: [Int]
    let edges: [GraphColoringEdge]
    var distinctVertices: [Int] { Array(Set(vertices)).sorted() }
    var description: String {
        "Graph(V=\(distinctVertices), E=\(edges.sorted()))"
    }
}

// MARK: - Generator

/// Multi-leaf bind-inner generator. The inner is a list of vertex labels (5 to 20 distinct integers in `0...50`). The bound subtree generates edges as index-pairs into that list — the edges' domain depends on the vertex count, so the upstream and downstream are structurally coupled. A non-bind rewrite using `.filter` would collapse to near-zero yield because random `Int` pairs almost never reference vertices in the chosen vertex list.
let graphColoringGen: ReflectiveGenerator<GraphColoringGraph> = {
    let verticesGen = #gen(.int(in: 0 ... 50, scaling: .constant).array(length: 5 ... 20, scaling: .constant))
    return verticesGen.bind { (vertices: [Int]) -> ReflectiveGenerator<GraphColoringGraph> in
        let n = vertices.count
        guard n >= 2 else {
            return .just(GraphColoringGraph(vertices: vertices, edges: []))
        }
        let edgePairGen = #gen(
            .int(in: 0 ... n - 1, scaling: .constant),
            .int(in: 0 ... n - 1, scaling: .constant)
        ) { left, right in (Int(left), Int(right)) }
        return edgePairGen.array(length: 1 ... 8, scaling: .constant)
            .map { (idxPairs: [(Int, Int)]) -> GraphColoringGraph in
                var seen: Set<GraphColoringEdge> = []
                var edges: [GraphColoringEdge] = []
                for pair in idxPairs {
                    let (i, j) = pair
                    guard i != j else { continue }
                    let edge = GraphColoringEdge(vertices[i], vertices[j])
                    if seen.insert(edge).inserted {
                        edges.append(edge)
                    }
                }
                return GraphColoringGraph(vertices: vertices, edges: edges)
            }
    }
}()

// MARK: - Helpers

/// Maximum vertex degree in the graph.
private func graphColoringMaxDegree(_ graph: GraphColoringGraph) -> Int {
    guard graph.edges.isEmpty == false else { return 0 }
    var degree: [Int: Int] = [:]
    for edge in graph.edges {
        degree[edge.lower, default: 0] += 1
        degree[edge.upper, default: 0] += 1
    }
    return degree.values.max() ?? 0
}

/// Brute-force chromatic number via backtracking `k`-coloring.
///
/// Tries `k = 1 ... |V|` in ascending order, returning the first `k` that admits a proper coloring. Small graph sizes make this exhaustive search tractable; the benchmark caps vertex counts well below the factorial wall.
private func graphColoringChromaticNumber(_ graph: GraphColoringGraph) -> Int {
    let vertices = graph.distinctVertices
    if vertices.isEmpty { return 0 }
    var adjacency: [Int: Set<Int>] = [:]
    for edge in graph.edges {
        adjacency[edge.lower, default: []].insert(edge.upper)
        adjacency[edge.upper, default: []].insert(edge.lower)
    }
    for k in 1 ... vertices.count {
        var assignment: [Int: Int] = [:]
        if graphColoringTryColor(vertices: vertices, index: 0, k: k, adjacency: adjacency, assignment: &assignment) {
            return k
        }
    }
    return vertices.count
}

private func graphColoringTryColor(
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
            if graphColoringTryColor(vertices: vertices, index: index + 1, k: k, adjacency: adjacency, assignment: &assignment) {
                return true
            }
            assignment.removeValue(forKey: vertex)
        }
    }
    return false
}

// MARK: - Property

/// Multi-basin shrinking property with three local minima.
///
/// SUT: a buggy Brooks's-theorem-style upper bound claiming χ(G) ≤ Δ(G), dropping the `+1` correction term. Brooks's theorem actually says χ(G) ≤ Δ(G) + 1, with equality reached by complete graphs `K_n` and odd cycles `C_(2k+1)`. The filter (`chromatic ≥ 3`) excludes trivial bipartite cases, so surviving counterexamples sit in one of three basins: K_3, K_4, or C_5. A single-axis reducer cannot bridge these basins; K_4 → K_3 requires coordinated vertex + edge removals.
let graphColoringProperty: @Sendable (GraphColoringGraph) -> Bool = { graph in
    guard graph.edges.isEmpty == false else { return true }
    guard graph.distinctVertices.count >= 3 else { return true }
    let chromatic = graphColoringChromaticNumber(graph)
    guard chromatic >= 3 else { return true }
    return graphColoringMaxDegree(graph) >= chromatic
}
