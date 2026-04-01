# Academic Influences on Exhaust

A formal account of the theoretical lineage behind Exhaust, organised by the layer of the system each body of work shapes. Two intellectual threads converge: the freer monad representation with PMP operations (Goldstein, building on Xia et al.), and the categorical reduction algebra (Sepulveda-Jimenez). Exhaust's inspectable bind bridges the two. The rest of the stack — combinatorial coverage, generator tuning, numerical scheduling analogies — builds on top of that convergence.

---

## 1. Freer Monad Foundation

**Goldstein, "Property-Based Testing for the People" (UPenn PhD, 2024)**

Primary intellectual ancestor. Exhaust is a faithful Swift translation of Goldstein's core architecture.

### What Exhaust takes

- **Freer monad** (`Freer f a`) as the representation for generators — effects reified as inspectable data structures rather than opaque closures. Exhaust: `FreerMonad<ReflectiveOperation, Value>` with `Any` standing in for the existential intermediate type.
- **Reflective generators** (`Freer (R b) a`) with the six-constructor operation set (`Pick`, `Lmap`, `Prune`, `ChooseInteger`, `GetSize`, `Resize`). Exhaust preserves all six with faithful semantics and adds seven more (`.sequence`, `.zip`, `.just`, `.filter`, `.classify`, `.unique`, `.transform`).
- **The forward/backward/replay interpreter triangle** — generate values, reflect values back into choice sequences, replay choice sequences into values.
- **Bidirectionality theorem**: `P[[g]] <$> R[[g]] === G[[g]]` — parsing the randomness of a generator is equivalent to running it forward.
- **Choice Gradient Sampling** (Chapter 3, Fig 3.3) — Brzozowski derivatives at each `Pick` site to compute per-branch fitness, then sample proportionally. Exhaust's `OnlineCGSInterpreter` implements this faithfully as a warmup phase.
- **Shrink the choice sequence, not the value** (Section 4.6) — the foundational principle shared with Hypothesis. Three passes (`subTrees`, `zeroDraws`, `swapBits`) operating on flat bracketed bit strings.

### Where Exhaust diverges

- Reification of `map`/`bind` as `.transform` (see Section 2).
- Offline CGS pipeline wrapping the online algorithm (see Section 5).
- 23 composable encoders in place of three passes, organised by a categorical framework (see Section 3).
- Automatic combinatorial coverage via ChoiceTree analysis (see Section 4).

---

## 2. Inspectable Bind: From Opaque Sequencing to Reified Dependencies

### Goldstein's PMP operations and the opaque bind barrier

Goldstein's `R b a` effect type (§4.3) includes `Lmap` and `Prune` — reifications of the `comap` operation from Xia et al.'s monadic profunctor framework (ESOP 2019). Together, `lmap f . prune` implements partial contravariant annotation: the reflector uses these to focus on a subpart of a value during the backward pass. Exhaust preserves these as `.contramap` and `.prune` with faithful semantics.

However, these PMP operations are *standalone effects*. They annotate around binds but cannot see through them. The freer monad's `Bind` constructor remains existentially opaque — no interpreter can discover the dependency between the inner generator's output and the bound generator's structure. Goldstein's backward interpreter (`choices`) operates on flat choice sequences, sidestepping bind structure entirely.

### What Exhaust adds: `comap` fused with `bind`

Exhaust's `bound(forward:backward:)` fuses `comap` and `bind` into a single reified operation:

```swift
#gen(.int(in: 1...10)).bound(
    forward:  { n in .bool().array(length: n) },  // bind (monadic)
    backward: { arr in arr.count }                // comap (pure)
)
```

This creates `.transform(.bind(forward:, backward:, ...))` — the comap annotation travels *inside* the bind operation rather than being a standalone effect. The backward function is stored as data, available to the reflector at the exact point where it needs to decompose through the bind.

Crucially, even a forward-only `.bind(forward:)` (without a `backward` function) still reifies as `.transform(.bind(forward:, backward: nil, ...))`. The dependency structure is visible to every interpreter — the generative interpreter records it in the `ChoiceTree`, flattening produces `.bind` markers in the `ChoiceSequence`, and the Bonsai reducer exploits the depth ordering. The `backward` function adds bidirectional *reflection* through the bind, but the structural visibility that powers the reducer does not require it.

The asymmetry is the whole point:

