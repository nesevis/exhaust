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

### Exhaust-only operations (7 additional)

| Operation | Purpose |
|---|---|
| `.sequence(length:, gen:)` | Stack-safe collection generation, avoids recursive bind chains |
| `.zip(generators:)` | Parallel composition without monadic nesting |
| `.just(Any)` | Constant value (the dissertation handles this via `Return`/`pure`) |
| `.filter(gen:, fingerprint:, filterType:, predicate:)` | Explicit validity marker for CGS optimization |
| `.classify(gen:, fingerprint:, classifiers:)` | Distribution statistics and coverage reporting |
| `.unique(gen:, fingerprint:, keyExtractor:)` | Deduplication via choice-sequence or key-based tracking |
| `.transform(kind:, inner:)` | Reifies `map`/`bind` as inspectable data. `TransformKind.bind` fuses `comap` with `>>=` (Xia et al. ESOP 2019), making bind dependencies visible to every interpreter — VACTI records them as `ChoiceTree.bind`, the reducer exploits them for depth-ordered reduction. See [academic-influences.md](academic-influences.md), Section 2 |

**Verdict: Superset.** All 6 dissertation operations are present with faithful semantics. Exhaust adds 7 more for practical concerns: stack safety (`sequence`), ergonomics (`zip`, `just`), observability (`filter`, `classify`, `unique`), and structural visibility (`.transform` — see Section 5 and 6 for how this enables the bind-aware reducer). The `filter` operation is particularly notable — the dissertation handles validity constraints at the CGS level, but Exhaust reifies them into the operation set so any interpreter can react to them.

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
| `OnlineCGSInterpreter` | CGS algorithm (Fig 3.3) | `Interpreters/Adaptation/OnlineCGSInterpreter.swift` |
| `Reflect` | reflect | `Interpreters/Reflection/Reflect.swift` |
| `Replay` | parse | `Interpreters/Replay/Replay.swift` |
| `ReductionMaterializer` | parse (during reduction) | `Interpreters/Reduction/ReductionMaterializer.swift` |
| `BonsaiScheduler` | choices + shrinking passes | Validity-preserving shrinking via categorical enc/dec pipeline |

### Not yet implemented

These dissertation concepts have no direct Exhaust equivalent:

- **genWithWeights** (example-based generation) — Exhaust's `Reflect` + `ChoiceGradientTuner` could compose to achieve this, but there's no dedicated reflect-then-reweight pipeline.
- **complete** (partial value completion) — no mixed forward+backward interpreter.
- **probabilityOf** (probability computation) — not present.

### Partially addressed: enumerate

The dissertation's `enumerate` interpreter exhaustively interprets `Pick` to produce all possible values. Exhaust takes a different approach to the same goal via **unified ChoiceTree analysis + t-way covering arrays** (`Sources/ExhaustCore/Analysis/`).

`ChoiceTreeAnalysis` runs the generator through VACTI (`ValueAndChoiceTreeInterpreter`) with `materializePicks = true`, which evaluates the full generator — including all bind chains — and produces a `ChoiceTree` capturing every random decision made during generation. The analysis then walks this tree to extract a parameter model:

- **Finite parameters** — `chooseBits` with explicit ranges ≤256 values, or `pick` between pure branches
- **Boundary parameters** — `chooseBits` with large ranges, synthesized down to boundary representatives (`{min, min+1, midpoint, max-1, max, 0 if in range}` for integers; special IEEE 754 values for floats)
- **Sequence parameters** — length (capped at `{0, 1, 2}`) plus up to 2 element slots with boundary or finite values

The analysis returns one of three outcomes:

| Result | Condition | Strategy |
|---|---|---|
| `.finite(FiniteDomainProfile)` | All parameters have small value sets | Exhaustive enumeration if space ≤ budget, otherwise pull-based pairwise coverage |
| `.boundary(BoundaryDomainProfile)` | Some parameters have large ranges | Pull-based pairwise coverage over boundary values |
| `nil` | Uses `getSize`/`resize`, >20 parameters, or other non-analyzable patterns | Skip to random sampling |

