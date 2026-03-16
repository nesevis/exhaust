# Categorical Audit: BonsaiReducer and CoverageRunner vs. Reduce-Solve-Recover

## Executive Summary

Both the BonsaiReducer and CoverageRunner instantiate the paper's base
reduce-solve-recover pipeline (Sections 3-5). In CoverageRunner, the pipeline
is `Generator ->[analyze] Profile ->[IPOG] CoveringArray ->[replay] TestCases`
-- one encoding, one solve, one decoding. In BonsaiReducer, the pipeline is
iterated: each V-cycle leg encodes candidate mutations, solves via property
evaluation, and decodes via materialization, composing legs into cycles and
cycles into a convergent reduction run. Both are clean instantiations of the
paper's `P ->[enc] Q ->[solve] Sol(Q) ->[dec] Sol(P)` shape.

The systems diverge on the paper's extensions (Sections 7-15). The
BonsaiReducer is an iterative, feedback-driven optimizer where Kleisli
effects, grade tracking, resource monoids, and 2-cell dominance are all
productive. The audit produces three genuine insights for the reducer. First,
the V-cycle composes legs via greedy resolution in Set, not via Kleisli
composition -- a structural source of local minima distinct from shortlex
barriers, addressable by beam search (keeping k > 1 candidates per leg).
Second, the proposed redistribution slack is correctly classified as Section
11.5 heuristic search (empirical grade on Kleisli endomorphisms), not Section
11.2 relax-round (a priori bound on decoding from a different problem).
Third, the DominanceLattice directly implements Def 15.3's 2-cells.

CoverageRunner is a one-shot pipeline operating in Set. The paper's extensions
do not apply: coverage quality is ordinal (interaction strength in a finite
lattice), not cardinal; there is no iteration or feedback; and the
compositional machinery has nothing to compose. The categorical framework
confirms that coverage is structurally different from reduction -- a useful
negative result -- but does not generate engineering recommendations. Coverage
improvements should be motivated by concrete fault-detection gaps, not by
categorical considerations.

The primary recommendation for the reducer is to instrument two sources of
local minima (within-leg shortlex barriers and cross-leg greedy resolution)
before committing to either redistribution slack or beam search.

## Proposed Next Steps

### BonsaiReducer

1. **Instrument local minimum prevalence.** Add diagnostic logging for two
   conditions: (a) `maxStalls` terminates a run where the result is longer or
   has larger values than a known-optimal counterexample (within-leg shortlex
   barriers), and (b) a successful leg-3 improvement follows a leg-2 that
   accepted its first candidate without exploring alternatives (cross-leg
   greedy resolution). Run the shrinking challenge suite and any available
   real-world test suites to quantify how often each condition occurs.

2. **Implement the mechanism the data justifies.** If within-leg barriers
   dominate, implement redistribution slack (Section 5): a
   `RedistributionSlackTracker` on `ReductionState` that allows the decoder to
   accept shortlex-worse candidates within a positional-cost budget, with exact
   legs paying back accumulated slack. This is cheaper and more targeted (a few
   extra probes per redistribution leg). If cross-leg greedy resolution
   dominates, implement beam search at k=2: keep the top 2 candidates from
   each leg and explore downstream for both. This is more general but more
   expensive (2x materializations per leg per cycle), and k=1 recovers the
   current greedy behavior. The two mechanisms are complementary and could be
   combined if both sources prove significant.

3. **Log per-leg grades.** Even without slack, logging `(gamma, w)` per leg
   and per cycle would make the categorical structure visible in diagnostic
   output and provide baseline data for the instrumentation in step 1.

### CoverageRunner

No changes are recommended based on this audit. The reduce-solve-recover
pipeline shape is already cleanly instantiated. The `CoverageStrategy`
protocol formalizes the enc stage, `SCADomainBuilder` formalizes the SCA
enc stage, and the replay methods formalize dec. The quality-ordered strategy
chain and per-parameter domain treatments in `ChoiceTreeAnalysis` are
well-structured engineering that does not benefit from categorical
formalization. Future coverage improvements (for example, constraint-aware
branch analysis for SCA, or higher-strength IPOG for small parameter counts)
should be motivated by concrete fault-detection gaps in the test suite, not
by categorical considerations.

---

## Detailed Audit

The paper formalizes optimization pipelines as a category **OptRed** whose objects
are costed sets `P = (X, c_P)` and whose morphisms are certified `(enc, dec)`
pairs. Sections 7-10 extend this to Kleisli effects, approximate reductions,
resources, and a unified grade `G = Aff_>=0 x W`. Section 15 adds 2-cells for
dominance and refinement between parallel morphisms.

