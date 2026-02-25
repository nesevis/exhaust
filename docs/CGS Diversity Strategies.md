# CGS Diversity Strategies

Approaches for improving output diversity of eager Choice Gradient Sampling.

## Problem

`GeneratorTuning.tune` pre-computes pick weights as success counts in a
single top-down pass. For recursive generators like BSTs (~31 pick sites),
depth-2+ branches often receive **weight 0** because composed predicates have
near-zero success rates during sampling. This causes diversity collapse: high
throughput and validity rate, but almost all outputs are height-1 trees.

The online CGS (`OnlineCGSInterpreter`) avoids this by computing
gradients at every pick during generation, but the multiplicative sampling
overhead at each recursion level makes it orders of magnitude slower.

## Implemented

### 1. Weight Smoothing + Temperature

`GeneratorTuning.smooth(_:epsilon:temperature:)`

Post-processing pass that walks the tuned generator tree and transforms every
pick's weights:

```
smoothed_i = (Double(w_i) + epsilon) ^ (1 / T)
scaled_i   = max(1, round(smoothed_i / sum * 10000))
```

- **Epsilon (Laplace smoothing)**: Prevents dead branches. epsilon > 0 ensures
  every branch gets non-zero weight.
- **Temperature T**: T > 1 flattens toward uniform (exploration). T < 1 sharpens
  toward argmax (exploitation). T = 1 preserves original ratios with epsilon offset.

**Results** (2000 maxRuns, BST generator):

| Metric          | Eager CGS | Smoothed (epsilon=1, T=2) |
|-----------------|-----------|---------------------------|
| Unique valid    | 23        | 71                        |
| Max height      | 3         | 4                         |
| Unique at h2    | 12        | 47                        |
| Unique at h3    | 1         | 13                        |

Cheap to apply, no re-tuning needed. Good baseline to layer other strategies on.

## Candidates for Exploration

### 2. Multi-Seed Ensemble

Run `tune` N times with different random seeds. Each discovers slightly
different weight configurations because sampling is stochastic. Round-robin (or
randomly select) between the resulting generators during generation.

- Dead simple, no algorithmic changes needed.
- Each tuning pass may find a different "mode" of the valid space.
- Linear cost in tuning time (N tune calls), but generation cost is unchanged.
- Composes well with smoothing: smooth each ensemble member independently.

**Open questions**: How many seeds are needed? Is random selection or
round-robin better? Does smoothing subsume this?

### 3. Stochastic Perturbation (Dirichlet Noise)

For each generated value, add Dirichlet noise to the pick weights before
selection (similar to AlphaZero's exploration noise). Each generation sees
slightly different weights, preventing mode collapse.

```
noisy_weight_i = (1 - alpha) * weight_i + alpha * Dir(concentration)
```

- More principled than temperature; noise is per-generation, not static.
- Harder to tune: requires choosing alpha and Dirichlet concentration.
- Could be combined with smoothing as the base weights.

### 4. Stratified Tuning

Adapt with progressively specific predicates:

1. `isValidBST` (broad)
2. `isValidBST && height >= 2`
3. `isValidBST && height >= 3`

Each produces weights targeting a different stratum of the output space.
Interleave the generators during sampling.

- Very effective for the BST case specifically.
- Requires domain knowledge about which strata matter.
- Could be automated: tune once, profile the output distribution, then create
  strata predicates for under-represented regions.

### 5. Alpha-Blending with Uniform

Interpolate CGS weights with uniform weights:

```
final_weight_i = alpha * (1 / N) + (1 - alpha) * cgs_weight_i
```

- Simple single-parameter control.
- alpha = 0 gives pure CGS (high validity, low diversity).
- alpha = 1 gives uniform (high diversity, low validity).
- Could sweep alpha or anneal it over the run.
- Simpler than Dirichlet noise but less adaptive.

### 6. Temperature Cycling

Rather than a fixed temperature, cycle T periodically:

```
T(step) = T_base + amplitude * sin(2 * pi * step / period)
```

Repeatedly alternates between exploration (high T) and exploitation (low T).
Prevents settling into a single mode.

- Composes directly with the existing `smooth` function — just vary T per batch.
- No additional tuning cost.
- Tuning: period length, amplitude, base temperature.

### 7. Duplicate Tracking with Dynamic Adjustment

Track generated outputs in a set. When duplicates emerge, increase temperature
(or epsilon). When novel outputs appear, decrease toward baseline.

```
if output in seen:
    T += delta
else:
    T = max(T_base, T - delta)
```

- Adaptive: responds to actual diversity, not just predicted.
- Requires mutable state during generation (a wrapper iterator).
- Could be implemented as a custom iterator wrapping `ValueInterpreter`.

### 8. Mixed-Strategy Generation

Alternate between CGS-tuned and uniform/unweighted generators:

- Even steps: use tuned generator (high validity rate).
- Odd steps: use original generator (high diversity, lower validity).

Simple interleaving recovers diversity without any weight manipulation. The
unweighted generator naturally explores branches that CGS suppressed.

- No tuning parameters beyond the mix ratio.
- Validity rate is the average of both strategies.
- Could use the smoothed generator as the "tuned" side for best of both.

### 9. Periodic Re-Tuning

Re-run `tune` from a fresh seed after every K generations. Each tuning
round samples differently, discovering new weight configurations over time.

- More expensive than ensemble (tunes repeatedly, not upfront).
- But tunes to the current state of exploration.
- Could be combined with modified predicates (see Stratified Tuning).

### 10. Epoch-Based Re-Weighting

Generate a batch with current weights, analyse the output distribution, then
re-tune with a modified predicate that penalises over-represented regions:

```
modified_predicate(x) = base_predicate(x) && !is_over_represented(x)
```

- Closed-loop: uses actual output distribution to guide re-tuning.
- Expensive: requires periodic re-tuning.
- Most complex to implement but potentially most effective for sustained runs.

## Composability Notes

Many of these strategies compose:

- **Smoothing** is a good base layer for everything else.
- **Temperature cycling** and **duplicate tracking** can wrap any smoothed generator.
- **Ensemble** and **mixed-strategy** are orthogonal to per-weight transformations.
- **Stratified tuning** and **epoch-based re-weighting** are the most
  heavyweight but can use smoothing internally.

A reasonable progression for experimentation:

1. Smoothing (done) — fixes the zero-weight problem.
2. Temperature cycling — adds dynamic exploration at near-zero cost.
3. Duplicate tracking — makes exploration adaptive to actual output.
4. Multi-seed ensemble — if single-tune coverage is still insufficient.
