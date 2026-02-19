# Exhaust vs Hypothesis: Shrinking Analysis

## Architectural Foundation

The most fundamental difference is in what gets shrunk:

- **Hypothesis** operates on a **flat choice sequence** — a linear list of `ChoiceNode`s. The tree structure (spans) is a derived/annotated view overlaid on this flat sequence. Shrinking mutates the flat sequence and re-runs the test function to discover the new structure.

- **Exhaust** operates on a **rich algebraic choice tree** (`ChoiceTree`) built from the Freer monad's reification of generator effects. The tree has explicit semantic nodes (`.branch`, `.sequence`, `.group`, `.choice`, `.important`, `.selected`). A flattened `ChoiceSequence` is derived for shortlex comparison and value-level mutation, but the tree remains the source of truth for structural passes.

## Points of Similarity

1. **Shortlex ordering** — Both use the same fundamental metric: shorter is better, then lexicographically smaller. Hypothesis' `sort_key` and Exhaust's `shortLexPrecedes` encode the same idea.

2. **Fixed-point iteration with pass reordering** — Both run passes in a loop until no pass makes progress. Both promote successful passes to run earlier in the next iteration.

3. **Adaptive/logarithmic probing** — Both use `find_integer` / `AdaptiveProbe.findInteger` for O(log k) search when a monotonic operation can be repeated.

4. **Tandem value reduction** — Hypothesis' `minimize_duplicated_choices` and `lower_integers_together` correspond to Exhaust's `reduceValuesInTandem`. Both recognise that correlated values must sometimes be lowered together.

5. **Numeric redistribution** — Both have passes to decrease an earlier value while increasing a later one by the same amount.

6. **Sibling reordering** — Both canonicalise the ordering of same-label children.

7. **Span deletion** — Hypothesis' `node_program("X" * k)` deletes contiguous runs of k nodes. Exhaust's `adaptiveDeleteSpans` deletes structurally meaningful spans.

## Key Differences

| Aspect | Hypothesis | Exhaust |
|---|---|---|
| **Test case representation** | Flat choice sequence + derived spans | Algebraic tree + derived flat sequence |
| **Shrink validity** | Re-runs test function to discover if mutation is valid | Can check structural validity via `materialize` before calling oracle |
| **Branch/oneOf handling** | `reduce_each_alternative`: detects shape-changing integers heuristically, then rerandomises | `promoteBranches` + `pivotBranches`: explicit tree surgery with fingerprint-based addressing |
| **Misalignment recovery** | `try_shrinking_nodes`: explicit repair for size-dependent string/bytes constraints | `materialize(..., strictness: .relaxed)`: generic fallback that retries alternative branches |
| **Stall detection** | `max_stall` counter on consecutive non-improving oracle calls | `stallBudget` on consecutive non-improving full loops through all passes |
| **Pass granularity** | Each pass uses a `ChoiceTree` to enumerate all possible invocations, stepping through one at a time | Each pass runs to completion on the current sequence before the next pass starts |
| **Speculative repair** | `try_shrinking_nodes` tries deleting regions after failed value reduction | `speculativeDeleteAndRepair` uses divide-and-conquer deletion + uniform value repair with coarse sweep + binary refinement |
| **Caching** | `engine.cached_test_function` caches by choice values | `ReducerCache` caches rejected sequences; `materialize` provides structural pre-check |

## What Exhaust Can Learn from Hypothesis

1. **`lower_common_node_offset`** — Hypothesis detects when multiple nodes are zig-zagging (e.g. `abs(m - n) > 1`) and reduces their common offset simultaneously. Exhaust's `reduceValuesInTandem` handles uniform reduction of siblings, but doesn't track *which nodes changed between shrink attempts* to detect this specific anti-pattern. Adding change-tracking could avoid exponential slowdowns in adversarial cases.

2. **Per-step ChoiceTree exploration** — Hypothesis runs each pass through many fine-grained *steps* (each step is one application of the pass at one position), with a `ChoiceTree` data structure tracking which positions have been tried. A single pass can make progress at position 7, then position 3, then position 12, without restarting. Exhaust runs each pass to completion as a single unit — if a pass makes one improvement, the entire pass queue restarts. This is simpler but may do more redundant work.

3. **`pass_to_descendant`** — Hypothesis has an explicit pass that replaces a span with one of its descendant spans (handling recursive strategies like `binary_tree`). Exhaust's `promoteBranches` is related but operates at the branch/pick level. A generalisation that works on arbitrary nested structures could help with recursive generators.

4. **Random-order fallback during stalls** — Hypothesis switches to random step ordering after `max_failures // 2` consecutive failures within a pass. This prevents long stalls when deterministic ordering hits a dead region. Exhaust's passes are deterministic with no randomisation fallback.

---

## Novel Approaches Enabled by Exhaust's Freer Monad

The Freer monad's reification of generator effects as an inspectable algebraic data structure gives Exhaust capabilities that are structurally impossible in flat-sequence shrinkers like Hypothesis. These fall into two categories: advantages already realised, and possibilities that the model opens up.

### Already Realised

**Structural pre-checking without oracle calls.** Because `materialize` can detect invalid mutations before calling the property, Exhaust can reject structurally impossible candidates for free. Hypothesis must call the test function (or check `choice_permitted`) for every candidate. This is a significant efficiency advantage for structural passes — the oracle is expensive, and avoiding unnecessary calls directly reduces shrinking time.

