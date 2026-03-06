# Exhaust Hot-Path Performance Analysis

## Context

A thorough analysis of the three main hot paths (value generation, hill climbing, reducer) plus the underlying data structures, identifying concrete performance improvements ordered by expected impact.

---

## Tier 1 — High-Impact, Low-Risk


### 5. HillClimber: mutate-in-place instead of full sequence copy per probe

**File:** `HillClimber.swift:113–114, 181–182`

Every probe copies the entire `ChoiceSequence` (`var probe = currentSequence`), modifies one entry, materializes, then discards the copy. For sequences of length N and B budget probes, that's O(N × B) element copies.

**Change:** Mutate `currentSequence[i]` in place, probe, then restore:
```swift
let saved = currentSequence[i]
currentSequence[i] = newEntry
// ... materialize ...
currentSequence[i] = saved  // restore on rejection
```
Requires making `PrefixMaterializer.materialize` borrow the sequence (accept by reference or `borrowing`) rather than consuming it.

---

### 6. Targeted `shortLexPrecedes` for known-edit positions

**Files:** `ChoiceSequence.swift:452–469`, various strategy files

`candidate.shortLexPrecedes(current)` is O(n), scanning every element. Most strategies edit only 1–2 known indices. Elements before the first edit are identical.

**Change:** Add `shortLexPrecedesEditing(at editIndex: Int, in current: ChoiceSequence) -> Bool` that compares only at the first edited position. Use the full scan only when edit positions are unknown.

---

## Tier 2 — Medium-Impact

### 7. `FitnessAccumulator.record` double dictionary lookup

**File:** `FitnessAccumulator.swift:25–29`

```swift
records[key, default: FitnessRecord()].totalFitness += fitness
records[key, default: FitnessRecord()].observationCount += observations
```

Two separate hash+probe operations for the same key. Fix:
```swift
records[key, default: FitnessRecord()].totalFitness += fitness  // keep first
records[key]!.observationCount += observations                  // key guaranteed to exist
```

---

### 8. `DefaultSeedPool.averageFitness` — cache the running sum

**File:** `DefaultSeedPool.swift:40–43`

Recomputes `seeds.reduce(0.0) { $0 + $1.fitness }` on every `.mutate` directive. O(n) per call with pool sizes up to 256.

**Change:** Maintain a `private var fitnessSum: Double`. Update it on insert/evict/revise.

---

### 9. `DefaultSeedPool.investFitness` — combine two min-scans into one

**File:** `DefaultSeedPool.swift:114–133`

Scans for `poolMinFitness` (O(n)), then scans again for `minIdx` (O(n)). Both can be done in a single pass.

---

### 10. HillClimber: defer reflection to end of climb

**File:** `HillClimber.swift:137–141`

On every accepted mutation, `Interpreters.reflect` runs a full backward pass and then `ChoiceSequence(reflected)` flattens the resulting tree. Only the final improved seed actually needs reflection.

**Change:** Use `result.sequence` directly during the climb. Reflect only once at line 223 when building the final `Seed`.

---

### 11. Replay interpreter: use index cursor instead of `removeFirst()`

**File:** `Replay.swift:117, 134, 168, 253–256`

`choices.removeFirst()` is O(n) on `Array` (shifts all remaining elements). The Materialize interpreter already uses an index-based `PrefixCursor` for this.

**Change:** Use an integer index that advances through the array instead of mutating it.

---

### 12. Remove dead `childrenAtDepth` in `extractContainerSpans`

**File:** `ChoiceSequence.swift:121–155`

`childrenAtDepth` array is populated but never read. Pure dead allocation.

---

### 13. `ChoiceSequenceValue.Branch.validIDs` — shared storage

**File:** `ChoiceSequenceValue.swift:92–114`

Every `Branch` marker stores `validIDs: [UInt64]` — the same array for all branches at a given pick site. These are COW-shared but each Branch still stores the array header. `shortLexCompare` does O(n) `firstIndex(of:)` on each comparison.

**Change:** Consider storing just `(id: UInt64, indexInSite: UInt8, siteSize: UInt8)` — the branch index and total count. Recover `validIDs` from the tree when actually needed (only in pivotBranches/promoteBranches).

---

## Tier 3 — Structural / Longer-Term

### 14. `runContinuation` closure allocation in `ValueInterpreter`

**File:** `ValueInterpreter.swift:126–130`

Every `.impure` step allocates a closure for `runContinuation`. The documented early-return optimization in VaCTI (line 300–305: "cuts 70% of time for string generators") is not applied in `ValueInterpreter`.

**Change:** Apply the same `.pure` early-return optimization. When the continuation returns `.pure`, skip the recursive call entirely.

---

### 15. `[Any]` existential boxing in sequence/zip handlers

**Files:** `ValueInterpreter.swift:333–345`, `ValueAndChoiceTreeInterpreter.swift:489–504`, `PrefixMaterializer.swift:484–532`

Every array element is boxed as `Any` (existential container = heap allocation for value types). For a 100-element `[Int]` array, that's 100 unnecessary heap allocations.

This is a fundamental consequence of type erasure in the interpreter and would require significant architectural changes (per-type specialization or unsafe buffer approaches) to fix.

---

### 16. `ChoiceTree` heap allocation per node

Every `indirect` case in the ChoiceTree enum is a separate heap allocation. The `.group([callee, inner])` pattern in `runContinuation` creates deeply nested binary trees of 2-element arrays. For n operations, this is n heap allocations for the groups alone.

A flat arena-based representation or incremental `ChoiceSequence` construction (building the sequence alongside the tree) would eliminate the need for the tree entirely in many code paths.

---

### 17. `String(describing: value)` in VaCTI `.pure` case

**File:** `ValueAndChoiceTreeInterpreter.swift:116`

Every `.pure` resolution calls `String(describing: value)` (reflection-based conversion, potentially very expensive), truncates to 50 chars, and stores it in `ChoiceTree.just(String)`. This string is often discarded by callers.

**Change:** Use a lazy/sentinel approach, or make the `.just` case store an optional `String?` that's computed on demand.

---

### 19. HillClimber `findInteger` is effectively a no-op wrapper

**File:** `HillClimber.swift:85`

`AdaptiveProbe.findInteger` is called but the closure always returns `false` for `k > 0`, meaning the exponential search never engages. The entire call reduces to a single probe with `k=1`. Replace with a direct inline probe to eliminate closure creation overhead.

---

## Verification

After implementing changes, verify by:
1. Running the full test suite: `swift test`
2. Comparing reduction step counts and wall-clock time on existing property test failures
3. Profiling with Instruments (Allocations, Time Profiler) on a benchmark that exercises:
   - Large array generation with filters
   - `#explore` hill climbing on a multi-pick generator
   - Reducer on a medium-complexity counterexample (~100 choice entries)
4. Checking that `ChoiceSequence.flatten` output is identical before/after the accumulator rewrite
5. Verifying Zobrist hash collision rate is acceptable (compare reducer outcomes before/after)
