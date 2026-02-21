# Codebase Report (Exhaust)

This codebase is a Swift property-based testing engine centered on a reflective generator model and a multi-pass shrinking reducer.  
Primary components are in `Sources/Exhaust/Core`, `Sources/Exhaust/Interpreters`, and `Sources/Exhaust/Interpreters/Reduction`.

## 1) Features

- Property-based generation DSL via `ReflectiveGenerator`, defined as a freer-monad program over `ReflectiveOperation` (`Sources/Exhaust/Core/Types/ReflectiveGenerator.swift`, `Sources/Exhaust/Core/Types/ReflectiveOperation.swift`, `Sources/Exhaust/Core/Types/FreerMonad.swift`).
- Multiple interpreters for the same generator language:
  - Random generation (`Sources/Exhaust/Interpreters/Generation/ValueInterpreter.swift`)
  - Generation with trace/tree capture (`Sources/Exhaust/Interpreters/Generation/ValueAndChoiceTreeInterpreter.swift`)
  - Reflection/inversion from output back to choices (`Sources/Exhaust/Interpreters/Reflection/Reflect.swift`)
  - Replay/materialization of choice traces (`Sources/Exhaust/Interpreters/Replay/Replay.swift`, `Sources/Exhaust/Interpreters/Replay/Materialize.swift`)
- Deterministic PRNG using Xoshiro256 (`Sources/Exhaust/Core/Types/Xoshiro.swift`).
- Rich reduction/shrinking engine with ordered passes, adaptive probing, and caching (`Sources/Exhaust/Interpreters/Reduction/Reducer.swift`).
- Challenge-oriented shrink tests validating difficult minimization scenarios (`Tests/ExhaustTests/Shrinking Challenges`).
- Reporting/analysis subsystem (`Tyche`) for result presentation and stats (`Sources/Exhaust/Tyche`).

## 2) CS Underpinnings

- Algebraic effects / freer monad: generator programs are syntax trees of operations interpreted by different semantics.
- Operational trace model: random decisions become a `ChoiceTree`, then a flattened `ChoiceSequence` for optimization and transformation (`Sources/Exhaust/Interpreters/Types/ChoiceTree.swift`, `Sources/Exhaust/Interpreters/Types/ChoiceSequence.swift`).
- Objective function: shrink targets shortlex minimal failing traces (shorter first, then lexicographically smaller), giving a well-defined minimization order.
- Search strategy: hybrid of monotone adaptive probing (binary search / integer search), heuristic local search, and bounded combinatorial search.
- Validity-preserving transformation: candidates are accepted only if they still materialize and still fail the property.
- Performance tactics: rejection-cache memoization, move-to-front pass scheduling, per-pass budgets, and loop-cycle guards.

## 3) Shrinking / Test-Case Reduction Approach

Reducer entrypoint: `Interpreters.reduce` in `Sources/Exhaust/Interpreters/Reduction/Reducer.swift`.

High-level pipeline:
1. Flatten failing `ChoiceTree` to `ChoiceSequence`.
2. Re-materialize sequence into a concrete value candidate.
3. Re-run property oracle; candidate must still fail.
4. Keep only shortlex-improving candidates.
5. Iterate pass list; successful pass moves to front (adaptive ordering).
6. Stop on fixed point / budget / cycle protection.

Conceptually, passes fall into four groups:
- Structural deletions (remove tree/sequence structure where possible).
- Semantic simplification (replace values with simpler canonical forms).
- Numeric reduction (single-value and coordinated multi-value minimization).
- Normalization/repair (fix ordering and salvage deletions with controlled repair).

## 4) Shrink Passes (Full List + High-Level Behavior)

Execution order from `ShrinkPass` in `Sources/Exhaust/Interpreters/Reduction/Reducer.swift`:

1. `naiveSimplifyValuesToSemanticSimplest`  
   One-shot global attempt: replace each reducible value with its semantic simplest form in a single candidate. Very cheap, good early win when failure is insensitive to magnitude/details.

2. `promoteBranches`  
   For branch/pick sites, tries replacing the currently chosen complex branch subtree with a structurally simpler subtree from another compatible site (fingerprint matching). Targets large structural wins quickly.