Both systems fit the paper's **base pipeline** (Sections 3-5), but they
diverge on the paper's **extensions** (Sections 7-15). The BonsaiReducer is
an iterative, feedback-driven optimizer where these extensions are productive.
CoverageRunner is a one-shot pipeline operating in Set where the extensions
do not apply.

A key insight is that the BonsaiReducer's V-cycle composes legs via **greedy
resolution** in **Set**, not via Kleisli composition in **Kl(P)**. Each leg
internally uses Kleisli arrows (encoders produce candidate sets), but
nondeterminism is resolved before cross-leg composition occurs. This is sound
but incomplete -- a structural source of local minima that the paper's
framework reveals clearly.

## 1. Objects: Optimization Problems as Costed Sets

**Paper** (Def 2.1): `P = (X, c_P)` where `c_P : X -> R_bar` is an
extended-real objective. Infeasible points get `+inf`.

### BonsaiReducer -- Strong fit

- **Decision set X**: `ChoiceSequence` -- the flattened sequence of choices
  encoding a generator execution.
- **Cost c_P**: Shortlex order on sequences (length first, then lexicographic).
  Implicitly `c(seq) = 0` when the property fails, `+inf` when it passes. The
  reducer minimizes sequence length and values subject to "still fails the
  property."
- **Feas(P)**: `{ seq : property(replay(gen, seq)) == false }` -- sequences
  that reproduce the failure.

The shortlex total order maps cleanly to the extended-real cost domain. The
`+inf` encoding for infeasible points is exactly what the shortlex guard in
`SequenceDecoder` implements: candidates that pass the property are rejected
(cost `+inf`), so they are outside `Feas(P)`.

### CoverageRunner -- Adequate fit

- **Decision set X**: The combinatorial parameter space described by
  `FiniteDomainProfile` or `BoundaryDomainProfile`.
- **Cost c_P**: Coverage strength as implicit cost. The hierarchy is exhaustive
  < t-way(t=n) < ... < t-way(t=2) < boundary < notApplicable. The runner
  maximizes coverage strength subject to a row budget.
- **Feas(P)**: `{ covering : rows.count <= budget }` -- covering arrays that
  fit within the budget.

The "cost" is inverted (we maximize strength), but this is just the standard
dual `c_P = -strength`. The fit is adequate but less natural: coverage
strength is ordinal (a finite lattice of interaction levels), not cardinal.
There is no single real-valued cost function with meaningful arithmetic.

## 2. Morphisms: Certified (enc, dec) Pairs

**Paper** (Def 3.1): A morphism `a : P -> Q` is `(enc_a, dec_a)` satisfying:
- `c_Q(enc(x)) <= c_P(x)` -- encoding preserves or improves cost.
- `c_P(dec(y)) <= c_Q(y)` -- decoding preserves or improves cost.

### BonsaiReducer -- Strong fit

| Role | Implementation |
|------|----------------|
| **enc** | `BatchEncoder.encode` / `AdaptiveEncoder.nextProbe` -- produces candidate `ChoiceSequence` mutations. Each candidate is a point in the reduced problem Q. |
| **dec** | `SequenceDecoder` (`.exact` and `.guided`, both via `ReductionMaterializer`) validates and recovers a candidate back into the original problem space by re-materializing through the generator. `.exact` replays with the current tree's valid ranges. `.guided` uses a fallback tree and tiered resolution (prefix cursor, then fallback PRNG) for cross-stage or bind-aware contexts. |

**Encoding guarantee**: Encoders produce candidates that are shortlex <= the
current best by construction -- deletion shrinks, zero-value reduces, binary
search descends. `c_Q(enc(x)) <= c_P(x)` holds.

**Decoding guarantee**: The materializer validates the candidate against the
generator's actual constraints (range checks, bind dependencies). If validation
fails, the candidate is rejected (goes into `rejectCache`). If it passes,
`c_P(dec(y)) <= c_Q(y)` holds because the replayed value reproduces the
failure with a shortlex-<= sequence.

The encoder/decoder separation is explicit in the protocol stack
(`SequenceEncoderBase` / `BatchEncoder` / `AdaptiveEncoder` for encoding,
`SequenceDecoder` for decoding). This is the deepest structural parallel with
the paper.

### CoverageRunner -- Implicit fit

| Role | Implementation |
|------|----------------|
| **enc** | `ChoiceTreeAnalysis.analyze` transforms a generator into a `FiniteDomainProfile` / `BoundaryDomainProfile` -- the "reduced" representation that IPOG can solve. |
| **dec** | `CoveringArrayReplay.buildTree` / `BoundaryCoveringArrayReplay.buildTree` decodes covering array rows back into `ChoiceTree`s that can be replayed through the original generator. |

