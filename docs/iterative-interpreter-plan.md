# Iterative Interpreter: Stack-Safe VACTI and ReductionMaterializer

**Reading guide**: The Architecture and Design sections explain *why* each decision was made. The Implementation Steps section says *what* to do and in *what order*. If you are sitting down to implement Step 1, start at "Implementation steps" and refer back to Design sections as needed for rationale.

**Goal**: This plan fixes a **correctness bug** — `EXC_BAD_ACCESS` stack overflow at bind depth 100 via CoverageRunner. It is not a performance optimization. The performance work in this plan (lazy allocation, fast-path preservation, benchmarking gates) is defensive — ensuring we do not *regress* — not aspirational.

## Context

The Exhaust framework's interpreters use mutual recursion between `generateRecursive` and `runContinuation` to walk the FreerMonad. Bind-based recursive generators hit two independent problems at depth:

1. **Combinatorial explosion** from `materializePicks: true` interpreting all pick branches inside bind-bound regions — cost is O(branches^depth).
2. **Stack overflow** from recursive selected-path interpretation — ~10 frames per bind level, overflows at ~depth 50-70.

Problem 1 is solved by disabling `materializePicks` inside bind-bound regions in VACTI's `handleTransform(.bind)` (implemented). The analysis treats bind-bound content as opaque, so materialized branches there are wasted work.

Problem 2 is confirmed by stack traces from both GuidedMaterializer and ReductionMaterializer at depth 100. The repeating pattern is:

```
handleTransform(.bind) → generateRecursive → handleZip → generateRecursive
  → handleContramap → generateRecursive → handleContramap → generateRecursive
  → handlePick → generateRecursive → handleTransform(.bind) → ...
```

~10 frames per bind level. This is pure recursion depth on the selected path — no branch fan-out, no materialization. The iterative continuation trampoline is the fix.

## Two independent problems, two fixes

| Problem | Cause | Fix | Status |
|---|---|---|---|
| Combinatorial explosion | `materializePicks` in bind-bound regions | Disable `materializePicks` before interpreting bound generator in `handleTransform(.bind)` | Implemented in VACTI |
| Stack overflow | Recursive `generateRecursive`/`runContinuation` mutual recursion | Iterative continuation stepping (this plan) | Not implemented |

Both fixes are needed. Without fix 1, depth 10 takes 102 seconds. Without fix 2, depth 100 stack overflows even with `materializePicks: false`.

## Architecture

### Two sources of recursion

1. **Continuation chain (horizontal)**: `generateRecursive` → handler → `runContinuation` → `continuation(result)` → `generateRecursive` → ... Each `.impure` node in the FreerMonad chain adds one round of this mutual recursion.

2. **Sub-generator interpretation (vertical)**: Operations like `pick`, `zip`, `sequence`, `transform(.bind)` contain sub-generators that are interpreted via recursive `generateRecursive` calls.

### Why trampolining source 1 also fixes source 2

Each recursive `generateRecursive` call for a sub-generator enters its own iterative loop. The continuation chain within that sub-generator runs iteratively, not recursively. Recursion only occurs at sub-generator *boundaries* — entering a pick branch, a zip child, a bind's inner or bound generator.

**Current cost** (mutual recursion): each bind level costs ~10 stack frames (confirmed by stack trace: handleTransform → generateRecursive → handleZip → generateRecursive → handleContramap × 2 → generateRecursive → handlePick → generateRecursive → back to handleTransform).

**After trampolining**: each bind level costs ~4-6 recursive frames at peak depth. Named handler functions (`handleTransform`, `handleZip`, `handlePick`) each add a frame in addition to their `generateRecursive` sub-generator calls. Sub-generator calls within a bind level are *sequential*, not concurrent — `handleZip` interprets child 1, pops its frames, then interprets child 2. The peak depth is the longest chain of nested entries live simultaneously:

- `handleTransform(.bind)` [frame 1] → `generateRecursive(innerGen)` [frame 2]
  - `handleZip` [frame 3] → `generateRecursive(child)` [frame 4]
    - `handlePick` [frame 5] → `generateRecursive(selectedBranch)` [frame 6] → next bind level

The bound generator is interpreted *after* the inner generator returns (sequential, not nested), so it reuses the same stack space. Zip children are also sequential — fan-out does not multiply peak depth. Contramaps and continuation chains become loop iterations, not stack frames. At ~4-6 frames per bind level (depending on generator shape), theoretical depth limit rises from ~100 to ~400-600 on a 512KB stack. The degenerate case (pure nested binds, no zip or pick) costs 2 frames per level. Generators with wider sub-generator fan-out increase the per-level peak by the nesting depth of the widest path, not by the total child count.

