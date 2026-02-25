# probeAndTune & CGS Analysis

## Comparison to CGS from the Papers

### What Goldstein's CGS Actually Is

Goldstein's CGS (Figure 3.3, Chapter 3) is an **online, per-value** algorithm. During each generation, at each pick site encountered, it:

1. Computes Brzozowski derivatives — one per choice — which are residual generators with that choice already fixed
2. Samples each derivative N times through the full remaining pipeline
3. Counts predicate successes as "fitness"
4. Selects a branch weighted by fitness (falling back to original weights when all fitnesses are 0)

The key property: because each derivative has already committed all choices above it, the sampling is contextually informed. The same pick at the same structural position gets different fitness scores depending on the choices made earlier in that generation.

### Exhaust Has Two Distinct Algorithms, Not One

**`OnlineCGSInterpreter`** is a faithful implementation of Goldstein's online CGS. The `handlePick` at line 382-499 does exactly the derivative-sample-select loop. The `DerivativeWrapper` mechanism (line 30) is a clean way to thread the "all outer continuations" context that Goldstein describes as the derivative composition. This is well done.

**`GeneratorTuning.tune()`** is not CGS at all — it's an **offline batch tuning** that's structurally closer to Tjoa et al.'s approach (minus the BDD/PPL machinery). It performs a single top-down pass, baking fitness-weighted weights into the generator tree. The weights are then static — they don't change per-generation. Calling this "CGS" in the type name is technically misleading; it's more accurately "offline fitness-weighted tuning."

**`probeAndTune`** combines the offline tuning with a structural probe (`containsPicks`) and adaptive smoothing. This is a pragmatic heuristic layer that neither paper describes.

### Substantive Differences from the Papers

| Aspect | Goldstein's CGS | Tjoa et al. | Exhaust (eager `tune`) | Exhaust (online CGS) |
|--------|----------------|-------------|------------------------|---------------------|
| When weights computed | Per-value, per-pick | Once (offline training) | Once (offline) | Per-value, per-pick |
| Scope | Pick sites only | Flat generators | Picks + synthesised picks from chooseBits/getSize | Picks + chooseBits subdivision |
| Sample budget | Uniform N across depth | N/A (exact inference) | Exponential decay with depth | Uniform N |
| Smoothing | Falls back to original weights | Bounded [0.1, 0.9] | Laplace + temperature (post-processing) | Falls back to equal weights |
| Objective | Validity rate | Multiple (entropy, spec entropy, target dist) | Validity rate | Validity rate |

The **chooseBits subdivision** (splitting ranges into 4 subranges and treating them as synthesised picks) is a novel extension not in either paper. Goldstein's formal language interpretation only covers pick sites; Tjoa et al. only support flat generators. This extension is one of Exhaust's genuine innovations, though it introduces the `insideSubdividedChooseBits` threading discussed below.

The **exponential depth decay** (`baseSampleCount / (2 << min(depth - 1, 10))`) is also novel. At depth 5, the budget is `n/32`. For a BST generator with depth-5 recursion, this means deep picks get 1–3 samples with the default `samples: 100`. This is pragmatic for preventing combinatorial blowup but makes deep fitness estimates very noisy.

---

## Naming Conventions

### What Works Well

- **`GeneratorTuning`** — matches the paper name exactly, clearly identifies the technique
- **`DerivativeWrapper`** — correctly maps to Goldstein's Brzozowski derivative concept
- **`successCount`** over the paper's "fitness" — more descriptive in code context
- **`tunedFilterCache`** — clear purpose
- **`smoothAdaptively`** vs `smooth` — the distinction is immediately clear

### Issues

- **`tune` vs `probeAndTune`**: The "auto" prefix suggests automatic parameter selection, but it actually means "probe first, then tune + smooth if needed." `probeAndTune` or `tuneIfApplicable` would be more precise. Currently, "auto" could be confused with auto-differentiation.

- **`OnlineCGSInterpreter`**: Accurate but extremely long (37 characters). More importantly, it correctly uses "CGS" for the online algorithm — but this creates a confusing asymmetry where the `GeneratorTuning` enum (which does the *offline* tuning) also bears the CGS name. If the enum were named `OfflineTuning` or `GeneratorTuning`, the naming would better reflect the actual algorithmic distinction.

- **`insideSubdividedChooseBits`**: This boolean is threaded through every recursive call as a parameter. The name is descriptive but the concept it guards against (preventing double-subdivision) would be clearer as a context property or a distinct operation type.

- **`measureAndTunePick`**: Descriptive but doesn't convey that this is the *core* of the algorithm — it's the fitness measurement + recursive inner tuning. Something like `measureAndTunePick` signals the two-phase nature well.

- **`smooth` / `smoothAdaptively`**: The methods live on `GeneratorTuning` but they're general-purpose weight transformations that could apply to any generator with picks. They're not CGS-specific. Keeping them on `GeneratorTuning` is convenient but conceptually imprecise.

---

## Room for Algorithmic Improvement

### Performance

**1. Double sampling through continuations in `measureAndTunePick`** (lines 228-276)

The top-level fitness measurement creates a `singleBranchPick` and samples through the full continuation (lines 229-246). Then the composed predicate for recursive inner adaptation *also* samples through the continuation for every evaluation (lines 249-261). Since the inner adaptation calls `tuneRecursive` → `measureAndTunePick` again, this creates a multiplicative effect: samples × inner samples × inner-inner samples. For a BST with 3 levels of nested picks, this is `O(N³)` continuation evaluations.

