# Exhaust vs. Goldstein's "Property-Based Testing for the People"

A detailed comparison of the Exhaust framework against Harrison Goldstein's PhD dissertation (UPenn, 2024), analyzing fidelity across the Freer Monad foundation, interpreter architecture, and Choice Gradient Sampling.

---

## 1. Freer Monad Foundation

**Dissertation**: `data Freer f a = Return a | Bind (f x) (x -> Freer f a)` — the standard freer monad with an existential intermediate type. Free generators are `Freer Pick a` (Chapter 3); reflective generators are `Freer (R b) a` where `R b` carries `Pick`, `Lmap`, `Prune`, `ChooseInteger`, `GetSize`, `Resize` (Chapter 4).

**Exhaust** (`Sources/ExhaustCore/Core/Types/FreerMonad.swift`):

```swift
enum FreerMonad<Operation, Value> {
    case pure(Value)
    indirect case impure(
        operation: Operation,
        continuation: (Any) throws -> FreerMonad<Operation, Value>
    )
}
```

Structurally identical. The existential intermediate type is handled via `Any` + type erasure — the only option in Swift's type system. The `bind()` and `map()` methods implement the monad interface. `ReflectiveGenerator<Value>` is a type alias for `FreerMonad<ReflectiveOperation, Value>`, mirroring the dissertation's `type Reflective b a = Freer (R b) a`.

**Verdict: Faithful.** The encoding is a direct translation.

---

## 2. Operation Set

### Dissertation's `R b a` (6 constructors)

| Dissertation | Exhaust | Notes |
|---|---|---|
| `Pick [Labeled (Gen a)]` | `.pick(choices: ContiguousArray<PickTuple>)` | Exhaust adds `siteID` for CGS tracking and `weight: UInt64` per choice |
| `Lmap (b -> Maybe a)` | `.contramap(transform: (Any) -> Any?, next:)` | Same semantics — partial lens. Exhaust bundles the sub-generator with the operation |
| `Prune` | `.prune(next:)` | Identical: handles `nil` from contramap |
| `ChooseInteger (Int, Int)` | `.chooseBits(min: UInt64, max: UInt64, tag:, isRangeExplicit:)` | Exhaust generalizes to all `BitPatternConvertible` types via `TypeTag` — handles Int, Float, Bool at the bit-pattern level. Characters are represented as integral indices into a `CharacterSet`, not as direct bit patterns |
| `GetSize` | `.getSize` | Identical |
| `Resize Int` | `.resize(newSize:, next:)` | Identical |

### Exhaust-only operations (6 additional)

| Operation | Purpose |
|---|---|
| `.sequence(length:, gen:)` | Stack-safe collection generation, avoids recursive bind chains |
| `.zip(generators:)` | Parallel composition without monadic nesting |
| `.just(Any)` | Constant value (the dissertation handles this via `Return`/`pure`) |
| `.filter(gen:, fingerprint:, filterType:, predicate:)` | Explicit validity marker for CGS optimization |
| `.classify(gen:, fingerprint:, classifiers:)` | Distribution statistics and coverage reporting |
| `.unique(gen:, fingerprint:, keyExtractor:)` | Deduplication via choice-sequence or key-based tracking |

**Verdict: Superset.** All 6 dissertation operations are present with faithful semantics. Exhaust adds 6 more, primarily for practical concerns: stack safety (`sequence`), ergonomics (`zip`, `just`), and observability (`filter`, `classify`, `unique`). The `filter` operation is particularly notable — the dissertation handles validity constraints at the CGS level, but Exhaust reifies them into the operation set so any interpreter can react to them.

---

## 3. Interpreter Architecture

### Dissertation (7+ interpretations)

1. **generate** — forward, produce values
2. **parse** — extract value from choice sequence
3. **randomness** — produce distribution over choice sequences
4. **reflect** — backward, decompose value into choice sequences
5. **choices** — backward, extract bracketed choice sequences for shrinking
6. **genWithWeights** — forward with example-derived weights
7. **complete** — mixed forward+backward, fill holes in partial values

