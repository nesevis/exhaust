# Principled Algebra of Test Case Reduction

A next-generation reducer architecture for Exhaust, grounded in the categorical
semantics of optimization reductions (Sepulveda-Jimenez, 2026) and the
bind-aware shrinking framework (Kolbu, 2026). This design replaces the
BonsaiReducer's interleaved V-cycle with a strict four-phase pipeline that
capitalizes on the reified ReflectiveGenerator's inspectable AST.

## Motivation

The current BonsaiReducer uses a V-cycle with interleaved structural and value
minimization legs. The key waste: Train (depth-0 value minimization) runs BEFORE
Prune (structural deletion), spending probes minimizing values inside containers
that will later be deleted entirely. The V-cycle also reduces bind-inner values
sequentially and greedily, missing combinations that only work jointly.

This document designs a principled replacement that:

1. Enforces strict structural-before-value phase separation
2. Exploits Kleisli composition over a product space of bind-inner values
3. Models structural visibility tiers grounded in the ChoiceTree
4. Uses the DependencyDAG from the reified AST for topological ordering

---

## 1. The Algebra

### Objects

The decision set is `ChoiceSequence` (`ContiguousArray<ChoiceSequenceValue>`).
The cost function is shortlex ordering: shorter sequences are cheaper; ties
broken lexicographically. Infeasible points (property passes) have cost
+infinity. This maps directly to the costed set `P = (X, c_P)` from
Sepulveda-Jimenez Definition 2.1.

### Morphisms

A reduction morphism is a triple `(encode, decode, classification)`:

- `encode: ChoiceSequence -> [ChoiceSequence]` proposes candidate mutations
- `decode: ChoiceSequence -> ShrinkResult?` materializes and validates
- `classification` determines which phase the morphism belongs to

Morphisms are classified by what they preserve:

- **Structure-preserving** (iso): Same ChoiceTree shape, different values. Exact
  decoder suffices. Corresponds to an exact reduction (Definition 3.1).
- **Structure-reducing** (epi): Fewer nodes. Guided decoder with fallback.
  Corresponds to an approximate reduction (Definition 8.3) with slack from
  bound re-derivation.
- **Structure-speculative** (partial): May temporarily grow. Skip shortlex check.
  Corresponds to a relax-round pattern (Section 11.2).

### Composition

**Within a phase**: two modes depending on structural information.

For phases operating on independent positions (Phase 3, Phase 2b): greedy
Set-based resolution (first-accepted candidate per encoder, then next encoder).
This is OptRed_ex (Section 3).

For Phase 2c (structural bind-inner reduction): Kleisli composition in Kl(P)
with angelic choice alpha = inf (Section 7, Definition 7.7). Per-coordinate
binary search steps compose as Kleisli arrows to produce a product space of
joint candidates. Approximate slack from bound re-derivation tracked via
Aff>=0 (Section 8, Proposition 8.9).

**Between phases**: sequential. Phase k runs only after Phase k-1 reaches
fixpoint. The composite pipeline is a graded T-reduction (Section 10,
Definition 10.3) with grade `g = (gamma, w)` tracking both approximation slack
and resource usage (property evaluations).

### Monotonicity

Every non-speculative morphism must satisfy:

    forall c in encode(s): shortlex(c) <= shortlex(s)

The decoder enforces this via shortlex comparison (guided mode) or range
rejection (exact mode).

### Convergence

Each phase targets a finite, strictly decreasing measure:

- Phase 1: number of non-minimal subtrees (finite)
- Phase 2: structural complexity (number of nodes, then structural values)
- Phase 3: shortlex within fixed structure
- Phase 4: bounded budget (hard cap)

An outer macro-cycle (Phases 1-3) converges because each iteration either
strictly reduces the sequence or stalls, and shortlex on finite sequences
over a finite alphabet is a well-order.

---

## 2. Structural Visibility Tiers

The degradation model is grounded entirely in what the reified ChoiceTree
reveals, not in user-provided backward functions (which are rarely supplied
in practice). The ChoiceTree ALWAYS tells us:

- Which entries are bind-inner vs bind-bound (`BindSpanIndex.BindRegion`)
- The inner subtree's `validRange` and shape
- The bound subtree's exact shape for the CURRENT inner value
- Whether the bind is data-dependent or structurally stable (getSize-bind)

