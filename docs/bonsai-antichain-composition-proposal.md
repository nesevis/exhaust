# Proposal: Antichain-Based Composition for Base Descent

Replacing pair enumeration in MutationPool with delta-debugging over structurally independent span sets, enabling k-way compositions that pair enumeration structurally cannot find.

---

## 1. The Problem

When the sequential adaptive loop in Phase 1b exhausts without accepting any candidate, `MutationPool` collects up to 20 individually-rejected span deletions and tests all disjoint pairs — up to C(20, 2) = 190 compositions. Each pair is a 2-way composition: delete both spans simultaneously, verify the property still fails. If a pair succeeds, the composite deletion is accepted via the pushout law (non-overlapping deletions compose as range-set union).

Pair enumeration is capped at k = 2. A 3-way, 4-way, or 8-way joint deletion — where k spans are jointly deletable but no (k-1)-subset is — cannot be discovered by testing pairs. The reducer must instead find these compositions through sequential restarts: accept a pair, restart, accept another pair, restart, chip away at the deletable set across multiple cycles. Each cycle costs a full base descent + fibre descent pass.

The question is how often k > 2 compositions matter. The answer depends on the generator's structure.

---

## 2. Why k > 2 Is Common

### 2.1 Zip is the antichain factory

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

This is not a contrived example. It is the default pattern for generating any struct, record, or configuration object. A realistic model type — an API request, a database row, a UI component's props — routinely zips 8–20 field generators. Every `Gen.zip` produces an antichain whose size equals the number of arguments.

### 2.2 Properties couple fields conjunctively

The k-way composition problem arises when the property's failure depends on the simultaneous *absence* of multiple independent features. This is common in properties that test defensive programming patterns:

**Redundant safety mechanisms.** The property crashes when all error-handling paths are removed — no timeout, no retries, no fallback. Any single mechanism prevents the crash. k = (number of mechanisms).

**Cross-field validation.** The property detects invalid state when multiple validation constraints are simultaneously absent. Each constraint independently catches the invalid input. k = (number of independent validators).

**Threshold logic.** The property fails when fewer than m of n optional features are present. Deleting any (n - m) features leaves m present — still valid. Deleting (n - m + 1) drops below the threshold. k = n - m + 1.

### 2.3 The reduction quality impact

Without k-way composition, the reduced counterexample retains spans that are jointly removable but individually necessary. The user sees a "minimal" test case with multiple optional fields populated and cannot determine which are relevant to the failure.

With k-way composition, the reducer removes all jointly-deletable spans in a single step. The counterexample is structurally smaller, and the remaining spans are the ones the property genuinely requires. The difference is between a confusing counterexample and a clear one.

---

## 3. The Proposal: Delta-Debugging over Antichains

### 3.1 Antichain computation

Given a set of candidate spans (individually rejected by the sequential adaptive loop), compute the maximum antichain — the largest subset with no dependency path between any pair in the `ChoiceDependencyGraph`.

Two spans are independent if:
- Neither contains a bind-inner value that controls the other's structure.
- Neither is an ancestor/descendant of the other in the DAG.
- Their dependency closures in the CDG are disjoint.

The current MutationPool checks disjointness by range overlap — whether span ranges intersect positionally. The CDG-based check is more precise: two spans can be positionally disjoint but dependency-linked (a bind-inner at position 5 controls structure at position 50). The CDG check replaces the geometric approximation with a structural one.