Plus `probabilityOf` and `enumerate` as sketched extensions.

### Exhaust interpreters

| Exhaust Interpreter | Dissertation Equivalent | File |
|---|---|---|
| `ValueInterpreter` | generate | `Interpreters/Generation/ValueInterpreter.swift` |
| `ValueAndChoiceTreeInterpreter` | generate + randomness | `Interpreters/Generation/ValueAndChoiceTreeInterpreter.swift` |
| `OnlineCGSInterpreter` | CGS algorithm (Fig 3.3) | `Interpreters/Generation/OnlineCGSInterpreter.swift` |
| `Reflect` | reflect | `Interpreters/Reflection/Reflect.swift` |
| `Materialize` | parse | Replays a ChoiceTree deterministically |
| `Reducer` | choices + shrinking passes | Validity-preserving shrinking via choice sequence manipulation |

### Not yet implemented

These dissertation concepts have no direct Exhaust equivalent:

- **genWithWeights** (example-based generation) — Exhaust's `Reflect` + `ChoiceGradientTuner` could compose to achieve this, but there's no dedicated reflect-then-reweight pipeline.
- **complete** (partial value completion) — no mixed forward+backward interpreter.
- **enumerate** (exhaustive interpretation of Pick) — not present.
- **probabilityOf** (probability computation) — not present.

**Verdict: Core-faithful with different emphasis.** Exhaust covers the dissertation's core forward/backward/replay triangle completely. The dissertation explores many novel interpretations (completers, enumerators, probability calculators) to demonstrate the power of the freer monad representation. Exhaust focuses on making the core interpretations production-grade with ChoiceTree hierarchies, stack-safe sequence handling, and the CGS optimization pipeline.

---

## 4. Choice Gradient Sampling (CGS)

This is where Exhaust diverges most significantly — and most interestingly — from the dissertation.

### Dissertation's CGS (Chapter 3, Figure 3.3)

- **Online, per-value**: At each `Pick` during generation, compute the derivative for every choice, sample each derivative N times, count valid outputs as "fitness", select proportionally.
- **Brzozowski derivatives**: Non-recursive, O(1) — "the generator that remains after a particular choice."
- **Cost**: Expensive per-sample (derivative evaluation at every pick site for every value generated).
- **Scope**: Applied to free generators (`Freer Pick a`), not reflective generators.

### Exhaust's three-stage offline approach (`ChoiceGradientTuner`)

**Stage 0 — Sequence length subdivision** (`subdivideSequenceLengths`):
Rewrites `sequence` length generators by splitting `chooseBits` ranges into 4 subranges wrapped in synthetic `pick` operations. This converts opaque continuous decisions into discrete choices that CGS can guide. _No dissertation equivalent_ — it's a practical necessity because Exhaust's `chooseBits` is richer than the dissertation's `ChooseInteger`.

**Stage 1 — Online CGS warmup** (`OnlineCGSInterpreter`):
Faithful to the dissertation's algorithm. Defunctionalized continuation frames (`DerivativeContext`) build derivatives and sample per-branch fitness. The key difference: results are accumulated into a `FitnessAccumulator` rather than used directly. This is a fixed warmup phase (default 200 runs), not a per-value decision.

**Stage 2 — Weight baking** (`bakeWeights`):
Converts accumulated fitness data into static pick weights. Four strategies:

| Strategy | Description | Dissertation equivalent |
|---|---|---|
| `totalFitness` | Raw cumulative fitness | Closest to dissertation's proportional selection |
| `validityRate` | Normalized fitness/observations | No equivalent |
| `fitnessSharing` (default) | Niche-count sharing: `weight_i = fitness_i / (1 + N * share_i)` | No equivalent |
| `ucb` | UCB1 exploration bonus from multi-armed bandit literature | No equivalent |