What it CANNOT tell us: what the bound subtree would look like for a DIFFERENT
inner value. The strategy for handling this unknown determines the tier.

### Tier 1: Guided Replay (structure-preserving)

The ChoiceTree from the last successful materialization serves as a fallback.
When the inner value changes, the materializer replays bound entries from the
fallback tree, clamping to the new inner's implied ranges.

    SequenceDecoder.guided(fallbackTree: tree)

**When it works**: Incremental inner changes (for example, reducing N from 10
to 5). The bound structure is similar -- perhaps shorter or with shifted
ranges -- but recognizably related to the previous version. The fallback tree
provides a structurally coherent starting point that the materializer adapts.

**What the tree reveals**: The bound subtree's shape, the per-entry
validRanges, and the cursor suspension semantics (which entries to clamp vs
skip). All derived from the reified structure, not from user annotations.

### Tier 2: PRNG Re-generation (structure-discarding)

No fallback tree, or guided replay has stalled (the fallback produces the
same bound content repeatedly). The materializer generates entirely fresh
bound content from PRNG, constrained only by the generator's structure.

    SequenceDecoder.guided(fallbackTree: nil, usePRNGFallback: true)

**When it works**: Radical inner changes or when the bound structure depends
sensitively on the inner value. Already used by `BindRootSearchEncoder`.

**What the tree reveals**: Even without a fallback, the ChoiceTree's bind
markers tell us exactly WHERE the bound subtree starts and ends. The
materializer knows which positions to re-generate. The generator's reified
structure constrains what PRNG can produce.

### Tier 3: Transparent (no bind handling needed)

The bind's inner is a `.getSize` node -- structurally stable during reduction.
The flattener emits `.group` markers instead of `.bind` markers. Standard
group-based reduction suffices with no special handling.

### Escalation Strategy

Phase 2 starts with Tier 1 (guided replay). When Tier 1 stalls on a
structural position (no progress after N probes), escalate to Tier 2 (PRNG
re-generation) for that position. This escalation is per-position, not
global -- some bind-roots may respond to guided replay while others need
PRNG exploration.

Phase 3 (leaf values, structure frozen) uses Tier 1 exclusively. Since
structural positions are converged, the fallback tree is stable and guided
replay degenerates to near-exact materialization for leaf positions.

### Future Direction: Observational Learning

Over multiple materialization attempts with different inner values, the
reducer accumulates ChoiceTree snapshots that reveal how bound structure
correlates with inner value. A future extension could build a lightweight
model of this relationship -- not from user annotations, but from the
structural traces the reified generator produces. This is uniquely enabled
by having full ChoiceTree visibility on every materialization.

---

## 3. The Dependency DAG

The core new abstraction. Replaces bind-depth as the ordering proxy.

### Structural vs Leaf Positions

A position in the ChoiceSequence is **structural** if changing it can alter
the number or shape of downstream entries. Concretely:

| Position Type      | Structural? | Identified By                            | Notes                                          |
|--------------------|-------------|------------------------------------------|------------------------------------------------|
| Bind-inner values  | Yes         | `BindSpanIndex.BindRegion.innerRange`    | May be compound (group/tuple)                  |
| Branch selectors   | Yes         | `.branch(Branch)` entries                | Single entry per pick site                     |
| Sequence lengths   | N/A         | Implicit in element count                | Not separate entries; reduce by deleting elems |
| All other values   | No (leaf)   | Everything else                          | Safe to reduce with exact decoder              |

Key insight: `.sequence(length:, elements:, _)` stores length as metadata,
NOT as a separate entry in the flattened ChoiceSequence. Sequence length
reduction is purely structural deletion via `DeleteSequenceElementsEncoder`.
There is no "length value" to target.

### The DAG Structure

```
PositionClassification:
  .structural(.bindInner(regionIndex))   -- values controlling bound subtrees
  .structural(.branchSelector)           -- pick-site choices
  .leaf                                  -- values not controlling downstream structure

DependencyDAG:
  nodes: [DependencyNode]               -- one per structural position
    .positionRange: ClosedRange<Int>     -- range in ChoiceSequence
    .kind: PositionClassification
    .dependents: [Int]                   -- indices of downstream structural nodes
  topologicalOrder: [Int]               -- structural nodes, upstream first
  leafPositions: [ClosedRange<Int>]     -- all non-structural value positions
```