The parameter model feeds a **pull-based greedy covering array generator** (`PullBasedCoveringArrayGenerator`) based on the density algorithm (Bryce & Colbourn, "A density-based greedy algorithm for higher strength covering arrays", STVR 2009). Each call to `next()` emits a single row that greedily maximises new pairwise coverage using unrestricted density with 1/|V_f| weighting for free factors (Section 2, Theorem 2.2). The coverage runner pulls rows until a property failure is found or the budget is exhausted — no upfront array construction. The paper's O(log k) row-count guarantee is preserved; the pragmatic adaptation omits multiple candidates, density-driven factor ordering, and repetitions in favour of determinism and fast time-to-first-row.

When the total space is small enough (`totalSpace <= coverageBudget`) and the generator has no binds, the pull-based generator at maximum strength covers the entire space — effectively exhaustive enumeration. For larger spaces, pairwise (t=2) coverage provides a principled middle ground between exhaustive and random. An empirical study of real-world faults found that pairwise coverage catches ~93% of interaction bugs, and 3-way catches ~98% (Kuhn, Wallace & Gallo, "Software Fault Interactions and Implications for Software Testing", IEEE TSE 2004).

The key difference from the dissertation's `enumerate`: Exhaust's approach is automatic (transparent to the user — `#exhaust` detects finite generators and switches strategy) and works through the existing `Interpreters.replay` infrastructure rather than requiring a new interpreter. Each covering array row is converted to a `ChoiceTree` via `CoverageProfile.buildTree(from:)` and replayed through the generator, reusing the same replay engine used for shrinking and materialization. The coverage budget (default 200) is separate from and additive with `maxIterations` — structured coverage runs first, then random sampling runs for the full `maxIterations` budget.

**Verdict: Core-faithful with different emphasis.** Exhaust covers the dissertation's core forward/backward/replay triangle completely. The dissertation explores many novel interpretations (completers, enumerators, probability calculators) to demonstrate the power of the freer monad representation. Exhaust focuses on making the core interpretations production-grade with ChoiceTree hierarchies, stack-safe sequence handling, the CGS optimization pipeline, and automatic combinatorial coverage for finite domains.

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
- `ChoiceTree` — hierarchical, with cases for `choice`, `just`, `sequence`, `branch`, `group`, `selected`, `getSize`, `resize`, `bind`. Preserves structural information from generation. The `bind(inner:, bound:)` case is architecturally significant — it records data dependencies from `.transform(.bind(...))` operations, enabling the BonsaiScheduler's depth-ordered reduction.
- `ChoiceSequence` — flat `ContiguousArray<ChoiceSequenceValue>` for mutation and reduction.

The hierarchical `ChoiceTree` is richer than anything in the dissertation. It enables structural manipulation (e.g., the `Reducer` can swap subtrees or zero out groups while respecting generator structure), whereas the dissertation's flat bit strings require the shrinking passes to rediscover structure.

---

## 6. Test Case Reduction (Shrinking)

The dissertation devotes §4.6 to validity-preserving shrinking and mutation. Exhaust's BonsaiReducer is a substantially expanded implementation of these ideas, organised by a categorical framework (Sepulveda-Jimenez, "Categories of Optimization Reductions", 2026; see [academic-influences.md](academic-influences.md), Section 3).

### Dissertation's approach (§4.6.1–4.6.3)

The dissertation describes two shrinking systems:

**Hypothesis-style internal reduction** (§4.6.1): Operates on bracketed bit strings representing the randomness consumed during generation. The key insight — shrink the *random choices*, not the value. Three passes find the shortlex minimum:
- `subTrees` — tries shrinking to every child sequence of the original
- `zeroDraws` — replaces `Draw` nodes with zeroes, progressively shorter
- `swapBits` — swaps 1s with 0s for lexically smaller strings

**Reflective shrinking** (§4.6.2): The dissertation's novel contribution. Implements a `choices` backward interpretation that extracts bracketed choice sequences from any value — even ones not produced by the generator. This enables shrinking externally provided values (e.g., a user-submitted bug report). Table 4.1 shows reflective shrinking matches Hypothesis's `genericShrink` quality across 5 SmartCheck benchmarks.

**Reflective mutation** (§4.6.3): Applies the same principle to HypoFuzz-style fuzzing — mutate the choice sequence rather than the value, guaranteeing structural validity.

### Exhaust's BonsaiReducer (`Interpreters/Reduction/`)