The enc/dec structure exists but is not reified as protocols. The pipeline
`Generator ->[analyze] Profile ->[IPOG] CoveringArray ->[replay] TestCases`
has the same shape as `P ->[enc] Q ->[solve] Sol(Q) ->[dec] Sol(P)`, but the
certification is implicit: analysis is faithful for analyzable generators, and
replay is exact for well-formed rows. The new `CoverageStrategy` protocol
begins to formalize the enc side (each strategy wraps a distinct encoding
path), but dec remains a set of static methods.

## 3. Category Structure: Composition and Identity

**Paper** (Prop 3.2): `(b . a) = (enc_b . enc_a, dec_a . dec_b)`. Identity is
`id_P = (id_X, id_X)`.

### BonsaiReducer -- Greedy resolution of Kleisli legs, not Kleisli composition

The V-cycle is a sequence of legs:
`Branch -> Snip -> Prune -> Train -> Redistribute`. Each leg internally uses
Kleisli arrows (encoders produce candidate sets, decoders may reject), but
the leg's output is a **single resolved candidate**, not a set. The
composition of legs is therefore deterministic function composition in
**Set**, not Kleisli composition in **Kl(P)**.

The actual execution is `resolve . leg_n . ... . resolve . leg_1`, not
`leg_n (circledot) ... (circledot) leg_1`. Full Kleisli composition (Prop
7.8) would explore the exponential tree of all leg-1-output x leg-2-output x
... paths and pick the globally optimal endpoint. Greedy resolution commits
at each leg.

This is **sound** (each step is exact, so the composite is exact) but
**incomplete** (it can miss better endpoints reachable through suboptimal
intermediate choices). A leg-2 encoder might produce a candidate that is
suboptimal for leg 2 but unlocks a much better result in leg 3, which greedy
resolution can never discover. This is a structural source of local minima
distinct from and compounding the shortlex local minimum problem discussed in
Section 5.

The paper's framework reveals this clearly: the V-cycle lives in Set (greedy
deterministic composition), not in Kl(P) (full nondeterministic composition).
The Kleisli structure exists within each leg but is resolved before cross-leg
composition occurs.

A cycle where no encoder succeeds is operationally the identity:
`bestSequence` does not change, and the stall counter decrements.
Associativity holds by construction (sequential function composition in Set).

### CoverageRunner -- Two levels, neither is composition in OptRed

The audit must distinguish two levels:

**Parameter-level composition (already exists).** `ChoiceTreeAnalysis` composes
per-parameter treatments into a single profile: finite-domain parameters
(domain <= 256) get exact enumeration, large-domain parameters get
boundary-value representatives, sequence parameters get length + element
decomposition. IPOG then combines these into a single covering array. This
*is* composition -- the analysis phase applies different "strategies" per
parameter and composes them via the covering array's column structure.

**Array-level selection (no composition).** The strategy chain
(Exhaustive -> TWay -> SingleParameter) is selection, not composition -- only
one strategy fires at the array level. This is a coproduct, not a composed
pipeline.

**Coverage and random are not composable morphisms.** The coverage -> random
pipeline in `__exhaust` is **not** a composition in the sense of Prop 3.2.
Composition requires morphisms with enc/dec structure that chains:
`enc_{b.a} = enc_b . enc_a` and `dec_{b.a} = dec_a . dec_b`. Coverage
encodes the generator into a profile and decodes covering array rows via
replay. Random just runs the generator with PRNG seeds -- it has no encoding
step (no profile, no analysis) and no decoding step (no replay from a
structured representation).

These are **independent testing strategies** that happen to run sequentially.
The total test effort is the union of their outputs, not the composition of
their encodings. The right categorical framing is a **coproduct with result
merging**: both strategies are alternative approaches to the same testing
problem, and their outputs are combined by set union. The `.notApplicable`
case supports this: when coverage contributes nothing, random runs unchanged
-- this is the coproduct injection, not the identity morphism of a composed
pipeline.

This distinction affects the resource recommendations: "compositional resource
allocation" across coverage and random is not a meaningful concept if they are
not composable morphisms. Resource allocation between them is a scheduling
decision. Per-strategy resource tracking still makes sense *within* coverage
(across strategies), but not across the coverage/random boundary.

## 4. Kleisli Effects (Section 7): Nondeterminism and Failure

**Paper** (Def 7.7): A T-effectful reduction uses Kleisli arrows
`enc_a : X -> TY` and `dec_a : Y -> TX`.

### BonsaiReducer -- Strong fit

`T = P` (powerset/nondeterminism). `AdaptiveEncoder` is explicitly a Kleisli
arrow: it returns one candidate at a time, feedback-driven, with possible
failure (`nextProbe -> nil`). `BatchEncoder` returns a sequence of candidates
(angelic nondeterminism -- first success wins).