The default `fitnessSharing` strategy addresses a practical problem the dissertation doesn't tackle: proportional selection overcommits to the dominant choice, exhausting unique values quickly. Fitness sharing preserves the ranking while flattening toward the tail. On AVL benchmarks, it produces 2x faster time-to-100 unique valid trees compared to raw `totalFitness`.

**Stage 3 — Adaptive smoothing** (`GeneratorTuning.smoothAdaptively`):
Per-site entropy analysis identifies bottleneck sites (where one choice dominates) and applies higher temperature there to prevent chokepoints. Well-distributed sites keep low temperature to preserve the tuned distribution. _No dissertation equivalent._

**Result**: After tuning, all subsequent generation uses the cheap `ValueAndChoiceTreeInterpreter` with baked weights — "same quality signal, ~100x cheaper per sample."

**Verdict: Architecturally faithful, strategically different.** The core CGS insight (derivatives + fitness sampling) is implemented faithfully in the `OnlineCGSInterpreter`. But Exhaust wraps it in an offline tuning pipeline that addresses real production concerns: diversity collapse, per-sample cost, and bottleneck sites. The dissertation's CGS is elegant and online; Exhaust's is pragmatic and amortized.

---

## 5. Choice Representation

**Dissertation**: Flat bit strings and bracketed choice sequences (e.g., `(10(1(100)0))`). Shrinking operates on these strings via `subTrees`, `zeroDraws`, and `swapBits` passes to find the shortlex minimum.

**Exhaust**: Dual representation:
- `ChoiceTree` — hierarchical, with cases for `choice`, `just`, `sequence`, `branch`, `group`, `selected`, `getSize`, `resize`. Preserves structural information from generation.
- `ChoiceSequence` — flat `ContiguousArray<ChoiceSequenceValue>` for mutation and reduction.

The hierarchical `ChoiceTree` is richer than anything in the dissertation. It enables structural manipulation (e.g., the `Reducer` can swap subtrees or zero out groups while respecting generator structure), whereas the dissertation's flat bit strings require the shrinking passes to rediscover structure.

---

## 6. Test Case Reduction (Shrinking)

The dissertation devotes §4.6 to validity-preserving shrinking and mutation. Exhaust's `Reducer` is a substantially expanded implementation of these ideas.

### Dissertation's approach (§4.6.1–4.6.3)

The dissertation describes two shrinking systems:

**Hypothesis-style internal reduction** (§4.6.1): Operates on bracketed bit strings representing the randomness consumed during generation. The key insight — shrink the *random choices*, not the value. Three passes find the shortlex minimum:
- `subTrees` — tries shrinking to every child sequence of the original
- `zeroDraws` — replaces `Draw` nodes with zeroes, progressively shorter
- `swapBits` — swaps 1s with 0s for lexically smaller strings

**Reflective shrinking** (§4.6.2): The dissertation's novel contribution. Implements a `choices` backward interpretation that extracts bracketed choice sequences from any value — even ones not produced by the generator. This enables shrinking externally provided values (e.g., a user-submitted bug report). Table 4.1 shows reflective shrinking matches Hypothesis's `genericShrink` quality across 5 SmartCheck benchmarks.

**Reflective mutation** (§4.6.3): Applies the same principle to HypoFuzz-style fuzzing — mutate the choice sequence rather than the value, guaranteeing structural validity.

### Exhaust's Reducer (`Interpreters/Reduction/`)

Exhaust implements a 12-pass reduction system that goes far beyond the dissertation's 3-pass description. Most passes operate on `ChoiceSequence` (the flattened form of `ChoiceTree`), but the structural passes `promoteBranches` and `pivotBranches` operate directly on the `ChoiceTree` — walking branch nodes, mutating the tree via fingerprint-indexed subscripts, and flattening to `ChoiceSequence` only for shortlex comparison and replay. All passes use the generator to replay candidates and check validity — the same "shrink the choices, not the value" principle, but with dramatically more sophisticated strategies.