### Affected interpreters

| Interpreter | File | Stack overflow confirmed? | Priority |
|---|---|---|---|
| ReductionMaterializer | `Interpreters/Reduction/ReductionMaterializer.swift` | Yes (stack trace at depth 100) | 1 |
| VACTI | `Interpreters/Generation/ValueAndChoiceTreeInterpreter.swift` | No (materializePicks fix prevents reaching depth) | 2 |
| GuidedMaterializer | `Exploration/GuidedMaterializer.swift` | Yes (stack trace at depth 100) | Replaced by ReductionMaterializer in CoverageRunner |
| ValueInterpreter | `Interpreters/Generation/ValueInterpreter.swift` | No (no tree construction, lightweight frames) | 3 |
| OnlineCGSInterpreter | `Interpreters/Adaptation/OnlineCGSInterpreter.swift` | Not tested | 4 |

All in `Sources/ExhaustCore/`.

### Why ReductionMaterializer is the sole correctness-critical target

`CoverageRunner.runFinite` and `runBoundary` previously used `GuidedMaterializer` for bind-aware replay and `Interpreters.replay` for non-bind generators. Both paths have been replaced with `ReductionMaterializer` in guided mode — a single materializer for all coverage replay. This means:

- **ReductionMaterializer** is the only interpreter that (a) crashes and (b) is actively used in production paths.
- **GuidedMaterializer** crashes but is no longer called by CoverageRunner — deprioritized.
- **VACTI** survives depth 100 because random generation statistically avoids the deep paths that coverage forcing exposes. It would only crash if a user constructed a generator where random paths consistently hit depth 50+.

### Scope and stopping criteria

This plan converts interpreters incrementally. After each step, the stopping criterion is: **does any remaining interpreter crash on inputs that production code paths actually produce?**

After Step 1 (ReductionMaterializer): the sole confirmed crash site is fixed. Step 2 (VACTI) is worth doing only if one of these conditions holds:
- A user-facing generator is discovered where random generation (not coverage replay) routinely reaches depth 50+.
- VACTI is adopted for a new code path that forces deep traversal (analogous to coverage rows forcing depth in ReductionMaterializer).
- The conversion is low-effort because ReductionMaterializer's pattern can be copied with minimal adaptation.

If none of these hold after Step 1, the remaining steps are deferred indefinitely.

#### Alternative mitigation: coverage depth cap

Coverage analysis could cap the maximum depth in covering array rows — if analysis determines that depth beyond some threshold is statistically negligible, it would avoid generating rows that force deep paths. This would not replace the trampoline (the crash is a correctness bug for any input that reaches the depth), but it would reduce the frequency of triggering it. A depth cap is a separate concern from this plan and is not a substitute for stack safety.

## Design

### Core change: iterative continuation stepping

Convert `generateRecursive` from mutual recursion with `runContinuation` into a `while` loop. Each iteration processes one `.impure` node: the handler interprets the operation (possibly recursing into sub-generators), then the loop calls the continuation and continues.

**Before** (current):
```
generateRecursive(gen)
  → handler(operation)
    → runContinuation(result, calleeTree, continuation)
      → continuation(result) → nextGen
      → generateRecursive(nextGen)   ← RECURSIVE CALL
        → handler(operation2)
          → runContinuation(...)
            → ...
```

**After** (iterative):
```
loop:
  match gen on .impure(operation, continuation)
  → handler(operation) → (result, calleeTree)
  → treeStack.push(calleeTree)
  → gen = continuation(result)
  → continue loop
```

When a handler calls `generateRecursive` for a sub-generator (pick branch, zip child, bind inner/bound), that call enters a fresh iterative loop. The recursion depth equals the number of sub-generator boundaries crossed, not the total number of FreerMonad operations in the chain.

### ChoiceTree accumulation

The current recursive approach builds `.group([calleeTree, innerTree])` bottom-up. The iterative approach accumulates callee trees in a stack and right-folds at the end:

```swift
// Stack: [treeA, treeB, treeC] + leaf
// Fold:  group([treeA, group([treeB, treeC])])
```

Right-fold function:
```swift
func foldTreeStack(_ stack: inout ContiguousArray<ChoiceTree>) -> ChoiceTree {
    guard var result = stack.popLast() else { return .emptyJust }
    while let callee = stack.popLast() {
        result = .group([callee, result])
    }
    return result
}
```