The cost algebra is `alpha = inf` (angelic): among all candidate mutations,
the reducer keeps the one with the smallest cost (shortlex minimum). This
matches Example 7.6 for `T = P, alpha = inf`.

The decoder is also effectful: `ReductionMaterializer` can reject candidates
(`.rejected`), fail (`.failed`), or succeed. This makes `dec_a : Y -> PX` --
a Kleisli arrow returning a set of possible decodings (typically singleton on
success, empty on failure).

### CoverageRunner -- Partial fit

Deterministic on the enc side (analysis is a function). Kleisli on the dec
side only when binds are present: `GuidedMaterializer` may fail or produce
different results depending on the PRNG seed. This is `T = P`
nondeterminism, but it only activates for bind-containing generators.

For bind-free generators, the entire pipeline is deterministic -- there is no
effectful structure.

## 5. Approximate Reductions and Quality Tracking

**Paper** (Def 8.3): An approximate reduction carries a grade
`gamma = (alpha, beta) in Aff_>=0` with
`c_P(dec(y)) <= alpha * c_Q(y) + beta`.

### BonsaiReducer -- Exact today, with a path to heuristic slack

The current system is **strictly exact** (`gamma = (1, 0)` for every accepted
step). The enforcement point is `SequenceDecoder`:

```swift
guard freshSequence.shortLexPrecedes(originalSequence) else { return nil }
```

No slack ever accumulates. Every accepted step must be a genuine shortlex
improvement.

This creates a limitation: **shortlex local minima**. When reaching the global
minimum requires temporarily increasing an early entry to unlock deletion of
later structure, no exact step can make that move (it would be shortlex-worse),
so the reducer stalls.

#### Categorical classification of the proposed slack

The proposed redistribution slack is **not** a relax-round morphism in the
sense of Section 11.2. Relax-round uses a *different*, tractable problem Q
(for example, a convex relaxation of a nonconvex problem), and the grade
quantifies the a priori loss of decoding Q's solution back to P.

Redistribution is an **endomorphism** `P -> P` -- the problem space does not
change. The slack proposal is closer to Section 11.5 (heuristic and
evolutionary optimization), where a Markov kernel `X -> P(X)` explores the
same space and the grade is an empirical quality annotation, not an a priori
bound. Specifically:

- The reducer's redistribution leg with slack is a nondeterministic
  endomorphism `ChoiceSequence -> P(ChoiceSequence)` that may return a
  shortlex-worse candidate.
- The grade `(1, beta)` is an **empirical budget** limiting the total cost
  increase, not a certified a priori bound on solution quality.
- The `bestSequence` monotonicity guard ensures that the externally visible
  morphism always has grade `(1, 0)` -- the pipeline is exact. Slack is purely
  internal.

This distinction matters: the Aff_>=0 composition law
`(1, beta_1) (x) (1, beta_2) = (1, beta_1 + beta_2)` still tracks slack
accumulation correctly within a run, but the grade does not provide an
external quality guarantee. It is an internal bookkeeping device.

#### The proxy faithfulness question

The proposed `positionalShortlexCost` (0.99 decay weighted key sum) does not
faithfully embed shortlex into R. A faithful embedding preserving additivity
does not exist: shortlex is lexicographic (the first differing position
dominates absolutely), while any additive metric lets many small later-entry
changes outweigh one early-entry change.

The right framing is option (b): accept the proxy's occasional unsoundness
and rely on `bestSequence` monotonicity as the safety net. The proxy serves
to bound the **diameter** of the working state's excursion from
`bestSequence`. It does not need to be faithful -- it needs to be correlated
enough that small proxy increases correspond to small shortlex perturbations
*in practice*. The grade's value is operational (when to pause
redistribution), not semantic (certifying the output).

Cases where the proxy disagrees with shortlex:
- Proxy says "cheap" but shortlex says "worse": an early entry increases
  by 1 (large shortlex impact, small proxy impact if weight is high).
  The 0.99 decay is mild enough that this is unlikely for positions near the
  front, but possible for positions in the middle of long sequences.
- Proxy says "expensive" but shortlex says "better": many later entries
  decrease by a lot (large proxy impact, no shortlex impact since the first
  differing position dominates). This direction is harmless -- it means
  slack is consumed unnecessarily, but the step is actually exact.

The first case (accepting a truly shortlex-worse step that the proxy
underprices) is the concerning one. The `bestSequence` guard prevents this
from affecting the final output, but it means slack budget could be consumed
on steps that are shortlex-worse than the proxy suggests. The practical
impact depends on how often redistribution modifies positions near the front
of the sequence vs. the tail. Empirical measurement is needed.