For the maximum antichain (Dilworth's theorem), compute the minimum chain cover via bipartite matching — O(n^2.5) via Hopcroft-Karp. For 20 candidates, this is trivial. In practice, a simpler greedy approach (iteratively select spans with no dependency edges to already-selected spans) produces a near-maximum antichain and is sufficient for the delta-debugging application.

### 3.2 Delta-debugging over the antichain

Instead of enumerating all pairs, apply Zeller-style delta debugging to the antichain. The algorithm finds the maximal subset of the antichain whose joint deletion preserves the property failure.

```
findMaximalDeletableSubset(antichain, property):
    // Phase 1: find a minimal failing subset by binary narrowing
    if property(compose(antichain)) fails:
        return antichain  // all spans jointly deletable
    
    if |antichain| == 1:
        return nil  // single span, already rejected individually
    
    split antichain into halves L, R
    leftResult  = findMaximalDeletableSubset(L, property)
    rightResult = findMaximalDeletableSubset(R, property)
    
    // Phase 2: take the larger successful subset, greedily extend
    best = larger of leftResult, rightResult (or either if equal)
    for span in antichain \ best:
        if property(compose(best ∪ {span})) fails:
            best = best ∪ {span}
    
    return best if non-empty, else nil
```

**Probe complexity.** Phase 1 (binary narrowing): O(n log n) probes. Phase 2 (greedy extension): O(n) probes. Total: O(n log n). For an antichain of 15 spans: roughly 75 probes. For 8 spans: roughly 32 probes.

**Comparison with pair enumeration.** For an antichain of size 8: delta-debugging costs ~32 probes and can find any k ≤ 8. Pair enumeration costs C(8, 2) = 28 probes and can only find k = 2. For size 15: delta-debugging costs ~75 probes, pair enumeration costs C(15, 2) = 105 probes. Delta-debugging is both cheaper and more capable at antichain sizes above ~7.

### 3.3 Composition via the pushout law

The joint deletion of k antichain members is computed exactly as the MutationPool already computes pair deletions: collect the ranges from all k spans, union them into a `RangeSet`, and apply `removeSubranges`. The pushout law (Jacobs 1999, §1.5; the fibration document Section 4.1) guarantees correctness: the composite of k non-overlapping cartesian morphisms is cartesian. No new composition machinery is needed.

The antichain guarantee (no dependency paths between members) is strictly stronger than the current disjointness check (no range overlap). Disjoint ranges can still have dependency edges; antichain members cannot. This means the antichain-based composition is more principled than the current pair composition — it guarantees not just that the range deletions don't interfere geometrically, but that the structural reductions don't interfere in the fibration.

---

## 4. Integration: Replacing Pair Enumeration

### 4.1 The MutationPool flow, current

```
Sequential adaptive loop exhausts
→ MutationPool.collect(): gather up to 20 rejected spans, ranked by deleted length
→ MutationPool.composePairs(): test all disjoint pairs (up to 190)
→ Merge individuals and pairs, sort by total deleted length, test in order
→ First accepted candidate commits
```

### 4.2 The MutationPool flow, proposed

```
Sequential adaptive loop exhausts
→ MutationPool.collect(): gather up to 20 rejected spans, ranked by deleted length
→ computeAntichain(): filter to maximum independent set via CDG
→ If |antichain| ≤ 2: fall back to pair enumeration (existing behaviour)
→ If |antichain| > 2: delta-debug over antichain to find maximal deletable subset
→ If delta-debugging finds a subset of size k:
    → compose the k-way deletion via removeSubranges
    → accept the composite
→ If delta-debugging finds nothing:
    → fall back to pair enumeration on the non-antichain spans
    → (spans excluded from the antichain due to dependency edges
       may still form valid pairs with other excluded spans)
```

The antichain search replaces pair enumeration for the common case (large antichains from zipped generators). Pair enumeration remains as a fallback for spans that have dependency edges and therefore can't join the antichain. The transition is seamless: at antichain size 2, delta-debugging degenerates to testing one pair, which is what pair enumeration would have tried first anyway.

### 4.3 Budget allocation

The sequential adaptive loop and the antichain search share the base descent budget (1950 probes per cycle). The sequential loop runs first and consumes whatever it needs. The antichain search runs on the remainder.

For an antichain of 8 spans, the delta-debugging search costs ~32 probes — well within any reasonable remaining budget. For an antichain of 20 spans, ~120 probes. The search is bounded by O(n log n) where n ≤ 20 (the existing collection limit), so the maximum cost is ~120 probes regardless of generator structure.

No budget increase is needed. The antichain search is cheaper than pair enumeration at antichain sizes above ~7, and roughly comparable below that.

### 4.4 Interaction with the sequence length guard

The MutationPool is currently capped at `sequence.count ≤ 500` to bound span-cache traversal cost. This guard applies to the collection phase, not the composition strategy. The antichain search operates on already-collected spans (up to 20), so the guard is unaffected.

---

## 5. What the Antichain Search Can and Cannot Find

### 5.1 What it can find

**Any k-way composition of structurally independent span deletions**, where the joint deletion preserves the property failure but no (k-1)-subset does. The delta-debugging algorithm converges on the maximal deletable subset — the largest set of antichain members that can be jointly removed while the property still fails.

Examples:
- 4 optional safety mechanisms, all must be removed to trigger a crash. k = 4. Pair enumeration cannot find this. The antichain search finds it in ~24 probes.
- 6 of 10 optional struct fields are jointly removable. k = 6. The antichain search finds the 6-element subset in ~50 probes.
- All 8 fields of a zipped generator are removable (the failure is purely structural, not value-dependent). k = 8. The antichain search finds this in its first probe (try all 8, property fails, accept).

### 5.2 What it cannot find

**Compositions involving dependency-linked spans.** If span A contains a bind-inner value that controls span B's structure, they're not in the antichain. Their joint deletion requires coordinated handling (the edge encoder) rather than independent composition. The antichain search correctly excludes them.

**Compositions where the property couples independent spans non-monotonically.** The delta-debugging algorithm assumes that if a subset S is deletable, then any superset S ∪ {x} is either also deletable or discoverable by greedy extension. If the property has truly adversarial coupling — deleting {A, B, C} works, deleting {A, B, C, D} doesn't, but deleting {A, B, C, D, E} does again — the greedy extension may miss {A, B, C, D, E}. This is a theoretical limitation of delta debugging; in practice, property failure sets are almost always downward-closed with respect to span deletion (removing more structure never *restores* a failure that removing less structure eliminated).

**Value-dependent compositions.** The antichain search uses the current value assignment (via guided materialisation) to test each proposed composition. If the composition succeeds only with specific values that the materialiser doesn't produce, the search misses it. This is the same opacity wall that affects all of base descent — the antichain search doesn't make it worse or better.

### 5.3 The non-monotonicity question

Delta debugging's correctness depends on a property being *monotone* with respect to the input partitioning — if a subset causes failure, every superset also causes failure (or at least, the minimal failing subset is findable by binary search). For span deletion, the relevant monotonicity property is: if deleting spans {A, B, C} preserves the failure, does deleting spans {A, B} also preserve it?

Not necessarily. The property might require the simultaneous absence of all three — deleting only two leaves the third in place, which prevents the failure. This is the exact k-way coupling we're trying to find.

Delta debugging handles this correctly. It doesn't assume monotonicity of the *failure* with respect to subset size. It assumes monotonicity of the *complement* — that the subset of spans that *cannot* be deleted is consistent (if span X is individually necessary given some context, it remains necessary in larger contexts). The binary narrowing phase finds a failing subset. The greedy extension phase grows it. Non-monotonicity in the failure direction causes the binary narrowing to take O(n²) rather than O(n log n), but the algorithm still terminates correctly.

---

## 6. Categorical Interpretation

### 6.1 Antichains in the base poset

The category of trace structures is a poset under structural inclusion: T' ≤ T when T' can be obtained from T by deleting spans. The CDG refines this poset with dependency edges. An antichain in the CDG is a set of base morphisms (span deletions) that are pairwise incomparable — no deletion is "contained in" or "dependent on" any other.

The pushout of k antichain members is their joint deletion — the smallest trace structure at or below all k reduced structures. For non-overlapping independent deletions, this is the structure with all k span sets removed. The pushout exists and is unique because the base is a poset.

### 6.2 The composition law at arbitrary arity

The fibration document (Section 4.1) invokes the composition law for pairs: if f is cartesian over g and f' is cartesian over g', then f ∘ f' is cartesian over g ∘ g'. This extends to arbitrary finite compositions by induction. The k-way composition of k cartesian morphisms is cartesian over the k-way composition of the corresponding base morphisms.

For the antichain, each span deletion is a cartesian morphism (a base change with a canonical lift via the materialiser). The k-way composition is the joint deletion, which is cartesian over the k-way pushout in the base. The composition law guarantees this composite is well-defined and canonical. No new theory is needed — the existing law applies at arbitrary k.

### 6.3 The antichain as the natural scope of composition

Pair enumeration tests compositions within C(n, 2) — the set of all 2-element subsets of the candidate pool. The antichain restricts composition to structurally independent spans, and delta-debugging searches the power set of the antichain efficiently. The antichain is the natural scope because it's the largest set over which the composition law applies without qualification — no dependency edges means no interaction between the cartesian lifts, so the composite lift is the product of the individual lifts.

For spans with dependency edges, composition is not free — the cartesian lift of the joint deletion may differ from the product of the individual lifts, because one deletion's structural change affects the other deletion's fibre. These compositions require the coordinated materialisation that the edge encoder would provide, not the independent composition that the pushout law guarantees.

### 6.4 Relationship to the Sepúlveda-Jiménez framework

In the reduction algebra, each span deletion is a morphism in OptRed. The k-way composition is a k-fold composite morphism. Grade composition applies: the composite's grade is the minimum of the individual grades. Since all antichain members are tested with the same decoder (guided materialiser), the composite's grade is the guided grade — exact if coverage is 1.0, bounded otherwise.

The 2-cell dominance relation within the hom-set is unaffected. The antichain search doesn't change which encoders dominate which — it changes how many individual deletions are composed into a single reduction step. The dominance lattice operates within each encoder; the antichain operates across the results of a single encoder (the structural deletion encoder) applied to different spans.

---

## 7. Cost-Benefit Analysis

### 7.1 Probe cost comparison

| Antichain size | Pair enumeration probes | Delta-debugging probes | Delta-debugging finds |
|---|---|---|---|
| 4 | C(4,2) = 6 | ~20 | up to k = 4 |
| 8 | C(8,2) = 28 | ~32 | up to k = 8 |
| 12 | C(12,2) = 66 | ~56 | up to k = 12 |
| 15 | C(15,2) = 105 | ~75 | up to k = 15 |
| 20 | C(20,2) = 190 | ~120 | up to k = 20 |

Delta-debugging is cheaper than pair enumeration at antichain sizes above ~7 and strictly more capable at all sizes above 2. Below 7, pair enumeration is cheaper by a small constant. The crossover point justifies the `|antichain| > 2` guard in Section 4.2 — below that, pair enumeration is simpler and costs the same or less.

### 7.2 Cycle savings

The primary benefit is not probe cost per cycle but **cycles saved**. A k-way composition discovered in one cycle would have required ⌈k/2⌉ cycles under pair enumeration (accepting one pair per cycle, restarting each time). Each saved cycle eliminates a full base descent + fibre descent pass.

For the typical case — 8-field struct, k = 4 deletable fields:
- Pair enumeration: 2 cycles × (base descent + fibre descent) ≈ 2 × 650ms = 1300ms
- Antichain search: 1 cycle with ~32 probes ≈ 1 probe cost × 32 ≈ 200ms

This is a significant speedup on generators where k > 2 compositions exist.

### 7.3 Worst case

If k = 1 for all spans (every span is individually deletable or individually necessary), the antichain search costs O(n log n) probes to discover what the sequential adaptive loop already found: each span's individual status. The search is pure overhead. The `|antichain| > 2` guard and the positioning after the sequential loop exhausts ensure this overhead only occurs when the sequential loop has already failed to find any individual deletions — meaning the overhead is paid in a context where the reducer is already stuck and needs to try compositions anyway.

If the antichain is empty (all spans have dependency edges — a pure bind chain with no zip), the search doesn't activate. No overhead.

### 7.4 When not to use

- **Pure bind chains** (`a >>= b >>= c >>= d`) — no antichain, no independent spans. The edge encoder is the appropriate tool.
- **Very small antichains** (size ≤ 2) — pair enumeration is simpler and equally capable. The guard catches this.
- **Properties with no k > 2 coupling** — the search discovers only individual deletions or pairs, which the existing pipeline already handles. No harm (the search is cheaper than pair enumeration at size > 7), but no benefit either.

---

## 8. Implementation Plan

### 8.1 Phase 0: Instrumentation

Before building the antichain search, measure whether k > 2 compositions exist in practice.

**Method.** After `MutationPool.composePairs()` exhausts without finding an accepted pair:

1. Compute the antichain from the rejected span pool using the CDG.
2. If `|antichain| > 2`, try the full-antichain deletion (one probe).
3. Log the result: antichain size, whether the full deletion succeeded, and if so, the implied k.

**Data to collect:**
- `antichain_size` — distribution across the test suite. Expect peak at the zip arity of the most common generator pattern.
- `full_antichain_success_rate` — how often does deleting the entire antichain preserve the failure?
- `implied_k` — when full-antichain deletion fails, the maximal deletable subset is somewhere between 0 and |antichain|. Without delta-debugging, the exact k is unknown, but the full-antichain probe gives a binary signal: k = |antichain| or k < |antichain|.

**Decision criteria:**
- If `full_antichain_success_rate > 0.1` — k = |antichain| compositions are common. Build the delta-debugging loop; many cases will be resolved by the first probe (delete everything).
- If `full_antichain_success_rate ≈ 0` but `antichain_size` is consistently > 4 — the compositions may exist at intermediate k. Build the delta-debugging loop to search for them.
- If `antichain_size` is consistently ≤ 2 — generators don't produce antichains large enough to benefit. Pair enumeration is sufficient. Stop here.

**Cost:** One extra materialisation + property invocation per stalled MutationPool activation. Negligible overhead, since the pool only activates when the sequential loop has already exhausted.

### 8.2 Phase 1: Antichain computation

Add a function to compute the antichain from the CDG and the rejected span pool:

```swift
func computeAntichain(
    candidates: [SpanDeletion],
    dag: ChoiceDependencyGraph
) -> [SpanDeletion] {
    var antichain: [SpanDeletion] = []
    
    for candidate in candidates {
        let isIndependent = antichain.allSatisfy { existing in
            !dag.hasPath(from: candidate.scope, to: existing.scope) &&
            !dag.hasPath(from: existing.scope, to: candidate.scope)
        }
        if isIndependent {
            antichain.append(candidate)
        }
    }
    
    return antichain
}
```

This is a greedy construction — it doesn't guarantee the *maximum* antichain (Dilworth's theorem), but it produces a maximal one (no candidate can be added without violating independence). For the MutationPool's purposes, a maximal antichain is sufficient. The greedy approach is O(n² × pathCheck) where n ≤ 20 and pathCheck is a BFS/DFS on the CDG — fast enough for the candidate pool sizes involved.