This preserves the exact tree shape produced by the recursive implementation.

**Handlers that produce no tree**: Operations like `.just` and `.getSize` produce no choice — they return a result but `.emptyJust` as their callee tree. The actual `runContinuation` (ReductionMaterializer lines 320-344) has three paths:

1. `calleeChoiceTree.isChoice && nextGen.isPure` → returns `calleeChoiceTree` directly (fast path, never reached for `.emptyJust` since it is not `.isChoice`).
2. `nextGen.isPure` (but callee is not `.isChoice`) → returns `calleeChoiceTree` without group wrapping.
3. Non-pure continuation → returns `.group([calleeChoiceTree, innerChoiceTree])` unconditionally, including when `calleeChoiceTree` is `.emptyJust`.

So `.emptyJust` **is** wrapped in a group when there is a non-pure continuation. The iterative version should push `.emptyJust` unconditionally. The fold produces `group([.emptyJust, rest])` which matches the recursive version. The `.pure` continuation case is handled by the loop break (returning the callee tree directly without folding), matching path 2 above. No filter step or sentinel is needed.

**Fast path preservation**: The current fast path fires when `calleeChoiceTree.isChoice && nextGen.isPure` — it short-circuits before building `group([callee, inner])`. In the iterative version, this translates to: after the handler returns a choice tree and the continuation returns `.pure`, the loop breaks early and returns the tree directly without pushing to the stack or folding. This preserves the zero-allocation fast path for the common case. The tree stack should be allocated lazily — only on the second loop iteration — so that the common single-`chooseBits` → `.pure` path incurs no `ContiguousArray` allocation or deallocation overhead.

### Two handler categories: callee-only vs. continuation-consuming

Most handlers follow a uniform pattern: produce a `(result, calleeTree)`, then call `runContinuation(result, calleeTree, continuation)`. The continuation tree ends up OUTSIDE the callee tree as `group([calleeTree, continuationTree])`. These are **callee-only** handlers — the iterative loop can call the continuation itself and accumulate the tree.

Two handlers do NOT follow this pattern:

- **handlePick**: calls `runContinuation` for EACH branch individually, embedding each branch's continuation tree INSIDE the branch node. The pick tree structure is `group([branch(choice: group([branchCallee, continuationTree])), ...])` — symmetric, with every branch containing its own continuation tree. If the loop called the continuation instead, the selected branch's continuation tree would end up outside the pick node, producing an asymmetric tree. ChoiceSequence flattening walks depth-first, so this asymmetry would reorder entries in the flattened sequence, breaking reduction.
- **handleSequence**: calls `runContinuation` for the result value but intentionally discards the continuation tree, returning only the sequence tree. The continuation has side effects (PRNG advancement, cursor movement) that must execute, but the tree is not recorded.

Both are **continuation-consuming** handlers — they call the continuation internally. The loop must NOT call the continuation again.

### Loop action design

The loop needs two paths:

```swift
enum LoopAction {
    case advance(CalleeResult)   // Push tree, call continuation, continue loop
    case terminal(Any, ChoiceTree) // Push tree, return — handler consumed continuation
}

// In the loop:
switch handler(operation) {
case let .advance(callee):
    treeStack.push(callee.calleeTree)
    gen = continuation(callee.result)
    // continue loop
case let .terminal(result, fullTree):
    treeStack.push(fullTree)
    return (result, fold(treeStack))
}
```

For a chain `chooseBits → pick → contramap → pure`:
1. Iteration 1: handleChooseBits → `.advance`, push calleeTree1, gen = continuation(bits)
2. Iteration 2: handlePick → `.terminal`, push fullPickTree (branches embed their continuations)
3. Fold: `group([calleeTree1, fullPickTree])` — matches the recursive version exactly.

### handlePick as a continuation-consuming handler

handlePick calls `runContinuationForBranch` for ALL branches (selected and non-selected). Each branch's tree embeds `group([branchCallee, continuationTree])`, preserving the symmetric pick structure. The handler returns `.terminal(finalValue, .group(branches))`.

