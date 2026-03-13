# Audit: Sepulveda-Jimenez Paper vs. KleisliReducer Implementation

---

## Part I: How the Paper's Framework Maps to Exhaust

### The Paper's Core Objects

The paper defines an **optimization problem** as a costed set `P = (X, c_P)` where `X` is a decision set and `c_P : X → R̄` is an extended-real objective. An **exact reduction morphism** `a : P → Q` is a pair `(enc_a : X → Y, dec_a : Y → X)` satisfying:

```
(1)  c_Q(enc_a(x)) ≤ c_P(x)    for all x ∈ X    (encoding doesn't increase cost)
(2)  c_P(dec_a(y)) ≤ c_Q(y)    for all y ∈ Y    (decoding doesn't increase cost)
```

These form a category **OptRed_ex** with composition `(b ∘ a) = (enc_b ∘ enc_a, dec_a ∘ dec_b)`.

### Exhaust's Instantiation

In Exhaust, the mapping is:

| Paper concept | Exhaust instantiation |
|---|---|
| Decision set `X` | `ChoiceSequence` (the space of all valid choice sequences for a generator) |
| Cost `c_P(x)` | Shortlex rank of `x`. Infeasible points (sequences that produce property-passing outputs) have cost `+∞`. |
| `Feas(P)` | Sequences whose materialized output fails the property |
| `Sol(P)` | The shortlex-minimal feasible sequence(s) |
| `enc_a` | Sequence mutation (delete spans, zero values, binary search, etc.) |
| `dec_a` | Re-materialization: `Interpreters.materialize()` or `GuidedMaterializer.materialize()` |
| Morphism `a : P → Q` | Each tactic is an endomorphism `P → P` (same problem, find a shorter sequence) |

---

## Part II: Correctness Audit — Where Implementation Matches or Diverges

### 1. The Encoding Inequality (Paper Eq. 1)

**Paper requires:** `c_Q(enc(x)) ≤ c_P(x)` — the encoded sequence has cost no greater than the original.

**Implementation:** Every tactic checks `candidate.shortLexPrecedes(sequence)` before accepting a mutation. For purpose-built deletion tactics (e.g., `DeleteContainerSpansTactic:49`), this is an explicit guard. For strategy-wrapping tactics, the underlying `ReducerStrategies` functions enforce this internally.

**Verdict: Correctly implemented.** The shortlex guard is the direct encoding of inequality (1).

### 2. The Decoding Inequality (Paper Eq. 2)

**Paper requires:** `c_P(dec(y)) ≤ c_Q(y)` **for all `y ∈ Y`** — decoding never increases cost.

**Implementation:** This is where the first significant divergence occurs. The paper requires `dec` to be cost-non-increasing *universally*. In Exhaust, `dec` is `GuidedMaterializer.materialize()`, which can produce a sequence *longer* (shortlex-larger) than its input because:
- Bound content is regenerated via PRNG (tier 3) and may be larger
- The fallback tree (tier 2) may supply values from an earlier, less-reduced state

The implementation compensates by checking the **round-trip** against the original:

```swift
// TacticReDerivation.swift:177
guard reDerivedSequence.shortLexPrecedes(originalSequence) else { return nil }
```

and:

```swift
// TacticEvaluation.swift:55
guard reDerivedSequence.shortLexPrecedes(originalSequence) else { return nil }
```

This checks `c_P(dec(enc(x))) ≤ c_P(x)` — the *composition* `dec ∘ enc` is cost-reducing. But it does **not** check `c_P(dec(y)) ≤ c_Q(y)` for `dec` alone.

**Verdict: Divergence, but not a correctness problem for the reducer's behavior.** The round-trip check is sufficient to ensure monotonic progress. However, it means we cannot invoke the paper's Proposition 3.2 (composition closure) to get *free* guarantees about tactic composition. Each composition must be verified empirically rather than derived from the categorical structure.