Extracted from ChoiceTree by walking it once alongside the ChoiceSequence.
Edges: bind-inner -> structural nodes within bound subtree, branch-selector
-> structural nodes within selected subtree. Topological sort via Kahn's
algorithm.

Recomputed on every structural change (same lifecycle as current
`BindSpanIndex`).

---

## 4. The Four Phases

### Phase 1: Structural Slicing

**Purpose**: Identify and collapse irrelevant subtrees in O(subtrees) probes.
This is the "mass pruning" / "dead code elimination" analogue from compiler
optimization.

**How it works** (generator-structural, no property instrumentation):

1. **Mass zero**: Replace ALL values with semantic simplest simultaneously.
   If the property still fails, everything is irrelevant -- done.
   (This is what ZeroValueEncoder phase-1 already does, but now as a
   dedicated first pass before any structural work.)

2. **Subtree probing**: For each top-level independent subtree (children of
   root group, bind regions, sequence elements), test whether zeroing that
   subtree alone preserves the failure. Use binary delta-debugging to find
   the minimal relevant subset.

3. **Permanent collapse**: Zero all irrelevant subtrees. These positions are
   marked `.reduced` in the ChoiceSequence (non-shrinkable).

**Encoder**: New `StructuralSlicingEncoder` (batch). Produces candidates with
individual subtrees zeroed. All-at-once probe first, then per-subtree.

**Decoder**: Guided with PRNG fallback (zeroing inner values changes bound
structure).

**Transition**: Single pass -- when no more subtrees can be collapsed.

### Phase 2: Structural Minimization

**Purpose**: Reduce all structure-controlling positions in topological order.
Only runs on positions classified as structural by the DependencyDAG.

**Sub-phases** (iterate to fixpoint within Phase 2):

#### 2a. Branch Simplification

- Promote branches to simpler alternatives (`PromoteBranchesEncoder`)
- Pivot branches to lower-weight choices (`PivotBranchesEncoder`)
- Decoder: guided, relaxed strictness, `materializePicks: true`

#### 2b. Structural Deletion (topological order, outermost first)

- Delete container spans (`DeleteContainerSpansEncoder`)
- Delete sequence elements (`DeleteSequenceElementsEncoder`)
- Delete sequence boundaries (`DeleteSequenceBoundariesEncoder`)
- Delete free-standing values (`DeleteFreeStandingValuesEncoder`)
- Aligned window deletion (`DeleteAlignedWindowsEncoder`)
- Speculative deletion (`SpeculativeDeleteEncoder`)
- Decoder: guided, relaxed strictness

#### 2c. Structural Value Reduction -- Kleisli Product Space

The centerpiece of the new architecture. Instead of sequential greedy
reduction of each bind-inner independently (operating in Set / OptRed_ex),
we move into the Kleisli category Kl(P) of the powerset monad (Section 7
of Sepulveda-Jimenez) and exploit the compositional guarantees.

**The problem with Set-based greedy (current approach)**:

- Reduce bind-inner-1, commit, reduce bind-inner-2, commit...
- Misses combinations: (inner_1=3, inner_2=7) may work when neither
  reduction succeeds independently
- Stale derivations: bound-1 is re-derived against inner_2's OLD value

**The Kleisli product space construction**:

Each outer bind-inner position i is a coordinate in a product space. Each
coordinate has a set of candidate values V_i from a binary search ladder
(midpoints between current value and semantic simplest):

```
V_i = binarySearchLadder(current_i, range_i, maxSteps: 8)
    = {current, mid(current, 0), mid(0, mid), ...}
    |V_i| = O(log(range_i))
```

Each per-coordinate step is a Kleisli arrow `r_i: X -> P(X)` that maps the
current sequence to the set of candidates where position i takes each value
in V_i. The Kleisli composition `r_k . ... . r_1` naturally produces the
Cartesian product -- all combinations of binary search values across all axes.

**Why the composition laws hold** (Proposition 7.8 + 8.9):

- **Encoding inequality (4)**: `enc_a^dag(c_Q) <= c_P` holds because the
  current value is always in the candidate set, so `inf <= current`.