#### What the per-leg grade buys you

The externally visible grade of a completed reduction run is always `(1, 0)` --
the `bestSequence` monotonicity guard ensures this. Per-leg grade tracking
serves two **internal** purposes:

1. **Knowing when to pause redistribution**: When the slack budget is
   exhausted, redistribution reverts to exact-only until exact legs pay it
   back. This is the primary operational value.
2. **Diagnostics**: Logging how much "uphill" movement was needed to escape a
   local minimum aids debugging and tuning the slack budget.

The grade does not serve a purpose visible to the caller. This is sufficient
justification -- the `CycleBudget` resource tracking similarly serves only
internal scheduling purposes and is not exposed to callers.

#### Empirical prevalence of shortlex local minima

The slack proposal is motivated by shortlex local minima. Whether stalling is
common enough to justify the engineering cost is an open empirical question.
The shrinking challenge suite has cases (Bound5, Coupling) where the reducer
converges but the result is visibly non-minimal. Whether that is a shortlex
local minimum vs. insufficient budget vs. an encoder gap is not always
distinguishable from the output alone.

Before implementing the slack tracker, the right first step is instrumentation:
log when `maxStalls` terminates a run where the result is longer or has larger
values than a known-optimal counterexample. This would quantify the prevalence
of shortlex local minima and inform whether the slack budget is worth the
complexity.

#### Design sketch: Redistribution slack tracker

Since redistribution preserves sequence length, the multiplicative factor
`alpha` is always 1. Only the additive component `beta` matters, giving a
degenerate Aff_>=0 where slack accumulates linearly:

```
(1, beta_1) (x) (1, beta_2) = (1, beta_1 + beta_2)
```

The design has four components:

**Real-valued cost proxy.** `positionalShortlexCost` as described above.
Earlier entries receive higher weight (decay factor 0.99). An unweighted sum
would be literally invariant under redistribution for unsigned integers
(a -= delta, b += delta conserves the total).

```swift
extension ChoiceSequence {
    var positionalShortlexCost: Double {
        var cost: Double = 0
        var weight: Double = 1.0
        let decay: Double = 0.99
        for entry in self {
            switch entry {
            case let .value(v), let .reduced(v):
                cost += Double(v.choice.shortlexKey) * weight
                weight *= decay
            case .group, .sequence:
                break
            }
        }
        return cost
    }
}
```

**Slack tracker.** A `RedistributionSlackTracker` tracks accumulated additive
slack. Slack increases when redistribution accepts a non-shortlex-improving
step. Slack decreases when exact legs (snip, prune, train) improve the
sequence, "paying back" accumulated approximation debt. A `slackBudget` caps
total allowed slack; setting it to 0 recovers exact-only behavior.

**Slack-aware decoder.** A variant of the guided decoder used only by the
redistribution leg. The existing exact path is tried first; slack is used only
as a fallback when the exact check fails, the result preserves the failure
property, and the cost increase fits within the remaining budget.

**Integration points:**
- State initialization: slack tracker on `ReductionState`.
- Exact legs pay back slack: `accept()` records cost decreases from
  non-redistribution legs.
- `bestSequence` guard: with slack, the working sequence can be shortlex-worse
  than `bestSequence`. The unconditional `bestSequence = sequence` update for
  bind cases must become conditional -- this is a latent correctness concern
  even without slack.
- Cycle boundary: reset slack when `bestSequence` genuinely improved.

**Composition law in practice.** Three redistribution steps (beta 12.0, 5.0,
0.0) followed by an exact train step decreasing cost by 20.0 yields overall
grade (1, 0) -- the pipeline is exact. If the train step only decreases cost
by 10.0, accumulated beta is 7.0, and redistribution has `budget - 7.0`
remaining before it pauses.

#### DominanceLattice interaction under slack

Invalidating dominance whenever slack is nonzero is the right lightweight
solution, and it costs less than it sounds. Dominance within the
redistribution leg itself is already minimal -- redistribution encoders do not
form dominance chains the way value-minimization encoders do. The lattice's
main value is in legs 1-3 (snip, prune, train), which are always exact. So
invalidating during leg 4 (where slack is active) has negligible cost.

The concern about a slack-elevated sequence producing misleading dominance for
subsequent exact legs is addressed by the fact that exact legs re-derive spans
and re-check from the current working sequence, not from cached dominance
state. The lattice resets at leg boundaries already.

#### Open questions for redistribution slack

- **Per-cycle vs per-run slack**: Per-cycle (reset each V-cycle) is safer but
  limits exploration. Per-run (cumulative with payback) allows deeper
  exploration but risks divergence. The design uses per-run with payback and
  per-cycle reset on genuine improvement.