```
forward:  (A) -> ReflectiveGenerator<B>   // monadic — the bound generator's structure depends on A
backward: (B) -> A                        // pure    — just extract the inner value from the output
```

### Why this matters

Exhaust's `.transform(.bind(forward:, backward:, ...))` reifies the bind as a first-class operation visible to every interpreter. This single addition propagates through the entire system:

1. The generative interpreter records `.bind(inner:, bound:)` in the `ChoiceTree`
2. Flattening produces paired `.bind(true/false)` markers in the `ChoiceSequence`
3. `BindSpanIndex` builds a structural index of every bind region
4. The Bonsai reducer's reduction pipeline exploits the dependency structure for depth-ordered reduction

This is the bridge between Goldstein (the representation) and Sepulveda-Jimenez (the reduction algebra). Without inspectable binds, the categorical reducer degenerates to the flat Hypothesis regime.

---

## 3. Categorical Reduction Algebra

**Sepulveda-Jimenez, "Categories of Optimization Reductions" (2026)**

### What Exhaust takes

- **Reduction morphisms as `(enc, dec)` pairs** (Def 3.1, 7.7) — the core architectural separation between pure structural mutation (encoders) and materialization/feasibility checking (decoders). Exhaust implements this literally: the `ComposableEncoder` protocol for `enc`, `SequenceDecoder` enum for `dec`.
- **Grade composition** via the affine-approximation monoid `Aff_≥0` (Section 8). Exhaust does not reify grades as a standalone type — instead, the approximation quality is implicit in the `ReductionPhase` ordering (four cases: `.structuralDeletion`, `.valueMinimization`, `.redistribution`, `.exploration`), where phases progress from exact encoders through bounded to speculative. Decoder selection via `SequenceDecoder.for(_:)` further encodes the approximation: `.exact` decoders produce fresh trees with current metadata, while `.guided` decoders introduce bounded slack from tiered re-derivation (prefix → fallback tree → PRNG). The shortlex guard is the actual runtime mechanism — a binary accept/reject filter. Budget allocation uses a flat per-phase ceiling rather than composable grade objects.
- **2-cell dominance** (Def 15.3) for pruning provably inferior encoders within a hom-set. Exhaust uses this within each reduction phase: all encoders sharing a decoder form a uniform hom-set where dominance comparison is well-defined.
- **Covariant/contravariant functors** on OptRed (`Cand`, `Sol`, Section 4). Sepúlveda-Jiménez provides the directional vocabulary: covariant passes propagate changes forward through the dependency chain. The fibration theory (Section 7) provides the justification for the ordering: the covariant depth sweep within fibre descent reduces bound-content values from minimum bind depth upward, settling shallow depths first so that deeper depths reduce in the correct context.
- **Natural transformations as post-processing** (Section 5.3) — inspiration for the shortlex merge step that recovers optimised bound values after re-derivation.
- **Relax-round pattern** (Section 11.2) — implemented in the Bonsai reducer's speculation leg (`runRelaxRound`) via `RelaxRoundEncoder`: when the reduction pipeline stalls, value redistribution relaxes the objective, then prune + train passes exploit the relaxed state, with pipeline-level checkpoint acceptance.
- **Kleisli generalisation** (Section 7) — lifting deterministic reductions to nondeterministic/randomised settings via Kleisli categories. Exhaust instantiates this at two levels: (1) the `ReductionMaterializer`'s guided mode, where re-derivation via three-tier resolution (prefix → fallback tree → PRNG) is nondeterministic, and (2) the `KleisliComposition` encoder, which composes two `ComposableEncoder`s through a `GeneratorLift`. The upstream encoder proposes a structural mutation, the lift re-derives the fibre (producing a fresh tree and sequence via the materialiser), and the downstream encoder (typically `FibreCoveringEncoder`) searches the fibre for a failure-preserving candidate. This is a full categorical composition `dec ∘ enc₂ ∘ lift ∘ enc₁`, not just nondeterministic retries.

### Where the instantiation is domain-specific