```swift
// After (iterative):
func handlePick(...) -> LoopAction? {
    var branches: [ChoiceTree.Branch] = []
    for (index, choice) in choices.enumerated() {
        let (branchResult, branchTree) = generateRecursive(choice.generator)
        // ALL branches go through runContinuationForBranch — this embeds
        // the continuation tree inside each branch, preserving the symmetric
        // pick structure that ChoiceSequence flattening requires.
        let (contValue, contTree) = runContinuationForBranch(
            result: branchResult, calleeChoiceTree: branchTree,
            continuation: continuation
        )
        if index == selectedIndex {
            finalValue = contValue
            branches.append(.selected(.branch(..., choice: contTree)))
        } else {
            branches.append(.branch(..., choice: contTree))
        }
    }
    return .terminal(finalValue, .group(branches))
}
```

**Stack depth impact**: handlePick's `runContinuationForBranch` calls `generateRecursive` recursively, which enters a new iterative loop. This adds one recursive frame per handlePick call. For the selected branch, this is the continuation that was previously trampolined — it is no longer trampolined. However, `materializePicks` is disabled inside bind-bound regions, so the deep recursion case (inside bind) only processes the selected branch. The cost is one recursive `generateRecursive` frame for the selected branch's continuation — the same as any other sub-generator entry.

### Handler refactoring pattern

Each callee-only handler changes from returning `(Output, ChoiceTree)?` (via `runContinuation`) to returning `.advance(CalleeResult)`. Continuation-consuming handlers (handlePick, handleSequence) return `.terminal(result, fullTree)`.

**Type erasure tradeoff**: The `Any` return erases the generic type that currently flows through handlers. Type errors become runtime crashes rather than compile-time failures. However, the erasure boundary is narrow (handler → loop → continuation call) and the continuation itself already performs the cast. The alternative — parameterizing the loop over `Output` — would require existential handler dispatch or a protocol with associated types, adding complexity without reducing the cast count. The mitigation is thorough test coverage: any type mismatch will surface as a crash in the existing test suite, not as silent data corruption.

To make the handler contract discoverable for future contributors:

```swift
/// The callee-only result returned by callee-only handlers.
///
/// `calleeTree` is the tree produced by *this* operation alone — it must NOT include
/// the continuation's tree. The loop calls `continuation(result)` to advance to the
/// next generator, and accumulates `calleeTree` in a stack for right-folding.
/// Returning a tree that includes continuation content will silently double a subtree
/// in the fold.
typealias CalleeResult = (result: Any, calleeTree: ChoiceTree)

/// What a handler tells the iterative loop to do next.
///
/// `.advance`: the handler produced a callee tree. The loop pushes it and calls the continuation.
/// `.terminal`: the handler consumed the continuation internally. The loop pushes the full tree and returns.
enum LoopAction {
    case advance(CalleeResult)
    case terminal(result: Any, fullTree: ChoiceTree)
}
```

Example — callee-only (`handleChooseBits`):
```swift
// Before: calls runContinuation internally
// After: returns .advance((randomBits, choiceTree)), loop calls continuation
```

Example — continuation-consuming (`handlePick`):
```swift
// Before: calls runContinuation per branch, returns (finalValue, .group(branches))
// After: calls runContinuationForBranch per branch, returns .terminal(finalValue, .group(branches))
```

### Fallback tree threading in the loop

In the current recursive implementation, `fallbackTree` is passed as a parameter to `generateRecursive` and decomposed at each operation. In the iterative version, the loop maintains `currentFallback` as mutable state alongside `currentGen` and `treeStack`.

Each iteration: decompose `currentFallback` into `(calleeFallback, continuationFallback)`. Pass `calleeFallback` to the handler. Update `currentFallback = continuationFallback`. The decomposition is shape-dependent:

- **Group-shaped fallback** `group([callee, continuation])`: split into `calleeFallback = callee`, `continuationFallback = continuation`.
- **Non-group fallback** (leaf, branch, or `.none`): `calleeFallback = currentFallback`, `continuationFallback = .none`. The callee gets whatever information is available; continuation proceeds without guidance.

After reduction, fallback tree shape may diverge from the generated tree shape. The decomposition functions handle this gracefully — the same way they do in the recursive version. This is inherited behavior, not new complexity.

**Why eager decomposition, not lazy**: The fallback must be decomposed *before* the handler runs, because the handler needs `calleeFallback` to guide sub-generator interpretation (for example, ReductionMaterializer in guided mode uses the fallback to replay specific choices). Deferring decomposition to fold time would be too late — the handler has already made decisions without guidance. The four co-evolving mutable variables (`currentGen`, `currentFallback`, `treeStack`, loop-local handler state) are the essential minimum.