The `dag.hasPath(from:to:)` query checks reachability in the CDG. If the CDG doesn't currently expose a reachability API, precompute the transitive closure at CDG construction time (O(V × E) for a DAG, where V and E are small) and store it as a boolean matrix or set-of-sets. Alternatively, compute reachability lazily per query via BFS — for 20 candidates and a small DAG, the cost is negligible.

### 8.3 Phase 2: Delta-debugging loop

```swift
func findMaximalDeletableSubset(
    antichain: [SpanDeletion],
    compose: ([SpanDeletion]) -> ChoiceSequence,
    test: (ChoiceSequence) -> Bool,
    budget: inout Int
) -> [SpanDeletion]? {
    guard budget > 0 else { return nil }
    
    // Try the full antichain first — cheapest possible success
    budget -= 1
    if test(compose(antichain)) {
        return antichain
    }
    
    guard antichain.count > 1 else { return nil }
    
    // Binary split and recurse
    let mid = antichain.count / 2
    let left = Array(antichain[..<mid])
    let right = Array(antichain[mid...])
    
    let leftResult = findMaximalDeletableSubset(
        antichain: left, compose: compose, test: test, budget: &budget
    )
    let rightResult = findMaximalDeletableSubset(
        antichain: right, compose: compose, test: test, budget: &budget
    )
    
    // Take the larger successful subset
    var best: [SpanDeletion]
    switch (leftResult, rightResult) {
    case let (l?, r?): best = l.count >= r.count ? l : r
    case let (l?, nil): best = l
    case let (nil, r?): best = r
    case (nil, nil): return nil
    }
    
    // Greedy extension: try adding each remaining span
    let bestSet = Set(best.map(\.id))
    for span in antichain where !bestSet.contains(span.id) {
        guard budget > 0 else { break }
        let extended = best + [span]
        budget -= 1
        if test(compose(extended)) {
            best = extended
        }
    }
    
    return best
}
```

