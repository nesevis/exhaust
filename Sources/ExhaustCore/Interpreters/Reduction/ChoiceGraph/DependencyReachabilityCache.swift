/// Reuses complete dependency searches while retaining only results relevant to a fixed candidate domain.
///
/// Positive results use a least-recently-used cache bounded by both source count and total retained node IDs. The default node budget scales linearly with the candidate count so any single source result fits; it never allocates an all-node transitive-closure table. Empty results are remembered separately in O(V) space. Sources without outgoing edges need no traversal or cache entry.
///
/// Topology and candidates are immutable for the lifetime of the cache. Copies share immutable adjacency and result sets, but advance cache state independently. Evicted results can require another O(V + E) traversal, so the memory bound does not guarantee that each source is traversed only once under arbitrary interleaving.
struct DependencyReachabilityCache {
    private struct Entry {
        let reached: Set<Int>
        var lastUse: Int
    }

    private let adjacency: [[Int]]
    private let candidates: Set<Int>
    private let sourceLimit: Int
    private let nodeLimit: Int
    private var entries: [Int: Entry] = [:]
    private var unreachableSources: Set<Int> = []
    private var accessCount = 0

    /// Counts actual searches rather than cache hits or leaf-source fast paths.
    private(set) var traversalCount = 0
    private(set) var cachedNodeCount = 0

    var cachedSourceCount: Int {
        entries.count
    }

    /// Allows smaller budgets for consumers with tighter working sets; zero disables positive-result retention.
    init(adjacency: [[Int]], candidates: Set<Int>, sourceLimit: Int = 32, nodeLimit: Int? = nil) {
        self.adjacency = adjacency
        self.candidates = candidates
        self.sourceLimit = max(0, sourceLimit)
        self.nodeLimit = max(0, nodeLimit ?? max(4096, candidates.count))
    }

    /// Excludes the source itself, matching restricted reachability used by replacement promotion.
    mutating func isReachable(from source: Int, to target: Int) -> Bool {
        guard source >= 0, source < adjacency.count,
              target >= 0, target < adjacency.count,
              source != target,
              candidates.contains(target),
              adjacency[source].isEmpty == false,
              unreachableSources.contains(source) == false
        else {
            return false
        }
        accessCount += 1
        if var entry = entries[source] {
            entry.lastUse = accessCount
            entries[source] = entry
            return entry.reached.contains(target)
        }
        traversalCount += 1
        let reached = DependencyReachability.reachableNodes(from: source, within: candidates, adjacency: adjacency)
        if reached.isEmpty {
            unreachableSources.insert(source)
        } else {
            retain(reached, from: source)
        }
        return reached.contains(target)
    }

    /// Evicts entire source results until both budgets permit insertion; partial sets would turn missing targets into incorrect negatives.
    private mutating func retain(_ reached: Set<Int>, from source: Int) {
        guard sourceLimit > 0, reached.count <= nodeLimit else {
            return
        }
        while entries.count >= sourceLimit || cachedNodeCount + reached.count > nodeLimit {
            guard let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) else {
                break
            }
            cachedNodeCount -= oldest.value.reached.count
            entries.removeValue(forKey: oldest.key)
        }
        entries[source] = Entry(reached: reached, lastUse: accessCount)
        cachedNodeCount += reached.count
    }
}