**Fallback exhaustion**: When the continuation chain is longer than the fallback tree's group nesting — for example, five continuation steps but only two levels of `group([_, _])` — `continuationFallback` becomes `.none` after the second decomposition and stays `.none` for the remaining three steps. This is expected behavior: the fallback guides as far as it can, then the materializer falls back to its default behavior (PRNG in generate mode, zero-fill in minimize mode). This is the same behavior the recursive version exhibits when the fallback tree is shallower than the generator — each `runContinuation` call decomposes whatever is left, and once the fallback is exhausted, subsequent operations see `.none`. Fallback exhaustion is not a degradation bug; it is the normal end of guided replay for partially-specified fallback trees.

### Why the loop mechanics are not shared across interpreters

Each interpreter threads different state through its loop: ReductionMaterializer has `fallbackTree` + `cursor` + `mode`; VACTI has `materializePicks` flag + depth tracking; OnlineCGSInterpreter has `DerivativeContext`. The handler signatures, return types, and post-handler bookkeeping differ enough that a shared `iterateFreerMonad` abstraction would need to be parameterized over all of this — effectively a protocol with associated types and closure parameters.

The shared structural skeleton — `while true` over the FreerMonad, handler dispatch, tree-stack push, continuation call — is ~15 lines. But the full loop body for ReductionMaterializer will be substantially longer: fallback decomposition, fast-path check, lazy tree-stack allocation, mode-dependent dispatch across four modes (exact, guided, generate, minimize), and the fold at the end. The "~15 lines" refers to the structural pattern that repeats, not the total per-interpreter code. This is stated explicitly to prevent premature generalization — the shared skeleton is small but the per-interpreter wrapping is not.

## Implementation steps

### Step 1: Refactor ReductionMaterializer `generateRecursive` into a loop

**File**: `Sources/ExhaustCore/Interpreters/Reduction/ReductionMaterializer.swift`

Priority target — confirmed stack overflow at depth 100 via CoverageRunner, and it is now the sole materializer used by CoverageRunner. This is a 1,243-line file with four modes (exact, guided, generate, minimize), nine handlers, and five inline operation cases.

**Commit strategy**: Each sub-step below is one commit. The test suite must pass after each commit, enabling `git bisect` if a regression surfaces later. Do not attempt the whole conversion as a single atomic change — the file is too large and the handlers too varied for a single commit to be reviewable or debuggable.

The conversion order is designed to provide early proof-of-concept validation before tackling the harder cases.

1. Retain `runContinuation` as a `private` helper, renamed to `runContinuationForBranch`. Post-conversion, its callers are handlePick (all branches) and handleSequence (for the result value). Renaming makes the dependency explicit. Add a doc comment: "Retained for continuation-consuming handlers that embed or execute the continuation internally."
2. Convert `generateRecursive` to a `while true` loop. This commit introduces the loop skeleton including: `LoopAction` enum, `CalleeResult` typealias, fallback decomposition per iteration (see "Fallback tree threading in the loop"), and a plain `ContiguousArray<ChoiceTree>` tree stack (unconditional allocation — simplest correct thing). Fallback threading is part of the loop skeleton from the start — not a late refinement — because handlers in guided and exact modes depend on receiving their `calleeFallback` to function correctly. All handler dispatch initially delegates to the existing named functions (which still call `runContinuation` internally), wrapping their results as `.terminal`. Tests pass trivially because behavior is unchanged. The lazy tree-stack optimization (step 10) is deferred until all handlers are converted and the test suite confirms structural equality — this gives a clean bisect point if the lazy path introduces a subtle bug.
3. Convert `handleChooseBits` first as proof-of-concept — simplest handler, no sub-generators, returns `.advance`. Exercises the core loop + continuation + tree-push pattern. Verify all tests pass before proceeding.
4. Convert `handleContramap` as the second proof-of-concept — it wraps a sub-generator via `generateRecursive`, so it validates that the tree-stack push/fold produces the correct shape for multi-step handlers. `handleChooseBits` alone only proves the loop skeleton; `handleContramap` proves the accumulation mechanics.
5. Convert remaining callee-only handlers and inline cases: `handlePrune`, `handleResize`, inline `.just`, inline `.getSize`, inline `.filter`, inline `.classify`, inline `.unique`. All return `.advance`.
6. Convert `handleZip` — sub-generator `generateRecursive` calls but straightforward tree construction, returns `.advance`.
7. Convert `handleTransform`: `.map` is simple (no sub-generators beyond inner), returns `.advance`; `.bind` is the most complex callee-only case (inner + bound sub-generators, cursor suspension/resume). The handler suspends the cursor, interprets inner and bound generators (both recursive calls into fresh iterative loops), resumes the cursor, and returns `.advance`. The cursor resume happens *in the handler before it returns* — the same point relative to the continuation call as in the recursive version. The ordering is preserved.
8. Convert `handlePick` to return `.terminal` — calls `runContinuationForBranch` for ALL branches (selected and non-selected), preserving the symmetric tree structure where each branch embeds its continuation tree. See "handlePick as a continuation-consuming handler" in the Design section.
9. Convert `handleSequence` to return `.terminal` — calls `runContinuationForBranch` for the result value, returns the sequence tree only (discards continuation tree, matching current behavior).
10. Preserve the `calleeTree.isChoice && nextGen.isPure` fast path via the lazy tree-stack pattern:

    ```swift
    var firstCalleeTree: ChoiceTree?  // Holds first tree before stack allocation
    var treeStack: ContiguousArray<ChoiceTree>?  // Allocated lazily on second iteration

    // On first .advance: store in firstCalleeTree, check fast path
    // On second .advance: allocate treeStack, push firstCalleeTree and current tree
    // On .terminal or .pure after first iteration: return firstCalleeTree directly
    ```

    This avoids `ContiguousArray` allocation for the common single-`chooseBits` → `.pure` path. For the two-operation case (`getSize` → `chooseBits` → `.pure`, common in size-scaled generators), the stack is allocated with one element pending. If this shows measurable overhead at millions of invocations, a fixed-size inline buffer (four-element tuple as stack, spilling to `ContiguousArray` only if exceeded) is a future optimization — not needed for ReductionMaterializer where per-invocation cost is dominated by fallback decomposition.

