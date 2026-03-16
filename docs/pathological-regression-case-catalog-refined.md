# Pathological / Regression Case Catalog (Refined For Exhaust)

This is a curated replacement for the broad cross-framework catalog. It focuses on cases that are both:

1. Architecturally high-risk for Exhaust.
2. Underserved by the current active test suite.

`swift test -q` currently passes (`412` tests), but several high-signal suites/cases are disabled or commented out.

## P0: Add First

1. `bind`-dependent reflection should be shrinkable, not just generatable.
Case: Reflect a known failing value from a `bind`-coupled generator and reduce it to the expected minimal counterexample.
Target: `Reflect` + `Materialize` + `reduceValues` stale-range unlock behavior.
Gap signal: `Tests/ExhaustTests/Shrinking Challenges/Coupling.swift:58` is disabled because value is not reflectable.

2. `getSize`/`resize` reflection parity under composition.
Case: Nested `zip + resize + getSize + map` should round-trip across many seeds and iterations.
Target: reflection correctness for size-sensitive continuations.
Gap signal: `Tests/ExhaustTests/CoreGeneratorTests.swift:27` (`Flatzip`) is disabled; `Gen+Sizing` notes size handling regression.

3. Optional `Character` pick-selection reflection should not crash.
Case: Re-enable and harden optional-character branch selection/replay tests.
Target: pick-site reflection and character-branch handling.
Gap signal: `Tests/ExhaustTests/PickSelectionTests.swift:48` is commented with crash note.

4. Floating-point anti-correlated shrink (double cancellation threshold).
Case: Shrink `(a, b)` to `(2^53, 1.0)` for `(a + b) - a == b`.
Target: `reduceValues` + `redistributeNumericPairs` on floating types.
Gap signal: `Tests/ExhaustTests/Experimental Challenges/DoubleCancellation.swift:36` is disabled.

5. Reduction determinism with identical input.
Case: Re-running reducer with same `gen/tree/property/config` should produce identical `(sequence, output)`.
Target: pass ordering stability and dictionary/set iteration sensitivity.
Gap signal: no direct reduction determinism tests; `redistributeNumericPairs` iterates dictionary buckets.

6. (Removed — `ReorderSiblingsEncoder` has been removed from the reducer.)

7. Relaxed materialization branch-fallback must not corrupt parser state.
Case: Branch ID mismatch should recover or reject safely without consuming unrelated context.
Target: `materializePickBranch` fallback + `skipToMatchingGroupClose`.
Gap signal: fragile fallback path in `Materialize.swift`.

8. Replay zip malformed-shape handling must be non-fatal.
Case: Invalid zip shape should return failure (`nil`/error), never crash process.
Target: replay robustness.
Gap signal: `fatalError("Unsupported")` exists in zip branch of replay recursive path.

## P1: Next Wave

9. Aligned deletion non-monotonic contiguous fallback.
Case: `k=1` fails but `k=2` succeeds in aligned sibling deletions.
Target: `deleteAlignedSiblingWindows` non-monotone fallback.

10. Aligned deletion non-contiguous subset fallback.
Case: Only non-contiguous slot subsets preserve failure and should be found.
Target: beam-search subset fallback in aligned deletion.

11. Aligned deletion with large slot counts.
Case: Cohorts near/above bit-width limits should not overflow masks or silently degrade.
Target: subset mask encoding limits and graceful fallback behavior.

12. Tandem reduction suffix-window unlock.
Case: Leading sibling already near target blocks full-set tandem, but suffix window can shrink.
Target: `reduceValuesInTandem` window planning logic.

13. Pair redistribution wrap-boundary case.
Case: Best move requires modular boundary jump for small-width integers (e.g. `Int16`).
Target: fallback `k` heuristics and wrapping-boundary delta logic.

14. Pair redistribution should avoid useless pure pair-swaps.
Case: Equivalent pair multiset swap must not be committed as improvement.
Target: anti-noise guard in `redistributeNumericPairs`.

15. Speculative delete-and-repair should succeed when pure deletion cannot materialize.
Case: Deleting index-coupled structure invalidates candidate; uniform repair should salvage minimal failing case.
Target: `speculativeDeleteAndRepair` and `repairAfterDeletion`.

16. Reducer cycle/oscillation guard.
Case: Construct pass interaction that toggles states and ensure cycle window exits with stable failing result.
Target: recent-sequence cycle detection and stall handling.

## P2: Valuable Hardening

17. NaN/Infinity shrinking termination and determinism.
Case: Properties over `NaN`, `+inf`, `-inf` should shrink deterministically without pass starvation.
Target: float shortlex and numeric passes.

18. Unicode grapheme and combining-mark string shrinking.
Case: Distinct Unicode normalization forms should replay and shrink stably.
Target: character/string generation, reflection, and materialization.

19. Marker-corruption robustness under edited sequences.
Case: Fuzzed unbalanced `group/sequence` markers should fail safely, never crash.
Target: materialization strict/relaxed behavior and sequence validation.

20. Over-budget behavior monotonicity (`fast` vs `slow`).
Case: `slow` should be equal-or-better than `fast` on shortlex for same failing input.
Target: budgeted passes and fallback quality.

21. High-value-count coupling (`>16` numeric values).
Case: When pair-redistribution pass is intentionally skipped, overall reducer should still find minimal witness.
Target: pass interaction when `redistributeNumericPairs` is gated off.

22. Deep recursion stress for reflect/materialize.
Case: Very deep nested groups/sequences should remain stack-safe and reproducible.
Target: recursive interpreter limits and practical depth ceilings.

## Suggested Immediate Test Reactivations

1. Re-enable and modernize `Tests/ExhaustTests/PickSelectionTests.swift`.
2. Re-enable targeted cases from `Tests/ExhaustTests/ShrinkingTerminationTests.swift`.
3. Re-enable representative `SpanExtraction` coverage from `Tests/ExhaustTests/SpanExtractionTests.swift` (suite currently disabled).
4. Re-enable `Coupling, Pathological` and `Double cancellation` once reflection/float paths are fixed.