Exhaust implements a categorical reduction pipeline with 24 composable encoders across four phases, organised by the enc/dec separation from Sepulveda-Jimenez. All encoders conform to `ComposableEncoder` — a role-agnostic protocol where the factory assigns each encoder to a role (upstream, downstream, standalone) based on CDG position. The `ReductionMaterializer` (the decoder) re-runs the generator against each candidate to produce a fresh `ChoiceTree` with current metadata. The categorical framework enables composability (Kleisli composition of encoder pairs through a generator lift) and principled phase ordering via `MorphismDescriptor` with dominance edges.

#### The 4-phase pipeline

Phases progress from exact encoders (guaranteed shortlex improvement) through bounded (re-derivation introduces slack) to speculative (may temporarily worsen before improving):

| Phase | Guarantee | Encoders |
|---|---|---|
| structuralDeletion | Exact | `DeletionEncoder` (parameterised by span category), `BranchSimplificationEncoder` (promote/pivot), `ContiguousWindowDeletionEncoder`, `BeamSearchDeletionEncoder`, `AntichainDeletionEncoder`, `SiblingSwapEncoder`, `BindSubstitutionEncoder` |
| valueMinimization | Exact or bounded | `ZeroValueEncoder`, `BinarySearchEncoder` (.rangeMinimum/.semanticSimplest), `ReduceFloatEncoder`, `LinearScanEncoder`, `ProductSpaceAdaptiveEncoder`, `ShortlexReorderEncoder`, `RegimeProbeEncoder` |
| redistribution | Bounded | `RedistributeByTandemReductionEncoder`, `RedistributeAcrossValueContainersEncoder` |
| exploration | Speculative | `RelaxRoundEncoder`, `KleisliComposition` with `DownstreamPick` (selects `FibreCoveringEncoder` or `ZeroValueEncoder` based on fibre characteristics) |

#### Mapping to dissertation passes

| Dissertation pass | Exhaust encoders | Notes |
|---|---|---|
| `subTrees` | `deleteByPromotingSimplestBranch` | Operates on `ChoiceTree` rather than flat sequences — replaces shallow branches with deeper, simpler ones at structurally compatible pick sites |
| `zeroDraws` | `zeroValue`, `binarySearchToSemanticSimplest`, `deleteFreeStandingValues` | Split into adaptive zero-fill, batched binary search toward semantic simplest, and individual value deletion |
| `swapBits` | `binarySearchToRangeMinimum`, `reduceFloat` | Binary search toward range minimum with specialised float handling (truncation, cross-zero probing, NaN/infinity normalisation, as-integer-ratio simplification) |
| (none) | The remaining 19 encoders | Bind-aware passes, structural deletion variants, redistribution, Kleisli exploration — all without dissertation equivalents |

#### BonsaiScheduler's four-phase pipeline

The scheduler exploits the `ChoiceTree.bind(inner:, bound:)` structure for depth-ordered reduction — a capability the dissertation's flat bit strings do not support:

- **Base descent** (Phase 1): structural deletion encoders remove unnecessary structure
- **Fibre descent** (Phase 2): value minimisation encoders reduce values within the current structure, sweeping from minimum bind depth upward so shallow values settle before deeper ones
- **Kleisli exploration** (Phase 3, when both stall): compositions propose upstream mutations, lift them through the generator via `GeneratorLift`, then search the resulting fibre with `DownstreamPick` (selects exhaustive, pairwise, or zero-value strategy based on fibre characteristics)
- **Relax-round** (Phase 4, when all stall): redistributes values to escape local minima, then exploits via a full Phase 1 + Phase 2 pipeline, with checkpoint/rollback acceptance

The scheduler is parameterised by a `SchedulingStrategy` protocol. The sole implementation, `AdaptiveStrategy`, skips Phase 1 when span extraction proves no structural work exists, adapts per-edge composition budgets based on prior-cycle observations, and uses signal-driven gating (convergence signals, edge observations) for Phase 3 and Phase 4 dispatch. On BinaryHeap (15 cycles), the adaptive strategy saves 17% of materializations with a 36% wall-clock speedup.

#### Key architectural differences from the dissertation

**Categorical enc/dec separation**: Encoders propose pure mutations; the `ReductionMaterializer` decodes them by re-running the generator. This separation (from Sepulveda-Jimenez) enables composability — `KleisliComposition` composes two `ComposableEncoder`s through a `GeneratorLift` — and principled phase ordering via `MorphismDescriptor` with dominance edges.