### Step 2: Refactor VACTI (conditional)

**File**: `Sources/ExhaustCore/Interpreters/Generation/ValueAndChoiceTreeInterpreter.swift`

Same pattern as ReductionMaterializer but simpler (no fallback tree threading). The bind-bound `materializePicks` fix remains in `handleTransform`.

**Gate**: Only proceed if the stopping criteria from "Scope and stopping criteria" are met. VACTI at depth 100 currently passes in 2ms — random generation statistically avoids the deep paths that would overflow. This step is insurance against a failure mode that production usage has not triggered.

**Performance gate**: If this step proceeds, benchmark before merging. Generator: `.string(of: .ascii, length: 0...100)` (high `chooseBits` call count per value). Metric: wall-clock time for 10,000 values via VACTI. Threshold: less than 5% regression versus the recursive baseline. If the regression exceeds 5%, investigate whether lazy tree-stack allocation and fast-path preservation are correctly eliminating allocations for the `chooseBits` → `.pure` common case.

### Step 3: Refactor remaining interpreters

- **ValueInterpreter**: Simplest — no tree construction, just loop over values
- **OnlineCGSInterpreter**: Same pattern with `DerivativeContext` threading

GuidedMaterializer is deprioritized — CoverageRunner no longer uses it.

### Step 4: Stack safety tests

**File**: `Tests/ExhaustCoreTests/Interpreters/StackSafetyTests.swift` (new)

- **Depth 100** (regression gate): bind-based recursive generator via ReductionMaterializer — the confirmed crash case. Must pass.
- **Depth 400** (headroom validation): same generator shape — at ~4-6 frames per bind level, depth 400 is within the limit for the parser-style shape.
- **Depth 500** (canary): same generator shape. Expected to pass, but closer to the theoretical limit (~400-600). If a future change increases per-level frame cost (for example, adding a wrapper operation), this test will fail before depth-400 does, providing early warning of headroom erosion.
- **Nested bind at depth 600** (degenerate case): a generator where each bind's inner gen is itself a bind (no zip or pick between levels). This is 2 recursive frames per bind level: `handleTransform` is a named function call (1 frame) which calls `generateRecursive(innerGen)` (1 frame) entering a new iterative loop. At depth 600 this is ~1200 frames — validates that the cheapest per-level case has substantial headroom.
- **Wide-fan-out at depth 150**: a generator where each bind level contains a zip of three sub-generators each containing a pick (~6 frames per level), to validate that the per-level frame count holds for non-typical shapes.
- **Pick nesting depth 30 outside bind** (canary for the non-trampolined path): a generator with picks nested 30 deep outside any bind-bound region, with `materializePicks: true`. handlePick's `runContinuationForBranch` recursively interprets every branch's continuation — this is the one path where the trampoline does not help. Pick nesting without bind is unusual in practice, but this confirms the cost stays within budget.
- **Shallow fallback tree**: a generator with a five-step continuation chain replayed against a two-level fallback tree. Verifies that fallback exhaustion (transition from group-shaped to `.none`) produces identical output to the recursive version — not just "doesn't crash" but structurally equal trees and values. The step 4 structural equality tests likely cover this implicitly via existing test generators, but a dedicated test makes the contract explicit.
- **Depth 100 via VACTI** (only if Step 2 is executed).
- **Tree shape structural equality**: same seed produces structurally equal `ChoiceTree` and value (by `Equatable` conformance, not reference identity — no tests compare trees by reference).

