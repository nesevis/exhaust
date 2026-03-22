# Principled Bind-Aware Test Case Reduction for Exhaust

A next-generation reducer architecture grounded in the fibred structure of
execution traces, forward-only replay, and joint structural search. This
design replaces the BonsaiReducer's interleaved V-cycle with a three-phase
pipeline whose phase ordering is forced by mathematical structure, not chosen
as a heuristic.

## Motivation

The current BonsaiReducer uses a V-cycle with five interleaved legs: branch
promotion, covariant value minimization (depth 1 to max), structural
deletion (depth 0 to max), covariant value minimization (depth 0), and
redistribution. Two problems:

1. **Wasted probes on doomed values.** The snip sweep runs
   before structural deletion (prune), spending property evaluations
   minimizing values inside containers that will later be deleted entirely.
   Value work within a fibre that will be abandoned is pure waste.

2. **Sequential greedy bind-inner reduction.** The covariant sweep reduces
   each bind-inner independently: reduce inner-1, commit, reduce inner-2,
   commit. This misses combinations -- `(inner_1=3, inner_2=7)` may
   preserve the failure when neither reduction succeeds independently. Bound
   content derived against inner-2's old value becomes stale.

This document designs a principled replacement that:

1. Separates structural independence isolation (graph analysis, one
   verification probe) from structural and value minimization (property
   evaluation required)
2. Enforces structural-before-value phase ordering, justified by a
   dominance theorem over the fibred trace space
3. Searches bind-inner values jointly over a product space rather than
   sequentially
4. Uses a single replay-with-projection primitive as the universal
   mechanism for all phases

---

## 1. The Bind-Aware Shrinking Problem

In property-based testing, when a randomly generated input falsifies a
property, the framework invokes a shrinking phase to reduce the
counterexample to a minimal failing case. Classical shrinking operates in the
output domain: the generator produces a concrete value, and the shrinker
applies type-specific mutations (removing list elements, decrementing
integers) to simplify it.

This approach fails in the presence of monadic bind (flatMap), where an
upstream generator's output parametrises the structure of a downstream
generator. Consider:

```swift
Gen.int(in: 0...100).flatMap { n in
    Gen.array(
        length: max(2, n + 1),
        element: Gen.int(in: 0...n)
    )
}
```

Here `n` defines everything about the downstream generator: the array length,
the domain of every element, and the number of choice points in the trace. An
output-domain shrinker that reduces individual array elements cannot reduce
`n` itself, because the relationship between `n` and the array structure is
encapsulated in an opaque closure. The shrinker is bind-unaware.

### 1.1 Reification and the Execution Trace

Solving this requires that the generator be reified into an inspectable
abstract syntax tree (AST) and that the framework record an execution trace
capturing every random choice, its domain, and its dependency relationships.
In Swift, the `@Sendable` closure attribute enforces functional purity,
guaranteeing that the reified AST is a strict directed acyclic graph of data
dependencies with no hidden mutable state.

The execution trace records, for each choice point: which stage of the
generator produced it, what value was chosen, what domain it was drawn from,
and whether its existence or domain was determined by an upstream bind point.
These are observable facts about a concrete execution, not algebraic
properties of the continuation functions.

### 1.2 Why Not Backward Execution?

Some frameworks propose running generators backwards: given a desired output,
recover the entropy that would have produced it. This requires continuations
to be injective arrows with deterministic left inverses. In practice,
user-written continuations are arbitrary `@Sendable` closures that are rarely
invertible. In the example above, given a shrunk array `[1, 0, 3]`, the value
of `n` cannot be uniquely recovered: it could be 3, 4, 50, or any value that
admits those elements.

The framework presented here is entirely forward-only. User continuations are
called, never inverted. The trace records what happened; replay tests what
would happen under different choices. This is all that is needed.

---

## 2. Data Model

The data model captures the distinction between the shape of an execution
(the skeleton) and the values chosen within that shape (the flesh).

### Core Types

**ChoiceSequence** (`ContiguousArray<ChoiceSequenceValue>`): The flattened
representation of an execution trace. Contains structural markers (`.group`,
`.sequence`, `.bind`, `.branch`) interleaved with value entries (`.value`,
`.reduced`). This is the decision set that the reducer operates on.

**ChoiceTree**: The hierarchical tree preserving structural information. Leaf
nodes (`.choice`, `.just`, `.getSize`), container nodes (`.sequence`,
`.group`, `.bind`, `.resize`), and control flow nodes (`.branch`,
`.selected`). The tree reveals bind boundaries, sequence structure, branch
alternatives, and per-entry valid ranges.

**SkeletonPoint**: A single choice point's structural metadata.

```
SkeletonPoint
  domain       : ChoiceDomain    -- finite, ordered set of values
  isBindPoint  : Bool            -- does this value parametrise
                                    downstream structure?
```

**Skeleton**: The shape of an execution, independent of the specific values
chosen.

```
Skeleton
  points : [SkeletonPoint]
  size   : (width: Int, bindDepthSum: Int, domainSum: Int)
           -- lexicographic ordering
```

**Trace**: A complete execution record.

```
Trace
  skeleton : Skeleton
  values   : [Choice]  -- one per point, each in its domain
```

### The Kleisli Chain

The reified generator is modelled as a Kleisli chain: a sequence of stages
where each stage is either independent (produced by map or zip) or dependent
(produced by flatMap/bind). This is a conceptual model for reasoning about
the algorithm; the implementation uses the existing `ReflectiveGenerator`
(FreerMonad) and interpreter infrastructure. The chain exposes the following
operations (implemented via existing interpreters and the ChoiceTree):

```
KleisliChain
  evaluate(Trace) -> Value
    Forward-evaluate the full chain to produce a value.

  bindPointIndices -> [Int]
    Indices of choice points that are bind points.

  replayFrom(stageIndex, Trace) -> Trace
    Re-evaluate from a given stage forward, calling
    continuations with the values in the trace to
    discover the new skeleton and project old values.

  skeletonFor(bindValues) -> Skeleton
    Run the chain with given bind-point values,
    recording only structure (domains and widths),
    without committing non-bind values.

  independentPositions(Trace) -> Set<Int>
    Compute structurally independent positions
    from the trace's dependency graph.
```

---

## 3. Formal Foundations

### 3.1 The Fibration of Trace Space

The space of all traces T projects onto the space of all skeletons via a map
that extracts the skeleton from a trace. The fibre over a particular skeleton
is the set of all traces with that skeleton -- concretely, the Cartesian
product of the domains at each choice point:

    F(s) = domain(s.points[0]) x domain(s.points[1]) x ... x domain(s.points[n-1])

A skeleton is fully determined by the values at bind points. Non-bind values
can vary freely without changing the skeleton. This gives the projection a
fibre structure: the total trace space is partitioned into fibres indexed by
skeletons, and the skeleton of a trace depends only on its bind-point values.

### 3.2 Skeleton Size Order

Skeletons are ordered by a total preorder that captures "structural
simplicity". The ordering is lexicographic over three components:

    s1 < s2 iff (s1.width, s1.bindDepthSum, s1.domainSum)
                <lex (s2.width, s2.bindDepthSum, s2.domainSum)

The three components, in priority order:

1. **Width** (total number of choice points). Fewer points is always simpler.
2. **Bind depth sum** (sum of bind nesting depths across all points). At
   equal width, a flatter skeleton is simpler. Deeper nesting implies more
   dependency edges, more fragility under projection, and more work per
   structural shrink in future cycles. This distinguishes skeletons that
   width and domain sum alone cannot: two skeletons with the same number of
   points and the same total domain but different nesting structures are not
   equally easy to reduce further.
3. **Domain sum** (sum of domain cardinalities). At equal width and depth,
   tighter domains are preferred.

### 3.3 The Shortlex Order on Traces

The cost function on traces is shortlex ordering: shorter choice sequences
are cheaper; ties broken lexicographically. Infeasible traces (where the
property passes) have cost +infinity.