The fix: reuse the top-level fitness measurement results to inform the inner predicate, or batch the sampling.

**2. `tuneZip` is O(components × sampleCount × components) per zip site** (lines 532-592)

Each composed predicate call (line 545) generates ALL other components from scratch (line 551-565). For a 3-way zip with 100 samples, that's 300 fresh component generations just for predicate evaluation in a single component's adaptation. Caching component samples across evaluations would help.

**3. No fitness information flows between online CGS generations**

`OnlineCGSInterpreter.handlePick` recomputes derivatives and resamples from scratch for every pick in every generation. There's no accumulation. Goldstein's paper is intentional about this (fresh context per generation), but a lightweight moving average or cached fitness from recent generations could reduce the per-generation overhead while preserving contextual awareness.

**4. `probeAndTune` latency spike on first filter encounter**

The filter handler in all three interpreters calls `probeAndTune` eagerly on the first encounter of each fingerprint. For complex generators, this means a potentially multi-second tuning pass happens *during* generation. Deferring to a background thread or using a "first N iterations use rejection, then tune" strategy would smooth the latency.

**5. Structural probe overkill**

`probeAndTune` runs full `ValueAndChoiceTreeInterpreter` generations (producing values + choice trees) just to check `containsPicks`. A lightweight walk of the `ReflectiveGenerator` tree — checking for `.pick` operations without generating values — would be O(tree size) instead of O(N × generation cost). This would only miss picks that are dynamically unreachable, which is an edge case.

### Architecture / Implementation

**1. `tune` silently ignores `.resize`** (line 206)

The fallthrough case `case .just, .prune, .resize, .classify: return gen` means picks *inside* a resize wrapper won't be tuned by the eager path. The online CGS interpreter handles resize correctly (line 267-276). This is a correctness gap — if a generator uses `Gen.resize` to wrap a sub-generator with picks, the eager tuner will miss them entirely.

**2. Three tree-walking functions with near-identical structure**

`smoothOperation`, `smoothAdaptiveOperation`, and `profileOperation` all walk the generator tree with the same case-matching pattern. The only meaningful difference is what happens at `.pick` sites. A generic `walkOperations` that takes a pick-handler closure would eliminate ~150 lines of duplication.

```swift
private static func walkOperation<Context>(
    _ op: ReflectiveOperation,
    context: Context,
    handlePick: (ContiguousArray<PickTuple>, Context) -> ReflectiveOperation
) -> ReflectiveOperation
```

**3. Three interpreters duplicate filter handling**

The `.filter` case in `ValueInterpreter` (lines 178-197), `ValueAndChoiceTreeInterpreter` (lines 237-259), and `OnlineCGSInterpreter` (lines 280-308) are structurally identical: cache lookup → `probeAndTune` on miss → rejection loop. This could be extracted to `InterpreterWrapperHandlers` alongside the existing `continueAfterSubgenerator` and `unwrapPruneInput`.

**4. Validity rate as sole objective limits diversity**

Both the eager and online paths optimize purely for validity rate (fitness = success count). Tjoa et al. demonstrate that **specification entropy** — entropy over the *valid* output distribution — produces better test diversity. Exhaust's adaptive smoothing partially addresses this (high temperature at bottleneck sites recovers dead branches), but it's applied as a heuristic post-processing step rather than as a principled objective during tuning.

A concrete improvement: during `measureAndTunePick`, instead of just counting successes, also track the *distinct* outputs produced by successful samples. Weight by `successCount * log(distinctOutputs + 1)` to reward branches that lead to diverse valid outputs, not just frequent ones.

**5. Synthesised pick IDs use random values** (e.g., line 323: `siteID: context.rng.next()`)

When `tuneChooseBits` and `tuneGetSize` create synthesised picks, they assign random `siteID` and `id` values using the RNG. This means the same logical subdivision gets different IDs on different tuning runs (even with the same seed, since the RNG state depends on traversal order). This makes it impossible to correlate synthesised pick sites across tuning runs for incremental refinement. Deterministic IDs based on the operation's position in the tree would be more stable.

**6. `composedPredicate` in `measureAndTunePick` creates a new `ValueInterpreter` per call** (lines 249-261)

Every call to the composed predicate allocates a fresh interpreter, generates through the continuation, and tests the result. Since `tuneRecursive` for inner generators will call this predicate `sampleCount` times per inner pick, the allocation overhead accumulates. Pre-allocating a reusable context or batching would reduce GC pressure.

---

## Summary

The implementation is solid and architecturally well-structured. The key insight I'd highlight:

- **The online `OnlineCGSInterpreter` faithfully implements Goldstein's CGS.** It's the real thing.
- **The eager `GeneratorTuning.tune()` is a distinct algorithm** that's closer to Tjoa et al.'s offline training. The CGS naming creates a false equivalence. Renaming it would clarify the codebase.
- **The biggest performance wins** are in reducing redundant sampling (the multiplicative continuation-through-continuation pattern in `measureAndTunePick` and the per-component regeneration in `tuneZip`).
- **The biggest architectural win** is extracting the duplicated tree-walking logic (smooth/smoothAdaptive/profile/tune all walk the same tree shape).
- **The `.resize` gap in `tuneRecursive`** is the most concerning correctness issue — it silently skips adaptation of picks inside resize blocks.