- **Budget scaling**: A fixed budget means different things for 5-entry vs
  500-entry sequences. A relative budget (for example, 10% of initial
  `positionalShortlexCost`) might be more robust.
- **Encoder awareness**: Should encoders know about the slack budget?
  Currently the design is transparent -- encoders produce candidates as before,
  and the decoder decides whether to use slack. An alternative is to let
  encoders produce intentionally non-shortlex-improving candidates when slack
  is available (for example, CrossStageRedistribute could try "rightward"
  redistributions). This would require extending the `AdaptiveEncoder`
  protocol.

### CoverageRunner -- Different abstraction needed

t-way coverage at strength `t < n` is an approximation of exhaustive coverage.
The "slack" is the uncovered (n-t)-way interactions. But coverage quality is
ordinal (a finite lattice of interaction levels), not cardinal. There is no
natural affine embedding, and the uncovered tuple count is generator-specific
and incomparable across generators. A 2-way array for 5 parameters with domain
10 has a very different uncovered count than one for 20 parameters with domain
3.

`Aff_>=0 x W` is the wrong framework for coverage. The right abstraction is
the paper's **2-cell refinement lattice** (Section 15): a finite lattice of
coverage criteria ordered by refinement, with resource bounds selecting a
point in the lattice. See Section 7 below.

## 6. Resources (Section 9): Monoidal Cost Tracking

**Paper** (Def 9.1-9.2): Resources form a monoidal preorder
`(W, <=, (x), I)`. Composition: `w_{b.a} = w_a (x) w_b`.

### BonsaiReducer -- Strong fit

`CycleBudget` with per-leg weights is the resource annotation. The resource
domain is materialization count (each probe costs one property evaluation).
Unused budget flows forward to subsequent legs (floor, not ceiling).

`LegBudget` tracks `used` and `stallPatience` per leg. The scheduler checks
`legBudget.isExhausted` before each encoder attempt.

The fit with Remark 9.4 is direct:
`P ->[encoder, w_enc] Q ->[property_check, w_prop] Q ->[decoder, w_dec] P`.
The total resource is `w_enc (x) w_prop (x) w_dec`.

Default weights: branch 5%, contravariant 30%, deletion 30%, covariant 25%,
redistribution 10%. These are normalized to sum to 1, giving a principled
allocation that matches the paper's idea of resource composition along a
pipeline.

### CoverageRunner -- Weak fit

`coverageBudget: UInt64` is a single number representing the maximum number of
covering array rows. No per-strategy allocation, no unused-budget forwarding,
no compositional tracking across strategies or phases.

Budget is checked once (`rows.count <= budget`) at array generation time.
The remaining budget after coverage is not passed to the random phase -- the
random phase has its own independent `samplingBudget`. This independence is
**intentional** for PRNG reproducibility: the random phase uses a seed-derived
PRNG that must be deterministic for `.replay(seed)`. If coverage results
influenced the random phase's starting point, the same seed would produce
different random samples depending on whether coverage ran and what it found,
breaking the replay contract.

#### Strengthening: Resource forwarding

Resource forwarding from coverage to random (increasing `samplingBudget` by
the coverage surplus) is low-value in isolation: uniform random has
diminishing returns after coverage handled the structured interactions.

The real value unlock is **strategy composition**: composing finite coverage on
small-domain parameters with boundary coverage on large-domain parameters with
t-way on medium parameters, all into a single covering array. Resource
forwarding becomes meaningful when surplus from a cheap strategy (for example,
exhaustive on 2 small-domain params, 4 rows) can fund a more expensive
strategy (for example, boundary on 3 large-domain params, 50 rows). This is
contingent on first solving strategy composition at the array level.

## 7. 2-Cells, Dominance, and Coverage Criteria (Section 15)

**Paper** (Def 15.3): A 2-cell `a => b` between parallel morphisms
`a, b : P -> Q` is a refinement: `enc_a (sqsubseteq) enc_b`,
`dec_a (sqsubseteq) dec_b`, `g_a <= g_b`.

### BonsaiReducer -- Strong fit

`DominanceLattice` explicitly implements 2-cells. Within a hom-set (encoders
sharing the same phase and decoder context), dominance prunes:

- Value minimization: `zeroValue => binarySearchToZero => binarySearchToTarget`
- Deletion: `deleteContainerSpans => speculativeDelete`

If the more-aggressive encoder succeeds, the less-aggressive one is skipped.
This matches Def 15.3: a successful zero-value probe **refines** any
binary-search probe.

The lattice resets at leg boundaries and after structural changes (deletion
changes the span set, invalidating prior dominance). Move-to-front promotion
of successful encoders adapts the ordering across cycles.

### CoverageRunner -- Quality ordering, not 2-cells