**Tree-aware branch promotion.** `promoteBranches` and `pivotBranches` perform genuine tree surgery: take a subtree from one location and graft it into another, with the tree structure ensuring type compatibility. Hypothesis' `reduce_each_alternative` is a heuristic approximation — it guesses that small integers control `one_of` branching and tries lowering them with rerandomisation. Exhaust *knows* the branch structure because the Freer monad reifies it. This means branch reduction is precise and complete rather than heuristic and best-effort.

**Cross-branch knowledge via `flattenAll`.** Because the ChoiceTree retains *non-selected* branches, Exhaust can compare the complexity of all alternatives at a pick site without executing them. Hypothesis only sees the selected branch and must execute alternatives to learn about them. This enables `promoteBranches` to sort candidates by complexity and try the most promising replacements first.

**Typed/semantic value reduction.** `ChoiceValue` distinguishes `.unsigned`, `.signed`, `.floating`, `.character` with explicit tags, and `semanticSimplest` encodes domain knowledge (0 for numbers, space for characters). The type information is structurally available at the tree level rather than requiring runtime type dispatch.

### Not Yet Exploited

#### 1. Constraint Propagation

The tree knows the valid ranges for each choice. When one choice is reduced, the tree could propagate tighter constraints to dependent choices *before* trying them.

Consider a generator like:
```swift
let n = gen.integer(in: 1...10)
let xs = gen.list(of: gen.integer(in: 0...n), count: n)
```

After reducing `n` from 7 to 3, the tree knows that subsequent `integer(in: 0...n)` choices now have a tighter range. Rather than trying all values and discovering invalidity via `materialize`, the tree could pre-constrain the search space. This would be a form of **abstract interpretation over the choice tree** that prunes the reduction search space before any oracle calls.

#### 2. Subtree Transplantation

The tree structure makes it possible to identify isomorphic subtrees (same label/structure at different positions) and transplant known-simple subtrees from one location to another.

This is a generalisation of `promoteBranches` that could work across *unrelated* parts of the tree. If two subtrees have the same shape and one has already been reduced to near-minimal, transplanting it to the other position could short-circuit what would otherwise require many individual reduction steps. The fingerprint system already supports the addressing needed for this.

#### 3. Importance-Guided Reduction

The `.important` marker already flags values that affected the property. This enables a reduction strategy that no flat-sequence shrinker can implement:

- **Phase 1:** Reduce all *non-important* values first. These are more likely to be freely reducible since the property doesn't depend on them.
- **Phase 2:** Tackle important values with more expensive strategies (tandem reduction, speculative delete-and-repair).
- **Phase 3:** Re-evaluate importance after structural changes — a value that was important before deletion of another subtree may no longer be.

This is a form of **information-directed search** where the shrinker uses knowledge about the property's dependency structure to order its work. Hypothesis has no equivalent because it cannot distinguish which choices mattered.

#### 4. Generator-Aware Repair

Since `materialize` has access to the original generator, Exhaust could use the generator itself to suggest repairs when structural mutations break validity. Rather than the coarse "uniform delta" repair in `speculativeDeleteAndRepair`, the generator could re-derive valid values for the modified structure.

Concretely: after deleting a subtree, instead of sweeping through uniform deltas, Exhaust could:
1. Run the generator forward from the mutation point
2. At each choice point, use the existing value if valid, or draw the simplest valid alternative
3. This produces a structurally valid candidate with minimal perturbation

This would be a form of **guided re-generation** that exploits the bidirectional nature of the Freer monad — the same generator that produced the original test case can be used to repair a broken mutation.

#### 5. Structural Diff-Based Reduction

`mapWhereDifferent` already exists on `ChoiceTree`. A reduction pass could maintain a **diff** between the current best tree and a target tree (all semantic simplest values), then try to resolve chunks of the diff simultaneously.

The key insight is that the tree structure provides a natural decomposition of the diff into independent regions. If two subtrees are structurally independent (no shared parent below the root), their diffs can be resolved in parallel or in any order. The tree makes this independence relationship explicit, whereas in a flat sequence, determining whether two regions are independent requires reconstructing the span structure.

This could enable a pass that:
1. Computes the tree-structured diff between current and target
2. Identifies maximally independent diff regions
3. Tries resolving each region, knowing that success in one region doesn't invalidate attempts in another

#### 6. Symbolic Shrinking via Effect Inspection

The most speculative possibility: because the Freer monad reifies effects as data, Exhaust could in principle perform *symbolic* analysis of the generator to identify which choices are constrained by the property.

For example, if the generator produces `(x, y)` and the property is `x + y > 10`, symbolic analysis of the generator's effect structure could determine that `x` and `y` are drawn independently and that the constraint is on their sum. This would directly suggest the redistribution strategy without needing to discover it empirically.

This is far from trivial to implement, but the Freer monad provides the structural foundation: the generator's effects are data that can be inspected, transformed, and reasoned about programmatically. No other property-based testing framework has this capability.

---

## Summary

Hypothesis is a mature, battle-tested shrinker optimised for the flat-sequence representation. Its key strengths are fine-grained step control, change tracking for exponential-slowdown avoidance, and robust heuristics for misalignment repair.

Exhaust's Freer monad foundation gives it a structural advantage: the tree is the truth, not a derived annotation. This enables passes (like branch promotion/pivoting) that are precise where Hypothesis must guess, and opens the door to constraint-propagation, importance-guided, and generator-aware strategies that are impossible in a flat-sequence model. The main areas where Exhaust could borrow from Hypothesis are change-tracking between shrinks and random-order fallback during stalls.