3. `pivotBranches`  
   Changes which branch is selected at pick nodes (using known branch alternatives from materialized structure). Useful when failure persists on a “smaller” branch shape.

4. `deleteContainerSpans`  
   Deletes spans corresponding to structural containers (lists/groups/subtrees) in batches at equal depth, using adaptive integer probing to maximize safe deletion size.

5. `deleteSequenceBoundaries`  
   Removes nested sequence boundaries (`][` style boundary markers in flattened form) to collapse structure and shrink nesting/segmentation overhead.

6. `deleteFreeStandingValues`  
   Deletes sequence elements that are not tied to nested container dependencies, again in adaptive batches for speed and monotone-style progress.

7. `deleteAlignedSiblingWindows`  
   Coordinated deletion of contiguous “windows” across sibling containers to preserve alignment constraints. Uses monotone search first, then bounded non-monotone/beam fallback for harder coupled layouts.

8. `simplifyValuesToSemanticSimplest`  
   Multi-candidate pass that applies semantic-simplest replacements more selectively than the naive pass, with shortlex gating and batching.

9. `reduceValuesInTandem`  
   Reduces aligned sibling values together by equal deltas (synchronized movement). Useful when invariants depend on relative similarity/alignment across repeated structures.

10. `reduceValues`  
    Core per-value minimizer. For each reducible value, probes target/bounds with adaptive binary search, updates valid ranges, and can do one-step unlock beyond stale bounds to escape local plateaus.

11. `redistributeNumericPairs`  
    Pairwise coupled optimization: move one numeric value toward its target while moving another away, preserving constraints such as sums/differences/cancellations. Includes heuristic scoring and bounded fallback when monotonicity breaks.

12. `speculativeDeleteAndRepair`  
    Attempts aggressive divide-and-conquer deletions, then “repairs” surviving values by proportional simplification so the candidate rematerializes and still fails. Designed for cases where pure deletion initially breaks structure.

13. `normaliseSiblingOrder`  
    Canonicalizes sibling ordering to produce a smaller normal form (full reorder attempt, then local/bubble-style swaps). Good final polishing when failure is permutation-invariant or weakly order-sensitive.

Implementation files:
- `Sources/Exhaust/Interpreters/Reduction/ReducerStrategies+NaiveSimplifyValues.swift`
- `Sources/Exhaust/Interpreters/Reduction/ReducerStrategies+PromoteBranches.swift`
- `Sources/Exhaust/Interpreters/Reduction/ReducerStrategies+PivotBranches.swift`
- `Sources/Exhaust/Interpreters/Reduction/ReducerStrategies+AdaptiveDeleteSpans.swift`
- `Sources/Exhaust/Interpreters/Reduction/ReducerStrategies+DeleteAlignedSiblingWindows.swift`
- `Sources/Exhaust/Interpreters/Reduction/ReducerStrategies+SimplifyValues.swift`
- `Sources/Exhaust/Interpreters/Reduction/ReducerStrategies+ReduceValuesInTandem.swift`
- `Sources/Exhaust/Interpreters/Reduction/ReducerStrategies+ReduceValues.swift`
- `Sources/Exhaust/Interpreters/Reduction/ReducerStrategies+RedistributeNumericPairs.swift`
- `Sources/Exhaust/Interpreters/Reduction/ReducerStrategies+SpeculativeDeleteAndRepair.swift`
- `Sources/Exhaust/Interpreters/Reduction/ReducerStrategies+ReorderSiblings.swift`

## 5) What This Means Practically

- This is not a single “delta-debugging” shrinker; it is a staged, optimizer-like system mixing structural and semantic minimization.
- It is designed for hard shrinking landscapes (coupled values, nested structures, branch-heavy generators), as reflected by the challenge suite in `Tests/ExhaustTests/Shrinking Challenges`.
- The architecture is research-oriented: clear semantic model, reusable interpreters, and a reduction engine with explicit search heuristics and safeguards.

If you want, I can generate a second report focused only on shrink-pass interactions (which passes enable/disable later passes, common failure modes, and tuning guidance for `.fast` vs `.slow`).