Coverage quality naturally forms a **finite lattice** ordered by interaction
strength:

```
exhaustive
    |
t-way(t=n)
    |
   ...
    |
t-way(t=2)
    |
boundary (strength 1)
    |
notApplicable
```

The intuition is that "exhaustive refines 3-way": every interaction covered
by 3-way is also covered by exhaustive, plus more. But this is **not** a
2-cell in the sense of Def 15.3.

Def 15.3 defines 2-cells between parallel morphisms `a, b : P -> Q` with
componentwise conditions: `enc_a (sqsubseteq) enc_b`,
`dec_a (sqsubseteq) dec_b`, `g_a <= g_b`. For `T = P` with
`(sqsubseteq) = (subseteq)`, `enc_a (sqsubseteq) enc_b` means
`enc_a(x) (subseteq) enc_b(x)` for all x -- the exhaustive encoding produces
a *subset* of the 3-way encoding's candidates. But exhaustive produces
*more* rows, not fewer. The componentwise ordering goes the wrong way on enc.

The refinement between coverage strategies is a **quality ordering on
outputs** (the resulting test suite covers more interactions), not a
componentwise ordering on enc/dec. This is closer to the paper's oplax
naturality (Prop 6.2, costs as oplax natural transformations on
`Cand^op -> Pos`) than to Def 15.3's 2-cells. The coverage strength
ordering is a property of what the composite pipeline achieves, not of how
the individual enc/dec components compare.

The current `CoveragePhase` enum and strategy chain implement this quality
lattice as a linear scan from top to bottom, returning the highest feasible
point. The `bestFitting` method's bottom-up search (try t=2, then t=3, and
so on, keeping the highest that fits within budget) is the resource-bounded
selection mechanism on this lattice.

**Existing parameter-level composition.** `ChoiceTreeAnalysis` already composes
per-parameter treatments: finite-domain parameters get exact enumeration,
large-domain parameters get boundary-value representatives, sequence
parameters get length + element decomposition. IPOG combines these into a
single covering array. This is genuine composition at the parameter level --
the analysis phase applies different coverage levels per parameter and composes
them via the covering array's column structure.

The gap is at the **array level**: the strategy chain selects one array-level
strategy rather than composing multiple. Closing this gap would mean composing
coverage criteria across parameter groups (for example, exhaustive on small
parameters composed with boundary on large parameters via a partitioned
covering array).

#### Note: Per-parameter coverage levels

One could imagine replacing `CoveragePhase` with per-parameter coverage levels
(for example, 3-way on {A, B, C} composed with 2-way on {D, E}). But all
parameters in one IPOG array share the same interaction strength t, and the
value of t-way coverage is in cross-parameter interactions. If you apply 3-way
to {A, B, C} and 2-way to {D, E}, cross-group interactions (A x D, B x E,
A x B x D, and so on) are still only 2-way covered. The improvement over
uniform 2-way is only within-group: 3-way on {A, B, C} instead of 2-way. For
3 small-domain parameters, the difference between 2-way and exhaustive is
typically a handful of extra rows -- small enough that the engineering cost of
heterogeneous-strength IPOG, a lattice traversal in `bestFitting`, and a
per-parameter coverage type would far exceed the value.

The existing system already handles the useful version of per-parameter
differentiation: `ChoiceTreeAnalysis` applies per-parameter *domain*
treatments (exact enumeration vs. boundary representatives), and IPOG builds
a single array at uniform strength over the heterogeneous columns.

## 8. Where the Framework Is Productive and Where It Is Not

### For BonsaiReducer: The framework produces genuine insights

The categorical framework is **productive** for the reducer. It reveals:

1. **Greedy resolution as a structural limitation** (Section 3). The V-cycle
   composes in Set, not in Kl(P). This is a source of local minima distinct
   from shortlex barriers, and the paper's Kleisli composition provides the
   formal alternative (beam search as resource-bounded Kl(P) composition).

2. **Correct classification of redistribution slack** (Section 5). The slack
   proposal is Section 11.5 (heuristic search with empirical grade), not
   Section 11.2 (relax-round). This prevents overstatement of what the grade
   guarantees.

3. **DominanceLattice as 2-cells** (Section 7). The lattice implements Def
   15.3 directly, and the framework clarifies when dominance should invalidate
   (at leg boundaries, on structural changes, and under nonzero slack).

The unified grade `Aff_>=0 x W` fits naturally:
- `alpha = 1` (length-preserving redistribution), `beta = slack` (operational
  budget on shortlex excursion).
- `W = materializations` (property evaluation count per leg).
- The monoid composition law tracks per-leg contributions.
- The grade serves internal purposes (scheduling, diagnostics), not external
  certification.