## Verification

1. All existing tests pass with structurally equal output (same seeds, same values, same trees by `Equatable` — not reference identity)
2. Depth 100, 400, and 500 bind-based generators via ReductionMaterializer run without stack overflow
3. Nested-bind (depth 600) and wide-fan-out (depth 150) generators via ReductionMaterializer run without stack overflow
4. Performance: run Parser shrinking challenge and verify phase timings are not regressed. No quantitative threshold — ReductionMaterializer's per-invocation overhead is already dominated by fallback decomposition and mode dispatch, so the trampoline overhead is expected to be unmeasurable. Any measurable regression would indicate a bug (for example, the fast path not firing), not an inherent cost.
5. `RecursiveOperationTests`, `CalculatorShrinkingChallenge`, `ParserShrinkingChallenge` all produce structurally equal counterexamples

## Risks

- **Tree shape divergence**: If the right-fold accumulation produces subtly different trees, ChoiceSequence flattening and reduction could break. Mitigate by running all tests with tree comparison assertions during development. Trees are compared by structural equality (`Equatable`), not reference identity.
- **handlePick is not trampolined**: handlePick is a continuation-consuming handler — it calls `runContinuationForBranch` for all branches, preserving the symmetric tree structure. Its continuation is NOT trampolined. This is acceptable because `materializePicks` is disabled inside bind-bound regions, so the deep recursion case only processes the selected branch. The cost is one recursive `generateRecursive` frame for the continuation, equivalent to any other sub-generator entry.
- **Type erasure at handler boundary**: Handlers return `Any` instead of the generic `Output` type. Type mismatches become runtime crashes rather than compile-time errors. Mitigated by: the erasure boundary is narrow (one cast per continuation call), and the existing test suite will surface any mismatch as a crash, not silent corruption.
- **Performance**: The `ContiguousArray<ChoiceTree>` allocation per `generateRecursive` call adds overhead. Mitigated by lazy allocation (only on second loop iteration) so the common single-operation → `.pure` fast path remains zero-allocation. The performance-sensitive case (VACTI with string generators, hundreds of `chooseBits` calls per value) is separate from the correctness-critical case (ReductionMaterializer with deep binds). ReductionMaterializer's per-invocation cost is already higher (fallback decomposition, mode dispatch, cursor operations), so the relative overhead of the array allocation is smaller. If VACTI conversion (Step 2) proceeds, benchmark string generation against a concrete threshold (see Step 2 performance gate).
- **Maintenance surface**: Five interpreters with per-interpreter loop + fold + handler refactoring. The shared structural skeleton is ~15 lines, but the full loop body for ReductionMaterializer is substantially longer (fallback decomposition, mode dispatch, fast-path check, lazy allocation). The loop mechanics are not shared because each interpreter threads different state (see "Why the loop mechanics are not shared"). The `LoopAction` enum and `CalleeResult` typealias make the handler contract explicit: a new `ReflectiveOperation` case must return either `.advance` (callee-only) or `.terminal` (continuation-consuming), and the doc comments explain which to choose.

## Empirical data

### Problem 1: Combinatorial explosion (fixed)

| Generator | Interpreter | Depth | Before fix | After fix |
|---|---|---|---|---|
| Parser-style (8 picks) + bind | VACTI | 10 | 102s | 5ms |
| Parser-style (8 picks) + bind | VACTI | 20 | never terminates | 12ms |
| Parser-style (8 picks) + bind | VACTI | 100 | never terminates | 2ms (generation) |

Fix: disable `materializePicks` in `handleTransform(.bind)` before interpreting bound generator.

### Problem 2: Stack overflow (this plan)