#### The 12 passes

| # | Pass | Dissertation equivalent | Description |
|---|---|---|---|
| 1 | `naiveSimplifyValuesToSemanticSimplest` | `zeroDraws` (partial) | One-shot: sets all values to semantic simplest (0 for numbers, index 0 for characters) |
| 2 | `promoteBranches` | Targeted alternative to `subTrees` | Operates on `ChoiceTree`: replaces a shallow branch's subtree with a deeper, simpler one at structurally compatible pick sites. Achieves the same effect as `subTrees` for recursive generators without needing a flat sequence-cursor interpreter |
| 3 | `pivotBranches` | None | Operates on `ChoiceTree`: switches which branch is `.selected` at pick sites, preferring alternatives whose subtrees are shortlex-simpler |
| 4 | `deleteContainerSpans` | None | Adaptive deletion of container structure spans (removing structural groupings, not replacing root with children) |
| 5 | `deleteSequenceBoundaries` | None | Collapses sequence boundaries (e.g., `[[V][V][V]]` -> `[[VVV]]`) |
| 6 | `deleteFreeStandingValues` | `zeroDraws` (generalized) | Removes individual value elements within sequences |
| 7 | `deleteAlignedSiblingWindows` | None | Coordinated deletion across structurally aligned sibling containers via beam search |
| 8 | `simplifyValuesToSemanticSimplest` | `zeroDraws` (partial) | Batched simplification using `findInteger` adaptive probing |
| 9 | `reduceValues` | `swapBits` (vastly expanded) | Binary search each value toward its reduction target, with specialized float handling (truncation, cross-zero probing, NaN/infinity, as-integer-ratio) |
| 10 | `redistributeNumericPairs` | None | Cross-container value redistribution — decreases earlier values while increasing later ones |
| 11 | `speculativeDeleteAndRepair` | None | Divide-and-conquer deletion with value repair for out-of-bounds adjustments |
| 12 | `normaliseSiblingOrder` | None | Reorders sibling elements to normalized order; falls back to bubble-sort if full sort fails |

#### Key architectural differences from the dissertation

**Shortlex ordering as the invariant**: Like Hypothesis and the dissertation, all candidates must satisfy `shortLexPrecedes(original)`. But Exhaust's richer `ChoiceSequence` (typed values rather than raw bits) makes shortlex comparisons more semantically meaningful.

**Adaptive probing via `findInteger`**: Many passes use `AdaptiveProbe.findInteger()` — a binary-search-like strategy that finds the largest batch of changes that can be made while preserving the failing property. The dissertation's passes are fixed-step; Exhaust's adapt to the landscape.

**Budget constraints**: Expensive passes (especially `deleteAlignedSiblingWindows` with its beam search) are budget-constrained via `ProbeBudget` to prevent runaway property invocations. The dissertation doesn't discuss computational budgets.

**Pass reordering**: After a successful improvement, the successful pass moves to the front of the next iteration. This exploitative strategy concentrates effort on passes that are making progress. The dissertation describes a fixed pass order.

**Cycle detection**: The reducer tracks `recentSequences` to detect when passes are cycling without progress, triggering early termination. The dissertation doesn't address convergence.

**Float-specific reduction**: `reduceValues` has extensive Hypothesis-inspired float handling — truncation shrinks, integral-float binary reduction, as-integer-ratio reduction, cross-zero probing, NaN/infinity normalization. The dissertation mentions floats only in passing.

**Stale range handling**: The "unlock boundary" probe (`UnlockProbeInput`) handles cases where recorded generator ranges become invalid mid-reduction — a practical concern that arises when shrinking changes upstream choices that affect downstream ranges.

**Verdict: Massively expanded.** The dissertation's 3 passes (`subTrees`, `zeroDraws`, `swapBits`) establish the principle. Exhaust's 12 passes implement a production-grade reduction system with adaptive probing, budget management, float specialization, cross-container redistribution, and convergence control. The core idea (shrink the choice sequence, replay through the generator) is faithful; the execution is an order of magnitude more sophisticated.