### For CoverageRunner: The base pipeline fits; the extensions do not

The reduce-solve-recover pipeline is the **right structural description** of
what CoverageRunner does:

```
Generator ->[analyze] Profile ->[IPOG] CoveringArray ->[replay] TestCases
    P          enc        Q      solve      Sol(Q)       dec       Sol(P)
```

One enc (`ChoiceTreeAnalysis.analyze`), one solve (IPOG), one dec
(`CoveringArrayReplay.buildTree`). The `CoverageStrategy` protocol and
`SCADomainBuilder` protocol both formalize the enc stage. The replay methods
formalize dec. This is a clean instantiation of the paper's Sections 3-5.

What does **not** fit is the paper's *extensions* to the pipeline (Sections
7-15). These constructions -- Kleisli composition, grade accumulation,
resource forwarding, 2-cell dominance -- are designed for **iterative,
feedback-driven optimization** where morphisms compose into multi-step
pipelines and grades accumulate across iterations:

1. `Aff_>=0 x W` (Section 10) -- requires cardinal costs with affine
   arithmetic. Coverage quality is ordinal (strength levels in a finite
   lattice), so the grade monoid has no natural instantiation.
2. 2-cells (Section 15, Def 15.3) -- requires componentwise enc/dec ordering.
   The coverage strength ordering is on output quality, and the enc ordering
   goes the wrong way (exhaustive produces more rows, not fewer).
3. Kleisli composition (Section 7) -- requires iterated morphisms. Coverage
   is a one-shot pipeline: analyze once, solve once, replay once. There is no
   feedback loop, no "try again with a different encoding."

The distinction is between the pipeline shape (which fits) and the iterative
compositional machinery (which does not). Coverage is a one-shot pipeline
operating in **Set** (deterministic functions), not in **Kl(P)**
(nondeterministic Kleisli arrows with iterated composition). The paper's
extensions add value for systems that iterate; coverage does not iterate.

The coverage recommendations (per-parameter domain treatments, uniform-
strength IPOG, quality-ordered strategy selection) are sound engineering ideas
that stand on their own merits without categorical motivation.

## Summary Scorecard

| Paper Concept | BonsaiReducer | CoverageRunner |
|---|---|---|
| Objects (costed sets) | Strong | Adequate |
| Morphisms (enc, dec) | Strong -- protocol-reified | Adequate -- implicit in pipeline stages |
| Composition | Greedy resolution in Set, not Kleisli composition (sound but incomplete) | Parameter-level composition exists; array-level is selection; coverage/random is coproduct, not composition |
| Kleisli effects | Strong -- AdaptiveEncoder is a Kleisli arrow; resolved per-leg | Partial -- only bind-aware replay |
| Approximation / Quality | Exact subcategory (path to heuristic slack via Section 11.5) | Quality-ordered lattice, not Aff_>=0 or 2-cells |
| Resources (W) | Strong -- CycleBudget with forwarding | Weak -- flat budget, intentional independence from random |
| 2-cells / Dominance | Strong -- DominanceLattice | Not applicable -- coverage ordering is on output quality, not componentwise enc/dec |
| Right abstraction | Aff_>=0 x W (unified grade) | Base pipeline (Sections 3-5) fits; extensions (Sections 7-15) do not |

## Recommendations

See **Proposed Next Steps** at the top of this document.

The audit identifies two distinct sources of local minima in the reducer:

- **Within-leg shortlex barriers** (Section 5): the decoder rejects any
  candidate that is not a shortlex improvement, preventing "uphill"
  redistributions that would unlock deletion of later structure.
- **Cross-leg greedy resolution** (Section 3): committing to one outcome per
  leg means missing better endpoints reachable through suboptimal intermediate
  choices. A deletion candidate that is suboptimal for leg 2 but enables a
  dramatic value minimization in leg 3 is never explored.

These are complementary problems requiring different mechanisms:

- **Redistribution slack** (Section 5) addresses within-leg barriers. It
  operates inside a single encoder's probing loop, allowing the decoder to
  accept shortlex-worse candidates within a budget. Beam search at the leg
  level would not help here because the uphill step never surfaces as a
  leg-level candidate.
- **Beam search** addresses cross-leg greedy resolution. Instead of committing
  to one candidate per leg, keep the top k candidates and explore downstream
  for each. This is a resource-bounded approximation of full Kleisli
  composition -- a Kl(P_k) composition where P_k is the "top-k powerset"
  monad. The resource cost scales linearly in k, and k=1 recovers the current
  greedy behavior. Beam search does not need a proxy cost metric, slack
  tracking, or dominance invalidation logic.

The relative priority depends on which source of local minima is more common
in practice. The first step is instrumentation (see Proposed Next Steps).