This gives us a costed set `P = (T, c)` where `T` is the set of all traces
and `c: T -> R_bar` is the shortlex cost with +infinity for passing traces.
A reduction morphism transforms one trace into another with lower or equal
cost while preserving the property failure.

**Relationship to skeleton size order.** Shortlex on the ChoiceSequence
(the flattened representation) refines the skeleton size order on the
Skeleton (the structural summary). If skeleton A is strictly smaller than
skeleton B by width, then any trace through A is literally shorter than any
trace through B, hence shortlex-smaller. Within the same skeleton (same
width), shortlex compares values lexicographically. So the shortlex order
on traces *is* the lexicographic product of skeleton size and value ordering,
expressed on the flattened representation rather than the decomposed one.
This means the monotonicity gate in Section 6 (`shortlex(materialized) <=
shortlex(original)`) and the convergence measure (skeleton.size, values)
are the same thing viewed at different levels of abstraction.

### 3.4 Phase Ordering Theorem (Structural Dominance)

**Theorem.** Let `t*` be a local minimum found by interleaving structural and
value shrinks arbitrarily. Let `t'` be a local minimum found by exhausting
structural shrinks first, then value shrinks. Then
`skeleton(t').size <= skeleton(t*).size`.

**Proof sketch.** Value shrinks, by definition, do not change the skeleton.
Therefore value shrinks cannot create new structural reduction opportunities:
the set of structurally feasible skeletons (those for which at least one
flesh assignment fails the property) is determined entirely by the generator
structure and the property, not by the current non-bind values. Structural
shrinks may invalidate prior value work (by eliminating choice points or
changing domains). Therefore, doing value work before exhausting structural
work can only waste effort, never unlock new structural reductions. The
structure-first ordering reaches an equal or smaller skeleton.

**Important distinction: feasibility vs discoverability.** The theorem is
about which structural shrinks are *feasible* (there exist flesh values in
the smaller fibre that fail the property). It does not claim that the
algorithm will *discover* all feasible structural shrinks in a single pass.
The search for structural reductions depends on the REPLAY mechanism's
projection heuristic (Section 4), which constructs a single candidate trace
in the smaller fibre from the current trace's flesh values. This projection
is sensitive to the starting flesh: different flesh values produce different
projected traces, which may or may not preserve the property failure.

The cyclic composition (Section 9) exploits this sensitivity. Value shrinks
cannot change the skeleton and therefore cannot create new structural
reduction opportunities. However, they change the flesh that projection uses
as its starting point, allowing the search to discover structural reductions
that were previously missed. The structural shrink was always feasible; the
cycle makes the projection heuristic more likely to find it. This is a
distinction about the search procedure, not about the solution space.

This theorem establishes that the phase ordering -- structural before value
-- is not a heuristic. It is the unique ordering that cannot be improved upon
by any interleaving strategy, with respect to the achievable skeleton size.

### 3.5 Partial Evaluation of the Residual Chain

Once structural minimization converges and the skeleton is fixed, the Kleisli
chain specialises. Every continuation has been evaluated at its fixed
bind-point value; every domain is determined. This is partial evaluation in
the sense of Kleene's s-m-n theorem: the structural parameters have been
fixed, yielding a residual programme whose free variables are the non-bind
choice values.

