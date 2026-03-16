# Grade Monoid Redistribution Slack Tracking

Design sketch for applying the Grade monoid from Sepulveda-Jimenez (§10) to the
BonsaiReducer's redistribution leg, enabling controlled non-exact steps to escape
shortlex local minima.

## Background

The paper defines the **grade monoid** G = Aff>=0 x W, combining:

- **Approximation slack** Aff>=0: pairs (alpha, beta) with composition
  `(alpha, beta) (x) (alpha', beta') = (alpha*alpha', beta + alpha*beta')`.
  Multiplicative factors multiply; additive errors accumulate with upstream scaling.
- **Resources** W: a monoidal preorder (e.g. time + memory) that adds under composition.

Each morphism carries a grade `g_a = (gamma_a, w_a)` satisfying:
- `enc_a^dag(c_Q) <= c_P` (encoding doesn't worsen cost)
- `dec_a^dag(c_P) <= f_{gamma_a} . c_Q` (decoding satisfies affine bound)

## Current State: Exact-Only Reductions

After tracing every accept path, the current system is **strictly exact**. The
enforcement point is `SequenceDecoder.swift:114`:

```swift
guard freshSequence.shortLexPrecedes(originalSequence) else { return nil }
```

Every guided decode -- including all redistribution -- must produce a result that
shortlex-precedes the input. The relaxed criteria in `CrossStageRedistributeEncoder`
(lines 536-538: `nonSemanticCount`, `sortedPairKeys`) are speculative: the encoder
produces candidates hoping materialization will yield a shortlex-better result. If
materialization doesn't produce a shortlex improvement, the decoder rejects them.

No slack ever accumulates. Every accepted step is exact: gamma = (1, 0).

This means the Grade monoid's value is not tracking existing uncontrolled slack, but
**enabling controlled slack to escape local minima** that exact-only reduction cannot
reach.

## Motivating Problem

Strict shortlex improvement creates local minima. Redistribution currently can only
shift mass "leftward" in shortlex terms (decrease earlier entries, increase later
ones). It cannot do the reverse even when doing so would unlock a globally simpler
counterexample.

Consider a generator producing `(a, b)` where `b` is drawn from `0...a`. If the
property fails when `b > 5`, the shortlex-simplest counterexample is `(6, 6)`. Value
minimization reaches it easily from most starting points.

But consider a more complex coupling where reaching the global minimum requires
*increasing* an early entry to unlock deletion of later structure. No exact step can
increase an early entry (it would be shortlex-worse), so the reducer stalls at a
local minimum.

Slack enables limited "uphill" movement: accept a step that's shortlex-worse by a
bounded amount, enabling subsequent exact steps to reach a better basin.

## Design

### 1. Shortlex Cost Metric

A real-valued proxy `c: ChoiceSequence -> R>=0` that makes affine operations
meaningful. Redistribution preserves sequence length, so we need only compare value
entries:

```swift
extension ChoiceSequence {
    /// Positionally-weighted shortlex cost.
    ///
    /// Earlier entries receive higher weight, reflecting shortlex's
    /// left-to-right priority. For redistribution (length-preserving),
    /// this metric is monotone with shortlex ordering when only two
    /// entries change.
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

The positional weighting ensures that redistributions changing earlier entries have
higher cost impact. The decay factor is mild (0.99) so that later entries still
contribute meaningfully -- this prevents "free" increases to tail entries.

An unweighted sum (`shortlexCost = sum of shortlexKeys`) is simpler but fails to
distinguish redistributions that affect early vs. late entries. For unsigned integers
where shortlexKey is the identity, the unweighted sum is literally invariant under
redistribution (a -= delta, b += delta conserves the total). The positional weighting
breaks this degeneracy.

### 2. Redistribution Slack Tracker

Since redistribution preserves sequence length, the multiplicative factor alpha is
always 1. Only the additive component beta matters, giving a degenerate Aff>=0 where
slack accumulates linearly:

```
(1, beta_1) (x) (1, beta_2) = (1, beta_1 + beta_2)
```

```swift
/// Tracks accumulated approximation slack across redistribution steps.
///
/// Based on the additive component of the Aff>=0 monoid from
/// Sepulveda-Jimenez S10.1, specialized to alpha = 1 (length-preserving
/// reductions). The composition law degenerates to
/// beta_{b.a} = beta_a + beta_b.
///
/// Slack increases when redistribution accepts a non-shortlex-improving
/// step. Slack decreases when exact legs (snip/prune/train) improve the
/// sequence, "paying back" accumulated approximation debt.
struct RedistributionSlackTracker {
    /// Maximum total slack allowed before redistribution is paused.
    ///
    /// Expressed in positional-shortlex-cost units. A budget of 0
    /// recovers the current exact-only behavior.
    let slackBudget: Double

    /// Accumulated additive slack since the last reset.
    private(set) var accumulatedSlack: Double = 0

    /// Number of non-improving steps accepted under the slack budget.
    private(set) var nonImprovingSteps: Int = 0

    /// Whether the redistribution leg may accept slack-using steps.
    var hasRemainingSlack: Bool {
        accumulatedSlack < slackBudget
    }

    /// Maximum cost increase allowed for the next redistribution step.
    var remainingSlack: Double {
        max(0, slackBudget - accumulatedSlack)
    }

    /// Records a redistribution step that increased shortlex cost.
    ///
    /// - Parameter costIncrease: The positive difference
    ///   `positionalShortlexCost(after) - positionalShortlexCost(before)`.
    mutating func recordSlack(_ costIncrease: Double) {
        accumulatedSlack += costIncrease
        nonImprovingSteps += 1
    }

    /// Records an exact improvement that pays back accumulated slack.
    ///
    /// Called when snip/prune/train legs accept a shortlex-improving
    /// step. The cost decrease offsets prior slack, potentially
    /// re-enabling redistribution.
    mutating func recordExactImprovement(_ costDecrease: Double) {
        accumulatedSlack = max(0, accumulatedSlack - costDecrease)
        if accumulatedSlack == 0 {
            nonImprovingSteps = 0
        }
    }

    /// Full reset. Called when bestSequence improves past the pre-slack
    /// baseline, or at the start of a new V-cycle epoch.
    mutating func reset() {
        accumulatedSlack = 0
        nonImprovingSteps = 0
    }
}
```

### 3. Slack-Aware Decoder

A variant of the guided decoder used only by the redistribution leg. The existing
exact decoder path is tried first; slack is used only as a fallback:

```swift
extension SequenceDecoder {
    /// Slack-aware decode: accepts results within `remainingSlack` of the
    /// original's positional shortlex cost, even if not shortlex-improving.
    ///
    /// Tries exact decode first. Uses slack only when the exact check
    /// fails, the result preserves the failure property, and the cost
    /// increase fits within the remaining budget.
    func decodeWithSlack<Output>(
        candidate: ChoiceSequence,
        gen: ReflectiveGenerator<Output>,
        fallbackTree: ChoiceTree,
        maximizeBoundRegionIndices: Set<Int>?,
        originalSequence: ChoiceSequence,
        property: (Output) -> Bool,
        slackTracker: inout RedistributionSlackTracker
    ) -> ShrinkResult<Output>? {
        let seed = ZobristHash.hash(of: candidate)
        switch ReductionMaterializer.materialize(
            gen,
            prefix: candidate,
            mode: .guided(
                seed: seed,
                fallbackTree: fallbackTree,
                maximizeBoundRegionIndices: maximizeBoundRegionIndices
            )
        ) {
        case let .success(output, freshTree):
            let freshSequence = ChoiceSequence(freshTree)
            guard property(output) == false else { return nil }

            // Exact path: shortlex-improving. No slack consumed.
            if freshSequence.shortLexPrecedes(originalSequence) {
                return ShrinkResult(
                    sequence: freshSequence,
                    tree: freshTree,
                    output: output,
                    evaluations: 1
                )
            }

            // Slack path: not shortlex-improving, but within budget.
            guard slackTracker.hasRemainingSlack else { return nil }

            let originalCost = originalSequence.positionalShortlexCost
            let freshCost = freshSequence.positionalShortlexCost

            // freshCost <= originalCost means cost-improving even if
            // not shortlex-improving (possible due to metric mismatch).
            // Accept without consuming slack.
            if freshCost <= originalCost {
                return ShrinkResult(
                    sequence: freshSequence,
                    tree: freshTree,
                    output: output,
                    evaluations: 1
                )
            }

            let costIncrease = freshCost - originalCost
            guard costIncrease <= slackTracker.remainingSlack else {
                return nil
            }

            slackTracker.recordSlack(costIncrease)
            return ShrinkResult(
                sequence: freshSequence,
                tree: freshTree,
                output: output,
                evaluations: 1
            )

        case .rejected, .failed:
            return nil
        }
    }
}
```

### 4. Integration Points

The slack tracker lives on `ReductionState` and interacts with the V-cycle at three
points.

**Point A: State initialization**

```swift
// In ReductionState:
var slackTracker: RedistributionSlackTracker

// In init:
self.slackTracker = RedistributionSlackTracker(
    slackBudget: config.redistributionSlackBudget
)
```

New field on `BonsaiReducerConfiguration`:

```swift
/// Maximum positional-shortlex-cost increase allowed across all
/// redistribution steps before redistribution pauses and waits for
/// exact legs to pay back the debt. Set to 0 for exact-only behavior.
let redistributionSlackBudget: Double
```

**Point B: Exact legs pay back slack**

In `accept()`, when called from non-redistribution legs:

```swift
func accept(
    _ result: ShrinkResult<Output>,
    structureChanged: Bool,
    isRedistribution: Bool = false
) {
    let costBefore = sequence.positionalShortlexCost

    // ... existing accept logic (update sequence, tree, output, etc.) ...

    let costAfter = sequence.positionalShortlexCost

    if isRedistribution == false, costAfter < costBefore {
        slackTracker.recordExactImprovement(costBefore - costAfter)
    }
}
```

**Point C: bestSequence guard**

With slack, the working `sequence` can be shortlex-worse than `bestSequence`. The
unconditional `bestSequence = sequence` update for bind cases must become conditional:

```swift
// In accept():
if sequence.shortLexPrecedes(bestSequence) {
    bestSequence = sequence
    bestOutput = output
}
// Remove the hasBind special case that unconditionally updates.
```

This is a latent correctness concern even without slack: the bind-case unconditional
update is safe today only because the decoder enforces exact improvement. With slack,
it would silently corrupt `bestSequence`. Without slack, if the decoder's shortlex
check were ever relaxed for other reasons, it would break.

**Point D: Cycle boundary**

In the V-cycle main loop, when bestSequence genuinely improved:

```swift
if state.bestSequence.shortLexPrecedes(cycleStartBest) {
    state.slackTracker.reset()
}
```

### 5. Redistribution Leg Changes

The redistribution leg calls `decodeWithSlack` instead of `decode` for encoders that
benefit from slack. The bind-aware redistribution path is the primary candidate:

```swift
// In runRedistributionLeg():
while let probe = bindAwareRedistributeEncoder.nextProbe(
    lastAccepted: lastAccepted
) {
    guard legBudget.isExhausted == false else { break }
    if let result = bindRedistDecoder.decodeWithSlack(
        candidate: probe,
        gen: gen,
        fallbackTree: fallbackTree ?? tree,
        maximizeBoundRegionIndices: Set([sinkRegionIndex]),
        originalSequence: sequence,
        property: property,
        slackTracker: &slackTracker
    ) {
        legBudget.recordMaterialization(accepted: true)
        accept(result, structureChanged: true, isRedistribution: true)
        lastAccepted = true
        redistributionAccepted = true
    } else {
        legBudget.recordMaterialization(accepted: false)
        lastAccepted = false
    }
}
```

Cross-stage redistribution is a secondary candidate. Tandem reduction probably should
remain exact-only since it already achieves good results within shortlex.

## Composition Law in Practice

Three redistribution steps within one cycle, then an exact train step:

| Step  | Type  | Grade (1, beta) | Accumulated beta |
|-------|-------|-----------------|------------------|
| R1    | Slack | (1, 12.0)       | 12.0             |
| R2    | Slack | (1, 5.0)        | 17.0             |
| R3    | Exact | (1, 0)          | 17.0             |
| Train | Exact, cost decrease 20.0 | (1, 0) | 0.0 |

The train step "paid back" 17.0 units of slack with 3.0 to spare. The Grade monoid's
composition law says the pipeline R1 . R2 . R3 . Train has overall grade (1, 0) --
the pipeline is exact.

If Train only decreased cost by 10.0:
- Accumulated beta = 17.0 - 10.0 = 7.0
- Next cycle starts with 7.0 units of debt
- Redistribution has `remainingSlack = budget - 7.0`
- If budget is 20.0, redistribution can still use 13.0 more before pausing

## What This Changes

1. **Enables "over the hill" redistribution**: The reducer can accept redistributions
   where early entries increase if later entries decrease sufficiently, even when the
   net shortlex effect is temporarily negative.

2. **Self-limiting**: The slack budget prevents unbounded quality degradation. When
   slack is exhausted, redistribution reverts to exact-only until exact legs pay it
   back.

3. **Monotonic guarantee on final output**: Because `bestSequence` is updated only on
   genuine shortlex improvement, the final result is always at least as good as the
   best exact result. Slack-elevated states are transient working states, never
   returned to the user.

4. **Backwards compatible**: Setting `redistributionSlackBudget = 0` recovers the
   current exact-only behavior.

## Open Questions

- **Per-cycle vs per-run slack**: Per-cycle (reset each V-cycle) is safer but limits
  exploration. Per-run (cumulative with payback) allows deeper exploration but risks
  divergence. The sketch above uses per-run with payback and per-cycle reset on
  genuine improvement.

- **Should the budget scale with sequence length?** A fixed budget means different
  things for 5-entry vs 500-entry sequences. A relative budget (e.g. 10% of initial
  `positionalShortlexCost`) might be more robust.

- **Metric choice**: `positionalShortlexCost` (weighted key sum) is a heuristic. It
  doesn't perfectly embed the shortlex ordering. Cases where the metric says
  "improved" but shortlex says "worse" (or vice versa) could cause surprising
  behavior. Worth investigating whether a lexicographic cost (first differing entry
  dominates) would be more faithful, at the expense of making the additive monoid
  structure less clean.

- **DominanceLattice interaction**: Slack-accepting steps might invalidate 2-cell
  dominance assumptions. If `zeroValue` succeeds on a slack-elevated sequence, it
  does not mean it would have succeeded on the exact-best sequence. The lattice might
  need a slack-aware invalidation rule (invalidate on any slack-using step).

- **Encoder awareness**: Should encoders know about the slack budget? Currently the
  design is transparent -- encoders produce candidates as before, and the decoder
  decides whether to use slack. An alternative is to let encoders produce
  intentionally non-shortlex-improving candidates when slack is available (e.g.
  CrossStageRedistribute could try "rightward" redistributions that increase early
  entries). This would require extending the `AdaptiveEncoder` protocol.