### 8.4 Phase 3: Integration with MutationPool

Replace the pair enumeration call path:

```swift
// In Phase 1b, after sequential adaptive loop exhausts:

let individuals = mutationPool.collect(spanCache: spanCache, limit: 20)

// Compute antichain from CDG
let antichain = computeAntichain(
    candidates: individuals,
    dag: choiceDependencyGraph
)

var accepted = false

if antichain.count > 2 {
    // Delta-debug over antichain
    if let subset = findMaximalDeletableSubset(
        antichain: antichain,
        compose: { spans in composeRangeSet(spans, from: sequence) },
        test: { candidate in propertyFails(candidate) },
        budget: &legBudget
    ) {
        accept(composeRangeSet(subset, from: sequence))
        accepted = true
    }
}

if !accepted {
    // Fall back to pair enumeration for non-antichain spans
    // (spans with dependency edges, or antichain too small)
    let pairs = mutationPool.composePairs(individuals)
    // ... existing pair enumeration logic ...
}
```

### 8.5 Estimated sizes

| Component | Lines | New/Modified |
|---|---|---|
| `computeAntichain` | ~30 | New function |
| `dag.hasPath(from:to:)` or transitive closure | ~20 | New on CDG |
| `findMaximalDeletableSubset` | ~50 | New function |
| Integration in Phase 1b | ~20 | Modified |
| Instrumentation (Phase 0) | ~15 | Modified |
| **Total** | **~135** | |

