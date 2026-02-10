# The Shrinking Challenge: Benchmark Analysis

## How Our Adaptive Shrinking Algorithm Handles the Hard Cases

This document analyses each challenge from [jlink/shrinking-challenge](https://github.com/jlink/shrinking-challenge), a benchmark suite that exposes weaknesses in property-based testing shrinking implementations. For each challenge, we describe the problem, identify what makes it hard, and assess how the algorithm described in *Adaptive Shrinking for Property-Based Testing* handles it — including any changes or additions required.

The challenges are ordered roughly by difficulty, from those the core algorithm handles directly to those that stress the heuristic and structural layers.

---

## 1. Reverse

**Property:** `reverse(list) == list` for a list of integers. This is trivially false for any list with more than one distinct element.

**Optimal result:** `[0, 1]` or `[1, 0]` — two elements that differ.

**What makes it hard:** Very little. This is the "hello world" of shrinking benchmarks. The list must have at least two elements, and at least two values must differ. Most frameworks handle this, though some fail to normalise consistently (e.g., producing `[0, 1]` sometimes and `[1, 0]` other times).

**Our algorithm:** Pass 2 (adaptive span deletion) removes all but two elements via `find_integer`. Pass 5 (minimise values) uses `binary_search_with_guess` to drive both values toward zero; one stops at 0, the other at 1 (since `[0, 0]` passes). Shortlex ordering guarantees normalisation to `[0, 1]`. No changes required.

---

## 2. Distinct

**Property:** Generate a list of integers containing at least three distinct elements. The property under test is simply "this list exists" — it always fails, and the shrinker must find the smallest such list.

**Optimal result:** `[0, 1, -1]` or `[0, 1, 2]` — three elements, all distinct, as small as possible.

**What makes it hard:** Normalisation. Most frameworks cannot consistently produce the same answer because reaching the optimal requires **reordering** elements during shrinking, which most shrinkers don't attempt. The distinctness constraint also means that naively zeroing values collapses the list below three distinct elements, causing the candidate to pass.

**Our algorithm:** Pass 3 (zero within range) will zero one element successfully. Pass 5 (minimise values) will drive values toward zero, but must respect the distinctness constraint — zeroing a second value to 0 would make the list `[0, 0, x]` which has only two distinct elements and therefore passes. The empirical centroid guides minimisation efficiently. However, consistent normalisation to a canonical form like `[0, 1, 2]` requires the ability to **swap** adjacent values — which is not currently a core pass. Pass 7 (reorder for shortlex polish) in the heuristic layer would handle this if implemented. Without it, we'll produce a correct minimal-size result but may not normalise consistently. **Consider promoting swap/reorder to a core pass if benchmark consistency matters.**

---

## 3. Deletion

**Property:** Given a list and an element, deleting all occurrences of the element from the list should produce a list that differs from the original (i.e., the element must appear in the list). The property is false when the list contains duplicates of the element.

**Optimal result:** `([0, 0], 0)` — the shortest list where deletion changes it, with the smallest values.

**What makes it hard:** The list and the element must be **shrunk simultaneously** — the element value must match at least one list entry. If you shrink the element to 0 without also shrinking a list entry to 0, the property starts passing. Most frameworks shrink parameters independently, which breaks this coupling.

**Our algorithm:** Because we operate on the flat `ChoiceSequence` rather than on separate "list" and "element" parameters, the element and the list entries are just value entries at different positions in the same sequence. Pass 5 (minimise values) processes all values in order, and since it uses `binary_search_with_guess` with the empirical centroid, both the element and the matching list entries tend to converge toward the same small value. The critical advantage of integrated shrinking is that each candidate is replayed through the generator, so the structural coupling between the element and the list is maintained by construction. **No changes required.** This is a case where integrated shrinking (operating on the choice sequence) gives us a fundamental advantage over type-based shrinking approaches.

---

## 4. Nested Lists

**Property:** Given a list of lists of integers, the sum of the lengths of all inner lists is at most 10. This is false for any input with more than 10 total elements across all inner lists.

**Optimal result:** `[[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]]` — a single list containing 11 zeros.

**What makes it hard:** Local minima. Under pure deletion-based shrinking, both `[[0], [0], ..., [0]]` (11 singleton lists) and `[[0, 0, ..., 0]]` (one 11-element list) are minima — you can't delete any element from either without dropping below the threshold. Moving from 11 singletons to a single list of 11 requires **redistributing elements between groups**, which is not a deletion operation.

**Our algorithm:** Pass 4 (pass to descendant) can collapse a nested group into its child, but the decisive technique is Pass 6 (pair redistribution) in the heuristic layer — specifically, redistributing elements from one inner list to another, then deleting the now-empty list. This is exactly the operation Hypothesis uses to escape this local minimum, and it's the reason Hypothesis and jqwik succeed here while most others don't. Our heuristic §11 (pair redistribution of adjacent groups) handles this directly. **No changes to the core algorithm, but the heuristic layer (§11) is essential for this challenge.** This is a good gate test for whether pair redistribution is worth its complexity — if we can't solve nestedlists without it, it earns its keep.

---

## 5. Length List

**Property:** Generate a pair `(n, list)` where `n` is an integer and `list` is a list of integers of length `n`. The (false) property is that the first element of the list is not equal to `n`.

**Optimal result:** `(1, [1])` — the shortest list where the first element equals the length.

**What makes it hard:** The coupling between `n` and the length of `list`. If you shrink `n` without shrinking the list, or vice versa, the generator constraint (list has length `n`) may be violated. In type-based shrinking frameworks, this is a classic failure mode — the shrinker doesn't know that `n` and the list length are related. In integrated shrinking frameworks, the generator enforces the constraint during replay, but shrinking `n` to a smaller value causes the list to be regenerated with fewer elements, which may not contain the necessary value.

**Our algorithm:** Integrated shrinking handles this naturally. Shrinking the choice that controls `n` causes the generator to produce a shorter list on replay. Pass 5 then minimises the list elements. The key insight is that `n` and the list length are not independent parameters — they're linked through the generator's control flow, and our replay-based approach preserves this linkage. The empirical centroid for the first element will reflect the distribution of values actually generated, guiding `binary_search_with_guess` toward the correct answer efficiently. **No changes required.**

---

## 6. Bound5

**Property:** Given a 5-tuple of lists of 16-bit signed integers, if each individual list sums to less than 256, then the total sum across all lists is less than 5 × 256. This is false due to integer overflow — e.g., `([-20000], [-20000], [], [], [])` is a counterexample because the individual sums are negative (below 256) but the combined sum overflows.

**Optimal result:** `([-32768], [-1], [], [], [])` or similar — one list containing the most negative 16-bit value, one containing a small negative value, and three empty lists.

**What makes it hard:** **Cross-component interdependence.** A single list in the tuple can never break the invariant alone — you need at least two lists to interact via overflow. Shrinking each list independently will zero out values that are individually "unnecessary" but collectively essential. The shrinker must understand that the values in list 1 and list 2 are coupled through the overflow condition.

**Our algorithm:** Pass 2 (adaptive span deletion) can empty three of the five lists, since removing an entire list's contents still allows the remaining lists to trigger the overflow. The challenge is in Pass 5 (minimise values): shrinking the negative values toward zero causes the overflow to disappear. However, because `binary_search_with_guess` searches for the *smallest* value that still fails, it will find the boundary — the value at which the overflow just barely occurs. The empirical centroid will reflect the distribution of 16-bit integers in the passing corpus, which is likely near zero, making the guess good for the non-essential values and bounded-cost for the essential ones. **The core algorithm should handle this, but the quality of the final result depends on the order in which values are minimised.** Since we process values in sequence order, and the tuple's lists appear sequentially in the choice sequence, we'll minimise list 1's value first (pushing it toward −32768), then list 2's value (finding −1 as the boundary), then zero out the rest. This is the correct behaviour. **No changes required.**

---

## 7. Large Union List

**Property:** Given a list of lists of integers, the union of all lists (treated as sets) contains fewer than 5 distinct elements. This is false when the total distinct element count across all inner lists reaches 5.

**Optimal result:** `[[0, 1, 2, 3, 4]]` — a single list with exactly 5 distinct values, all as small as possible.

**What makes it hard:** Similar to nested lists — local minima under deletion. Multiple short lists each contributing one or two distinct values are a local minimum, since deleting any single list drops the distinct count below 5. The shrinker needs to consolidate elements into a single list, which requires redistribution.

**Our algorithm:** The analysis is similar to Nested Lists (challenge 4). Pass 2 handles initial deletion. The heuristic layer's pair redistribution (§11) consolidates elements across lists. Pass 5 then minimises values toward `[0, 1, 2, 3, 4]`. The distinctness constraint means that `binary_search_with_guess` can't drive two values to the same target — but since each value is minimised independently and the oracle rejects candidates that drop below 5 distinct elements, the algorithm naturally finds the smallest 5 distinct values. **No changes required beyond ensuring the heuristic layer is active.**

---

## 8. Calculator

**Property:** Generate a recursive arithmetic expression tree (with operations +, −, ×, ÷ and integer leaves), evaluate it, and assert that evaluation doesn't throw an exception. This is false because division by zero is possible.

**Optimal result:** `Div(0, 0)` or `Div(1, 0)` — the simplest expression containing a division by zero.

**What makes it hard:** **Recursive structure.** The expression tree is generated recursively, producing a deeply nested `ChoiceSequence` with nested group markers. Shrinking must collapse the tree to a single division node with a zero denominator, which requires removing all non-essential branches and then minimising the remaining leaf values. The recursive nesting means the span structure is deep, and Pass 4 (pass to descendant) must work through multiple levels.

**Our algorithm:** The recursive structure is represented as nested `groupOpen`/`groupClose` markers in the choice sequence. Pass 4 (pass to descendant) replaces a compound expression with one of its subexpressions — e.g., replacing `Add(Div(1, 0), Lit(5))` with `Div(1, 0)`. Repeated application collapses the tree to the minimal failing subtree. Pass 2 confirms there's no unnecessary structure around it. Pass 5 minimises the leaf values. The key requirement is that **Pass 4 works recursively through nested groups**, which it does by design — it iterates from outermost to innermost spans, and each successful collapse triggers a reset to the top of the pass list. **No changes required.** This is a good stress test for the span index extraction (§1) and the pass-to-descendant operation.

---

## 9. Coupling

**Property:** Generate two lists of integers of the same length. The (false) property asserts some condition on corresponding elements — typically that no pair of corresponding elements sums to a particular value.

**Optimal result:** Two short lists (e.g., length 1) with the smallest values that violate the condition.

**What makes it hard:** **Correlated structure across independent-looking parameters.** The two lists must remain the same length throughout shrinking. Deleting an element from one list without deleting the corresponding element from the other violates the structural invariant. Type-based shrinkers that treat the two lists independently will almost certainly break the length coupling.

**Our algorithm:** As with Deletion and Length List, integrated shrinking handles this by construction. The generator produces both lists from the same choice sequence, and the length coupling is encoded in the control flow (e.g., one choice controls the length, and both lists draw that many elements). Shrinking the length choice shortens both lists simultaneously on replay. The only risk is if the generator uses *separate* length choices for the two lists — but even then, Pass 5 would try to minimise each length independently, and the oracle would reject candidates where the lengths diverge. **No changes required.** This is another case where integrated shrinking provides a structural advantage.

---

## 10. Difference

**Property:** Generate two lists of integers. The (false) property asserts that the two lists are equal. Any pair of unequal lists is a counterexample.

**Optimal result:** Two lists that differ minimally — e.g., `[0]` and `[1]`, or `[]` and `[0]`, depending on the exact property formulation.

**What makes it hard:** The shrinker must find the smallest pair of lists that differ. Naively shrinking both lists toward `[]` makes them equal (both empty), which passes. The shrinker must maintain a difference while making both lists as small as possible. This requires coordinated shrinking — making one list shorter or simpler than the other.

**Our algorithm:** Pass 2 (adaptive span deletion) tries removing elements from both lists. Since we process spans in order, one list will be reduced before the other. The oracle rejects candidates where the lists become equal, so the algorithm will find a state where one list has been emptied (or reduced to a single element) and the other retains just enough to differ. Pass 5 then minimises values. The shortlex ordering naturally prefers the shortest total sequence, which means shorter lists with smaller values. **No changes required.**

---

## 11. Binary Heap

**Property:** Generate a list of integers, insert them into a binary heap implementation, then verify the heap invariant (every parent ≤ its children). The property is false when the heap implementation has a bug — the challenge provides a deliberately buggy `toHeap` function.

**Optimal result:** A short list (typically 2–3 elements) that triggers the bug in the heap construction.

**What makes it hard:** **Semantic opacity.** The failure depends on the internal behaviour of the buggy heap implementation, not on an obvious structural property of the input. The shrinker has no insight into *why* the input triggers the bug — it can only probe the oracle. The minimal triggering input may require specific value relationships (e.g., elements in a particular relative order) that are easy to accidentally destroy during shrinking.

**Our algorithm:** This is exactly the scenario the core algorithm is designed for. Pass 2 removes unnecessary elements. Pass 5 minimises remaining values. The empirical centroid guides value minimisation toward the distribution of passing inputs, and values that are failure-critical will resist minimisation (the oracle rejects attempts to move them). The `binary_search_with_guess` approach means the cost of discovering that a value is failure-critical is bounded. **No changes required.** The quality of the result depends on how many oracle calls we're willing to spend, not on any architectural limitation.

---

## Summary

| Challenge | Core sufficient? | Heuristic layer needed? | Notes |
|---|---|---|---|
| Reverse | ✅ | No | Straightforward deletion + minimisation |
| Distinct | ⚠️ | Swap/reorder pass | Correct size, may not normalise consistently |
| Deletion | ✅ | No | Integrated shrinking handles coupling |
| Nested Lists | ❌ | §11 (pair redistribution) | Core hits local minimum without redistribution |
| Length List | ✅ | No | Generator replay preserves n/length coupling |
| Bound5 | ✅ | No | Sequential value minimisation finds overflow boundary |
| Large Union List | ❌ | §11 (pair redistribution) | Same redistribution requirement as Nested Lists |
| Calculator | ✅ | No | Pass 4 (descendant) collapses recursive trees |
| Coupling | ✅ | No | Integrated shrinking preserves length coupling |
| Difference | ✅ | No | Shortlex ordering naturally finds minimal difference |
| Binary Heap | ✅ | No | Oracle-driven search, no structural insight needed |

**8 of 11 challenges are handled by the core algorithm alone.** The two challenges that require the heuristic layer (Nested Lists and Large Union List) both need the same technique — pair redistribution (§11) — confirming that this heuristic earns its place in the algorithm. The remaining challenge (Distinct) needs a swap/reorder pass for consistent normalisation, which is a low-cost addition.

---

## Implications for the Main Document

The shrinking challenge benchmark validates several design decisions in the main document:

**Integrated shrinking is non-negotiable.** Five of the eleven challenges (Deletion, Length List, Bound5, Coupling, Difference) involve coupling between parameters that type-based shrinkers cannot handle without manual intervention. Operating on the flat choice sequence and replaying through the generator is not merely convenient — it is architecturally necessary.

**Pair redistribution is the single most impactful heuristic.** The two challenges that defeat the core algorithm (Nested Lists and Large Union List) both require moving elements between groups. No amount of deletion or value minimisation can escape their local minima. This confirms §11's placement in the heuristic layer and suggests it should be the **first** heuristic implemented after the core passes.

**Pass 4 (pass to descendant) is essential for recursive generators.** The Calculator challenge cannot be solved without collapsing recursive tree structure. This pass is correctly placed in the core algorithm.

**`binary_search_with_guess` with empirical centroid handles value coupling gracefully.** In Bound5, the overflow boundary is found naturally by searching for the smallest failing value at each position. The centroid provides a good guess for non-failure-critical values (near zero, approaches O(1)) and a bounded-cost search for failure-critical values. No special handling of cross-component dependencies is needed.

**Normalisation requires element reordering.** The Distinct challenge shows that producing a *correct* minimal result and producing a *canonical* minimal result are different problems. If consistent normalisation across runs is a goal, consider adding a lightweight swap pass to the core algorithm — either as a dedicated Pass 7 or by extending the shortlex polish at the end of the pass cycle.
