# Categorical Audit: BonsaiReducer and CoverageRunner vs. Reduce-Solve-Recover

An audit of how well the BonsaiReducer and CoverageRunner instantiate the
reduce-solve-recover framework from Sepulveda-Jimenez, "Categories of
Optimization Reductions" (Jan 2026).

The paper formalizes optimization pipelines as a category **OptRed** whose objects
are costed sets `P = (X, c_P)` and whose morphisms are certified `(enc, dec)`
pairs. Sections 7-10 extend this to Kleisli effects, approximate reductions,
resources, and a unified grade `G = Aff_>=0 x W`. Section 15 adds 2-cells for
dominance and refinement between parallel morphisms.

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
dual `c_P = -strength`. The fit is adequate but less natural: there is no
single real-valued cost function -- the quality of a covering array is the
interaction strength, which is ordinal, not cardinal.

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

### BonsaiReducer -- Strong fit

The V-cycle is a composition of legs:
`Branch -> Snip -> Prune -> Train -> Redistribute`. Each leg is a morphism
`P -> P` (endomorphism). The cycle composes legs sequentially, and cycles
compose across iterations until the stall budget is exhausted. This matches
the paper's Prop 3.2 directly.

A cycle where no encoder succeeds is operationally the identity:
`bestSequence` does not change, and the stall counter decrements.
Associativity holds by construction (sequential function composition).

### CoverageRunner -- Weak fit

The strategy chain (Exhaustive -> TWay -> SingleParameter) is **selection**,
not composition -- only one strategy fires. This is a coproduct, not a
composed pipeline. The coverage -> random pipeline in `__exhaust` is a genuine
composition (coverage produces partial results, random sampling completes),
but it is orchestrated by the caller, not by the coverage system itself.

The `.notApplicable` result is the identity: coverage adds nothing, the random
phase runs unchanged.

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

## 5. Approximate Reductions (Section 8): Affine Slack

**Paper** (Def 8.3): An approximate reduction carries a grade
`gamma = (alpha, beta) in Aff_>=0` with
`c_P(dec(y)) <= alpha * c_Q(y) + beta`.

### BonsaiReducer -- Exact today, with a clear path to approximate

The current system is **strictly exact** (`gamma = (1, 0)` for every accepted
step). The enforcement point is `SequenceDecoder`:

```swift
guard freshSequence.shortLexPrecedes(originalSequence) else { return nil }
```

No slack ever accumulates. Every accepted step must be a genuine shortlex
improvement.

This creates a well-known limitation: **shortlex local minima**. When reaching
the global minimum requires temporarily increasing an early entry to unlock
deletion of later structure, no exact step can make that move (it would be
shortlex-worse), so the reducer stalls.

#### Strengthening: Redistribution slack via Grade monoid

The Grade monoid `G = Aff_>=0 x W` from Section 10 provides the formal
foundation for controlled non-exact steps. Since redistribution preserves
sequence length, the multiplicative factor `alpha` is always 1, and only the
additive component `beta` matters:

```
(1, beta_1) (x) (1, beta_2) = (1, beta_1 + beta_2)
```

The design has four components:

**Real-valued cost proxy**. A positionally-weighted shortlex cost
`c: ChoiceSequence -> R_>=0` that makes affine operations meaningful.
Earlier entries receive higher weight (decay factor 0.99), reflecting
shortlex's left-to-right priority. An unweighted sum would be literally
invariant under redistribution for unsigned integers (a -= delta, b += delta
conserves the total).

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

**Slack tracker**. A `RedistributionSlackTracker` tracks accumulated
additive slack. Slack increases when redistribution accepts a
non-shortlex-improving step. Slack decreases when exact legs (snip, prune,
train) improve the sequence, "paying back" accumulated approximation debt.
A `slackBudget` caps total allowed slack; setting it to 0 recovers exact-only
behavior.

**Slack-aware decoder**. A variant of the guided decoder used only by the
redistribution leg. The existing exact path is tried first; slack is used only
as a fallback when the exact check fails, the result preserves the failure
property, and the cost increase fits within the remaining budget.

**Integration points**:
- State initialization: slack tracker on `ReductionState`.
- Exact legs pay back slack: `accept()` records cost decreases from non-redistribution legs.
- `bestSequence` guard: with slack, the working sequence can be shortlex-worse than `bestSequence`. The unconditional `bestSequence = sequence` update for bind cases must become conditional -- this is a latent correctness concern even without slack.
- Cycle boundary: reset slack when `bestSequence` genuinely improved.