---

## 9. Open Questions

1. **Greedy vs Dilworth.** The greedy antichain construction produces a maximal antichain (can't add any more members without violating independence) but not necessarily the *maximum* antichain (largest possible). For the MutationPool's purposes, does the distinction matter? If the greedy construction misses 2 spans that could have been in a larger antichain, the delta-debugging search operates on a slightly smaller set. Those 2 spans fall through to pair enumeration. The practical impact depends on whether the missed spans participate in k-way compositions that the smaller antichain can't find. Measuring the gap between greedy and maximum antichain sizes across the test suite would quantify this.

2. **Ordering within the antichain.** The delta-debugging binary split is sensitive to the ordering of the antichain. If the deletable subset is {A, B, C, D} and the antichain is ordered [A, C, E, B, D, F, G, H], the binary split [A, C, E, B] / [D, F, G, H] separates deletable members across both halves, requiring more probes to reconstruct the subset. Ordering the antichain by span weight (deleted length, descending) biases the split toward placing high-impact spans in the same half, which tends to align with the property's coupling structure (high-impact spans are more likely to be jointly deletable because they represent major structural components). Whether the ordering matters enough to tune is an empirical question.

3. **Interaction with structural probing.** The structural probing proposal classifies spans as necessary, unnecessary, or indeterminate. The antichain search could consume these classifications: exclude spans classified as structurally necessary (they won't contribute to any composition) and include only unnecessary + indeterminate spans. This pre-filters the antichain, reducing its size and the delta-debugging cost. The interaction is clean — structural probing runs first (or lazily on first encounter), the antichain search runs after the sequential loop exhausts, and the classifications inform which spans enter the antichain.

4. **Incremental antichain maintenance.** After a structural acceptance, the CDG is rebuilt and the antichain must be recomputed. If structural acceptances are frequent (many successful deletions per cycle), the antichain is recomputed many times. An incremental approach — removing the accepted span from the antichain and checking whether any previously-excluded spans can now join — would avoid full recomputation. But since the antichain search only runs after the sequential loop exhausts (no structural acceptances found), this is likely unnecessary. The antichain is computed once per pool activation.

5. **Parallel composition with edge encoders.** The antichain search handles horizontal independence (spans with no dependency edges). The edge encoder handles vertical dependence (spans connected by bind edges). In principle, both could run in the same exploration phase: the antichain search composes independent span deletions while the edge encoder traverses bind edges. The two strategies operate on disjoint parts of the CDG and don't interfere. Whether running them in parallel (or interleaved) yields better results than running them sequentially depends on how often the CDG has both large antichains and deep bind chains simultaneously — which is the case for generators that zip bind chains.

6. **Relationship to the 500-entry guard.** The MutationPool's activation is currently gated on `sequence.count ≤ 500`. The antichain search has the same O(n log n) cost profile regardless of sequence length (it operates on at most 20 collected spans, not on the sequence directly). The 500-entry guard could be relaxed for the antichain search while keeping it for pair enumeration, since the antichain search's cost is independent of sequence length. This would extend k-way composition to larger generators where pair enumeration is currently disabled.

---

## 10. Relationship to Other Proposals

### MutationPool (existing)

The antichain search is a direct replacement for the pair enumeration phase of MutationPool. The collection phase (gathering up to 20 rejected spans, ranked by deleted length) is unchanged. The composition mechanism (`removeSubranges` on a `RangeSet`) is unchanged. Only the search strategy changes: from exhaustive pair enumeration to delta-debugging over the antichain. Pair enumeration is retained as a fallback for spans excluded from the antichain.

### Structural probing

Structural probing classifies spans as necessary/unnecessary before they enter the pool. The antichain search consumes these classifications to pre-filter its candidate set. The two proposals are complementary: structural probing reduces the search space, the antichain search explores it more efficiently.

### Edge encoder

The edge encoder traverses bind edges (vertical dependencies). The antichain search composes across independence (horizontal independence). They address orthogonal parts of the CDG. A generator that zips bind chains has both antichains (between the chains) and chains (within each chain). The edge encoder and antichain search would each handle their respective structure without interference.

### Convergence cache

The convergence cache operates in fibre descent, caching per-coordinate stall points. The antichain search operates in base descent, composing span deletions. They interact only through the shared invalidation trigger: a structural acceptance from the antichain search clears the convergence cache. No deeper interaction.

---

## References

- Jacobs, B. (1999). *Categorical Logic and Type Theory*. §1.5, Lemma 1.5.5 (composition of cartesian morphisms).
- Zeller, A. & Hildebrandt, R. (2002). Simplifying and isolating failure-inducing input. *IEEE Trans. Software Eng.*, 28(2), 183–200. (Delta debugging.)
- Dilworth, R. P. (1950). A decomposition theorem for partially ordered sets. *Annals of Mathematics*, 51(1), 161–166. (Antichain-chain duality.)
- Sepúlveda-Jiménez, A. (2026). Categories of optimization reductions. (Grade composition, 2-cell dominance.)