Value minimization operates on this residual. The simplification is
*structural*: the problem has fixed dimensionality (number of choice points
cannot change), fixed domains (each value is drawn from a known finite set),
and generator-level independence (changing leaf A's value cannot change leaf
B's domain or existence). This makes the search space well-defined and
bounded.

The simplification is not *computational*: the property can couple any subset
of values arbitrarily. A property like `array[0] + array[3] == 7` makes
positions 0 and 3 tightly coupled even though they are generator-independent.
You cannot shrink either one without simultaneously adjusting the other. This
property-level coupling is invisible to the generator's dependency graph and
is why Phase 2 requires iterative coordinate descent (cycling through all
leaves repeatedly) rather than a single pass. The worst case for Phase 2 is
a property that requires a specific combination of values across many leaves
-- coordinate descent finds this only by exhaustive cycling, which can be
slow. Phase 1 has a clear structural signal (fewer choice points is
unambiguously progress). Phase 2 has no such signal: reducing a leaf value
might take you away from the failure, and you only discover this by testing.

### 3.6 Structural Independence via the Generator's Dependency Graph

The reified ChoiceTree records two kinds of dependency edges:

- **Data dependence**: bind-inner -> every position in the bound subtree
  (the inner value parametrises the bound generator's structure and domains)
- **Control dependence**: branch selector -> every position in the selected
  subtree (the selector determines which subtree exists)

These are structural facts about the generator, observable from the tree
without instrumenting the property. They form a directed dependency graph
over choice points.

A position `i` is **structurally independent** if it has no dependency path
(via bind or branch edges) to any other position -- that is, no other
position's existence, domain, or value is affected by `i`, and `i` is not
affected by any bind-inner or branch selector. Concretely, `i` is
structurally independent if it is a leaf value inside a top-level group
sibling that contains no bind or branch nodes connecting it to other
siblings.

**Theorem (Structural Independence).** For any structurally independent
choice point `i`, modifying `values[i]` cannot change any other choice
point's domain, existence, or value. The generated value changes only in the
component contributed by `i`; all other components are identical.

This is provable from the tree structure alone -- no property evaluation
needed. Whether the changed component affects the property outcome is a
separate question that the theorem cannot answer (the property is opaque).
Phase 0's defensive verification step (Section 7) bridges this gap
empirically: it zeroes all independent positions and confirms the property
still fails. The theorem guarantees the zeroing is safe with respect to
the generator; the verification confirms it is safe with respect to the
property.

**Important limitation.** The property is an opaque closure. The dependency
graph captures which choice points can influence *each other* through the
generator's structure, but cannot determine which parts of the generated
value the property actually inspects. A true dynamic backward slice (Weiser
1984) would trace from the property assertion backward through the program's
data and control flow to identify exactly which inputs matter. This is
impossible for an opaque `@Sendable` closure.

What the algorithm computes instead is a **structural over-approximation**:
every position reachable from a bind-inner or branch selector via dependency
edges is conservatively marked as potentially relevant. Positions with no
such path are structurally independent and can be safely zeroed. This is
sound (zeroing a structurally independent position cannot affect any other
position's domain or existence) but conservative (it may mark positions as
relevant when they are not, because the property might not inspect the
component they contribute to).

The defensive verification step (Section 7, Phase 0) guards against the
over-approximation being insufficient: if zeroing the off-graph positions
causes the property to pass (because the property had a dependency the
structural graph could not see -- for example, hashing the entire value),
the algorithm falls back to the unpruned trace.

---

## 4. The Replay Mechanism

All phases of the algorithm share a single primitive operation: forward
replay with value projection. When a bind-point value changes, the chain is
re-evaluated forward from the point of change, and old downstream values are
mapped onto the new skeleton.

This mechanism subsumes what other frameworks describe as cobind (comonadic
extension), comap (bidirectional focusing), backward lenses, Landauer
embeddings, or reverse-mode propagation. It requires no algebraic inversion
of continuations. It is simply: call the continuation with the new value,
observe the new generator and its skeleton from this bind point downward, and
attempt to reuse old choices.

### The REPLAY Operation

```
REPLAY(chain, trace, bindIndex, candidate) -> Trace

  1. Set trace.values[bindIndex] <- candidate

  2. CALL the continuation forward with candidate.
     Observe the new generator and its skeleton
     from this bind point downward.
     This is opaque: we cannot predict the result;
     we can only call and observe.

  3. For each downstream choice point j in the
     NEW skeleton:

     IF a positionally corresponding old point exists
       AND old value is in the new domain
       -> REUSE the old value
          (it comes from a known-failing trace, so
           it is the best available starting point
           for preserving the failure)

     ELSE IF old value can be clamped into new domain
       -> CLAMP the old value to the new domain's bounds
          (preserves more information from the known-failing
           trace than domain minimum; appropriate when old
           and new domains are commensurate — both integer
           ranges, same type, overlapping structure)

     ELSE
       -> USE the new domain's MINIMUM
          (the universally valid default; clamping is
           unsound when domains are incommensurate,
           for example old domain was 0...50 and new
           domain is an enum {red, green, blue})

     Points in the old skeleton with no correspondent
     in the new skeleton are ELIMINATED: zero cost,
     they simply cease to exist.

  4. Return the new trace (skeleton + projected values).
```

**Clamping vs domain minimum: the tradeoff.** The current
`ReductionMaterializer` uses clamping (clamp old value into new range) as the
default fallback. This preserves more information from the known-failing
trace: if the old value was 47 and the new domain is `0...10`, clamping
produces 10, which is closer to the old value than 0 and more likely to
preserve whatever property the old value contributed to.

Domain minimum is safer in pathological cases (incommensurate domains where
clamping is meaningless) but more aggressive (throws away more information).
The algorithm uses a two-tier fallback: clamp when domains are commensurate
(same underlying type, overlapping or containment relationship), domain
minimum when they are not. The `ChoiceTree` reveals domain types via
`ChoiceMetadata`, making the commensurability check possible without
heuristics.

### The Maximal Conservation Principle

Because the property is opaque, the algorithm has exactly one source of
information about what makes the property fail: the current known-failing
trace. Every candidate construction in every phase is a variant of the same
forced strategy:

> Keep as much of the known-failing configuration as possible, change one
> thing, and ask the oracle.

This is the **maximal conservation principle**. It is not a REPLAY-specific
heuristic -- it is the universal strategy forced by property opacity, applied
at three scales:

- **Structural projection (Phase 1, REPLAY).** When a bind-inner shrink
  changes the skeleton, construct a candidate trace for the new skeleton that
  reuses the maximum amount of information from the known-failing trace.
  This is projection across a structural change.
- **Product space search (Phase 1c).** Each candidate in the product space
  sets bind-inner values to new coordinates while deriving bound content via
  REPLAY -- keeping as much of the known-failing structure as the new inner
  values permit.
- **Pointwise value descent (Phase 2).** Try the smallest value at each
  leaf position, keeping all other positions at their current (known-failing)
  values. This is maximal conservation applied one position at a time.

The principle is honest about what it is: a heuristic for constructing
candidates in a search space that cannot be navigated by gradient or
structure. If a projected or reduced trace happens to pass the property, the
candidate is rejected -- even though a different configuration might fail.
This is a false negative in the search, not an error in the algorithm. The
algorithm remains sound (it never accepts a passing trace as a shrink) but is
not complete (it may miss valid reductions whose only witnesses require
configurations far from the known-failing trace).

### Escalation Tiers

Replay uses a three-tiered fallback strategy, determined by the ChoiceTree's
structural visibility. All three tiers implement the same REPLAY interface;
they differ only in how they resolve downstream values when old values cannot
be reused.

**Tier 1: Guided Replay (structure-preserving).** The ChoiceTree from the
last successful materialization serves as a fallback. When the inner value
changes, the materializer replays bound entries from the fallback tree,
clamping to the new inner's implied ranges.

When it works: Incremental inner changes (for example, reducing N from 10 to
5). The bound structure is similar -- perhaps shorter or with shifted ranges
-- but recognizably related to the previous version. The fallback tree
provides a structurally coherent starting point that the materializer adapts.

What the tree reveals: The bound subtree's shape, the per-entry validRanges,
and the cursor suspension semantics (which entries to clamp vs skip). All
derived from the reified structure, not from user annotations.

**Tier 2: PRNG Re-generation (structure-discarding).** Guided replay has stalled,
or there is no fallback tree. The materializer generates entirely fresh bound
content from PRNG, constrained only by the generator's structure.

When it works: Radical inner changes, or when the bound structure depends
sensitively on the inner value, or when the failure-preserving flesh values
are far from the projected values.

What the tree reveals: Even without a fallback, the ChoiceTree's bind markers
tell us exactly where the bound subtree starts and ends. The materializer
knows which positions to re-generate. The generator's reified structure
constrains what PRNG can produce.

**Tier 3: Transparent (no bind handling needed).** The bind's inner is a
`.getSize` node -- structurally stable during reduction. The flattener emits
`.group` markers instead of `.bind` markers. Standard group-based reduction
suffices with no special handling.

**Escalation strategy.** Structural minimization starts with Tier 1. When
Tier 1 stalls on a specific bind position (no progress after N probes),
escalate to Tier 2 (full PRNG re-generation) for that position. This
escalation is per-position, not global -- some bind-roots may respond to
guided replay while others need PRNG exploration. Value minimization uses
Tier 1 exclusively. For leaves whose
controlling bind-inner is unchanged, guided replay degenerates to near-exact
materialization (stable fallback tree). For leaves inside a bound subtree
whose bind-inner was shrunk by Phase 2, guided replay performs genuine
clamping against the new domains.

---

## 5. The Dependency DAG

The core structural abstraction. Replaces bind-depth as the ordering proxy.

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
`BindSpanIndex`). The DAG extraction is O(n) in the ChoiceSequence length --
a single walk with a stack -- and is dominated by the cost of property
evaluation, which is the bottleneck for all phases.

### Why the DAG, not bind-depth?

The current BonsaiReducer uses bind-depth as a proxy for ordering:
the depth sweep processes depths 1 to max (covariant), covariant sweep processes
depth 0, deletion processes depths 0 to max. This works for simple
generators but breaks down with nested binds, branches inside binds, and
independent subtrees at the same depth.

The DAG captures the actual dependency structure: if position A's value
determines whether position B exists, then A must be reduced before B. Two
positions at the same bind-depth but in independent subtrees can be reduced
in parallel (or in either order). The topological sort handles nested
dependencies correctly regardless of depth.

---

## 6. Reduction Morphisms

A reduction morphism is a triple `(encode, decode, classification)`:

- `encode: ChoiceSequence -> [ChoiceSequence]` proposes candidate mutations
- `decode: ChoiceSequence -> ShrinkResult?` materializes and validates
- `classification` determines which phase the morphism belongs to

### Morphism Classifications

Morphisms are classified by what they preserve:

**Structure-preserving (exact).** Same skeleton shape, different values. Exact
decoder suffices -- the candidate can be validated by range-checking each
entry against the current ChoiceTree's validRanges. No replay needed. Used by
value minimization encoders operating on leaf positions within a fixed
skeleton.

**Structure-reducing (approximate).** Fewer skeleton points, or different
skeleton shape. Requires the REPLAY mechanism to project old values onto the
new skeleton. The projection introduces slack: the materialized trace may
have slightly different shortlex cost than predicted from the candidate
sequence alone, because bound content is re-derived against the new inner
values.

**Structure-speculative (relaxing).** May temporarily increase cost. The
encoder proposes a candidate that is not shortlex-smaller, gambling that
subsequent reduction on the relaxed state will find a better local minimum
than the current one. Requires checkpointing and rollback.

### Composition

**Within a phase:** greedy resolution by default. For each encoder, try
candidates in order; accept the first that passes the property and satisfies
the phase's acceptance criterion. Then move to the next encoder. This is the
simplest composition -- first-accepted candidate per encoder.

The `ProductSpaceEncoder` (Phase 1c) is an exception: it evaluates all
candidates in its search space and selects the shortlex-minimal one that
preserves failure. This is strictly better than greedy -- it finds the best
candidate, not merely the first passing one. It is sound because the
acceptance gate is still applied to the selected candidate; the difference is
that the encoder examines the full candidate set before committing. The batch
evaluation is what makes joint bind-inner reduction effective: greedy
resolution would commit to the first passing combination and miss better ones.

**Between phases:** sequential. Phase k runs only after Phase k-1 reaches
fixpoint. The composite pipeline is a sequential chain of reductions, each
operating on the output of the previous.

**Between cycles:** the outer loop alternates structural and value phases
until neither makes progress. Each productive cycle strictly reduces the
lexicographic measure (skeleton.size, values), which is well-founded on
finite sets, guaranteeing termination.

### Acceptance Gates

The acceptance gate differs by phase:

**Phase 0:** One property evaluation for defensive verification. Acceptance
is by structural independence (Section 3.6), confirmed by verification.

**Phase 1:** `shortlex(materialized) <= shortlex(original)` AND property
fails. Shortlex on the full ChoiceSequence is the universal gate. This is not
in tension with the skeleton.size convergence measure because a structural
shrink that reduces width necessarily produces a shorter ChoiceSequence, which
is shortlex-smaller regardless of the projected flesh values. The skeleton
size order is not a separate gate -- it is a *search heuristic* that
determines which structural shrinks to *attempt*. The encoder proposes
candidates with smaller skeletons; the shortlex gate decides whether the
materialized result is accepted.

The interesting case: a structural shrink that changes bindDepthSum or
domainSum without changing width. After materialization, the ChoiceSequence
has the same length but different values. The shortlex gate compares the full
sequences lexicographically. If the projected flesh happens to be
lexicographically larger, the candidate is rejected even though the skeleton
is "structurally simpler." This is correct behaviour: the shortlex order is
the true objective, and skeleton.size is a proxy. A structurally simpler
skeleton that produces a lexicographically worse trace is not an improvement
by the objective we are actually optimizing. The cyclic variant may recover
this later if value minimization produces flesh that makes the structural
shrink shortlex-beneficial on the next pass.

**Phase 2:** `shortlex(materialized) <= shortlex(original)` AND property
fails AND skeleton unchanged (phase boundary guard). Same shortlex gate, with
the additional constraint that the skeleton must not change.

**Speculation:** No shortlex gate during the speculative step itself.
Acceptance is deferred: the speculative state is exploited via Phases 1-2,
and the final result must shortlex-precede the checkpoint.

### Convergence

Shortlex on finite choice sequences over a finite alphabet is a well-order.
Each non-speculative acceptance strictly reduces shortlex. Therefore the
algorithm terminates: each phase can accept at most finitely many shrinks
before reaching a local minimum, and the outer cycle can iterate at most
finitely many times before the pair (skeleton.size, values) stabilizes.

---

## 7. The Three Phases

The shrinker executes three phases. Each phase is justified by a single
formal principle. Every possible shrink is classified into exactly one phase.
The phase ordering is forced by the mathematics, not chosen as a heuristic.

### Phase 0: Structural Independence Isolation

**Formal basis:** Structural independence via the generator's dependency graph
(Section 3.6). A choice point that has no dependency path (via bind or branch
edges) to any other choice point is structurally independent: its value
cannot affect any other position's domain, existence, or value through the
generator's structure. Zeroing it is sound with respect to the generator; the
defensive verification confirms it is sound with respect to the property.

**Purpose:** Eliminate structurally independent choice points in a single pass
with one property evaluation. This is the "dead code elimination" analogue
from compiler optimization, applied to the execution trace.

**What this can and cannot detect.** Phase 0 identifies positions that are
structurally isolated in the generator's dependency graph -- they have no
bind or branch path connecting them to other positions. This detects
independent subtrees in compositional generators: a `(config, payload)` tuple
where `config` and `payload` are independent subtrees, optional branches with
unused arms, diagnostic fields that don't feed into other generators.

Phase 0 *cannot* detect that the property ignores a specific subtree. If
`config` and `payload` are both structurally connected to the root (for
example, both feed into a single bind), Phase 0 marks both as potentially
relevant even if the property only inspects `payload`. This is a consequence
of the property being an opaque closure -- the dependency graph captures
generator-level structure, not property-level data flow.

```
structuralIsolation(chain, trace, property) -> Trace

  1. CONSTRUCT the structural dependency graph from the
     ChoiceTree:
     - For each bind node: add edges from bind-inner to
       every position in the bound subtree
     - For each branch node: add edges from branch selector
       to every position in the selected subtree
     - These are structural facts read from the tree,
       not runtime observations

  2. COMPUTE connectedSet = the set of all positions
     reachable from any bind-inner or branch selector
     via dependency edges, plus those bind-inners and
     branch selectors themselves.
     (Single forward BFS/DFS from structural roots,
      O(|nodes| + |edges|))

     independentSet = all positions NOT in connectedSet.
     These are leaf values in top-level group siblings
     that contain no bind or branch nodes connecting
     them to other siblings.

  3. FOR EACH i IN independentSet:
       trace.values[i] <- skeleton.points[i].domain.minimum

  4. VERIFY (defensive):
       IF property(chain.evaluate(trace)) still fails:
         RETURN pruned trace
       ELSE:
         RETURN original unpruned trace
         (The structural analysis was insufficient: some
          supposedly-independent position matters to the
          property through a path the generator's dependency
          graph does not capture. This can happen when the
          property has side-channel dependencies — for
          example, hashing the entire generated value — that
          are invisible because the property is a black box.
          Fall back to the unpruned trace and let Phases 1-2
          handle reduction without the benefit of isolation.
          The DependencyDAG constructed in step 1 is still
          valid — it is a structural fact about the
          ChoiceTree, independent of the values. Phase 1
          reuses it regardless of whether Phase 0 pruned
          anything.)
```

**Complexity:** O(n + e) for graph construction and reachability. One
property evaluation for verification.

**Why this is better than property-probing.** An alternative approach tests
subtree relevance by property evaluation: zero each subtree individually,
check if the property still fails, use delta-debugging to find the minimal
relevant subset. This costs O(subtrees) property evaluations for a one-shot
result. Structural isolation achieves the same effect for structurally
independent positions using graph analysis that costs zero property
evaluations. The single defensive verification at the end guards against the
structural analysis being insufficient (the property depending on something
the generator graph cannot see).

**Transition:** Single pass. Phase 0 runs exactly once at the start of
reduction.

**When Phase 0 helps and when it does not.** Phase 0 identifies structurally
independent positions -- those with no bind or branch dependency path to any
other position. In the motivating example, every element is inside a single
bind's bound subtree, and the bind-inner `n` controls all of them. The
entire trace is structurally connected, so Phase 0 identifies no independent
positions and eliminates nothing. This is the common case for monolithic
generators with a single bind chain.

Phase 0 earns its keep in compositional generators that produce independent
subtrees. A generator that builds a `(config: Config, payload: Payload)`
tuple as two independent group children has `config` and `payload` in
separate subtrees with no bind or branch edges between them. If all bind and
branch nodes are within `payload`, the `config` subtree is structurally
independent and gets zeroed for free. Generators with optional branches,
unused diagnostic fields, or compositional structures with independent
components all benefit. The O(n + e) cost is negligible either way, so Phase
0 is always worth running, but the expectation should be tempered: it can
only detect independence visible in the generator's structure, not
independence that depends on what the property inspects.

### Phase 1: Structural Minimization

**Formal basis:** Fibration of trace space over skeleton space. Skeleton
changes can eliminate entire choice points; value work within a fibre that
will be abandoned is wasted. Therefore: minimise the skeleton (fibre) before
minimising values within it.

**Purpose:** Reduce all structure-controlling positions -- bind-inner values,
branch selectors, and container structure -- until no further structural
simplification is possible.

**Sub-phases** (iterate to fixpoint within Phase 1):

#### 1a. Branch Simplification

Branch positions have a unique property that distinguishes them from
bind-inner values: promoting a branch can change the generator type
downstream (for example, a `pick` that selects between `Gen.int(...)` and
`Gen.string(...)` produces entirely incompatible bound subtrees). Branch
changes invalidate the DependencyDAG more radically than bind-inner changes.

Branch simplification runs first within each structural iteration:

- Promote branches to simpler alternatives (`PromoteBranchesEncoder`)
- Pivot branches to lower-weight choices (`PivotBranchesEncoder`)
- Decoder: guided, relaxed strictness, `materializePicks: true`

If any branch is simplified, the DependencyDAG is recomputed and structural
minimization restarts from 1a. This is not a heuristic -- after a branch
change, the set of bind points and their domains may have changed entirely.

#### 1b. Structural Deletion (topological order, outermost first)

Reduce the skeleton by removing structural elements. Process in topological
order from the DependencyDAG (outermost/upstream first):

- Delete container spans (`DeleteContainerSpansEncoder`)
- Delete sequence elements (`DeleteSequenceElementsEncoder`)
- Delete sequence boundaries (`DeleteSequenceBoundariesEncoder`)
- Delete free-standing values (`DeleteFreeStandingValuesEncoder`)
- Aligned window deletion (`DeleteAlignedWindowsEncoder`)
- Decoder: guided, relaxed strictness

**A note on `SpeculativeDeleteEncoder`.** Despite its name, this encoder is
not speculative in the sense of Section 6's "structure-speculative" morphism
classification (may temporarily increase cost). It is a deletion encoder with
a wider search window: it uses PRNG fallback for the deleted region rather
than guided replay, accepting any result that is shortlex-smaller. It
satisfies the monotonicity gate and belongs in Phase 1b. The name reflects
its search strategy (willing to discard old bound content entirely), not its
cost behaviour. It does not belong in the bounded speculation escape hatch.

Each successful deletion triggers DAG recomputation and restart from 1b (a
deletion can enable adjacent deletions -- removing sequence elements may make
remaining spans deletable). Deletion does not restart from 1a because
removing structural elements almost never creates new branch simplification
opportunities.

#### 1c. Joint Bind-Inner Reduction (Product Space Search)

The current BonsaiReducer reduces each bind-inner independently: reduce
inner-1, commit, reduce inner-2, commit. This sequential greedy approach
misses combinations that only work jointly and produces stale bound
derivations (bound-1 is re-derived against inner-2's OLD value).

**The product space construction.** Each outer bind-inner position `i` is a
coordinate in a product space. Each coordinate has a set of candidate values
`V_i` from a binary search ladder (midpoints between current value and
domain minimum):

```
V_i = binarySearchLadder(current_i, range_i, maxSteps: s)
    = {current, mid(current, min), mid(min, mid), ...}
    |V_i| = O(log(range_i))
```

**Handling nested binds (dependent products).** When bind-inners are
independent (no dependency edges between them in the DAG), the product space
is a simple Cartesian product `V_1 x V_2 x ... x V_k`. But nested binds
create dependencies: in the generator

```swift
Gen.int(in: 0...10).flatMap { n in       // inner-1
    Gen.int(in: 0...n).flatMap { m in    // inner-2
        Gen.array(length: m, element: Gen.int(in: 0...m))
    }
}
```

`inner-2`'s domain is `0...n`, which depends on `inner-1`. If the product
space tests `(inner-1 = 3, inner-2 = 7)`, the candidate is invalid --
`inner-2 = 7` is not in `0...3`.

The product space must be constructed in topological order: each coordinate's
candidate set is computed against the *candidate values* of its upstream
coordinates, not against the current trace values. For nested binds, this
means the product is not Cartesian but a *dependent product* (a sigma type):

```
V_1 x V_2(v_1) x V_3(v_1, v_2) x ...
```

For full enumeration (k <= 3), the candidate count may be smaller than the
Cartesian upper bound because invalid combinations are pruned during
construction, not during evaluation. For the adaptive strategy (k > 3),
the "halve all coordinates simultaneously" step must respect dependencies:
halving `inner-1` may invalidate the current `inner-2` value, requiring a
projection of downstream coordinates before the combined candidate can be
tested. This projection uses the same REPLAY mechanism -- the dependent
structure is handled naturally by forward replay through the chain.

**Cost of dependent enumeration.** For nested binds, computing `V_2(v_1)`
requires calling the continuation with `v_1` to discover `inner-2`'s new
domain -- a REPLAY call. For k = 2 with 6 steps on axis 1, this means 6
REPLAY calls just to determine `V_2` for each candidate `v_1`, plus up to
36 property evaluations for the actual candidates. The total cost is up to
6 + 36 = 42, not 36. For k = 3 with nested dependencies, the overhead is
multiplicative: discovering `V_3(v_1, v_2)` for each `(v_1, v_2)` pair adds
another layer of REPLAY calls.

The general pattern: for a chain of d fully nested dependent binds with s
steps per axis, the discovery cost is O(s^d) `skeletonFor` calls (one per
point in the dependent product to determine the next axis's domain). This is
the same order as the candidate count itself. Each `skeletonFor` call runs
the chain recording only structure (not committing values), which is cheaper
than a full REPLAY + property evaluation -- roughly 0.3x to 0.5x depending
on generator complexity.

For k = 2 with 6 steps, the effective cost is approximately
6 * 0.4 + 36 = 38.4 evaluation-equivalents, not 36. For k = 3 with fully
nested dependencies (worst case), discovery adds up to 216 * 0.4 = 86.4
evaluation-equivalents on top of 216 property evaluations, for an effective
total of approximately 302 evaluation-equivalents. Still within a typical
per-cycle budget of 3250, but a meaningful fraction.

In practice, deeply nested dependent binds are rare. The common case is
independent bind-inners (parallel flatMaps, tuple generators), where the
discovery cost is zero -- each axis's domain is known from the current
ChoiceTree. When k > 3 triggers the adaptive strategy, discovery cost is
amortized over the halving steps and is not a concern.

**Traversal strategy** (switched by k = number of outer bind-inners):

For k <= 3 with maxSteps = 6: **Full enumeration.** The product space has at
most 216 candidates. Each requires one property evaluation with REPLAY.
Accept the shortlex-minimal candidate that preserves failure. This gives
the strongest guarantee: the best candidate in the search space is found.

For k > 3: **Adaptive coordinate descent.** Halve ALL coordinates
simultaneously (one evaluation). If accepted, recurse on the halved space.
If rejected, delta-debug which subset of coordinates can be halved --
O(k * log k) evaluations to identify the maximal halvable subset. Then
recurse. Cost: O(k * log(range) * log(k)).

**Budget awareness.** The product space search consumes one property
evaluation per candidate tested. For k = 3, maxSteps = 6, this is up to
216 evaluations -- a substantial fraction of a typical per-cycle budget
(3250 in the current BonsaiReducer). The maxSteps parameter should be tuned
per-cycle based on remaining budget: start with maxSteps = 6, reduce to 4 or
3 if budget pressure is high. The adaptive strategy for k > 3 is inherently
budget-friendly -- it starts with a single probe and expands only as needed.

**What this replaces:**

- `BindRootSearchEncoder` (sequential halving, Tier 2 only)
- `BinarySearchToZeroEncoder` on structural spans (sequential, per-axis)
- `BindAwareRedistributeEncoder` (pairwise redistribution)

All three are subsumed by the product space search, which tests combinations
they cannot reach.

**New encoder:** `ProductSpaceEncoder` (BatchEncoder for k <= 3,
AdaptiveEncoder for k > 3).

**Decoder:** Tier 1 (guided with fallback tree) as default. All inner values
are set simultaneously via REPLAY, so all bound content is re-derived against
the correct combination.

**Escalation within the product space.** The batch encoder separates
candidate *discovery* from candidate *escalation* to control budget.

*Discovery pass (Tier 1 only).* Evaluate all candidates in the product space
using Tier 1 projection. This costs at most `|V_1 x ... x V_k|` property
evaluations (up to 216 for k = 3, maxSteps = 6). Collect all candidates
whose Tier 1 projection preserves failure. If any pass, accept the
shortlex-minimal one. The discovery pass alone provides the full
"shortlex-minimal" guarantee for candidates reachable via Tier 1.

*Escalation pass (Tier 2).* If no candidate passes Tier 1, escalate -- but
not on all 216 candidates. Sort the Tier 1 failures by **largest fibre first**
(largest inner values, hence widest domains and most choice points) and
escalate only the top N candidates (default N = 5) to Tier 2 (full PRNG
re-generation). Each Tier 2 attempt generates entirely fresh bound content
for the candidate's inner values. With N = 5, the escalation pass costs at
most 5 additional property evaluations.

The largest-fibre-first ordering is deliberate: Tier 2 success depends on
whether PRNG can find *any* flesh assignment in the new fibre that fails the
property. Larger fibres have more possible flesh assignments, so PRNG has
more room to hit a failure. A candidate with inner value 8 (reduced from 47)
has a larger fibre than a candidate with inner value 3. If the larger
candidate succeeds via Tier 2, the cyclic composition will continue shrinking
it in future passes -- the shortlex-smallest result will be found eventually
through iterative reduction, not by picking the smallest candidate upfront.

If a Tier 2 attempt finds a passing candidate, accept it. It is the
shortlex-smallest among the successful escalated candidates (tested in
largest-fibre order, but acceptance still applies the shortlex gate).

This two-pass design means the worst-case cost of the product space search
is 216 (discovery) + 5 (Tier 2 escalation) = 221 property evaluations for
k = 3. The "shortlex-minimal" guarantee is exact for Tier 1 candidates and
approximate (best-of-N) for escalated candidates. In practice, most product
space candidates that will pass do so at Tier 1; escalation is a fallback
for the minority of cases where projection fails across the board.

**Non-bind structural values** (branch selectors at depth 0): Reduced with
existing encoders (`ZeroValueEncoder`, `BinarySearchToZeroEncoder`) targeting
structural spans only. These are not part of the product space (discrete
choices, not continuous ranges).

**Inner iteration and restart policy.** The restart target after a successful
sub-phase depends on what changed:

```
1a change (branch simplified)  -> restart from 1a
  Branch changes can alter the generator graph: new bind points,
  new branches, entirely different downstream structure. Full
  restart is required.

1b change (structure deleted)  -> restart from 1b
  Deletion enables more deletion (adjacent spans become deletable).
  But deletion almost never creates new branch simplification
  opportunities, so restarting from 1a is wasteful.

1c change (bind-inner reduced) -> restart from 1a
  A bind-inner value change can alter which branches and bind-inners
  exist downstream. Full restart is required.
```

This saves the cost of attempting branch simplification after every deletion,
which is typically futile.

**Transition:** When a full 1a -> 1b -> 1c pass makes no progress.

### Phase 2: Value Minimization

**Formal basis:** Partial evaluation of the specialised Kleisli chain
(Section 3.5). The skeleton is *structurally* fixed: width and bind nesting
depth are frozen. Domains may shift when the phase boundary guard permits a
bind-inner value change (one that preserves width and bindDepthSum but alters
domainSum). The chain specialises to a residual programme whose structural
parameters are fixed but whose domain boundaries may narrow as bind-inner
values decrease.

Within this residual, choice points are *generator-independent*: changing
leaf A's value cannot change leaf B's domain or existence. They may still be
*property-coupled*: the property's truth value can depend on their joint
configuration in ways invisible to the generator's dependency graph.
Generator-independence makes Phase 2 structurally simpler than Phase 1
(fixed dimensionality, bounded domains). Property-coupling is why Phase 2
requires iterative coordinate descent rather than a single pass.

**Purpose:** Reduce all values within structurally frozen skeleton.

**Phase boundary guard.** A bind point may still be shrunk during value
minimization, but only if doing so preserves the skeleton's **width and
bindDepthSum** (the first two components of the skeleton size order). The
guard deliberately ignores domainSum: for a structurally dependent bind, any
inner-value change necessarily shifts the bound subtree's domains (and hence
domainSum), even when the structural shape (number of points and nesting
depth) is unchanged. If the guard compared full skeleton equality including
domainSum, structurally dependent bind-inners would be unreachable by Phase 2
entirely -- every candidate would be rejected because domainSum changed. This
would be overly conservative: a bind-inner change that preserves width and
nesting depth but shifts domains is a value-level change with structural side
effects, not a structural change. Phase 2 should be able to make it.

For example, after structural minimization fixes `n = 5`, value minimization
might try `n = 4`. The skeleton width is unchanged (both produce 6 elements),
the nesting depth is unchanged, but domainSum changes (elements now range
over `0...4` instead of `0...5`). The guard accepts this: `n = 4` is a value
shrink with domain-side effects. The shortlex gate provides the final check
-- if the materialized trace is shortlex-worse despite the smaller inner
value, it is rejected.

If `n = 3` produced a different width (for example, `max(2, n+1)` gives 4
vs 6), the guard rejects it -- that is a structural change belonging to
Phase 1.

**Optimising the guard via structural constancy classification.** The naive
guard calls `skeletonFor(newBindValues)` for every bind-point candidate,
which invokes the continuation -- the expensive operation. But the ChoiceTree
reveals a cheaper classification: some binds are **structurally constant**,
meaning the bound subtree's shape does not depend on the inner value:

```swift
// Structurally constant: bound subtree ignores inner value
Gen.int(in: 0...10).flatMap { _ in Gen.string(length: 5) }

// Structurally dependent: bound subtree shaped by inner value
Gen.int(in: 0...10).flatMap { n in Gen.array(length: n, ...) }
```

This classification can be computed once during DAG construction (or detected
by the existing `RangeDependencyDetector`). For structurally constant binds,
the phase boundary guard is a no-op: every value shrink on that inner is safe
because the skeleton cannot change in any component. For structurally
dependent binds, the guard must call `skeletonFor` to check width and
bindDepthSum, but does not compare domainSum.

**No depth ordering needed for correctness:** Since all structural positions
are converged, bind-inners will not change, so bound-subtree leaves are
stable. All leaves can be processed in a single flat pass without violating
any phase invariant.

**Efficiency note: structural proximity ordering.** While any ordering is
correct, some orderings find reductions faster. When Phase 2 shrinks a
bind-inner value that passes the phase boundary guard, the bound subtree's
domains shift. Leaves in that subtree may have been clamped to new values by
the materialiser and may now be reducible in ways they were not before.
Processing those leaves next -- before leaves in unrelated subtrees -- is
sensible because their domains just changed. This is a generator-structural
reason to prioritise them (domain-shift recency), not a claim about
property-level causality. The DependencyDAG identifies which leaves share a
structural ancestor, but it cannot identify which leaves are coupled through
the property -- that would require the same impossible property-level
analysis. The flat pass will find all reductions eventually (by cycling
through all leaves), but structural proximity ordering reduces the number of
cycles needed when domain shifts create new reduction opportunities.

**Encoders** (targeting leaf positions only):

- `ZeroValueEncoder` -- set to domain minimum
- `BinarySearchToZeroEncoder` -- binary search toward zero
- `BinarySearchToTargetEncoder` -- binary search toward target values
- `ReduceFloatEncoder` -- float-specific reduction strategies
- `TandemReductionEncoder` -- coordinated sibling leaf pairs
- `CrossStageRedistributeEncoder` -- leaf pairs across generator stages

**Decoder:** Exact for generators without binds. Tier 1 (guided replay) for
leaves inside bind-bound subtrees. For leaf positions whose controlling
bind-inner is unchanged, guided mode degenerates to near-exact
materialization (the fallback tree matches the current structure exactly).
For leaf positions inside a bound subtree whose bind-inner was just shrunk by
Phase 2 (permitted by the phase boundary guard), the materialiser performs
genuine guided replay with clamping: the fallback tree reflects the old
inner value's structure, and values outside the new domains are clamped. This
is slightly more expensive than exact decoding and may produce different
values, but is handled correctly by the existing materialiser infrastructure.

**Transition:** When all leaf encoders stall (no progress in a full pass).

---

## 8. Encoder-to-Phase Mapping

| Encoder                          | Current Leg      | New Phase                              | Change                             |
|----------------------------------|------------------|----------------------------------------|------------------------------------|
| `PromoteBranchesEncoder`         | Branch           | 1a                                     | Unchanged                          |
| `PivotBranchesEncoder`           | Branch           | 1a                                     | Unchanged                          |
| `DeleteContainerSpansEncoder`    | Prune            | 1b                                     | Now runs BEFORE value min          |
| `DeleteSequenceElementsEncoder`  | Prune            | 1b                                     | Now runs BEFORE value min          |
| `DeleteSequenceBoundariesEncoder`| Prune            | 1b                                     | Unchanged                          |
| `DeleteFreeStandingValuesEncoder`| Prune            | 1b                                     | Unchanged                          |
| `DeleteAlignedWindowsEncoder`    | Prune            | 1b                                     | Unchanged                          |
| `SpeculativeDeleteEncoder`       | Prune            | 1b                                     | Unchanged                          |
| `BindRootSearchEncoder`          | Train            | Subsumed by `ProductSpaceEncoder`      | Joint search replaces sequential   |
| `ZeroValueEncoder`               | Train/Snip       | 1c (structural targets) + 2           | Split by position classification   |
| `BinarySearchToZeroEncoder`      | Train/Snip       | 1c (structural targets) + 2           | Split by position classification   |
| `BinarySearchToTargetEncoder`    | Train/Snip       | 2                                      | Leaf only                          |
| `ReduceFloatEncoder`             | Train/Snip       | 2                                      | Leaf only                          |
| `BindAwareRedistributeEncoder`   | Redistribution   | Subsumed by `ProductSpaceEncoder`      | Product space finds combos         |
| `ProductSpaceEncoder` (NEW)      | --               | 1c                                     | Joint product over outer binds     |
| `TandemReductionEncoder`         | Redistribution   | 2                                      | Leaf redistribution                |
| `CrossStageRedistributeEncoder`  | Redistribution   | 2                                      | Leaf pairs only                    |
| `RelaxRoundEncoder`              | Exploration      | Speculation (escape hatch)             | Unchanged                          |

---

## 9. Composition and the Outer Cycle

### Strict Composition (simpler, may leave reduction on the table)

```
reduce(chain, trace, property) -> Trace

  Phase 0: structuralIsolation(chain, trace, property)
         |
         v
  Phase 1: structuralMinimisation(chain, _, property)
         |
         v
  Phase 2: valueMinimisation(chain, _, property)
         |
         v
       RETURN
```

### Cyclic Composition (recovers missed structural reductions)

```
reduce(chain, trace, property) -> Trace

  current <- structuralIsolation(chain, trace, property)

  REPEAT:
    current <- structuralMinimisation(chain, current, property)
    current <- valueMinimisation(chain, current, property)
  UNTIL neither phase made progress

  RETURN current
```

This is not interleaving structural and value shrinks arbitrarily. Each phase
runs to convergence before yielding to the other. The iteration is between
converged phases. This connects naturally to a V-cycle scheduling strategy
where the "down" pass is structural and the "up" pass is value-level, with
cycles until convergence.

**Why the cycle is needed.** Because projection across bind boundaries is
best-effort (not algebraic), Phase 1 may reject structural shrinks whose
projected flesh happened to pass the property, even though different flesh
values in the smaller fibre would fail. Phase 2 can change bind-point values
without changing the skeleton (the phase boundary guard permits this),
providing new starting points for Phase 1 on the next cycle. The cycle
recovers structural reductions that were missed due to incomplete projection.

### Bounded Speculation (escape hatch for local minima)

When the cyclic composition converges (neither phase makes progress across a
full cycle), a bounded speculation step can escape local minima:

1. Checkpoint all state
2. Speculative redistribution (`RelaxRoundEncoder`) -- may increase cost
3. If accepted: exploit via Phases 1-2 on the relaxed state
4. Accept if final result shortlex-precedes checkpoint
5. Rollback otherwise

Budget: Hard cap. If speculation produces no improvement, reduction
terminates. Speculation is not a phase in the same formal sense as Phases 0-2
-- it has no convergence guarantee. It is a bounded escape hatch.

---

## 10. Formal Properties

### 10.1 Phase Classification is Total and Exhaustive

Every possible shrink is classified into exactly one phase. Zeroing a
structurally independent point belongs to Phase 0. Any shrink that changes the skeleton
belongs to Phase 1. Any shrink that changes a value within a fixed skeleton
belongs to Phase 2. These categories are exhaustive and mutually exclusive.

### 10.2 Phase Ordering is Forced

Phase 0 before Phase 1: slicing reduces the number of choice points Phase 1
must consider. Phase 1 before Phase 2: structural shrinks can eliminate
entire choice points; value work on eliminated points is wasted. Phase 2
cannot enable Phase 1 (in the strict variant): value changes within a fixed
skeleton do not, by definition, change the skeleton.

### 10.3 Soundness

The algorithm never accepts a trace that passes the property. Every accepted
shrink is a genuine counterexample. Soundness holds unconditionally,
regardless of the opacity of continuations.

### 10.4 Monotonicity

Each accepted shrink strictly reduces the objective: skeleton size in Phase
1, value magnitude in Phase 2. Phase 0 is a one-shot pass. In the cyclic
variant, the pair (skeleton.size, values) decreases lexicographically on each
productive cycle.

### 10.5 Termination

Phase 0 is a single pass and terminates trivially. Phase 1: skeleton size is
a natural number that strictly decreases on each successful step, bounded
below by zero. Phase 2: intuitively, each value decreases toward its domain
minimum -- but this per-position intuition is approximate because domain
shifts (from shrinking a structurally dependent bind-inner that passes the
boundary guard) can clamp downstream values or change domain minima. The
exact argument does not depend on per-position reasoning: shortlex on the
full ChoiceSequence strictly decreases on each acceptance (enforced by the
gate), and shortlex on finite sequences over a finite alphabet is a
well-order. This is the actual termination proof. The cyclic variant
terminates because the same shortlex well-order applies across cycles.

### 10.6 Completeness

The algorithm is explicitly incomplete. Because user-written continuations
are opaque and generally non-invertible, the projection across bind
boundaries may fail to find counterexamples in smaller fibres that do contain
them. An oracle that could invert arbitrary continuations would find them,
but no such oracle exists for arbitrary `@Sendable` closures. This
incompleteness is inherent to the opacity of user-written code and is
mitigated (not eliminated) by the cyclic variant and the escalation from
guided replay to PRNG re-generation.

---

## 11. Worked Example

Consider the motivating generator with a failing trace:

```
Generator:
  Gen.int(in: 0...100).flatMap { n in
    Gen.array(length: max(2, n+1),
              element: Gen.int(in: 0...n))
  }

Failing trace (property fails for this value):
  n = 47
  array = [31, 2, 45, 12, 0, 8, 44, 3, 19, 27,
           41, 6, 33, 14, 22, 38, 1, 46, 9, 35,
           20, 7, 40, 11, 29, 16, 43, 4, 37, 23,
           10, 34, 18, 42, 5, 26, 15, 39, 21, 30,
           13, 36, 24, 28, 17, 32, 8, 25]
  Skeleton: width=49, bindDepthSum=48, domainSum=4896

Suppose the property is:
  "no element exceeds 3"
```

### Phase 0: Structural Independence Isolation

The dependency graph has edges from `n` (bind-inner) to every array element
(bound subtree). All positions are structurally connected -- `n` controls
the existence and domains of every element, and every element is inside the
single bind's bound subtree. Phase 0 identifies no independent positions and
makes no changes. This is the common case for monolithic generators (see the
Phase 0 effectiveness discussion above).

### Phase 1: Structural Minimization (first pass)

Phase 1 tries shrinking `n` via binary search. The search seeks the smallest
candidate value that still preserves the failure, bisecting between the last
rejected value (lower bound, property passed) and the last accepted value
(upper bound, property failed). Key structural constraint: `max(2, n+1)`
means the array length is exactly `n+1` for `n >= 1`. You cannot
independently shrink the array length -- it is structurally coupled to `n`.
Reducing `n` is the *only* way to shorten the array.

The binary search proceeds: `n = 23` (width 25, property fails because some
projected element exceeds 3), then `n = 11` (width 13, still fails), then
`n = 5` (width 7, still fails if a projected element exceeds 3), then
`n = 2` (width 4, domain is `0...2`, no element can exceed 3, property
passes, rejected).

Binary search converges between 2 and 5. Try `n = 3`: width 5, domain
`0...3`. Projection: old elements with values <= 3 survive, others default to
0. The element 3 does not exceed 3 (the property is "exceeds 3", not
"exceeds or equals 3"). Property passes. Rejected.

Try `n = 4`: width 6, domain `0...4`. Projection preserves an element with
value 4, and 4 > 3. Property fails. Phase 1 accepts `n = 4`.

Phase 1 continues trying further reductions. `n = 3` was already rejected.
Phase 1 converges at `n = 4` with skeleton width 6.

### Phase 2: Value Minimization (first pass)

The skeleton is fixed: `n = 4`, 5 elements in domain `0...4`. Phase 2 tries
shrinking each element toward 0. The property fails when any element exceeds
3. Phase 2 reduces all elements to 0 except one that must remain > 3. The
element at value 4 is the witness.

After Phase 2: `n = 4`, array = `[0, 0, 0, 0, 4]`.

Phase 2 also tries shrinking `n` itself. The phase boundary guard asks: does
`skeleton(n=3) == skeleton(n=4)`? No -- width changes from 6 to 5. Rejected;
this belongs to Phase 1.

### Cyclic re-entry: Phase 1 (second pass)

The cyclic composition re-enters Phase 1 with the improved flesh: `n = 4`,
`[0, 0, 0, 0, 4]`. Phase 1 tries `n = 3` again. This time the flesh being
projected is different from the first pass: the old values are
`[0, 0, 0, 0, 4]`. With `n = 3`, the domain is `0...3`. Elements 0 through 3
(all value 0) survive. Element 4 (value 4) is out of domain `0...3` and
defaults to 0. All elements are now 0. No element exceeds 3. Property passes.
Phase 1 rejects.

The improved flesh did not help. The problem is fundamental: the only value
in `0...4` that exceeds 3 is 4, and 4 is not in `0...3`. No flesh values in
the `n = 3` fibre can fail the property. The `n = 3` skeleton is genuinely
infeasible for this property. `n = 4` is the structural minimum.

Neither phase makes progress. Cyclic composition terminates.

### Final result

`n = 4`, array = `[0, 0, 0, 0, 4]`. Skeleton width 6 (1 bind point + 5
elements).

### What the example reveals

This example illustrates several properties of the algorithm:

1. **Phase 0 is vacuous for monolithic generators.** Every choice point is
   structurally connected via the single bind chain. Phase 0 costs one
   verification probe and eliminates nothing.

2. **Structural and value minimization are genuinely separate concerns.** The
   structural minimum (`n = 4`) is determined by the property's threshold
   and the domain coupling. Value minimization within the fixed skeleton is
   a simpler problem: zero all non-witness elements.

3. **The phase boundary guard correctly classifies bind-point shrinks.** When
   Phase 2 tries `n = 3`, the skeleton changes, so the guard rejects it as
   a Phase 1 candidate. The cyclic variant gives Phase 1 another chance with
   better flesh, but in this case the structural shrink is genuinely
   infeasible.

4. **The generator's `max(2, n+1)` coupling makes array length non-independent.**
   There is no way to produce a 2-element array at `n = 4` -- the generator
   forces 5 elements. The "true minimum" counterexample is `n = 4` with one
   element being 4 and the rest at 0. The algorithm finds exactly this.

---

## 12. The ChoiceTree as the Primitive

Everything in this document follows from a single architectural decision: the
generator is reified into an inspectable ChoiceTree, and every materialization
produces a fresh tree alongside the generated value. The ChoiceTree is the
primitive; every algorithmic capability described here is a consequence of
having it. Without the tree, you are Hypothesis (flat byte stream, no
structural visibility). With the tree, you have all of this.

**Phase 0 is possible because the tree reveals dependency edges.** The
ChoiceTree records which choice points are bind-inners and which are in bound
subtrees, and which are branch selectors controlling selected subtrees. This
gives us structural dependency edges for free -- they are facts about the
tree, not annotations. Forward reachability from structural roots identifies
the connected set; everything else is structurally independent and can be
zeroed. Hypothesis cannot distinguish independent from dependent positions
because its byte stream is flat.

**Phase 1 is possible because the tree reveals bind boundaries.** The
ChoiceTree marks exactly where each bind's inner and bound subtrees start and
end. This enables the skeleton/fibre decomposition: we can classify every
position as structural or leaf, build the DependencyDAG, and topologically
sort structural positions. QuickCheck's output-domain shrinking cannot access
the entropy stream at all; Hypothesis's byte-level operations cannot see bind
boundaries in their flat representation.

**The product space is possible because the tree reveals bind-inner ranges.**
Each bind-inner's `validRange` is recorded in the ChoiceTree. We know
exactly which positions are bind-inners, what their domains are, and which
are independent vs nested. This is what lets us construct the discretized
product space and search it jointly. No other PBT framework has this
information.

**The escalation tiers are possible because the tree reveals bound subtree
structure.** Guided replay works by walking the fallback ChoiceTree alongside
the new one, matching positions and clamping values. PRNG re-generation knows
exactly which positions to re-generate because the bind markers delimit the
bound subtree. Both tiers depend on structural information that only the
ChoiceTree provides.

**The phase boundary guard is possible because the tree reveals structural
constancy.** Whether a bind is structurally constant (bound shape independent
of inner value) or structurally dependent is a fact about the ChoiceTree's
structure. This classification drives the optimised guard in Phase 2 and
informs the DAG construction.

The phased architecture turns these capabilities into a systematic algorithm:
dependency graph constructed -> independent positions eliminated (Phase 0) ->
structural positions reduced jointly (Phase 1) -> leaf positions reduced in
stable context (Phase 2). Each step exploits information that is uniquely
available from the reified ChoiceTree. The tree is not an implementation
detail; it is the reason the algorithm exists.

---

## 13. Summary

| Phase | Formal Basis | Mechanism | Guarantee |
|-------|-------------|-----------|-----------|
| 0: Structural Independence Isolation | Structural independence via generator dependency graph | Forward reachability from structural roots; zero independent positions; defensive verification | Sound: structurally independent positions cannot affect other positions through the generator |
| 1: Structural Minimization | Fibration of trace space over skeleton space | Shrink bind-point values and delete structure; forward replay with projection; accept if skeleton strictly smaller | Dominance: skeleton reduction cannot be achieved by value reduction |
| 2: Value Minimization | Partial evaluation of the specialised Kleisli chain | Shrink any value within structurally fixed skeleton; reject if width or bindDepthSum would change | Residual: structurally fixed dimensionality, domains may shift |

The algorithm provides five formal guarantees:

- **Soundness:** never accepts a trace that passes the property.
- **Monotonicity:** each accepted shrink strictly reduces the objective.
- **Termination:** the lexicographic order (skeleton.size, values) is
  well-founded and finite.
- **Total classification:** every possible shrink belongs to exactly one
  phase.
- **Forced ordering:** the phase sequence is determined by the mathematics,
  not by heuristic choice.

It is explicitly honest about one limitation: incompleteness. Because
user-written continuations are opaque and generally non-invertible, the
projection across bind boundaries may fail to find counterexamples in smaller
fibres that do contain them. The cyclic variant mitigates this by allowing
Phase 2's value changes to provide new starting points for Phase 1, but
cannot eliminate the incompleteness entirely. This is an inherent cost of
treating continuations as opaque callables rather than requiring them to be
algebraically invertible.