**Composition law in practice**: Three redistribution steps (beta 12.0, 5.0,
0.0) followed by an exact train step decreasing cost by 20.0 yields overall
grade (1, 0) -- the pipeline is exact. If the train step only decreases cost
by 10.0, accumulated beta is 7.0, and redistribution has
`budget - 7.0` remaining before it pauses.

**Monotonic guarantee on final output**: Because `bestSequence` is updated
only on genuine shortlex improvement, the final result is always at least as
good as the best exact result. Slack-elevated states are transient working
states, never returned to the user.

#### Open questions for redistribution slack

- **Per-cycle vs per-run slack**: Per-cycle (reset each V-cycle) is safer but
  limits exploration. Per-run (cumulative with payback) allows deeper
  exploration but risks divergence. The design uses per-run with payback and
  per-cycle reset on genuine improvement.
- **Budget scaling**: A fixed budget means different things for 5-entry vs
  500-entry sequences. A relative budget (for example, 10% of initial
  `positionalShortlexCost`) might be more robust.
- **Metric choice**: `positionalShortlexCost` does not perfectly embed the
  shortlex ordering. Cases where the metric says "improved" but shortlex says
  "worse" (or vice versa) could cause surprising behavior. A lexicographic cost
  (first differing entry dominates) would be more faithful, at the expense of
  making the additive monoid structure less clean.
- **DominanceLattice interaction**: Slack-accepting steps might invalidate
  2-cell dominance assumptions. If `zeroValue` succeeds on a slack-elevated
  sequence, it does not mean it would have succeeded on the exact-best
  sequence. The lattice might need a slack-aware invalidation rule.
- **Encoder awareness**: Should encoders know about the slack budget?
  Currently the design is transparent -- encoders produce candidates as before,
  and the decoder decides whether to use slack. An alternative is to let
  encoders produce intentionally non-shortlex-improving candidates when slack
  is available (for example, CrossStageRedistribute could try "rightward"
  redistributions). This would require extending the `AdaptiveEncoder`
  protocol.

### CoverageRunner -- Implicit approximation, untracked

t-way coverage at strength `t < n` is an approximation of exhaustive coverage.
The "slack" is the uncovered (n-t)-way interactions. But this is not
formalized as an affine bound -- there is no explicit `(alpha, beta)`.

The coverage -> random pipeline composes an approximate reduction (t-way
coverage, missing some interactions) with a probabilistic solver (random
sampling). The paper's Prop 8.4 says `gamma_{b.a} = gamma_a (x) gamma_b` --
but CoverageRunner does not track this.

#### Strengthening: Coverage approximation grade

Formalizing the coverage gap would enable principled decisions:

- **Track uncovered interaction count**: After IPOG produces a strength-t
  covering array, the gap from exhaustive is the set of (t+1)-way and higher
  interactions not guaranteed to be covered. This could be expressed as an
  additive slack `beta = |uncovered_tuples|`.
- **Compose with random**: If random sampling hits each uncovered tuple with
  probability `p` per sample, then `n` random samples cover each tuple with
  probability `1 - (1-p)^n`. The composed grade `gamma_{random . coverage}`
  would have a smaller beta, quantifying what the pipeline actually guarantees.
- **Budget allocation**: If the grade were tracked, the system could allocate
  budget between coverage and random to minimize the composed grade, rather
  than using fixed additive budgets.

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
random phase has its own independent `samplingBudget`.

#### Strengthening: Compositional resource allocation

- **Per-strategy resource tracking**: Each `CoverageStrategy` could carry a
  resource annotation `w` (for example, estimated IPOG time + replay time).
  The strategy chain would compose these: `w_{chain} = w_1 (x) w_2 (x) w_3`.
- **Budget forwarding**: If exhaustive coverage uses 50 rows out of a
  2000-row budget, the remaining 1950 could be made compositionally
  available to a subsequent boundary coverage pass (currently impossible
  since only one strategy fires).
- **Cross-phase allocation**: The total test budget could be partitioned
  between coverage and random using a monoidal split, rather than using two
  independent numbers (`coverageBudget` and `samplingBudget`).

## 7. 2-Cells and Dominance (Section 15): Refinement

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

### CoverageRunner -- Degenerate fit