| Generator | Interpreter | Depth | Result |
|---|---|---|---|
| Parser-style + bind | ReductionMaterializer (via CoverageRunner) | 100 | `EXC_BAD_ACCESS (code=2)` — stack overflow |
| Parser-style + bind | GuidedMaterializer (via CoverageRunner) | 100 | `EXC_BAD_ACCESS (code=2)` — stack overflow |
| Parser-style + bind | VACTI (generation, not coverage replay) | 100 | Pass, 2ms |
| Parser-style + bind | ValueInterpreter | 100 | Pass, <1ms |

The stack traces show ~10 frames per bind level repeating: `handleTransform(.bind)` → `generateRecursive` → `handleZip` → `generateRecursive` → `handleContramap` × 2 → `generateRecursive` → `handlePick` → `generateRecursive` → back to `handleTransform(.bind)`.

**Stack size context**: Swift's default thread stack is 512KB (main thread 8MB on macOS). At ~10 frames per bind level with typical frame sizes (~200-500 bytes each), depth 100 produces ~1,000 frames ≈ 200-500KB — near the non-main thread limit. The crash has been observed on arm64; x86_64 frame sizes differ slightly but the limit is similar. Swift Testing and XCTest may run tests on different thread configurations, but both use 512KB worker threads.

**Post-trampoline estimate**: After conversion, each bind level costs ~4-6 recursive frames at peak depth (named handler functions add a frame each; see "Why trampolining source 1 also fixes source 2" for the detailed breakdown). The degenerate case (pure nested binds) costs 2 frames per level. Sub-generator calls are sequential (zip child 1's frames are popped before child 2 starts), so fan-out does not multiply peak depth. At ~4-6 frames per level, theoretical depth limit rises to ~400-600 on a 512KB stack. Depth 400 is a conservative stress test target; depth 500 is the canary.

VACTI and ValueInterpreter survive because they don't enter the coverage replay path. The coverage replay forces specific depth values via covering array rows, hitting the deep paths that random generation statistically avoids.

## Future evolution: fully iterative interpreter via continuation stack

The plan above trampolines the continuation chain (horizontal recursion) but preserves recursive `generateRecursive` calls for sub-generator boundaries (vertical recursion). Each handler that wraps a sub-generator — handleContramap, handleZip, handleTransform(.bind), handlePick — still calls `generateRecursive` recursively. Each call enters the iterative loop, so it is a single frame, but the frames nest: bind → zip → contramap → pick → next bind produces ~4-6 frames per bind level.

These sub-generator entries do not *need* to be recursive. `generateRecursive` is an iterative loop. Instead of calling it recursively, each sub-generator boundary can push the current continuation and tree-stack position onto an explicit **continuation stack** and switch `gen` to the sub-generator, continuing the same loop:

```swift
// Sub-generator entry (e.g., handleContramap encountering nextGen):
continuationStack.push((continuation, treeStack.count))
gen = nextGen
continue loop

// Sub-generator completion (.pure):
if let (savedContinuation, savedPosition) = continuationStack.pop() {
    let calleeTree = foldTreeStack(from: savedPosition)
    treeStack.push(calleeTree)
    gen = savedContinuation(value)
    continue loop
} else {
    return (value, foldTreeStack(from: 0))
}
```

This eliminates ALL recursive `generateRecursive` calls. Every sub-generator boundary becomes a push/pop on a heap-allocated continuation stack. The result is a single flat loop with **O(1) thread stack depth** regardless of generator depth. The stack overflow becomes structurally impossible at any depth.

**Why this is not the plan**: handlePick is a continuation-consuming handler that calls `runContinuationForBranch` for each branch in a loop. Flattening this into the continuation stack requires serializing handlePick's branch-iteration state into continuation-stack operations — essentially coroutine-style interleaving. This is doable but touches every handler simultaneously rather than allowing incremental, per-commit conversion. The mixed approach (iterative loop with recursive sub-generator entries) is the pragmatic first step: it fixes the crash, is incrementally verifiable, and raises the depth limit from ~100 to ~400-600.

If the depth limit of ~400-600 proves insufficient, or if debug-mode performance of the interpreter becomes a concern (the fully iterative version eliminates ~5-6 function calls per bind level, meaningful in debug builds where `@inline(__always)` is ignored), the continuation-stack architecture is the next step. It builds on the iterative loop from this plan — the loop body, `LoopAction` enum, `CalleeResult` typealias, and tree-stack folding all carry over. The change is: replace recursive `generateRecursive` calls with continuation-stack push/pop.