**Shortlex ordering as the invariant**: Like Hypothesis and the dissertation, all candidates must satisfy `shortLexPrecedes(original)`. But Exhaust's richer `ChoiceSequence` (typed values rather than raw bits) makes shortlex comparisons more semantically meaningful.

**Bind-depth ordering**: The `BindSpanIndex` builds a structural index of every bind region. BonsaiScheduler's covariant sweep reduces bound-content values from minimum bind depth upward, settling shallow depths first so that deeper depths reduce in the correct context. The dissertation has no notion of bind dependencies.

**Adaptive probing via `findInteger`**: Many encoders use `AdaptiveProbe.findInteger()` — a binary-search-like strategy that finds the largest batch of changes that can be made while preserving the failing property. The dissertation's passes are fixed-step; Exhaust's adapt to the landscape.

**Budget constraints**: Expensive encoders (especially `deleteAlignedSiblingWindows` with its beam search) are budget-constrained. `CycleBudget` allocates across legs using dynamic cost estimates from each encoder's Big-O model and the current tree shape. `LegBudget` enforces per-leg hard caps with stall patience. The dissertation doesn't discuss computational budgets.

**Kleisli composition**: `KleisliComposition` composes an upstream and downstream `ComposableEncoder` through a `GeneratorLift` — the upstream proposes a structural mutation, the lift re-derives the fibre (producing a fresh tree and sequence), and the downstream searches the fibre via `DownstreamPick` (runtime selection of exhaustive, pairwise, or zero-value strategy based on actual fibre characteristics). This is a direct instantiation of Sepulveda-Jimenez §7 (Kleisli generalisation), enabling cross-level exploration that neither the dissertation nor Hypothesis addresses.

**Convergence signals**: Typed encoder observations (`ConvergenceSignal`) flow from encoders to the factory across cycles via the convergence cache. The factory pattern-matches on signals to select recovery encoders: `nonMonotoneGap` triggers a `LinearScanEncoder` (bounded exhaustive scan below the convergence point), `zeroingDependency` suppresses zero-value on coupled coordinates, `scanComplete` reverts to binary search. `EdgeObservation` carries per-edge downstream observations for composition decisions. Neither the dissertation nor Hypothesis has cross-cycle encoder feedback.

**Adaptive scheduling**: The `SchedulingStrategy` protocol separates scheduling decisions from the orchestration skeleton. `AdaptiveStrategy` skips Phase 1 when span extraction proves no structural work exists (no generator lifts wasted), adapts per-edge composition budgets based on prior-cycle observations, and uses signal-driven gating for Phases 3 and 4. The dissertation's shrinking passes run unconditionally.

**Tiered materialisation**: `ReductionMaterializer` uses three-tier resolution: prefix replay → fallback tree → PRNG. This handles stale ranges from upstream mutations gracefully, a practical concern that arises when shrinking changes upstream choices that affect downstream ranges.

**Float-specific reduction**: `ReduceFloatEncoder` has extensive Hypothesis-inspired float handling — truncation shrinks, integral-float binary reduction, as-integer-ratio reduction, cross-zero probing, NaN/infinity normalisation. The dissertation mentions floats only in passing.

**Verdict: Massively expanded.** The dissertation's three passes (`subTrees`, `zeroDraws`, `swapBits`) establish the principle. Exhaust's 24 composable encoders across four categorical phases implement a production-grade reduction system with bind-aware scheduling, Kleisli composition with runtime downstream selection, adaptive probing, convergence signal feedback, non-monotonicity detection, adaptive scheduling with Phase 1 skip, float specialisation, cross-container redistribution, and fibre-based exploration. The core idea (shrink the choice sequence, replay through the generator) is faithful; the execution is categorically organised and an order of magnitude more sophisticated.

---

## 7. Bidirectionality

Both systems implement the same core bidirectional pattern. The dissertation's key theorem:

> **Theorem 1**: `P[[g]] <$> R[[g]] === G[[g]]`
> (Parsing the randomness of a generator is equivalent to running it forward.)