`CoveragePhase` ordering (`.exhaustive < .tWay < .boundary`) is an implicit
dominance chain. The strategy chain iterates strongest-first: if exhaustive
succeeds, t-way is skipped. But this is **selection** among alternatives, not
refinement between parallel morphisms -- only one strategy is ever applied.

The hom-sets have size 1 (one strategy per phase), so dominance is trivial.
No invalidation or adaptation is needed.

#### Strengthening: Composable strategies and dominance

- **Strategy composition, not selection**: The paper suggests composing
  strategies: first apply exhaustive coverage to small-domain parameters, then
  apply boundary coverage to large-domain parameters, and compose the results.
  The current architecture cannot express this because strategies are
  alternatives (a coproduct), not a pipeline of composed morphisms.
- **Within-phase alternatives**: If multiple t-way strategies existed
  (for example, IPOG vs. a constraint-based method), a `CoverageDominance`
  lattice could prune: if IPOG produces a stronger result, skip the
  constraint-based method. The `CoverageStrategy` protocol already provides
  the metadata (`name`, `phase`) needed for dominance tracking.
- **Adaptation**: Move-to-front is possible if coverage ran multiple times
  (for example, across different generators in a test suite). The framework
  could learn which strategies tend to succeed for which generator profiles.

## 8. Unified Grade (Section 10): G = Aff_>=0 x W

**Paper** (Def 10.1): The product grade `G := Aff_>=0 x W` combines
approximation slack and resource cost. Composition:
`(gamma, w) (x)_G (gamma', w') = (gamma (x) gamma', w (x) w')`.

### BonsaiReducer -- Partially instantiated

The approximation component is `(1, 0)` (exact). The resource component is
tracked via `CycleBudget`. So `G = {(1,0)} x W` -- the exact subcategory
with resource tracking. With the redistribution slack extension, this would
become `G = Aff_>=0 x W` -- the full grade monoid.

The paper's Prop 10.4 says the grade of a composite pipeline is the monoid
product of its steps' grades. The V-cycle already composes legs sequentially,
so the grade composition law would hold by construction.

### CoverageRunner -- Absent

Neither the approximation component (coverage strength vs exhaustive) nor the
resource component (budget) is formalized as a grade. No composition law
operates. Introducing the unified grade would require:

1. An approximation grade for each strategy (for example, `(1, uncovered_count)` for t-way coverage).
2. A resource grade for each strategy (for example, `(IPOG_time, replay_time)`).
3. A composition law for the coverage -> random pipeline.

This is the largest structural gap between CoverageRunner and the paper.

## Summary Scorecard

| Paper Concept | BonsaiReducer | CoverageRunner |
|---|---|---|
| Objects (costed sets) | Strong | Adequate |
| Morphisms (enc, dec) | Strong -- protocol-reified | Adequate -- implicit in pipeline stages |
| Composition | Strong -- V-cycle legs compose | Weak -- selection, not composition |
| Kleisli effects | Strong -- AdaptiveEncoder is a Kleisli arrow | Partial -- only bind-aware replay |
| Approximation (Aff) | Exact subcategory (clear path to approximate via slack tracker) | Implicit, untracked |
| Resources (W) | Strong -- CycleBudget with forwarding | Weak -- flat budget, no composition |
| 2-cells / Dominance | Strong -- DominanceLattice | Degenerate -- trivial phase ordering |
| Unified grade (G) | Partial -- exact x W (full with slack extension) | Absent |

## Priority Recommendations

### For BonsaiReducer

1. **Implement redistribution slack** (Section 5 above). This is the highest
   value extension -- it moves the reducer from the exact subcategory into the
   approximate subcategory, enabling escape from shortlex local minima while
   preserving the monotonic guarantee on final output.

2. **Log the grade**. Even without slack, logging `(gamma, w)` per leg and per
   cycle would make the categorical structure visible in the output, aiding
   debugging and performance analysis.

### For CoverageRunner

1. **Track coverage approximation quality**. When returning `.partial`, compute
   and log the uncovered interaction count. This is the first step toward an
   explicit approximation grade.

2. **Compositional resource allocation**. Replace the flat `coverageBudget`
   with a per-strategy resource annotation that composes across the pipeline.
   This enables budget forwarding from cheaper strategies to more expensive
   ones.

3. **Strategy composition over strategy selection**. Redesign the strategy
   chain so that strategies can compose (for example, finite coverage on
   small-domain parameters composed with boundary coverage on large-domain
   parameters). This is the deepest structural change and the highest payoff
   for coverage quality.
