# Graph-Theoretic Framing of Bonsai Reduction

A design analysis of the `ChoiceDependencyGraph` as a graph problem, the algorithms from combinatorics and optimisation theory that apply to test case reduction over a fibred trace space, and a concrete proposal for replacing pair enumeration in `MutationPool` with delta-debugging over structurally independent span sets.

---

## 1. The ChoiceDependencyGraph as a Decomposition of the Optimisation Space

The `ChoiceDependencyGraph` is a DAG whose vertices are the structural positions in a `ChoiceSequence` — bind-inner values that control downstream structure via data-dependent binds, and branch selectors at pick sites. Edges encode "controls the structure of" relationships: a bind-inner node has an edge to every structural node inside its bound range, and a branch selector has an edge to every structural node inside its selected subtree. Leaf positions (values not inside any structural node's range) are collected separately.

This DAG is not merely a dependency tracker. It is a **decomposition of the search space into coupled and uncoupled components**:

- **Edges** = coupling. An upstream value determines the downstream structure and domain. Reducing the upstream value changes which fibre the downstream content lives in.
- **No path between two nodes** = independence. Their reductions compose freely — the pushout law (§4.1 of the fibration analysis) guarantees that independent deletions can be applied simultaneously by taking the union of their removed ranges.
- **Topological depth** = the Kleisli tower height. The coupling direction is strictly one-way: upstream controls downstream, never the reverse.

This structure maps directly to the **conditional independence** structure exploited by graphical model algorithms. Two leaf ranges under different structural parents are conditionally independent given those parents' values. Two structural nodes with no directed path between them are unconditionally independent — their reductions cannot interact.

The DAG is rebuilt after every structural acceptance (O(n log n) for edge construction via sorted scan + binary search, plus O(V + E) for Kahn's topological sort). It is typically small: real generators produce DAGs with fewer than 20 structural nodes. Any graph algorithm that costs less than one property evaluation is effectively free.

---

## 2. What the DAG Already Provides

Before identifying new algorithms, it is worth cataloguing the graph-theoretic operations the reducer already performs, to clarify what is covered and where the gaps are.

**Topological ordering** (Kahn's algorithm). Used by `buildDeletionScopes` to iterate structural nodes roots-first, ensuring that root bind-inner deletions eliminate downstream subtrees before they are targeted individually. This is the standard prerequisite for any DAG algorithm.

**Bind-inner topology extraction** (`bindInnerTopology()`). Filters the topological order to bind-inner nodes only, restricting dependency edges to other bind-inner nodes. Used by `ProductSpaceBatchEncoder` to classify axes as independent (Cartesian product enumeration) or dependent (per-upstream-value domain ladders via `computeDependentDomains`).

**Leaf position collection** (`collectLeafPositions`). Identifies value positions not inside any structural node's range. These are the free coordinates within each fibre — the targets for Phase 2 value minimisation.

**Brute-force pair composition** (`MutationPool`). After the sequential deletion loop exhausts without accepting, collects up to 20 individual deletion candidates and tests all C(20, 2) disjoint pairs. This is the composition law (§4.1) applied by enumeration rather than by graph structure.

**What is missing.** The DAG provides topological order but does not expose its **width** (maximum antichain size), its **transitive reduction** (minimal edge set), or any **weighted prioritisation** of nodes. The `MutationPool` composes pairs but does not know which pairs are structurally guaranteed to be independent — it uses geometric disjointness (span ranges don't overlap) rather than graph-theoretic independence (no dependency path). And the composition is capped at k = 2, so k-way joint deletions for k > 2 cannot be discovered.

---

## 3. Why k > 2 Compositions Matter

### 3.1 Zip is the antichain factory

The most common generator composition pattern — building a struct from independent field generators — produces antichains by construction:

```swift
let user = Gen.zip(
    gen.string(),                    // name      — independent subtree
    gen.int(in: 18...99),           // age       — independent subtree
    Gen.optional(gen.email()),       // email     — independent subtree
    Gen.optional(gen.phone()),       // phone     — independent subtree
    Gen.optional(gen.address()),     // address   — independent subtree
    gen.bool(),                      // isActive  — independent subtree
    Gen.optional(gen.date()),        // createdAt — independent subtree
    Gen.optional(gen.string())       // bio       — independent subtree
) { name, age, email, phone, address, isActive, createdAt, bio in
    User(name: name, age: age, email: email, phone: phone,
         address: address, isActive: isActive, createdAt: createdAt, bio: bio)
}
```

The `ChoiceDependencyGraph` for this generator has 8 independent subtrees hanging off the zip node. No edges between them. They form a maximum antichain of size 8. Each subtree's span can be deleted without structurally affecting any other.

This is not a contrived example. It is the default pattern for generating any struct, record, or configuration object. A realistic model type — an API request, a database row, a UI component's props — routinely zips 8-20 field generators. Every `Gen.zip` produces an antichain whose size equals the number of arguments.

### 3.2 Properties couple fields conjunctively

The k-way composition problem arises when the property's failure depends on the simultaneous *absence* of multiple independent features:

**Redundant safety mechanisms.** The property crashes when all error-handling paths are removed — no timeout, no retries, no fallback. Any single mechanism prevents the crash. k = (number of mechanisms).

**Cross-field validation.** The property detects invalid state when multiple validation constraints are simultaneously absent. Each constraint independently catches the invalid input. k = (number of independent validators).

**Threshold logic.** The property fails when fewer than m of n optional features are present. Deleting any (n - m) features leaves m present — still valid. Deleting (n - m + 1) drops below the threshold. k = n - m + 1.

### 3.3 The reduction quality impact

Without k-way composition, the reduced counterexample retains spans that are jointly removable but individually necessary. The user sees a "minimal" test case with multiple optional fields populated and cannot determine which are relevant to the failure.

With k-way composition, the reducer removes all jointly-deletable spans in a single step. The counterexample is structurally smaller, and the remaining spans are the ones the property genuinely requires. The difference is between a confusing counterexample and a clear one.

### 3.4 The cycle savings

The primary benefit is not probe cost per cycle but **cycles saved**. A k-way composition discovered in one cycle would have required ceil(k/2) cycles under pair enumeration (accepting one pair per cycle, restarting each time). Each saved cycle eliminates a full base descent + fibre descent pass.

For the typical case — 8-field struct, k = 4 deletable fields — pair enumeration requires 2 cycles of base + fibre descent. The antichain search finds all 4 in a single cycle. The saved cycle is a full traversal of the entire pipeline, not just the MutationPool activation cost.

---

## 4. Antichain Decomposition and Delta-Debugging

### 4.1 The theorem (Dilworth)

In any finite partially ordered set, the minimum number of chains (totally ordered subsets) needed to cover all elements equals the maximum antichain size (the largest set of mutually incomparable elements). Equivalently: minimum path cover = maximum antichain.

The maximum antichain of the ChoiceDependencyGraph is the largest set of structural nodes with no directed path between any pair. Their deletions are unconditionally independent: applying them simultaneously is the pushout (join in the structural inclusion poset), and the result is the smallest structure consistent with all of them having been applied.

### 4.2 Antichain computation

Two candidates are independent if neither is an ancestor/descendant of the other in the DAG — their dependency closures in the CDG are disjoint. The current `MutationPool` checks disjointness by range overlap (whether span ranges intersect positionally). The CDG-based check is more precise: two spans can be positionally disjoint but dependency-linked (a bind-inner at position 5 controls structure at position 50).

**Greedy vs maximum.** The maximum antichain can be computed via bipartite matching on the reachability graph (Hopcroft-Karp, O(E√V)). For the MutationPool's purposes, a **greedy maximal** antichain — iteratively select spans with no dependency edges to already-selected spans — is likely sufficient. The greedy approach is O(n² × pathCheck) where n ≤ 20 and pathCheck is a BFS on the CDG. The gap between greedy and maximum antichain sizes is an empirical question (see Section 9, open question 1).

For either approach, the transitive closure of a 20-node DAG costs O(V³) = O(8000) — sub-microsecond. The computation is dominated by the cost of a single property evaluation by orders of magnitude.

### 4.3 Delta-debugging over the antichain

Instead of enumerating all pairs, apply Zeller-style delta debugging to the antichain. The algorithm finds the maximal subset of the antichain whose joint deletion preserves the property failure.

```
findMaximalDeletableSubset(antichain, property):
    // Phase 1: find a failing subset by binary narrowing
    if property(compose(antichain)) fails:
        return antichain  // all spans jointly deletable

    if |antichain| == 1:
        return nil  // single span, already rejected individually

    split antichain into halves L, R
    leftResult  = findMaximalDeletableSubset(L, property)
    rightResult = findMaximalDeletableSubset(R, property)

    // Phase 2: take the larger successful subset, greedily extend.
    // The extension iterates antichain \ best — the full complement, not just
    // the unchosen half. This is critical: if leftResult = {A, B} and
    // rightResult = {C}, taking leftResult as best and extending over
    // antichain \ {A, B} tries adding C, D, E, ... — including elements
    // from the right half that the right-side recursion found individually.
    // Without the full-complement iteration, cross-half compositions like
    // {A, B, C} would be missed.
    best = larger of leftResult, rightResult (or either if equal)
    for span in antichain \ best:
        if property(compose(best ∪ {span})) fails:
            best = best ∪ {span}

    return best if non-empty, else nil
```

**Probe complexity.** Phase 1 (binary narrowing): O(n log n) probes. Phase 2 (greedy extension): O(n) probes. Total: O(n log n).

| Antichain size | Pair enumeration probes | Delta-debugging probes | Delta-debugging finds |
|---|---|---|---|
| 4 | C(4,2) = 6 | ~20 | up to k = 4 |
| 8 | C(8,2) = 28 | ~32 | up to k = 8 |
| 12 | C(12,2) = 66 | ~56 | up to k = 12 |
| 15 | C(15,2) = 105 | ~75 | up to k = 15 |
| 20 | C(20,2) = 190 | ~120 | up to k = 20 |

Delta-debugging is cheaper than pair enumeration at antichain sizes above ~7 and strictly more capable at all sizes above 2. Below 7, pair enumeration is cheaper by a small constant. The crossover justifies an `|antichain| > 2` guard — below that, pair enumeration is simpler and costs the same or less.

### 4.4 The non-monotonicity question

Delta debugging's correctness is sometimes stated as depending on a *monotonicity* property. For span deletion, the relevant question is: if deleting spans {A, B, C} preserves the failure, does deleting {A, B} also preserve it?

Not necessarily. The property might require the simultaneous absence of all three — deleting only two leaves the third in place, which prevents the failure. This is the exact k-way coupling the search targets.

Delta debugging handles this correctly. It does not assume monotonicity of the *failure* with respect to subset size. It assumes monotonicity of the *complement* — that the subset of spans that *cannot* be deleted is consistent. Concretely, what "consistent" means here is that the property oracle is a deterministic function of the full candidate sequence: the same subset of deleted spans, composed via `removeSubranges`, always produces the same candidate, and that candidate always produces the same test result. This is Zeller's "unambiguous" condition — the interestingness test never returns different results for the same input depending on context. The property oracle satisfies this by construction (deterministic guided materialisation + deterministic property evaluation on a fixed candidate). The binary narrowing phase finds a failing subset. The greedy extension phase grows it. Non-monotonicity in the failure direction causes the binary narrowing to take O(n²) rather than O(n log n) in the worst case, but the algorithm still terminates correctly because each probe is deterministic.

### 4.5 What the search can and cannot find

**Can find:** any k-way composition of structurally independent span deletions where the joint deletion preserves the property failure. Examples: 4 optional safety mechanisms all must be removed to trigger a crash (k = 4); 6 of 10 optional struct fields are jointly removable (k = 6); all 8 fields of a zipped generator are removable — found in the first probe.

**Cannot find:** compositions involving dependency-linked spans (correctly excluded from the antichain — these need the coordinated handling of the edge encoder). Also cannot find compositions where the property couples independent spans non-monotonically in the complement direction (deleting {A,B,C} works, {A,B,C,D} doesn't, {A,B,C,D,E} works again). This is a theoretical limitation; in practice, property failure sets are almost always downward-closed with respect to span deletion.

**Value opacity.** The antichain search uses the current value assignment (via guided materialisation) to test each proposed composition. If the composition succeeds only with specific values that the materialiser doesn't produce, the search misses it. This is the same opacity wall that affects all of base descent — the antichain search doesn't make it worse or better.

---

## 5. Integration: CDG-Driven Antichain Composition

### 5.1 Why the CDG is the primary data source, not the MutationPool

The antichain operates on **CDG nodes**, not on MutationPool entries. The CDG and the span cache answer different questions:

- **CDG**: "which structural nodes are independent?" — a property of the generator's topology, stable across span categories. Two zip children are independent regardless of whether you are deleting container spans, sequence elements, or free-standing values within their subtrees.
- **Span cache**: "what concrete spans exist within a given scope?" — what `spanCache.deletionTargets(category:inRange:from:)` provides for each position range.

The current `MutationPool.collect` iterates all (scope, slot) pairs and builds one candidate per pair. Multiple candidates can map to the **same CDG node** — for example, `containerSpans`, `sequenceElements`, and `freeStandingValues` within the same bind-inner's scope are three deletion strategies for one structural region. The antichain groups by CDG node, picks the best deletion per node (largest `deletedLength` across all slot categories), and composes across independent nodes.

When the antichain search accepts a k-way composition, it accepts the **specific slot chosen per node** — the slot with the largest `deletedLength` at the time of composition. This is the natural greedy choice, and the antichain independence guarantee means the slot choice for one node cannot affect the validity of another node's slot choice. If a node's second-best slot (fewer deleted positions but perhaps a structurally cleaner deletion) would have composed better with neighbours, the search does not discover this — the slot is fixed per node before composition begins. Open question 4 in Section 12 discusses whether trying multiple slots per node is worth the additional search cost.

This means the antichain search **does not depend on `MutationPool.collect`**. It queries the span cache directly using each CDG node's `scopeRange`. Consequences:

1. The `sequence.count ≤ 500` guard is irrelevant — the antichain's cost depends on the number of CDG nodes (typically < 20), not on sequence length.
2. There is no need to wait for the MutationPool to collect and rank candidates — the antichain can be computed as soon as the sequential adaptive loop exhausts.
3. `MutationPool.composePairs` is retained only for the non-antichain remainder (dependent nodes, or antichains of size ≤ 2).

### 5.2 The current flow

```
Sequential adaptive loop exhausts
→ Guard: sequence.count ≤ 500
→ MutationPool.collect(): gather up to 20 rejected spans per (scope, slot), ranked by deleted length
→ MutationPool.composePairs(): test all disjoint pairs (up to 190)
→ Merge individuals and pairs, sort by total deleted length, test in order
→ First accepted candidate commits
```

### 5.3 The proposed flow

```
Sequential adaptive loop exhausts
→ dag.maximalAntichain(): compute independent node set from CDG (no sequence length guard)
→ For each antichain node: query span cache for best deletion candidate (largest deletedLength across all slots)
→ If |antichain| > 2: delta-debug over antichain to find maximal deletable subset
    → compose the k-way deletion via removeSubranges
    → accept the composite if found
→ If antichain is ≤ 2 or delta-debug finds nothing:
    → Guard: sequence.count ≤ 500
    → MutationPool.collect() + composePairs() as fallback
    → (spans from dependent nodes, or small antichains where pairs suffice)
```

The antichain search runs first and is not gated on sequence length. Pair enumeration is demoted to a fallback for the cases the antichain cannot handle: spans with dependency edges, or antichains too small for delta-debugging to outperform pair testing.

**Fallback deduplication.** When the antichain search fails and the MutationPool fallback activates, the MutationPool may construct pair candidates whose component spans overlap with spans already tested as part of a k-way antichain composition. The k-way composed candidate has a different Zobrist hash from any pair composed from a subset of its spans, so the reject cache does not deduplicate across the two strategies. This means the MutationPool may re-materialise candidates whose component spans were already tested in a larger composition — wasted materialisation, but not wasted property evaluations (the composed sequences differ). This minor inefficiency is not worth fixing unless profiling shows it matters.

### 5.4 Per-node span selection

Each antichain node needs a concrete deletion candidate. For a bind-inner node with `scopeRange = 15...40`, the span cache may offer container spans, sequence elements, and free-standing values within that range. The antichain search picks the candidate with the largest `deletedLength` — the one that removes the most material from the sequence. This is a single span-cache query per node, not the full (scope × slot) iteration that `MutationPool.collect` performs.

If a node has no deletable spans in the cache (all span categories are empty within its scope), it is excluded from the antichain — it contributes nothing to a composition.

### 5.5 Budget allocation

The sequential adaptive loop and the antichain search share the base descent budget (1950 probes per cycle). The sequential loop runs first and consumes whatever it needs. The antichain search runs on the remainder. For an antichain of 8 spans, the delta-debugging search costs ~32 probes — well within any reasonable remaining budget. The maximum cost is ~120 probes (antichain of 20), regardless of generator structure.

### 5.6 Relationship to other reducer components

**Edge encoder.** The edge encoder traverses bind edges (vertical dependencies). The antichain search composes across independence (horizontal independence). They address orthogonal parts of the CDG. A generator that zips bind chains has both antichains (between the chains) and chains (within each chain). The two strategies handle their respective structure without interference.

**Convergence cache.** Operates in fibre descent. The antichain search operates in base descent. They interact only through the shared invalidation trigger: a structural acceptance from the antichain search clears the convergence cache.

**Structural probing.** If implemented, structural probing would classify spans as necessary/unnecessary/indeterminate. The antichain search could consume these classifications to pre-filter: exclude structurally necessary nodes from the antichain, reducing delta-debugging cost.

### 5.7 Post-acceptance landscape

When the antichain search accepts a k-way composition, the acceptance calls `accept(result, structureChanged: true)`, which triggers the standard structural-acceptance path: `branchTreeDirty` is set to `true` (ReductionState.swift:205), `spanCache` and `convergenceCache` are invalidated, and `bindIndex` is rebuilt from the new sequence. The caller returns `true` from `runStructuralDeletion`, and the Phase 1 loop restarts from Phase 1a (branch simplification).

The DAG is rebuilt on the next `runStructuralDeletion` entry via `rebuildDAGIfNeeded()`. A k-way acceptance that removed multiple independent subtrees produces a substantially different DAG: the deleted nodes are gone, their dependents (if any) may now be roots, and new antichains may exist among the survivors. Whether a second antichain search is productive on the rebuilt DAG depends on whether the sequential adaptive loop exhausts again — if the simpler DAG allows individual deletions to succeed, the adaptive loop handles them and the antichain search never activates. The antichain search is most valuable on the *first* pass of a complex generator (where the full zip structure is intact and many independent subtrees exist), and less valuable on subsequent passes (where the survivors are typically the structurally necessary fields that resist both individual and composed deletion).

The `branchTreeDirty` flag is set automatically by `accept()` — no special handling is needed for k-way deletions. The next Phase 1a pass re-materialises the tree with picks, allowing branch encoders to see the post-deletion topology. A k-way deletion that removes multiple independent subtrees may create new branch simplification opportunities (for example, a pick site that previously had content in its selected branch may now have an empty selected branch, enabling branch promotion). These opportunities are discovered by the standard Phase 1a restart, not by any special post-antichain logic.

---

## 6. Transitive Reduction

**What it is.** The transitive reduction of a DAG is the smallest subgraph with the same reachability relation. Edge (A, C) is removed if there exists a path A → B → C through an intermediate node.

**How it maps.** The current edge construction in `ChoiceDependencyGraph.build` (lines 133-179) adds edges from every structural node to every structural node whose `positionRange` overlaps its `scopeRange` (for bind-inner nodes) or is contained within its `scopeRange` (for branch selectors). For a three-level nested bind where A has scope 10...50, B sits at position 20 with scope 25...45, and C sits at position 30: A's scope overlaps both B's position and C's position, creating edges A→B and A→C. B's scope overlaps C's position, creating B→C. The transitive edge A→C is present in the current implementation — this is not hypothetical.

The shortcut is semantically redundant — A controls C only because A controls B and B controls C — but its presence has two concrete effects:

1. **Coarser product-space enumeration.** `bindInnerTopology()` reports C's `dependsOn` list as `[A, B]`. The `ProductSpaceBatchEncoder` then computes C's domain ladder from A's value (the first in the dependency list), not B's. Since B's value constrains C's domain more tightly than A's does, the ladder computed from A is wider — the product space is larger — and more evaluations are spent testing candidates that B's domain would have ruled out.

2. **Duplicate deletion targets.** `buildDeletionScopes` creates a scope for A covering its entire bound range (which includes B and C's ranges). It also creates scopes for B and C. A's scope already covers everything B and C's scopes cover, so the deletion encoders running on B and C's scopes are partially redundant work. The span cache and reject cache filter most of this, but the cache lookups and encoder invocations still cost time.

**What it would improve.** After transitive reduction, `bindInnerTopology()` reports C's `dependsOn` as `[B]` only. The product-space encoder computes C's domain ladder from B's value — the immediate parent — giving a tighter domain. For a three-level nested bind where each level has an 8-element ladder, the product space shrinks from 8 × 8 × 8 = 512 (when C depends on both A and B) to 8 × 8 = 64 (when C depends only on B, with B's value already fixed during enumeration). This is an 8x reduction in Phase 1c candidates.

**Computational cost.** O(V · E) for a DAG: for each edge (u, v), check whether v is reachable from u via another path. For V = 20, E = O(20): negligible. Applied as a post-processing step in `ChoiceDependencyGraph.build` after edge construction and before topological sort.

---

## 7. Critical Path Prioritisation

**What it is.** Weight each node by its "structural impact" — the number of positions it controls (`scopeRange.count`). The critical path is the longest weighted path from any source to any sink in the DAG.

**How it maps.** When `buildDeletionScopes` iterates the topological order and multiple independent roots exist (the antichain at level 0), the order among those roots is currently determined by their position in the `topologicalOrder` array, which is an artefact of Kahn's algorithm's queue order — essentially arbitrary. The critical path determines which root to try first: the one whose reduction cascades into the most downstream positions.

**Why it matters.** Phase 1b restarts from Phase 1a on every structural acceptance. The first accepted deletion triggers a DAG rebuild and a full restart of the sub-phase loop. If that first acceptance removes 40 positions (a high-impact root), the restarted loop operates on a sequence that is 40 entries shorter — all downstream deletions that were in the root's subtree are eliminated. If the first acceptance removes 3 positions (a low-impact leaf), the restart saves almost nothing.

**Computational cost.** O(V + E) dynamic programming on the topological sort: for each node in reverse topological order, compute the maximum weighted path to any descendant. The critical path is the node with the maximum total. Negligible cost.

**Evaluation savings.** This is an ordering heuristic, not a structural improvement. It does not change what is tried, only when. The saving is the difference between hitting the high-impact deletion first (and restarting on a much shorter sequence) versus hitting it later (after wasting budget on low-impact attempts). In the worst case, no saving; in the best case, the entire Phase 1b budget is applied to a sequence that is already substantially reduced.

---

## 8. Conditionally Useful Algorithms

### 8.1 Minimum Path Cover

By Dilworth's theorem, the minimum number of directed paths needed to cover all nodes equals the maximum antichain size. This is free from the antichain computation in Section 4.

The minimum path cover tells you the inherent parallelism of the DAG: how many independent chains of dependent structural reductions exist. Each chain must be processed sequentially (upstream before downstream), but chains can be interleaved freely.

**Limitation in the antichain context.** An antichain has at most one member per chain (by definition — two members of the same chain have a dependency path between them). This means "partition the antichain into chains and delta-debug each separately" degenerates to testing each antichain member individually, which is what the sequential adaptive loop already did before the antichain search activated. The minimum path cover does not add information beyond what the antichain already provides for the delta-debugging application.

The minimum path cover would be relevant for **dependency-aware composition** — composing deletions *within* chains, where upstream-before-downstream ordering matters. This is the domain of the edge encoder, not the antichain search. It may have value as metadata for calibrating the edge encoder's traversal strategy, but that is a separate proposal.

### 8.2 Factor Graph / Junction Tree

The fibred structure is a conditional independence structure. Two leaf ranges under different structural parents are conditionally independent given those parents. Making this explicit as a factor graph — with structural nodes as variable nodes and leaf ranges as factor nodes — would enable joint value reduction across independent leaf ranges (the fibre-level analog of the antichain search for structural deletions).

**Practical limitation.** Phase 2 already exploits conditional independence implicitly: each leaf range gets its own value encoders, and the sequential per-range pass cannot interact with independent ranges. Given that Phase 2 evaluations are typically cheap (fixed structure, no materialisation), the implementation complexity outweighs the savings.

---

## 9. Algorithms Not Worth Pursuing

| Algorithm | Why not |
|-----------|---------|
| **Dominator trees** | Redundant. The generator's nesting guarantees that scope ranges form a **laminar family** — for any two nodes, their scopes are either disjoint or one strictly contains the other. In a laminar family, the containment relationship is a tree, and that tree *is* the dominator tree. The DAG already encodes it via `scopeRange`. Dominator trees would add value only if the architecture ever allowed cross-cutting structural dependencies (overlapping but non-nested scopes), which `_bind` and `pick` cannot produce. |
| **Treewidth** | The DAG is already a near-tree (treewidth 1-3 in practice). Bounded treewidth makes NP-hard problems tractable, but no subproblem in the Bonsai pipeline is NP-hard. The bottleneck is property evaluation, not graph computation. |
| **Network flow / min-cut** | "Most impactful structural reduction" is just the root with the largest scope range — an O(V) scan. Min-cut machinery is designed for dense graphs with non-obvious bottlenecks; the DAG is sparse and tree-like. |
| **Elimination orderings** | Zero fill-in for tree-like structures; the natural topological ordering is already optimal. Relevant for dense constraint graphs, not the sparse structures arising from generator nesting. |
| **Graph coloring** | Subsumed by the antichain. The maximum antichain *is* the maximum independent set with respect to the reachability relation. Computing a full graph coloring yields the antichain as a byproduct but produces no additional useful information. |

---

## 10. Relationship to the Fibration Structure

The graph-theoretic framing and the categorical framing from `bonsai-fibred-minimisation.md` describe the same structure from different angles.

**The antichain is the product decomposition of the base.** The maximum antichain identifies the structural positions that are mutually independent — their reductions can be applied in any order and composed freely. In fibration terms, the base morphism factors as a product of independent morphisms, one per antichain element. The pushout law (§4.1) is the categorical statement of this factorisation; the antichain decomposition is its graph-theoretic computation.

**The composition law at arbitrary arity.** The fibration document (Section 4.1) invokes the composition law for pairs: if f is cartesian over g and f' is cartesian over g', then f ∘ f' is cartesian over g ∘ g'. This extends to arbitrary finite compositions by induction. The k-way composition of k cartesian morphisms is cartesian over the k-way pushout in the base. The antichain guarantee (no dependency paths between members) means the composite lift is the product of the individual lifts — no interaction between the cartesian lifts. For spans *with* dependency edges, the cartesian lift of the joint deletion may differ from the product of the individual lifts, because one deletion's structural change affects the other's fibre. These compositions require coordinated materialisation, not independent composition.

**The transitive reduction is the Hasse diagram of the base poset.** The fibration doc treats the set of trace structures as a poset under structural inclusion. The transitive reduction of the ChoiceDependencyGraph is the Hasse diagram of this poset restricted to the structural nodes. It makes the minimal dependency structure explicit, which is what the `ProductSpaceBatchEncoder` needs: the immediate-parent relationship in the Kleisli tower, not the full reachability relation.

**The critical path is the longest chain in the base poset.** By Mirsky's theorem (the dual of Dilworth's), the minimum number of antichains needed to cover the poset equals the longest chain length. The critical path identifies this longest chain — the sequence of structural reductions that must be applied sequentially because each depends on its predecessor. The chain length is a lower bound on the number of structural reduction cycles needed to fully reduce the base.

**The minimum path cover is the Kleisli tower count.** Each path in the minimum cover corresponds to a maximal chain of dependent binds — one Kleisli tower. The number of paths equals the number of independent towers, which is the maximum antichain size (Dilworth). This connects the graph decomposition to the Kleisli tower analysis in §5 of the fibration doc.

**The Sepúlveda-Jiménez framework.** In the reduction algebra, each span deletion is a morphism in OptRed. The k-way composition is a k-fold composite morphism. Grade composition applies: the composite's grade is the minimum of the individual grades. Since all antichain members are tested with the same decoder (guided materialiser), the composite's grade is the guided grade. The 2-cell dominance relation is unaffected — the antichain changes how many individual deletions are composed into a single reduction step, not which encoders dominate which.

---

## 11. Implementation Plan

### 11.1 Phase 0: Instrumentation

Before building the delta-debugging loop, measure whether k > 2 compositions exist in practice.

After the sequential adaptive loop exhausts: compute the antichain from the CDG, query the span cache for each antichain node's best deletion candidate, and try the full-antichain deletion (one probe). Log the result: antichain size, whether the full deletion succeeded, and the implied k.

**Decision criteria:**
- `full_antichain_success_rate > 0.1` — k = |antichain| compositions are common. Build the delta-debugging loop; many cases will be resolved by the first probe.
- `full_antichain_success_rate ≈ 0` but `antichain_size` consistently > 4 — compositions may exist at intermediate k. Build the delta-debugging loop.
- `antichain_size` consistently ≤ 2 — pair enumeration is sufficient. Stop here.

**Cost:** One extra materialisation + property invocation per stalled Phase 1b activation. Negligible.

### 11.2 Reachability and antichain on the CDG

Add a precomputed reachability matrix to `ChoiceDependencyGraph`, computed during `build()` after edge construction. Iterate in reverse topological order, propagating reachability sets from dependents upward. O(V²) space, O(V·E) time.

New method:

```swift
/// Returns a maximal antichain — a set of node indices with no directed path
/// between any pair, to which no further node can be added without violating
/// independence.
///
/// Uses greedy construction: iterate nodes by `scopeRange.count` descending
/// (largest scopes first), add to antichain if independent of all existing
/// members. This produces a maximal antichain (no node can be added), but not
/// necessarily the *maximum* antichain (largest possible). The true maximum
/// requires bipartite matching (Dilworth / Hopcroft-Karp) and can be added
/// later if the greedy-vs-maximum gap matters empirically — see Section 12,
/// question 1.
func maximalAntichain() -> [Int]
```

**File:** `Sources/ExhaustCore/Interpreters/Reduction/ChoiceDependencyGraph.swift`

### 11.3 Per-node span selection

New helper that populates each antichain node with a concrete deletion candidate:

```swift
/// For each antichain node index, queries the span cache for the best
/// deletion candidate across all slot categories within the node's scopeRange.
/// Returns (nodeIndex, spans, deletedLength) tuples, excluding nodes with
/// no deletable spans.
func collectAntichainCandidates(
    antichainNodes: [Int],
    dag: ChoiceDependencyGraph,
    spanCache: inout SpanCache,
    slots: [ReductionScheduler.DeletionEncoderSlot],
    sequence: ChoiceSequence
) -> [(nodeIndex: Int, spans: [ChoiceSpan], deletedLength: Int)]
```

For each antichain node, iterates `slots` and calls `spanCache.deletionTargets(category:inRange:from:)` with the node's `scopeRange`. Picks the slot with the largest total span length. Nodes with no spans in any slot are dropped.

**File:** `Sources/ExhaustCore/Interpreters/Reduction/ReductionState+Bonsai.swift` (private helper)

### 11.4 Delta-debugging loop

```swift
/// Finds the maximal subset of the antichain whose joint deletion preserves
/// the property failure. Binary-splits the antichain, recurses into both
/// halves, takes the larger successful subset, then greedily extends it
/// over the full complement (not just the unchosen half — see Section 4.3).
///
/// - Complexity: O(*n* log *n*) property evaluations where *n* is the antichain size.
func findMaximalDeletableSubset(
    candidates: [AntichainCandidate],
    compose: ([[ChoiceSpan]]) -> ChoiceSequence,
    test: (ChoiceSequence) throws -> AcceptResult?,
    budget: inout ReductionScheduler.LegBudget
) throws -> [AntichainCandidate]?
```

The `compose` closure takes `[[ChoiceSpan]]` — one span array per candidate — unions all span ranges into a `RangeSet`, and applies `removeSubranges`. The caller passes `candidates.map(\.spans)` into `compose`; the full `AntichainCandidate` tuples (with `nodeIndex` and `deletedLength`) are only needed for the return value, so the caller knows which nodes were in the accepted subset. The `test` closure uses `speculativeDecoder.decode(candidate:gen:tree:originalSequence:property:)` — same as the existing MutationPool test path.

**File:** new file or `ReductionState+Bonsai.swift`

### 11.5 Integration into `runStructuralDeletion`

After the sequential adaptive loop exhausts (line ~250 in `ReductionState+Bonsai.swift`), replace the MutationPool block:

1. `dag.maximalAntichain()` — no sequence length guard.
2. `collectAntichainCandidates(...)` — one span-cache query per node.
3. If `|candidates| > 2`: run `findMaximalDeletableSubset`.
4. If accepted: `accept(result, structureChanged: true)`, return `true`.
5. If antichain is ≤ 2 or delta-debug finds nothing: fall back to `MutationPool.collect` + `composePairs` on the remaining budget (gated by `sequence.count ≤ 500` as before).

**File:** `Sources/ExhaustCore/Interpreters/Reduction/ReductionState+Bonsai.swift` (lines ~252-308)

### 11.6 Estimated sizes

| Component | Lines | New/Modified |
|---|---|---|
| Reachability matrix in CDG | ~25 | New in `ChoiceDependencyGraph.swift` |
| `maximalAntichain()` | ~25 | New in `ChoiceDependencyGraph.swift` |
| `collectAntichainCandidates` | ~30 | New in `ReductionState+Bonsai.swift` |
| `findMaximalDeletableSubset` | ~55 | New function |
| Integration in Phase 1b | ~25 | Modified in `ReductionState+Bonsai.swift` |
| Instrumentation | ~15 | Modified |
| **Total** | **~175** | |

---

## 12. Open Questions

1. **Greedy vs Dilworth.** The greedy antichain construction produces a maximal antichain but not necessarily the *maximum* antichain. If the greedy construction misses nodes that could have been in a larger antichain, those nodes' spans are invisible to the delta-debugging search (though they may still be found by the pair enumeration fallback). Measuring the gap between greedy and maximum antichain sizes across the test suite would quantify whether this matters.

2. **Ordering within the antichain.** The delta-debugging binary split is sensitive to the ordering of the antichain. If the deletable subset is {A, B, C, D} and the antichain is ordered [A, C, E, B, D, F, G, H], the split separates deletable members across both halves, requiring more probes to reconstruct the subset. Two ordering strategies are worth instrumenting. **By `deletedLength` descending**: biases the split toward placing high-impact nodes in the same half, maximising material removed by the first successful probe. **By structural depth ascending** (shallowest nodes first): places root-level nodes in the first half of the split, so the first recursive call tests high-impact root deletions that remove entire subtrees (potentially including the deeper nodes). This biases toward finding the highest-impact subset first, reducing the average probe count for the greedy extension phase. Whether depth or weight is the better criterion is empirical — both are cheap to compute (depth from `bindIndex.bindDepth`, weight from `scopeRange.count`).

3. **Interaction with structural probing.** Structural probing classifies spans as necessary, unnecessary, or indeterminate. The antichain search could consume these classifications to pre-filter: exclude structurally necessary nodes from the antichain, reducing delta-debugging cost.

4. **Slot selection per node.** The current design picks the slot with the largest `deletedLength` per node. An alternative: try multiple slots per node (the top 2-3 by `deletedLength`) as separate antichain candidates in the delta-debugging search. This increases the search space but may find compositions where the best slot per node is not the one that composes well with neighbours. Whether this matters depends on how often different slot categories produce different composition outcomes — likely rare, since the antichain independence is structural and slot-independent.

---

## 13. Summary

The ChoiceDependencyGraph already encodes the structural decomposition needed for efficient reduction. Three graph algorithms would extract more information from it at negligible computational cost:

| Algorithm | What it provides | Primary beneficiary |
|-----------|-----------------|-------------------|
| Antichain decomposition | Maximal independent set of structural nodes | `MutationPool` — replaces brute-force pair enumeration with delta-debugging over antichains |
| Transitive reduction | Minimal edge set (Hasse diagram) | `ProductSpaceBatchEncoder` — tighter per-upstream-value domains |
| Critical path | Weighted longest path | `buildDeletionScopes` — highest-impact deletion attempted first |

The antichain decomposition is the highest-impact change. The primary gain is not per-cycle probe savings but **cycles saved**: a k-way composition discovered in one cycle replaces ceil(k/2) sequential cycles of base + fibre descent. For generators built from `Gen.zip` — the default pattern for any struct — k-way compositions are the common case, not the exception. Every `Gen.zip` produces an antichain whose size equals the number of arguments.

The graph-theoretic and categorical framings are complementary: the antichain is the product decomposition of the base morphism, the transitive reduction is the Hasse diagram of the base poset, and the critical path is the longest chain in the Kleisli tower structure. Each graph algorithm has a categorical counterpart, and each categorical law has a graph-theoretic computation.

Several superficially appealing algorithms — dominator trees, treewidth, network flow, elimination orderings, graph coloring — are either redundant with existing structure, inapplicable to the regime, or subsumed by the antichain.

---

## References

- Dilworth, R. P. (1950). A decomposition theorem for partially ordered sets. *Annals of Mathematics*, 51(1), 161-166.
- Jacobs, B. (1999). *Categorical Logic and Type Theory*. §1.5, Lemma 1.5.5 (composition of cartesian morphisms).
- Mirsky, L. (1971). A dual of Dilworth's decomposition theorem. *The American Mathematical Monthly*, 78(8), 876-877.
- Sepúlveda-Jiménez, A. (2026). Categories of optimization reductions. (Grade composition, 2-cell dominance.)
- Zeller, A. & Hildebrandt, R. (2002). Simplifying and isolating failure-inducing input. *IEEE Trans. Software Eng.*, 28(2), 183-200.