**Practical consequence:** If `dec` (GuidedMaterializer) could guarantee `shortlex(output) ≤ shortlex(input)`, we could remove the round-trip shortlex guard entirely and rely on the categorical guarantee. We can't, so the guard stays. This is not a bug — it's a weakening of the theoretical framework that the implementation handles pragmatically.

### 3. Feasibility Preservation (Lemma 3.3)

**Paper guarantees:** `enc_a(Feas(P)) ⊆ Feas(Q)` — encoding preserves feasibility.

**Implementation:** Encoding (sequence mutation) does **not** guarantee feasibility. A mutation can produce a sequence whose materialized output *passes* the property (i.e., leaves `Feas`). The implementation checks feasibility *a posteriori*:

```swift
// TacticEvaluation.swift:73
guard property(output) == false else { return nil }
```

```swift
// TacticReDerivation.swift:168
if property(reDerivedOutput) { return nil }
```

**Verdict: Divergence.** The paper's morphisms are *certified* — correctness is structural. The implementation's tactics are *speculative* — they propose mutations and check if they work. This is inherent to the domain: there's no way to know in advance whether deleting a span will preserve the property failure without running the property.

**Important insight for new tactics:** This means every tactic *must* include a property check. The paper's framework suggests we could avoid this if we could construct `enc` maps that provably preserve feasibility. In PBT shrinking this is generally impossible (the property is a black box), but there are special cases: zeroing a value in a monotone domain is guaranteed to preserve failure if the property is antitone in that value. If we could detect such structure, we could skip the property check — a significant performance win.

### 4. The Kleisli Generalization (Section 7)

**Paper's Definition 7.7:** A *T-effectful reduction* uses Kleisli arrows `enc_a : X → TY` and `dec_a : Y → TX`, with cost comparison via Kleisli lifting `f†(c_Q) ≤ c_P`.

**Implementation:** The Kleisli aspect manifests through `GuidedMaterializer`'s nondeterminism:
- The PRNG (seeded by `candidate.zobristHash`) introduces controlled randomness in bound value regeneration
- The fallback tree adds a second source of variation
- `GuidedMaterializer` can fail (`filterEncountered`, `failed`)