The paper defines the algebra; Exhaust supplies:
- The concrete encoders across the Bonsai reducer's reduction pipeline (structural and value encoders)
- The shortlex well-order on variable-length choice sequences (the paper assumes fixed-structure candidate spaces)
- The bind-depth ordering for dependent generators (the Bonsai reducer's covariant sweep within fibre descent)
- The tiered materialization resolution (prefix → fallback tree → PRNG), a form of replay interpreter
- Deletion as a category of pass (the paper models fixed-structure reductions; deletion changes sequence length)
- The `ProductSpaceAdaptiveEncoder` for batch enumeration of bind-inner product spaces (up to three bind regions) — a fibrewise search strategy that jointly explores correlated bind-inner values
- **Adaptive resource estimation** in place of the paper's static resource annotations (§9). The paper models resource costs as fixed monoidal annotations `w_a` on morphisms, composed via `w_{b∘a} = w_a ⊗ w_b`. Exhaust instead computes `estimatedCost` dynamically from the current `ChoiceTree` structure (span counts, depth, sequence lengths) and each encoder's Big-O model. This is used for encoder *ordering* within a phase (cheapest first), not for budget allocation — phases use a flat materialization ceiling. Within a cycle, move-to-front adaptation further adjusts the order: when an encoder accepts a probe, it is promoted to the front so the next iteration tries it first.

---

## 4. Combinatorial Testing: Covering Arrays

**Bryce & Colbourn, "A density-based greedy algorithm for higher strength covering arrays" (STVR 2009)**

### What Exhaust takes

- The **one-test-at-a-time density algorithm** for lazy covering array generation. `PullBasedCoveringArrayGenerator` emits one row per `next()` call, greedily maximising new t-tuple coverage. `CoverageRunner` pulls rows until a property failure is found, avoiding the cost of building the full array.
- **Unrestricted density** for level selection (Section 2, Theorem 2.2): when choosing a value for a factor, the contribution from non-completing slices (where some other factors are still free) is weighted by 1/|V_f| — the probability that a random assignment to the free factors would cover an uncovered tuple. This preserves the paper's O(log k) row-count guarantee.
- **Bit-vector coverage tracking** with `slicesByCompletingColumn` for efficient per-column evaluation: completing slices give exact coverage (0-restricted density), non-completing slices give density-weighted partial coverage.

### What Exhaust does not take

- **Multiple candidates per row** (Layer 2): the paper shows 10 candidates reduce array size by ~5–10%, but at 10x the per-row cost. Early-stop PBT makes this uneconomical.
- **Density-driven factor ordering** (Layer 3): Exhaust uses a fixed left-to-right ordering after sorting by domain size ascending. The paper finds density-based ordering produces modestly smaller arrays, but the effect diminishes with unrestricted density.
- **Best (t-1)-tuple seeding**: fixing the first t-1 factors to the values of the most common uncovered (t-1)-tuple before density fill.
- **Repetitions** (Layer 1): Exhaust generates one deterministic suite. Reproducibility requires no random tie-breaking.
- **Seeding from an existing array** (Section 4, p. 52): pre-marking tuples from an orthogonal array seed.

### How it fits

The density algorithm is a natural match for PBT because the deliverable is the *failure*, not the covering array. The O(log k) guarantee means most t-way interactions are covered within the first few dozen rows; if a bug is triggered by any specific interaction, it is typically found long before the full array is constructed. The pull-based interface integrates cleanly with `CoverageRunner`'s row-by-row materialization loop, which matches the paper's stated design goal that "tests in the test suite must be generated one test at a time" (Section 1, p. 39).

**Kuhn, Wallace & Gallo, "Software Fault Interactions and Implications for Software Testing" (IEEE TSE 2004)**

### What Exhaust takes

- The empirical justification for t-way coverage: pairwise (t=2) catches ~93% of interaction bugs, 3-way catches ~98%. This motivates Exhaust's default strength selection and the coverage budget tradeoff.

**Goldstein, Hughes, Lampropoulos & Pierce, "Do Judge a Test by its Cover: Combining Combinatorial and Property-Based Testing" (ESOP 2021)**

### What Exhaust takes (and doesn't)

This paper — co-authored by Goldstein and John Hughes (QuickCheck) — generalises combinatorial coverage from flat tuples of constructors to algebraic data types via **regular tree expressions** and **sparse test descriptions**. The key idea: define coverage over *descriptions* of structurally interesting test cases (e.g., "a tree with a red node somewhere above a black node") rather than over flat parameter tuples. The paper's tool, *QuickCover*, uses coverage information to **thin** the distribution of an existing random generator, finding bugs with 10x fewer tests.

Exhaust deliberately does not adopt the paper's *combinatorial thinning* (fanout) approach. The paper's cost model assumes that *generating* test suites is cheap while *running* tests is expensive — thinning amortises the generation cost across many CI runs. In Exhaust's cost model, materialisation (running the generator to produce a value from a choice sequence) dominates property evaluation, so the fanout argument doesn't hold: generating N covering-array candidates costs N materialisations regardless of whether the property is cheap or expensive.

**What Exhaust does take** is the broader insight that combinatorial coverage and PBT can be unified. Exhaust's `ChoiceTreeAnalysis` achieves this from the opposite direction: instead of thinning a random generator's output, it analyses the generator's choice structure to *construct* a covering array directly. The freer monad's inspectability (which the paper does not exploit — it works with opaque QuickCheck generators) enables this: the `ValueAndChoiceTreeInterpreter` walks the generator to extract finite/boundary parameters, then a pull-based greedy generator produces rows on demand, and `Interpreters.replay` materialises each row.

**Bind-awareness is the key divergence.** The paper treats generators as opaque and operates on their output distribution. Exhaust's `ChoiceTreeAnalysis` sees through bind chains via the `ChoiceTree.bind(inner:, bound:)` node and treats bound subtrees as opaque (Option B from [transform-reification-next-steps.md](transform-reification-next-steps.md)). This collapses the parameter count for dependent generators — the inner subtree contributes its parameters to the covering array, but the bound subtree (whose parameters are meaningless without the correct inner value) is exercised through random generation. Without this, a length-dependent array generator would fan out into N element parameters per possible length, producing an intractably large covering array.

### How it fits

Exhaust's coverage system leverages the inspectability of the freer monad in a way neither Goldstein's dissertation nor the ESOP 2021 paper explores. `ChoiceTreeAnalysis` runs a forward interpretation (`ValueAndChoiceTreeInterpreter` with `materializePicks = true`) to extract a parameter model from the generator's choice structure, then dispatches based on domain size:

- **Finite domains** (all parameters have small value sets): exhaustive enumeration if the total space fits within the coverage budget, otherwise pairwise coverage via the density method over the full value sets.
- **Boundary domains** (some parameters have large ranges): pairwise coverage via the density method over **synthesised boundary values** rather than the full domain. For integers, boundary representatives are `{min, min+1, midpoint, max-1, max, 0 if in range}`. For floats, they include IEEE 754 special values (±0, ±∞, NaN, subnormals). For dates, boundary values include domain edges with BVA ±1 neighbours, calendar boundaries (start/end of day, month, year), epoch points, and DST transition moments with their ±1-second neighbours — the kind of values that have historically been bug-prone and that random sampling is unlikely to hit within a reasonable budget. The covering array then guarantees that every t-tuple of these boundary values across parameters appears in at least one test case.

The covering array rows are replayed through the existing `Interpreters.replay` infrastructure. The coverage budget is separate from and additive with `maxIterations` — structured coverage runs first, then random sampling runs for the full random budget.

### Covering arrays in the reducer: FibreCoveringEncoder

The covering array infrastructure is also reused inside the BonsaiReducer. `FibreCoveringEncoder` — a `ComposableEncoder` used as the downstream leg of `KleisliComposition` (Section 3) — searches a fibre for *any* failure-preserving candidate rather than minimising toward a target. It operates in two regimes: exhaustive mixed-radix enumeration for small fibres (total space ≤ 128), and pairwise covering (strength 2) via the density method for larger ones. Each `nextProbe()` call pulls the next greedy row from a `PullBasedCoveringArrayGenerator` — no upfront batch build. This connects the combinatorial testing infrastructure (Section 4) with the fibration theory (Section 7): the upstream mutation selects a point in the base (trace structure), and `FibreCoveringEncoder` lazily explores the fibre above it.

---

## 5. Generator Tuning: Probabilistic Programming

**Tjoa, Garg, Goldstein, Millstein, Pierce & Van den Broeck, "Tuning Random Generators: Property-Based Testing as Probabilistic Programming" (OOPSLA2, 2025)**

### What Exhaust takes

- **Offline tuning of generator weights** via an objective function — the core pattern of Exhaust's `ChoiceGradientTuner`. The paper frames generators as programs in a probabilistic programming language (Loaded Dice) with symbolic weights; Exhaust's `OnlineCGSInterpreter` plays the same role as the paper's inference engine, computing per-branch fitness via derivative sampling.
- **Entropy maximisation** as a diversity objective. Exhaust's fitness sharing strategy addresses the same diversity collapse problem the paper tackles with entropy-based objectives.
- **REINFORCE** adapted to generator tuning — replacing infeasible exact enumeration with sampling-based gradient estimates. Exhaust's warmup phase (default 400 runs) is the sampling-based analogue.
- **Validity-aware tuning** — jointly optimising for diversity and validity (the filter predicate). Exhaust's `FitnessAccumulator` tracks per-branch fitness that reflects both dimensions.

### Where Exhaust diverges

The paper uses exact probabilistic inference via BDDs (in Dice) for gradient computation. Exhaust trades this for a sampling-based approximation (derivative evaluation in the `OnlineCGSInterpreter`), which is the pragmatic choice for a runtime framework. The paper's approach is more theoretically grounded; Exhaust's is more practically deployable.

Exhaust adds three mechanisms not in the paper:
- **Fitness sharing** (niche-count sharing: `weight_i = fitness_i / (1 + N * share_i)`) to flatten the distribution toward the tail without destroying the ranking.
- **UCB1 exploration bonus** from multi-armed bandit literature as an alternative weight-baking strategy.
- **Adaptive smoothing** via per-site entropy analysis — high temperature at bottleneck sites (where one choice dominates), low temperature at well-distributed sites.

---

## 6. Prior Art in Property-Based Testing

### MacIver & Donaldson, "Test-Case Reduction via Test-Case Generation" (ECOOP 2020)

This paper deserves individual treatment, not just a mention under "Hypothesis." It formalises the foundational concepts that Exhaust's entire reduction architecture builds on.

#### What Exhaust takes

- **Internal reduction** — the key idea that test-case reduction should be applied *internally*, to the sequence of random choices made during generation, not *externally* to the generated value. This eliminates the test-case validity problem: because internal reduction works by re-generating, any reduced test case is one that the generator *could* have produced. Exhaust's BonsaiReducer operates on `ChoiceSequence` and `ChoiceTree`, never on the generated value directly. Encoders operate on one or the other depending on the pass — some mutate the flattened sequence, others work on the tree structure. The `ReductionMaterializer` then re-runs the generator against each candidate to produce a fresh tree with current metadata.

- **Shortlex optimisation** as the reduction order (Section 2.2). Among choice sequences of the same length, prefer the lexicographically smaller one; among sequences of different lengths, prefer the shorter one. Exhaust adopts this directly — the shortlex well-order on `ChoiceSequence` is the termination guarantee for the Bonsai reducer's reduction pipeline (every accepted candidate is strictly shortlex-smaller, and any strictly decreasing chain in a well-order is finite).

- **Generator-directed reduction** (Section 3.2). The paper's key engineering insight: although we don't have a grammar for the choice sequence format, we do have a *parser* — the generator itself. By instrumenting the generator API (recording `draw` call boundaries), the reducer discovers structural information about which regions of the choice sequence correspond to which parts of the generated value. This is the precursor to Exhaust's `ChoiceTree` — where MacIver & Donaldson record `(start, end)` positions of `draw` calls, Exhaust builds a full hierarchical tree with typed nodes (`.choice`, `.sequence`, `.bind`, etc.).

- **The `Source` / prefix-replay pattern** (Section 3.2, Figure 5). Hypothesis's `Source` object replays a prefix of the choice sequence, then falls back to random bits when the prefix is exhausted. This is directly echoed by Exhaust's `Materializer` in guided mode (replay a `ChoiceSequence` prefix, then fall back to the fallback tree or PRNG — Hypothesis's "extend=full" strategy).

- **Generator/reducer co-design** (Section 3.3). The paper notes that designing generators to be "reduction friendly" — e.g., generating lists by drawing a per-element continue/stop bit rather than drawing a length first — makes structural deletions O(n) instead of O(n^2). Exhaust's `.sequence` operation is the reified version of this: it encodes array boundaries as `.sequence(true/false)` markers in the `ChoiceSequence`, so the reducer can delete elements by removing the region between markers without needing to adjust a separate length entry.

- **The 15-pass reducer architecture** (Section 3.1). Hypothesis 5.15.1 had 15 passes across 5 categories: contiguous deletion (6), sub-region replacement (1), zero-fill (1), lexicographic reduction (4), and simultaneous reduce-and-delete (3). Exhaust's 23 composable encoders across four phases are a direct descendant — expanded with bind-aware passes, Kleisli composition, and fibre-based exploration, reorganised by the categorical framework from Sepulveda-Jimenez, but covering the same operational space.

- **The `find_integer` adaptive binary search** (from MacIver's blog post "Improving Binary Search by Guessing", 2019). An O(log n) search that finds the largest integer satisfying a predicate by exponential probing followed by binary search — achieving logarithmic complexity relative to the *answer* rather than the search space. Exhaust's `ZeroValueEncoder` and `BinarySearchToSemanticSimplestEncoder` implement this pattern as `ComposableEncoder` conformances.

- **Integrated shrinking.** Hypothesis pioneered the idea that shrinking should be built into the generator infrastructure rather than requiring users to write separate `shrink` functions per type (the QuickCheck `Arbitrary` model). This had a huge influence — Goldstein's dissertation explicitly builds on it, and Exhaust inherits the principle completely: users never write shrinking logic. The generator's choice structure *is* the shrinking strategy. MacIver & Donaldson's ECOOP 2020 paper formalises this as internal reduction, and Goldstein's freer monad representation takes it further by making the choice structure inspectable. But the foundational insight — that shrinking is a property of the *randomness consumed*, not the *value produced* — originates with Hypothesis.

- **Float handling.** Hypothesis's special-case float reduction pass (Section 3.3 of the ECOOP paper) — designed so that lexicographic reduction of the choice sequence produces "visually simpler" floating-point numbers rather than reducing toward 5e-324 (the smallest positive double) — directly inspired Exhaust's `ReduceFloatEncoder`. Exhaust generalises this via `TypeTag` and `BitPatternConvertible`, handling floats at the bit-pattern level with a multi-stage pipeline (truncation, cross-zero probing, NaN/∞ canonicalisation, as-integer-ratio simplification).

#### Where Exhaust diverges

The paper operates on flat, unstructured choice sequences. All 15 passes treat every position uniformly — there is no notion of bind dependencies or depth-ordered sweeps. Exhaust's bind-aware architecture (the Bonsai reducer's reduction pipeline, `BindSpanIndex`, depth-filtered target extraction) has no analogue in Hypothesis. The degenerate no-binds case collapses back to the Hypothesis regime: a flat sweep of delete → minimise → redistribute.

### Hedgehog (Stanley, 2017)

A Haskell PBT library that, like Hypothesis, integrates shrinking into the generator rather than requiring separate `Arbitrary`/`shrink` instances. Two specific design choices influenced Exhaust:

- **Size-parameterised value ranges.** Hedgehog's `Range` type scales the effective range of numeric generators based on the current size parameter, starting small and growing toward the full range. Exhaust's `Gen.choose(in:, scaling:)` with `.getSize` → `._bind` → `chooseDerived(in: scaledRange)` follows this pattern — the size parameter narrows the effective range, so early test cases use small values and later ones explore the full domain.
- **API ergonomics.** Hedgehog's clean combinator API (monadic generator composition without separate shrink definitions) informed Exhaust's public API design — generators compose via `map`, `bind`, `mapped`, `bound`, `filter`, and collection combinators without the user ever writing shrinking logic.

### QuickCheck (Claessen & Hughes, ICFP 2000)

The original property-based testing framework. Exhaust inherits the generator DSL pattern (combinators like `map`, `bind`, `choose`, `oneOf`) and the size-parameterised generation model (`getSize`/`resize`).

### Hypothesis rule-based stateful testing (MacIver)

Hypothesis's `RuleBasedStateMachine` provides a framework for testing stateful systems by generating sequences of operations (rules) and checking invariants after each step. Rules declare preconditions and can reference objects created by earlier rules via `Bundle` (a named collection of values produced during the test).

Exhaust's `@Contract` macro is a direct descendant of this design:
- `@Command` methods correspond to Hypothesis rules
- `Bundle<T>` for referencing entities from prior commands echoes Hypothesis's `Bundle`
- `@Invariant` methods are checked after each command, matching Hypothesis's invariant checking
- `skip()` corresponds to precondition filtering

The macro synthesis approach is Exhaust's contribution — Hypothesis requires manual class-based conformance, while `@Contract` derives the command enum, generator, and runner from annotated stored properties and methods.

### Wayne, "PBT and Contracts" (2019)

Hillel Wayne's blog post proposes combining property-based testing with code contracts (preconditions/postconditions). The key insight: if functions already have contract annotations, PBT tests can be reduced to pure generation — feed random inputs to contracted functions, and the contracts serve as automatic test oracles. This "chains" through call graphs: when a function calls other contracted functions, their contracts are checked automatically, transforming basic fuzzing into integration testing.

This idea — that the specification *is* the test oracle, and PBT's job is just to generate inputs — directly informs Exhaust's `@Contract` design philosophy. The `@Invariant` annotation plays the role of Wayne's contracts: invariants are checked automatically after every command, so the user writes the specification (invariants + command preconditions) and Exhaust handles generation, sequencing, and reduction.

---

## 7. Fibration Theory

The Bonsai reducer's reduction pipeline has a categorical structure that goes beyond the reduction algebra of Sepúlveda-Jiménez. The trace space is a Grothendieck fibration — trace structures form the base, value assignments form the fibres — and several laws from fibration theory are directly exploited in the implementation. This section records the academic influences.

**Jacobs, *Categorical Logic and Type Theory* (1999)**

The standard reference for fibration theory. Exhaust uses:

- **Cartesian-vertical factorisation** (§1.4) — any morphism in the total category of a fibration factors uniquely as a cartesian morphism (base change) followed by a vertical morphism (fibrewise adjustment), given a cleavage. This is the categorical justification for the base descent → fibre descent ordering: base descent is the cartesian factor, fibre descent is the vertical factor. This is a step-level invariant of the reduction pipeline's core; the speculation leg breaks the factorisation at the step level and recovers it at the pipeline level via checkpoint acceptance.
- **Uniqueness of cartesian lifts** (§1.1, Proposition 1.1.4) — motivates doing exactly one guided materialisation attempt before falling back to PRNG, since the canonical projection is essentially unique. Implemented as the regime probe in base descent.
- **Composition of cartesian morphisms** (§1.1, Exercise 1.1.4(ii); §1.5, Lemma 1.5.5) — motivates the `MutationPool` in base descent, which composes non-overlapping structural deletions.
- **Bifibrations and the `g! ⊣ g*` adjunction** (§9.1, Lemma 9.1.2; §1.9, Proposition 1.9.8) — the cocartesian direction `g!` provides the theoretical basis for the scaffolded counit test in the regime probe's unknown branch.
- **Fibrewise search** — the `FibreCoveringEncoder` (Section 4) is a direct application of fibrewise reasoning: given a fixed base point (trace structure from an upstream mutation), it systematically explores the fibre above it using covering arrays. `KleisliComposition` implements the categorical structure: the upstream `ComposableEncoder` selects a base morphism, `GeneratorLift` computes the cartesian lift, and `FibreCoveringEncoder` searches the resulting fibre.

---

## 8. Convergence of Threads

**The reified comap-bind is the bridge.** Goldstein's PMP operations (`Lmap`/`Prune`) enable bidirectional annotation *around* binds, but the `Bind` constructor itself remains opaque. Exhaust's `.transform(.bind(forward:, backward:, ...))` fuses the `comap` annotation *into* the bind, making the dependency structure visible as inspectable data. Without this, neither the categorical reduction algebra (Sepúlveda-Jiménez) nor the fibration theory (Jacobs) would have depth information to exploit — the reducer would degenerate to the flat Hypothesis regime.

**The two categorical frameworks are complementary.** Sepúlveda-Jiménez's reduction algebra organises the *encoder/decoder infrastructure*: how morphisms compose, how grades track approximation quality, how 2-cell dominance prunes the encoder set. The fibration theory organises the *scheduling structure*: why the base-before-fibre ordering is canonical, and why the cartesian-vertical factorisation makes the phase decomposition well-defined. The bind-depth ordering within phases follows naturally from the same dependency logic. The reduction algebra operates *within* each phase; the fibration theory operates *between* phases.

The remaining influences are additive rather than structural:
- Tjoa et al. shapes the CGS tuning pipeline (Section 5) but does not affect the core representation or reduction architecture.
- Bryce & Colbourn and Kuhn et al. provide the coverage analysis layer (Section 4), which is an independent capability built on the same ChoiceTree infrastructure.