---

## 7. Bidirectionality

Both systems implement the same core bidirectional pattern. The dissertation's key theorem:

> **Theorem 1**: `P[[g]] <$> R[[g]] === G[[g]]`
> (Parsing the randomness of a generator is equivalent to running it forward.)

Exhaust's `Reflect` interpreter implements the backward pass (`P[[g]]`), and `ValueAndChoiceTreeInterpreter` captures both the forward value and the choice tree (`G[[g]]` + `R[[g]]`). The `Materialize` interpreter replays a choice tree to recreate the value (`P[[g]]` applied to recorded randomness).

The correctness properties the dissertation establishes — soundness, completeness, pure projection, overlap — are structurally maintained by Exhaust's operation-by-operation interpretation in `Reflect.swift`. Each `ReflectiveOperation` case mirrors the dissertation's backward interpretation rules:

- `pick` → tries all choices against target value (sound: only succeeds if a branch matches)
- `chooseBits` → checks if target's bit pattern falls within range (sound + complete for the range)
- `contramap` → applies transform then reflects recursively (sound given invertible transform)
- `prune` → unwraps valid input (handles partial lens failure)

---

## 8. Summary Table

| Aspect | Dissertation | Exhaust | Assessment |
|---|---|---|---|
| Freer monad | `Freer f a` with existential | `FreerMonad<Op, Val>` with `Any` | Faithful translation |
| Operation set | 6 constructors in `R b a` | 12 constructors in `ReflectiveOperation` | Superset — all 6 present + 6 practical additions |
| Choice representation | Flat bit strings, bracketed sequences | Hierarchical `ChoiceTree` + flat `ChoiceSequence` | Richer — enables structural manipulation |
| CGS algorithm | Online, per-value | Offline, amortized warmup + baked weights | Same core, different deployment strategy |
| Diversity preservation | Not addressed | Fitness sharing, UCB, adaptive smoothing | Novel extension |
| Continuous values | `ChooseInteger (Int, Int)` | `chooseBits` with `TypeTag` for Int/Float/Char/Bool | Generalized |
| Stack safety | Relies on Haskell laziness | Explicit `sequence`/`zip` operations | Necessary for Swift |
| Filter/validity | Implicit in CGS predicate | Reified as `.filter` operation | More explicit |
| Interpreter count | 7+ (exploring generality) | 6 (optimized for production) | Narrower but deeper |
| Test case reduction | 3 passes (`subTrees`, `zeroDraws`, `swapBits`) | 12 passes with adaptive probing, budgets, float specialization | Massively expanded |
| Example-based generation | `reflect -> analyzeWeights -> genWithWeights` | Not yet implemented | Future opportunity |
| Partial completion | `complete` interpreter | Not yet implemented | Future opportunity |
| Enumeration | `enumerate` interpreter | Not yet implemented | Future opportunity |

---

## 9. Conclusion

Exhaust is a **faithful implementation** of the dissertation's core theory — the freer monad foundation, the reflective operation set, and the forward/backward/replay interpreter triangle are all directly traceable to Goldstein's formalization. The CGS algorithm is implemented correctly at the derivative level.

Where Exhaust adds genuine novelty is in the **offline CGS pipeline** (warmup -> fitness sharing -> adaptive smoothing), the **12-pass Reducer** (adaptive probing, budget management, float specialization, cross-container redistribution), the **sequence length subdivision** preprocessing, and the **reification of filter/classify/unique** into the operation set. These are practical engineering contributions that make the theory work at scale in a strict, non-lazy language.

What Exhaust hasn't yet explored are the dissertation's more **speculative interpretations** — completers, enumerators, `probabilityOf`, and the example-based generation workflow. These represent the dissertation's exploration of what's possible with the freer monad representation, and they remain available as future directions since the underlying architecture supports them.