The implementation uses **angelic nondeterminism** (the paper's `α = inf`): it takes the best available result. When `GuidedMaterializer` fails, the tactic returns `nil` (no result) rather than a worst-case result. When it succeeds, the shortlex guard selects only improvements.

The paper's Proposition 7.8 guarantees that T-effectful reductions compose via Kleisli composition. In the implementation, composition is sequential application (tactic A then tactic B), not formal Kleisli composition. But the angelic semantics ensures that each step's nondeterminism is resolved favorably before the next step runs.

**Verdict: Correctly instantiated in spirit, but informally.** The implementation doesn't construct literal Kleisli arrows, which is fine — Swift doesn't have a monad typeclass. The important property (nondeterministic steps compose monotonically under angelic semantics) holds by construction.

### 5. 2-Cells and Dominance (Section 15)

**Paper's Definition 15.3:** A **2-cell** `a ⇒ b` between parallel morphisms `a, b : P → Q` requires:
```
enc_a ⊑ enc_b     (a's encoding is pointwise ≤ b's)
dec_a ⊑ dec_b     (a's decoding is pointwise ≤ b's)
g_a ≤ g_b         (a has a better or equal grade)
```

This is the paper's notion of *refinement*: `a` is at least as good as `b` in every component.

**Implementation:** `TacticLattice` (`TacticLattice.swift`) declares dominance edges manually:

```swift
// KleisliReducer.swift:582–614
.init(tactic: ...(DeleteContainerSpansTactic()), dominates: [4, 5]),
.init(tactic: ...(DeleteSequenceElementsTactic()), dominates: [3, 5]),
// ...
```

The implementation's notion of "dominance" is operational: *"if A succeeds, B has no remaining work to do at this depth."* This is related to but distinct from the paper's componentwise refinement.

**Specific edge audit:**

| Edge | Paper justification | Holds? |
|---|---|---|
| DeleteContainerSpans ⇒ DeleteAlignedWindows | enc: removing whole containers removes at least as much as aligned-window subset selection. dec: same (both use TacticEvaluation). | **Plausible but not formally verified.** Container deletion removes strictly more structure, but aligned windows can delete *across* containers (siblings at the same depth). A container span and an aligned window are different structural units — container deletion at depth D doesn't necessarily subsume aligned-window deletion at depth D. |
| DeleteContainerSpans ⇒ SpeculativeDelete | enc: removing containers is strictly more aggressive than speculative single-span deletion with repair. | **Correct.** Speculative delete operates on the same spans (free values + containers) but one at a time; container deletion can remove batches. |
| DeleteSequenceElements ⇒ DeleteFreeStandingValues | enc: removing sequence elements (groups inside sequences) removes structural units that may contain free-standing values. | **Partially correct.** If an element group contained free-standing values, those are gone. But free-standing values *outside* sequence elements are untouched. The dominance holds in the sense that element deletion is structurally more powerful (removes more), not that it subsumes all free-standing value deletions. |
| ZeroValue ⇒ BinarySearchToZero | enc: setting to zero is the best possible outcome of binary-searching toward zero. | **Correct.** If zeroing works, binary search can't do better. |
| ZeroValue ⇒ BinarySearchToTarget | enc: zero is ≤ any target. | **Correct.** |
| BinarySearchToZero ⇒ BinarySearchToTarget | enc: binary search to zero finds values ≤ binary search to an arbitrary target. | **Correct** (when the target is the current value, binary search to zero finds something ≤ it). |

**Verdict: The dominance edges are reasonable heuristics but don't strictly satisfy Definition 15.3's componentwise refinement requirement.** The paper requires `enc_a(x) ⊑ enc_b(x)` *for every* `x` — meaning A's mutation is pointwise at least as good. In practice, DeleteContainerSpans and DeleteAlignedWindows operate on *different* span sets, so the pointwise comparison is not well-defined over the same domain.

**This is not a correctness bug** — the pruning is conservative (prune only within a cycle, reset next cycle), so over-pruning can only cause missed optimization within a single cycle, not incorrect results. But it means the 2-cell structure is an approximation, not a theorem.

### 6. Approximate Reductions (Section 8)

**Paper:** An approximate reduction allows slack `γ = (α, β)` where `c_P(dec(y)) ≤ α · c_Q(y) + β`. The Aff_≥0 monoid composes these bounds: factors multiply, additive terms accumulate.

**Implementation:** Not used. Every tactic requires an exact improvement (shortlex strictly smaller, property still fails). There is no notion of "approximately smaller."

**Verdict: Missed opportunity.** The paper's approximate reductions could model:
- **Speculative delete-and-repair** (`SpeculativeDeleteTactic`): deletes a span then uses GuidedMaterializer to "repair" the sequence. The repair step may produce a sequence that's *locally* worse (longer bound content) but *globally* better (shorter overall). This is an approximate reduction with `α = 1, β > 0`.
- **Cross-stage redistribution** (`RedistributeTactic`): moves numeric mass between values. Some values increase while others decrease. The net shortlex effect depends on positions — this could be modeled as an approximate reduction where the slack quantifies the worst-case positional regression.
- **Future tactics that do "exploratory" mutations**: e.g., temporarily increase a value to enable a larger deletion elsewhere. The approximation grade would track the temporary regression.

### 7. Resources (Section 9)

**Paper:** Resource-annotated reductions `(a, w)` carry a resource cost `w ∈ W` (time, memory, evaluations). Resources compose via the monoidal product: `w_{b∘a} = w_a ⊗ w_b`. This gives compositional resource bounds — the total resource usage of a pipeline is the monoidal product of its steps.

**Implementation:** Resources are tracked ad-hoc:
- `EvaluationCounter` counts property evaluations per tactic (reported in `ShrinkResult.evaluations`)
- `probeBudgets` cap per-tactic evaluation counts
- No compositional resource bounds — the total budget is implicit in the stall counter

**Verdict: Partially implemented.** The `evaluations` field on `ShrinkResult` is the resource annotation `w_a`. But it's not used for compositional reasoning — the reducer doesn't compute "total evaluations for this cycle" from individual tactic evaluations. The probe budgets are per-tactic caps, not compositional bounds.

**Insight for new tactics:** If we formalized resources as the paper suggests, we could:
- Set a *per-cycle* evaluation budget and allocate it across tactics based on their resource annotations
- Prefer low-resource tactics early in the cycle (cheap probes first) and escalate to high-resource tactics only when cheap ones stall
- Track resource usage across cycles to detect diminishing returns and terminate earlier

### 8. The Unified Grade (Section 10)

**Paper:** The grade monoid `G = Aff_≥0 × W` combines approximation slack and resource cost into a single composable annotation. Composition law: `(α, β, t, m) ⊗ (α', β', t', m') = (αα', β + αβ', t + t', m + m')`.

**Implementation:** Not used. There is no unified grade on tactics.

**Verdict: Not applicable to current design, but valuable for future work.** If we wanted to build a *self-tuning* reducer that adapts tactic selection based on observed performance, the grade monoid would be the right abstraction. Each tactic's grade would encode "how much improvement per evaluation" — a quality/cost ratio that guides scheduling.

### 9. Natural Transformations and Post-Processing (Section 5.3)

**Paper:** A *reduction-invariant post-processing* family `h_P : Cand(P) → Cand(P)` is a natural endotransformation on `Cand` if `enc_a ∘ h_P = h_Q ∘ enc_a` for every reduction `a : P → Q`.

**Implementation:** The shortlex-merge step in stall-triggered re-derivation (KleisliReducer.swift:428–440) is a post-processing operation: for each bound position, keep the shortlex-smaller of the old and new entries. This is applied *after* re-derivation, modifying the candidate without changing the problem.

**Verdict: Correctly motivated by the paper's framework.** The merge step is a natural endotransformation on the candidate functor — it selects the pointwise minimum at each bound position, which commutes with encoding (mutation) because it operates independently at each position. The paper validates this design pattern.

However, the merge step has a subtlety: it modifies individual entries without re-running the generator, potentially creating a sequence that doesn't correspond to any valid execution. The implementation handles this by re-materializing and re-checking:

```swift
// KleisliReducer.swift:444–446
if didMerge, mergedSeq.shortLexPrecedes(seq),
   let mergedResult = try? materialize(gen, with: newTree, using: mergedSeq),
   property(mergedResult) == false
```

This is the *a posteriori* feasibility check from point 3 — the merge is speculative, not certified.

---

## Part III: Structural Divergences

### 10. Endomorphisms vs. Reductions Between Different Problems

**Paper:** Morphisms go between *different* problems `P → Q`. The category structure matters because you can chain `P → Q → R`.

**Implementation:** All tactics are endomorphisms `P → P`. The "problem" never changes — it's always "find the shortlex-smallest feasible sequence for this generator and property." The categorical composition `b ∘ a` is just "apply tactic A, then apply tactic B to the result."

**Consequence:** Much of the paper's machinery (functorial constructions between different problems, natural transformations between functors on different categories) doesn't directly apply to the single-problem endomorphism setting. What *does* apply:
- Composition closure (Prop 3.2): composing two valid endomorphisms gives a valid endomorphism
- 2-cells (Def 15.3): refinement between parallel endomorphisms on the same problem
- Resource composition (Prop 9.3): total resource usage of sequential tactics

### 11. The `dec` Inconsistency Between Evaluation Pipelines

`TacticReDerivation.resolve()` at depth 0 calls `GuidedMaterializer.materialize(gen, prefix: strategySequence, seed: seed)` — **without** a fallback tree. Bound values come from PRNG.

`TacticEvaluation.evaluate()` at depth 0 calls `GuidedMaterializer.materialize(gen, prefix: candidate, seed: seed, fallbackTree: context.fallbackTree ?? tree)` — **with** a fallback tree.

**Paper implication:** In the paper's framework, all morphisms of the same "type" (e.g., all depth-0 reductions on the same problem) should use the same `dec` map. Having two different decoding functions means the tactics don't form a uniform hom-set — they're morphisms in different categories that happen to have the same objects.

**Practical consequence:** Strategy-wrapping tactics (via `TacticReDerivation`) explore the bound-value space via PRNG randomness. Purpose-built deletion tactics (via `TacticEvaluation`) preserve bound values via the fallback tree. This means:
- A deletion followed by a numeric reduction may produce different results than the same operations with swapped `dec` maps
- The composition isn't "symmetric" in the categorical sense

**Is this a problem?** Not for correctness — both pipelines check shortlex improvement and property failure. But it means we can't reason about tactic interactions using the paper's composition law alone. The `dec` inconsistency is a pragmatic choice (different tactics need different re-derivation strategies) that trades categorical cleanliness for practical effectiveness.

### 12. The `break depthLoop` vs. Lattice Traversal Interaction

The implementation breaks out of the entire depth loop on the first tactic success (KleisliReducer.swift:306). This means `TacticTraversal.markSucceeded()` is never called — the dominance pruning within a depth pass never activates.

The lattice structure exists but is currently **inert**. Dominance pruning only matters if multiple tactics can succeed within a single depth before breaking.

**Paper implication:** The paper's 2-cell structure (Section 15) is designed for reasoning about *parallel* morphisms — multiple reductions that could be applied to the same problem. The `break depthLoop` serializes tactics so aggressively that the parallel structure isn't exploited.

**Consequence for new tactics:** The lattice is infrastructure for a future where the reducer tries multiple tactics at a depth before breaking. If we changed the strategy to "try all non-dominated tactics at depth D, accept the best result, then break," the lattice pruning would become active and valuable.

---

## Part IV: What the Paper's Guarantees Offer for Designing New Tactics

### Guarantee 1: Composition Closure (Proposition 3.2)

**The guarantee:** If `a` and `b` are certified reductions, `b ∘ a` is a certified reduction.

**What it means for tactic design:** If you can prove that a new tactic satisfies the (enc, dec) contract individually, you get correctness of all tactic compositions for free. You don't need to reason about interactions between your new tactic and existing tactics.

**Current gap:** The implementation verifies correctness empirically (shortlex guard + property check) rather than structurally. To leverage this guarantee, each tactic would need to prove:
1. `enc` is shortlex-non-increasing (mutations don't make things worse)
2. `dec` is shortlex-non-increasing (re-materialization doesn't make things worse)

Item (1) is straightforward to verify. Item (2) requires GuidedMaterializer to be shortlex-non-increasing, which it isn't (see point 2 above).

**Actionable insight:** If we could design a GuidedMaterializer variant that guarantees shortlex-non-increasing output (e.g., by clamping all regenerated values to be ≤ the corresponding fallback value), we could remove all round-trip shortlex guards and rely on the categorical guarantee. This would be a meaningful performance improvement — every shortlex comparison against the original sequence is eliminated.

### Guarantee 2: Feasibility Preservation (Lemma 3.3)

**The guarantee:** `enc_a(Feas(P)) ⊆ Feas(Q)` — encoding maps feasible points to feasible points.

**What it means for tactic design:** If `enc` preserves feasibility, the property check after encoding is unnecessary.

**When this could apply:**
- **Monotone properties:** If the property is antitone in a value (decreasing the value can only make failure "more failed"), zeroing that value is guaranteed to preserve feasibility. A tactic that detects monotonicity could skip the property check.
- **Structure-preserving mutations:** If a mutation preserves the generator's output type and the property depends only on the output type (not the specific values), structural mutations like reordering siblings preserve feasibility.
- **Idempotent mutations:** If applying the mutation twice gives the same result as applying it once, and the first application was feasible, the mutation is feasibility-preserving.

### Guarantee 3: The 2-Cell Criterion for Dominance (Definition 15.3)

**The guarantee:** If `a ⇒ b` (2-cell), then `a` is at least as good as `b` in every component. Using `a` instead of `b` can only improve the pipeline.

**What it means for tactic design — a formal checklist for adding dominance edges:**

To claim "tactic A dominates tactic B," verify:

1. **Encoding refinement:** For every feasible sequence `s`, `shortlex(enc_A(s)) ≤ shortlex(enc_B(s))`. Meaning: A's mutation is at least as aggressive as B's.

2. **Decoding refinement:** For every encoded sequence `s'`, `shortlex(dec_A(s')) ≤ shortlex(dec_B(s'))`. Meaning: A's re-materialization is at least as good as B's.

3. **Grade refinement:** `g_A ≤ g_B`. Meaning: A uses no more resources than B.

In practice, checking (1) is the most important. For our deletion tactics, this means: "A removes at least as much material as B on every input." This is **stronger** than the current informal criterion ("if A succeeded, B has no work left").

**Example — is DeleteContainerSpans ⇒ DeleteAlignedWindows correct?**

Container spans are `[…]` groupings. Aligned windows are subsets of siblings selected by beam search. These operate on *different structural units*. A container span at depth D contains multiple children; an aligned window selects children *across* multiple containers. It's possible for aligned-window deletion to succeed where container deletion fails (e.g., removing one child from each of three containers). The dominance edge is **too aggressive** by the paper's criterion — it's not true that `enc_DeleteContainerSpans(s) ⊑ enc_DeleteAlignedWindows(s)` for all `s`.

**However:** The practical consequence is minor. Over-pruning within a cycle means aligned-window deletion might be skipped when it could have succeeded. The next cycle resets all pruning, so aligned windows get another chance. The only cost is one extra cycle.

### Guarantee 4: Compositional Resource Bounds (Proposition 9.3)

**The guarantee:** `w_{b∘a} = w_a ⊗ w_b` — resource usage of a pipeline is the monoidal product of its steps.

**What it means for tactic design:**

If each tactic declares a resource bound `w` (maximum property evaluations), the reducer can compute the total resource usage of a cycle *before running it*:

```
w_cycle = w_branch ⊗ w_container ⊗ w_numeric ⊗ w_float ⊗ w_ordering ⊗ w_crossStage
```

This enables:
- **Budget allocation:** Given a total budget for the cycle, allocate it across tactics proportionally
- **Early termination:** If the remaining budget is less than the next tactic's declared resource cost, skip it
- **Adaptive scheduling:** Track observed resource usage per tactic across cycles, tighten bounds dynamically

Currently, only three tactics have probe budgets (`deleteAlignedSiblingWindows`, `redistributeNumericPairs`, `reduceValuesInTandem`). Formalizing all tactics with resource bounds would enable these optimizations.

### Guarantee 5: Kleisli Naturality (Theorem 7.16)

**The guarantee:** On the feasibility-preserving subcategory, the inclusion `Feas_T ⇒ Cand_T` is a Kleisli-natural transformation.

**What it means for tactic design:** When designing tactics that involve nondeterminism (PRNG-seeded re-derivation), the Kleisli-naturality guarantee says that the feasibility structure is preserved *through* the nondeterminism — feasible inputs map (in the Kleisli sense) to feasible outputs.

**Practical consequence:** This validates the design pattern of "mutate deterministically, then re-derive nondeterministically." As long as the nondeterministic step (GuidedMaterializer) maps feasible encoded sequences to *distributions over* feasible sequences (under angelic semantics: at least one feasible outcome exists), the pipeline preserves feasibility in the Kleisli sense.

**For new tactics:** Any tactic that uses GuidedMaterializer for re-derivation inherits this guarantee. If you introduce a new re-derivation mechanism (e.g., a different fallback strategy), you need to verify that it satisfies the Kleisli-naturality condition: feasible inputs must have at least one feasible output in the nondeterministic result.

### Guarantee 6: The Oplax Naturality of Costs (Proposition 6.2)

**The guarantee:** The cost function family `c_P` is an oplax natural transformation from the constant functor to the cost functor. The 2-cell inequality is `c_P ∘ dec_a ≤ c_Q`.

**What it means for tactic design:** This says that costs are "compatible with reduction" in a relaxed sense — decoding from `Q` to `P` can only make costs *worse or equal*, never better. In shortlex terms: re-materializing a sequence can only produce something shortlex-equal or shortlex-larger, never shortlex-smaller.

**This is exactly the property GuidedMaterializer violates.** Re-materialization *can* produce a shortlex-smaller sequence (e.g., if the fallback tree had smaller bound values than the prefix). The implementation's shortlex guard compensates, but the oplax naturality condition fails.

**Consequence:** We cannot use the paper's Proposition 6.2 to derive cost bounds without the empirical shortlex check. If we wanted oplax naturality, we'd need a re-materialization that never accidentally improves the sequence — e.g., by always padding regenerated content to be at least as long as the input.

---

## Part V: Summary of Actionable Insights

### For Correctness

1. **The `dec` map (GuidedMaterializer) doesn't satisfy the decoding inequality universally.** This is inherent to the domain (re-derivation can expand bound content) and is correctly handled by the round-trip shortlex guard. No fix needed, but be aware that the paper's composition guarantees require this guard to remain.

2. **The dominance edges in the deletion lattice are heuristic, not formally 2-cells.** The DeleteContainerSpans ⇒ DeleteAlignedWindows edge is too aggressive by Definition 15.3's standard. This causes no correctness issues (pruning resets each cycle) but may cause slightly slower convergence in cases where aligned-window deletion would have succeeded where container deletion failed.

3. **The two evaluation pipelines (TacticReDerivation vs. TacticEvaluation) use different `dec` maps.** This means tactics don't form a uniform category. Not a bug, but it complicates reasoning about tactic interactions. Consider whether the fallback-tree inconsistency is still necessary, or whether both could use the same strategy.

### For New Tactic Design

4. **Use the (enc, dec) contract as a design template.** For every new tactic, explicitly define:
   - What is `enc`? (How does it mutate the sequence?)
   - What is `dec`? (How does it recover a valid triple?) — Usually `TacticEvaluation.evaluate()` or `TacticReDerivation.resolve()`.
   - Does `enc` guarantee shortlex improvement? (It must.)
   - Does the round-trip (`dec ∘ enc`) guarantee feasibility? (Check empirically if can't prove structurally.)

5. **When adding dominance edges, apply the paper's 2-cell checklist:**
   - Does A's encoding strictly subsume B's encoding on *every* input? Not just "A is more powerful in general."
   - If unsure, don't add the edge — the cost of running a redundant tactic is lower than the cost of missing an optimization by over-pruning.

6. **Consider formalizing resource bounds on all tactics.** Even a rough bound (e.g., "this tactic evaluates the property at most `O(n)` times where `n` is the span count") would enable budget-aware scheduling.

7. **The approximate-reduction framework (Section 8) is unexploited.** For tactics that do "speculative" work (temporarily worsening one coordinate to improve another), the Aff_≥0 grade monoid provides the right composition law. This is particularly relevant for potential future tactics like "increase one value to enable a larger deletion elsewhere."

### For the Lattice Architecture

8. **The `break depthLoop` makes lattice pruning inert.** The dominance structure is currently infrastructure-in-waiting. To activate it, the reducer would need to try multiple tactics at a depth before breaking. Consider whether this is worth the additional complexity — the paper's framework supports it, but the current "break on first success" strategy is simpler and may be sufficient.

9. **The paper's locally posetal 2-category (Proposition 15.4) suggests that dominance should be a *preorder*, not just a DAG.** The current `TacticLattice` is a DAG with explicit edges. A preorder-based design would allow transitive dominance (A ⇒ B and B ⇒ C implies A ⇒ C) without listing all transitive edges. This is minor but would make the lattice construction less error-prone.