- **Decoding inequality (5)**: holds approximately. Materializing a candidate
  with changed inner values introduces slack from bound re-derivation. This
  is a T-approximate reduction (Definition 8.3) with slack `gamma_i = (1,
  delta_i)` where delta_i bounds the shortlex growth from bound content
  change on axis i.

- **T-algebra affine-homomorphism** (Definition 8.6): holds for (P, inf) --
  inf distributes over monotone affine maps.

- **Composite slack** (Proposition 8.9): `gamma = (x)_i gamma_i = (1, sum
  delta_i)` -- additive slack accumulates predictably across coordinates.

- **Safety net**: the final acceptance check (`shortlex(materialized) <=
  shortlex(original)` AND `property fails`) is independent of the framework.
  The Kleisli structure organizes the search; acceptance is hard-gated.

**Traversal strategy** (switched by k = number of outer bind-inners):

For k <= 3: **Full enumeration**. With ~8 binary search steps per axis, the
product space has 8 to 512 candidates. Each requires one property evaluation.
This is well within typical budgets and gives the full angelic-choice guarantee
(alpha = inf picks the shortlex-minimal success).

For k > 3: **Adaptive coordinate descent**. Halve ALL coordinates
simultaneously (one evaluation). If accepted, recurse on the halved space. If
rejected, delta-debug which subset of coordinates can be halved -- O(k . log k)
evaluations to identify the maximal halvable subset. Then recurse.
Cost: O(k . log(range) . log(k)).

**What this replaces**:

- `BindRootSearchEncoder` (sequential halving, Tier 2 only)
- `BinarySearchToZeroEncoder` on structural spans (sequential, per-axis)
- `BindAwareRedistributeEncoder` (pairwise redistribution)

All three are subsumed by the product space search, which tests combinations
they cannot reach.

**New encoder**: `ProductSpaceEncoder` (BatchEncoder for k <= 3, AdaptiveEncoder
for k > 3).

**Decoder**: Tier 1 (guided with fallback tree) as default. On stall, escalate
to Tier 2 (PRNG re-generation) for the entire product space. All inner values
are set simultaneously, so all bound content is re-derived against the correct
combination -- no stale derivations.

**Non-bind structural values** (branch selectors at depth 0): Reduced with
existing encoders (`ZeroValueEncoder`, `BinarySearchToZeroEncoder`) targeting
structural spans only. These are not part of the product space (discrete
choices, not continuous ranges).

**Inner iteration**: 2a -> 2b -> 2c -> if 2c made progress, back to 2b. This
allows product space reduction (2c) to enable further deletions (2b) without
breaking the structural/value separation.

**Transition**: When a full 2a -> 2b -> 2c pass makes no progress.

### Phase 3: Value Minimization

**Purpose**: Reduce all leaf values within frozen structure. Structure is
settled -- exact decoder suffices.

**No depth ordering needed**: Since all structural positions are converged,
bind-inners will not change, so bound-subtree leaves are stable. Process all
leaves in a single flat pass.

**Encoders** (targeting leaf positions only):

- `ZeroValueEncoder`
- `BinarySearchToZeroEncoder`
- `BinarySearchToTargetEncoder`
- `ReduceFloatEncoder`
- `TandemReductionEncoder` (sibling leaf pairs)
- `CrossStageRedistributeEncoder` (leaf pairs only)

**Decoder**: Exact for generators without binds. Tier 1 (guided replay) for
leaves inside bind-bound subtrees -- the structure is frozen, so the fallback
tree is stable and guided mode degenerates to near-exact materialization.

**Transition**: When all leaf encoders stall (no progress in a full pass).

### Phase 4: Speculative Exploration

**Purpose**: Bounded speculation when Phases 1-3 have converged.

**Strategy**:

1. Checkpoint all state
2. Speculative redistribution (`RelaxRoundEncoder`) -- may increase cost
3. If accepted: exploit via Phases 2-3 on the relaxed state
4. Accept if final result shortlex-precedes checkpoint
5. Rollback otherwise

**Budget**: Hard cap. If exploration produces no improvement, macro-cycle
terminates.

---

## 5. The Macro-Cycle