Exhaust's `Reflect` interpreter implements the backward pass (`P[[g]]`), and `ValueAndChoiceTreeInterpreter` captures both the forward value and the choice tree (`G[[g]]` + `R[[g]]`). The `Replay` interpreter replays a choice tree to recreate the value (`P[[g]]` applied to recorded randomness).

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
| Operation set | 6 constructors in `R b a` | 13 constructors in `ReflectiveOperation` | Superset — all 6 present + 7 practical additions |
| Choice representation | Flat bit strings, bracketed sequences | Hierarchical `ChoiceTree` + flat `ChoiceSequence` | Richer — enables structural manipulation |
| CGS algorithm | Online, per-value | Offline, amortized warmup + baked weights | Same core, different deployment strategy |
| Diversity preservation | Not addressed | Fitness sharing, UCB, adaptive smoothing | Novel extension |
| Continuous values | `ChooseInteger (Int, Int)` | `chooseBits` with `TypeTag` for Int/Float/Char/Bool | Generalized |
| Stack safety | Relies on Haskell laziness | Explicit `sequence`/`zip` operations | Necessary for Swift |
| Filter/validity | Implicit in CGS predicate | Reified as `.filter` operation | More explicit |
| Interpreter count | 7+ (exploring generality) | 5 core interpreters + BonsaiScheduler | Narrower but deeper |
| Test case reduction | 3 passes (`subTrees`, `zeroDraws`, `swapBits`) | 24 composable encoders across 4 categorical phases with Kleisli composition, convergence signals, adaptive scheduling, non-monotonicity detection, float specialisation | Massively expanded |
| Combinatorial coverage | Not addressed | Unified ChoiceTree analysis → automatic t-way covering arrays (pull-based density algorithm) for finite domains + boundary value synthesis for large domains | Novel — draws on Bryce & Colbourn (STVR 2009), Kuhn et al. (IEEE TSE 2004), and NIST SP 800-142 |
| Example-based generation | `reflect -> analyzeWeights -> genWithWeights` | Not yet implemented | Future opportunity |
| Partial completion | `complete` interpreter | Not yet implemented | Future opportunity |
| Enumeration | `enumerate` interpreter | Unified ChoiceTree analysis with automatic exhaustive enumeration (small domains) and boundary value coverage (large domains) | Different approach — via VACTI-generated ChoiceTree walk + covering arrays + replay, not a dedicated interpreter |

---

## 9. Conclusion

Exhaust is a **faithful implementation** of the dissertation's core theory — the freer monad foundation, the reflective operation set, and the forward/backward/replay interpreter triangle are all directly traceable to Goldstein's formalization. The CGS algorithm is implemented correctly at the derivative level.

Where Exhaust adds genuine novelty is in:

- The **reification of `map`/`bind`** as `.transform` — fusing Xia et al.'s `comap` with monadic `>>=` to make bind dependencies visible to every interpreter, enabling depth-ordered reduction.
- The **offline CGS pipeline** (warmup → fitness sharing → adaptive smoothing).
- The **BonsaiReducer** — 24 composable encoders across four categorical phases (Sepulveda-Jimenez), with bind-aware scheduling, Kleisli composition through a generator lift with runtime downstream selection (`DownstreamPick`), typed convergence signals for cross-cycle encoder feedback, non-monotonicity detection via `LinearScanEncoder`, adaptive scheduling (`SchedulingStrategy` protocol with Phase 1 skip and signal-driven gating), float specialisation, and fibre-based exploration via covering arrays.
- The **`Gen.recursive` combinator** — transparent recursive generator composition with per-layer CGS tuning, no dissertation equivalent.
- The **sequence length subdivision** preprocessing.
- The **reification of filter/classify/unique** into the operation set.
- **Automatic combinatorial coverage** via unified ChoiceTree analysis.

The coverage system is particularly notable: `ChoiceTreeAnalysis` runs the generator through VACTI to produce a `ChoiceTree`, then walks it to extract a parameter model — handling not just finite domains but also large-range boundary value synthesis and sequence parameters. This approach sees through opaque bind chains that defeat recursive generator walkers, because VACTI evaluates the full generator before analysis begins. The extracted parameters feed pull-based density covering arrays for t-way combinatorial coverage, composing boundary value analysis (selecting *which values* to test) with interaction testing (ensuring *combinations* of those values are covered) — the standard practice recommended by NIST SP 800-142. This leverages the inspectability of the freer monad representation in a way the dissertation doesn't explore: using a forward interpretation (VACTI) to enable structural analysis that selects a fundamentally different testing strategy.

What Exhaust hasn't yet explored are the dissertation's more **speculative interpretations** — completers, `probabilityOf`, and the example-based generation workflow. These represent the dissertation's exploration of what's possible with the freer monad representation, and they remain available as future directions since the underlying architecture supports them.