```
repeat {
    Phase 1: Structural Slicing
    Phase 2: Structural Minimization (2a -> 2b -> 2c, inner fixpoint)
    Phase 3: Value Minimization (flat pass)
    madeProgress = any phase accepted a candidate
} until madeProgress == false

Phase 4: Speculative Exploration
if Phase 4 succeeded: restart macro-cycle
```

Phase 2 may enable new slicing (Phase 1) in the next iteration: deleting
elements may make remaining elements' values irrelevant. The macro-cycle
handles this naturally.

---

## 6. Encoder-to-Phase Mapping

| Encoder                        | Current Leg    | New Phase                              | Change                             |
|--------------------------------|----------------|----------------------------------------|------------------------------------|
| `PromoteBranchesEncoder`       | Branch         | 2a                                     | Unchanged                          |
| `PivotBranchesEncoder`         | Branch         | 2a                                     | Unchanged                          |
| `DeleteContainerSpansEncoder`  | Prune          | 2b                                     | Now runs BEFORE value min          |
| `DeleteSequenceElementsEncoder`| Prune          | 2b                                     | Now runs BEFORE value min          |
| `DeleteSequenceBoundariesEncoder`| Prune        | 2b                                     | Unchanged                          |
| `DeleteFreeStandingValuesEncoder`| Prune        | 2b                                     | Unchanged                          |
| `DeleteAlignedWindowsEncoder`  | Prune          | 2b                                     | Unchanged                          |
| `SpeculativeDeleteEncoder`     | Prune          | 2b                                     | Unchanged                          |
| `BindRootSearchEncoder`        | Train          | Subsumed by `ProductSpaceEncoder`      | Joint search replaces sequential   |
| `ZeroValueEncoder`             | Train/Snip     | 2c (non-bind structural) + 3           | Split by target classification     |
| `BinarySearchToZeroEncoder`    | Train/Snip     | 2c (non-bind structural) + 3           | Split by target classification     |
| `BinarySearchToTargetEncoder`  | Train/Snip     | 3                                      | Leaf only                          |
| `ReduceFloatEncoder`           | Train/Snip     | 3                                      | Leaf only                          |
| `BindAwareRedistributeEncoder` | Redistribution | Subsumed by `ProductSpaceEncoder`      | Product space finds combos         |
| `ProductSpaceEncoder` (NEW)    | --             | 2c                                     | Kleisli product over outer binds   |
| `TandemReductionEncoder`       | Redistribution | 3                                      | Leaf redistribution                |
| `CrossStageRedistributeEncoder`| Redistribution | 3/4                                    | Depends on targets                 |
| `RelaxRoundEncoder`            | Exploration    | 4                                      | Unchanged                          |
| `StructuralSlicingEncoder` (NEW)| --            | 1                                      | New                                |

---

## 7. What This Exploits That Others Cannot

The reified ReflectiveGenerator gives Exhaust capabilities no other PBT
framework has:

1. **Visible structure**: The ChoiceTree reveals bind boundaries, sequence
   structure, and branch alternatives. This enables the DependencyDAG and
   structural/leaf distinction -- impossible with Hypothesis's flat byte stream.

2. **Explicit dependencies**: Bind edges (inner -> bound) are first-class in
   the tree. We can topologically sort structural positions and reduce in
   dependency order -- impossible with QuickCheck's output-domain shrinking.

3. **Structural visibility tiers**: The ChoiceTree always reveals bind
   boundaries, inner ranges, and current bound structure. Guided replay
   preserves bound structure on incremental changes; PRNG re-generation
   handles radical changes. The escalation between tiers is informed by
   the tree -- the reducer observes whether guided replay stalls and
   escalates per-position, not globally.

4. **Kleisli product space over bind-inners**: Because the ChoiceTree reveals
   exactly which positions are bind-inners and their valid ranges, we can
   construct a discretized product space and search it jointly. The Kleisli
   composition laws (Proposition 7.8, 8.9) guarantee cost and slack bounds
   propagate. No other PBT framework can do joint bind-inner minimization --
   they either cannot see binds (Hypothesis) or cannot access the entropy
   stream (QuickCheck).

The phased architecture turns these capabilities into a systematic algorithm:
structure visible -> dependencies extracted -> topological order computed ->
structural positions reduced jointly (Kleisli product space) -> leaf positions
reduced in stable context.
