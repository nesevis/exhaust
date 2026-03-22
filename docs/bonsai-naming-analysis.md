# Bonsai: Naming the Reducer After What It Does

> A principled algebra of reductions, scheduled by a compiler-style pass
> pipeline, tuned by heuristics.
>
> Why "KleisliReducer" is a misnomer, why every borrowed analogy breaks,
> and why the reducer is best understood as bonsai cultivation of a
> reified Kleisli tree.

## The Problem With Borrowed Names

The reducer has accumulated three names from three different fields, none of
which accurately describe what it does.

### "KleisliReducer"

In Sepulveda-Jimenez's *Categories of Optimization Reductions* (2026), "Kleisli"
refers specifically to Section 7's generalization: replacing deterministic
`Set`-valued morphisms with Kleisli arrows `X → TY` for a monad `T`. This is
one layer of a six-layer categorical framework (`OptRed_{T,α}^{gr}`). The Kleisli
aspect — nondeterministic re-derivation via `GuidedMaterializer` — is one of
seven major components of the reducer and arguably not the most distinctive.

Problems:

- The standard reducer also uses `GuidedMaterializer`. "Kleisli" doesn't
  differentiate the two.
- The implementation doesn't construct literal Kleisli arrows. The audit document
  acknowledges this: *"correctly instantiated in spirit, but informally."*
- The doc comments already describe the system more accurately than the type name:
  *"V-cycle reducer: multigrid reduction over bind depths."*
- The user-facing setting (`.useKleisliReducer`) says *"cyclic coordinate descent
  over bind depths"* — which describes the structure, not the Kleisli generalization.

### "Coordinate descent"

The three-pass taxonomy (contravariant / deletion / covariant) contradicts the
coordinate-descent framing. Coordinate descent assumes **homogeneous axes**: the
same operation applied at each coordinate, just restricted to that dimension.

The reducer does three fundamentally different things at the same depth depending
on which pass it's in:

- **Value sweep at depth 2**: exact value minimization, `.direct` decoder,
  structure-preserving, lattice-stable
- **Deletion at depth 2**: structure-destroying span removal, `.guided` decoder,
  lattice-invalidating
- **Covariant at depth 0**: value minimization that shifts the landscape for all
  bound depths, re-derives forward

These have different decoders, different approximation classes, different
structural contracts, and different information-flow directions. The depth axis
is a dependency graph with asymmetric causality (inner determines bound ranges,
not vice versa), not a uniform coordinate to minimize along.

### "V-cycle"

The V-cycle analogy comes from multigrid methods, where the "V" describes the
shape of the traversal through discretization levels: fine → coarse → fine.

The reducer's depth traversal traces a different shape. In the Kleisli tree's
natural orientation (root/depth 0 at the top, leaves/depth max at the bottom):

```
depth 0 (root)        ●              ●
                     / \
                    /   \
depth 1            ●     \
                          \
depth max (leaves) ●       ●
                 contra   del   cov
```

Contravariant starts at the leaves and ascends; deletion starts at the root and
descends. That's a **Λ** (inverted V), not a V. The V only appears if you adopt
the multigrid convention where coarse = bottom and fine = top — importing an
orientation convention from a field where it makes intuitive sense (fewer grid
points = less stuff = lower) but where it contradicts the Kleisli tree's natural
root-at-top orientation.

The operations don't match either. In a real multigrid V-cycle, the same
smoother runs on both arms at different resolutions. Here the ascending arm is
exact value minimization and the descending arm is structure-destroying deletion.

"V-cycle" requires three layers of indirection:

1. Borrow the algorithm name from multigrid (the operations don't match)
2. Borrow the orientation convention (the natural orientation is inverted)
3. Call it a V when it's a Λ in the domain's own terms

---

## What the Reducer Actually Is

A generator is composed of Kleisli chains, but as complexity grows it naturally
forms a **tree**. The `ChoiceTree` is the reified structure of that Kleisli tree.
The reducer operates directly on this tree — it is performing tree surgery.

The three passes, described in tree terms:

1. **Bottom-up value optimization** (post-order): optimize leaf values first,
   work toward root. Each node's value is minimized within ranges fixed by its
   ancestors. Structure-preserving, exact.

2. **Top-down structural pruning** (pre-order): remove subtrees starting at the
   root, because deleting a root-level node eliminates entire subtrees without
   needing to visit their children. Structure-destroying, bounded.

3. **Root perturbation with re-derivation**: modify root values, causing the
   entire subtree structure to shift (inherited ranges change, bound content is
   re-derived). Landscape-shifting, bounded.

### The compiler analogy

This three-pass pattern appears in optimizing compilers operating on an AST.
The mapping is precise enough to be instructive — not just a loose analogy, but
a structural correspondence where each pass has the same role, the same
directional properties, and the same ordering justification.

#### The three passes

**Constant folding ↔ Snip (contravariant)**

In a compiler, constant folding evaluates expressions where all operands are
already known: `2 + 3` becomes `5`. It works bottom-up because leaf expressions
(literals) are resolved first, then their results enable parent expressions to
fold. The operation is exact — no approximation, no structural change. The
expression `2 + 3` and the literal `5` have the same semantics; the tree just
gets simpler values at each node.

In the reducer, the contravariant sweep minimizes values at bound depths where
ranges are fixed by ancestors. It works bottom-up (max → 0) because leaf/bound
values can be minimized independently within their inherited ranges. The
operation is exact (`.direct` decoder) — no re-derivation, no structural change.
The tree keeps the same shape; the values just get smaller.

Shared properties: bottom-up, exact, structure-preserving, locally optimal
within current constraints. Both are pure exploitation — extract all value from
the current tree shape without disturbing it.

**Dead code elimination ↔ Prune (deletion)**

In a compiler, DCE removes code that is unreachable or whose results are never
used. It often works top-down: if a branch condition is known to be always-false
(perhaps because folding just resolved it), the entire subtree under that branch
is dead and can be removed. Eliminating a function call eliminates all code
reachable only through that call.

In the reducer, the deletion sweep removes spans and subtrees from the choice
sequence. It works top-down (0 → max) because removing a root-level span
eliminates entire subtrees — there's no point individually deleting children of
a node you're about to remove. Re-derivation (`.guided` decoder) fills in the
gap, analogous to the compiler re-linking around the deleted code.

Shared properties: top-down, structural, irreversible. Both change the shape of
the tree. Both may expose new optimization opportunities that weren't visible
before the removal.

**Constant propagation ↔ Train (covariant)**

In a compiler, constant propagation takes a variable assigned a known constant
at a definition site and substitutes that constant at all downstream use sites.
This is top-down information flow: the root (definition) determines what's
computable at the leaves (uses). After propagation, expressions that were
previously opaque (involving variables) become transparent (involving only
constants) — creating new work for the next folding pass.

In the reducer, the covariant sweep changes inner values (depth 0) and
re-derives bound content downstream. The root perturbation shifts bound ranges,
causing the entire subtree to be re-derived. After training, bound values that
were previously at their local minima within old ranges may have entirely new
ranges — creating new work for the next snip pass.

Shared properties: top-down, information flows from root to leaves, changes
what's possible at child nodes, creates new work for the next bottom-up pass.
Both are exploration — they shift the landscape at the cost of disrupting
locally-optimal work done in the previous bottom-up pass.

#### The cascade

In compilers, these three passes form a cascade where each creates work for the
next:

```
fold ──exposes──→ eliminate ──exposes──→ propagate ──exposes──→ fold
 │                    │                      │                    │
 │  folding resolves  │  removing dead code  │  substituting      │
 │  a branch cond to  │  reveals that a      │  constants creates │
 │  `true`, exposing  │  variable has only   │  new foldable      │
 │  dead code in the  │  one remaining       │  expressions at    │
 │  false branch      │  definition site,    │  leaf nodes        │
 │                    │  enabling propagation│                    │
```

The reducer has the same cascade structure:

```
snip ──exposes──→ prune ──exposes──→ train ──exposes──→ snip
 │                   │                  │                  │
 │  zeroing a value  │  pruning a       │  shifting an     │
 │  may make an      │  subtree changes │  inner value     │
 │  entire branch    │  the shortlex    │  changes bound   │
 │  irrelevant to    │  context,        │  ranges,         │
 │  the property     │  exposing new    │  creating new    │
 │  failure          │  inner-value     │  values to snip  │
 │                   │  training opps   │                  │
```

Each pass is individually convergent (it reaches a fixed point within its own
constraints). But reaching that fixed point exposes new work for the next pass.
The outer cycle terminates when a full rotation (snip → prune → train) produces
no new work — the combined fixed point.

#### Why the ordering matters

The ordering isn't arbitrary. In both compilers and the reducer, running the
passes in a different order wastes work:

**Fold before propagate (snip before train):** If you propagate first, you
substitute constants into expressions that could have been further simplified by
folding — wasting propagation effort on suboptimal values. In the reducer: if
you train first (shift inner values) before snipping (minimizing bound values),
re-derivation starts from unoptimized bound values. The fallback tree and prefix
carry worse values, so re-derivation regresses more. Snipping first ensures
re-derivation starts from the best available bound values — the Gauss-Seidel
argument from the plan document.

**Eliminate before propagate (prune before train):** If you propagate into dead
code, you waste work analyzing and transforming subtrees that will be removed
anyway. In the reducer: if you train before pruning, re-derivation fills in
content for subtrees that could have been deleted. Pruning first removes those
subtrees, so re-derivation operates on a smaller tree.

**Fold before eliminate (snip before prune):** Folding can resolve branch
conditions, revealing which branches are dead. Without folding first, DCE can't
see those opportunities. In the reducer: snipping can zero out values that make
entire branches unnecessary for preserving the property failure, exposing pruning
opportunities that weren't visible before.

This is the same cascade logic as the plan document's "cat-stroking algorithm":
smooth the fur (snip), then ruffle (prune + train). If you ruffle first, the fur
goes everywhere.

#### The phase ordering problem

In compilers, the **phase ordering problem** is the observation that different
orderings of optimization passes produce different final results, and finding the
optimal ordering is in general NP-hard. LLVM's `-O2` pipeline is a manually
crafted heuristic: a fixed sequence of passes chosen for good average-case
behavior, refined over years of engineering. Recent research explores ML-guided
pass ordering to improve on the hand-tuned sequence.

The reducer's three-pass cycle is the equivalent of LLVM's `-O2` — a principled
fixed ordering justified by the cascade dependencies above. The Gauss-Seidel /
"snip before train" argument is the theoretical justification. Just as LLVM
doesn't try every possible pass ordering, the reducer doesn't try every possible
sweep schedule — it uses the one ordering that minimizes wasted work given the
known dependency structure.

#### Where the analogy breaks: black-box vs. static analysis

The key difference between compiler optimization and test case reduction is
**observability**. A compiler has full static visibility into the program — it can
determine at compile time whether a branch is dead, whether an expression is
constant, whether a variable is used. This enables passes like Wegman & Zadeck's
Sparse Conditional Constant Propagation (SCCP), which fuses folding,
propagation, and elimination into a single pass using SSA form and a lattice.

The reducer has a **black-box property**. It cannot statically determine whether
zeroing a value preserves the property failure, or whether pruning a subtree
leaves a viable counterexample. Every candidate must be tested empirically —
materialized and run through the property function. This is why each pass
requires a decoder and a property check, and why the passes can't be fused into
an SCCP equivalent.

This black-box constraint is also why the reducer needs the dominance lattice
(triage). A compiler can analyze pass interactions statically; the reducer must
discover them empirically, and the lattice prunes encoders that are known to be
dominated based on past results — a runtime approximation of static analysis.

The attribute grammar connection is also precise:

- **Valid ranges** at bound nodes are inherited attributes (determined by
  ancestor/inner values)
- **Optimal values** at bound nodes are synthesized attributes (best value within
  range)
- Contravariant = synthesize bottom-up; covariant = re-derive inherited top-down

### What no single framework captures

No existing framework combines all three passes with the dependency-ordered
cycling:

| Aspect | Attribute grammars | Compiler AST | Bilevel opt | Structural EM |
|---|---|---|---|---|
| Bottom-up exploit | Synthesize | Constant folding | Inner problem | E-step |
| Structural pruning | — | Dead code elimination | — | Structure search |
| Top-down landscape shift | Inherit | Constant propagation | Outer problem | M-step |
| Dependency-ordered cycling | Multi-pass eval | Standard practice | Standard | Standard |

The reducer's three-pass taxonomy is a genuine combination. It deserves a name
from its own domain rather than a borrowed one.

---

## Two Layers: Algebra and Scheduling

The reducer is not one thing — it is two things composed. The name
"KleisliReducer" conflates them. Understanding the system requires separating
the **algebra** (what reductions are and how they compose) from the
**scheduling** (what order to run them in and how to manage resources).

### The algebra: Sepulveda-Jimenez

The categorical framework from *Categories of Optimization Reductions* provides
the theory of individual morphisms:

| Contribution | Paper reference | What it guarantees |
|---|---|---|
| Morphism structure | Def 3.1, 7.7 | Each encoder is a certified `(enc, dec, grade)` triple |
| Composition closure | Prop 3.2, 7.8 | Composing two valid reductions gives a valid reduction |
| 2-cell dominance | Def 15.3 | A partial order on parallel morphisms: "A is at least as good as B" |
| Resource composition | Prop 9.3 | Total resource usage = monoidal product of steps |
| Kleisli generalization | §7 | Nondeterministic `dec` (via `GuidedMaterializer`) fits the framework |
| Grade composition | §10 | Approximation slack and resources compose in a single monoid |

This is **infrastructure**. It answers: "Can I add a new encoder without breaking
existing ones?" (Yes — if it satisfies the morphism contract, composition
closure is automatic.) "Is encoder A strictly better than encoder B?" (Check the
2-cell criterion.) "How much budget does this pipeline need?" (Sum the resource
components.)

The algebra is real and valuable, but it is invisible to the user. It doesn't
determine what the reducer *does* — it determines what guarantees the reducer
can offer about whatever it chooses to do. It's the type system, not the
program.

### The scheduling: compiler-style pass pipeline

The three-pass cascade (snip → prune → train) is the architecture that makes
this reducer different from a flat loop over tactics. It determines:

| Decision | What governs it | Character |
|---|---|---|
| What passes exist | Domain analysis (tree structure, bind dependencies) | Engineering |
| What order to run them | Cascade analysis (snip exposes prune, prune exposes train, train exposes snip) | Principled engineering |
| Why snip before train | Gauss-Seidel: settle dependent values before perturbing independent values | Theoretical justification |
| Why prune before train | Don't re-derive content for subtrees you're about to remove | Common sense |
| Budget allocation per leg | Empirical tuning (`hardCap`, `stallPatience`) | Heuristic |
| When to trigger shaping | Stall detection (contravariant + deletion stalled) | Heuristic |
| Encoder selection within a leg | Dominance lattice + adaptive probing | Heuristic using algebraic infrastructure |

The scheduling is **architecture**. It's what users are opting into when they
write `.bonsai`. It's analogous to LLVM's `-O2` pipeline: a fixed pass
ordering justified by cascade dependencies, with budget knobs tuned by
experience. The cascade ordering isn't a theorem — it's principled engineering
justified by the dependency structure of the Kleisli tree.

### How the two layers interact

The algebra provides guarantees that the scheduling relies on:

- **Composition closure** means the scheduler can run passes in any order
  without worrying about correctness — any sequence of valid morphisms is a
  valid morphism. The cascade ordering is a performance choice, not a
  correctness requirement.
- **2-cell dominance** feeds the triage step: within a pass, the scheduler
  skips encoders that are dominated by one that already succeeded. The algebra
  provides the partial order; the scheduler uses it to prune the search.
- **Resource composition** gives the budget model: per-leg caps decompose
  additively, and unused budget can be forwarded to the next leg. The algebra
  says costs add; the scheduler decides how to allocate.
- **Grade composition** tells the scheduler which passes can be freely
  reordered (all non-speculative passes have grades that compose via lattice
  join, which is commutative) and which must run last (speculative passes).

In short: the algebra says "these are the rules of the game." The scheduler
says "here's how to play it well." The algebra is domain-independent — it
applies to any `(enc, dec, grade)` reduction pipeline. The scheduler is
domain-specific — it exploits the tree structure of choice sequences with bind
dependencies.

### What this means for naming

"KleisliReducer" names the algebra (specifically, one layer of it — the Kleisli
generalization from §7). But the algebra is infrastructure. The name should
reflect what the system *does* — a structured pass pipeline that cultivates a
tree to its minimal form — not what mathematical framework guarantees its
correctness.

The relationship between algebra and scheduler is like the relationship between
a type system and a compiler optimization pipeline. You don't name GCC's `-O2`
after the Hindley-Milner type system that makes it safe to inline functions. You
name it after what it does to your code. The algebra ensures correctness; the
pipeline delivers performance. The pipeline is the product; the algebra is the
warranty.

---

## Bonsai

An arborist maintains trees for health, safety, and productivity. The goal is a
thriving, well-managed tree. But that's not what the reducer does. The reducer's
goal is **miniaturization while preserving essential character** — make the
choice tree as small as possible while keeping the property failure.

That's not arboriculture. That's bonsai.

Bonsai is the art of cultivating miniature trees. The cultivator starts with
nursery stock — a sapling or collected tree far larger than the eventual
miniature — and, through iterative cycles of cutting, wiring, and root work,
produces the smallest tree that still reads as a tree. The input is always
larger than the output, often dramatically so: a metre-tall nursery tree becomes
a 20cm miniature that still has the essential character of the original. The
discipline is entirely oriented around controlled reduction.

The reducer starts with a failing choice sequence — the "nursery stock" produced
by whatever generation or exploration strategy found the counterexample. This
sequence may be hundreds of entries long, full of incidental complexity that
isn't necessary to reproduce the failure. Through iterative cycles of snipping,
pruning, and training, the reducer produces the shortest sequence that still
fails the property — the bonsai that preserves the essential character (the
failure) in minimal form.

| Bonsai stage | Reducer stage |
|---|---|
| Collect or grow nursery stock | Generation / exploration finds a failing test case |
| Initial heavy structural pruning | Early deletion passes remove large chunks |
| Refinement over successive seasons | Repeated snip → prune → train cycles |
| Mature bonsai (minimal, stable form) | Fixed point — the settled counterexample |

In real bonsai, the cultivator *chooses* stock with an eye toward what it could
become — they see the miniature inside the large tree. The reducer doesn't have
that luxury, and doesn't need it. A bonsai cultivator makes aesthetic judgements:
this branch has better movement, that trunk line is more elegant, this nebari
(root spread) suggests a windswept style. The reducer makes no aesthetic
judgements. There is only shortlex — the total order on choice sequences where
shorter is better, and among equal-length sequences, lexicographically smaller
is better. The "vision" is replaced by an objective function that admits no
ambiguity. Every candidate is either shortlex-smaller (accept) or not (reject).

This is where the metaphor is honest rather than flattering. Bonsai cultivation
is partly vision and partly technique. The reducer has only technique — the
property function is opaque, the shortlex order is mechanical. The scheduling
(snip before prune before train) is the technique doing all the work. There is
no artistic eye; there is only the cascade.

The tree metaphor is already partially present in the codebase: `ChoiceTree`,
`promoteBranches`, `pivotBranches`. Bonsai completes it — naming the goal, not
just the substrate.

### The philosophy

Bonsai cultivation rests on a few principles that map directly onto test case
reduction:

**The tree fights back.** A bonsai wants to grow to full size. Left alone, it
will. The cultivator is constantly working against the tree's natural tendency.
In the reducer: the choice sequence "wants" to be complex enough to produce the
failing output. Re-derivation (regrowth) can produce longer content. The
shortlex guard is the pot that constrains unbounded growth.

**Multiple scales of intervention.** Bonsai has a clear intensity ladder:
maintenance pruning (pinch back a shoot — seconds, trivial) → wiring (bend a
branch into position — moderate, reversible) → structural pruning (remove a
major limb — significant, irreversible) → root pruning and repotting (major
intervention, tree needs recovery time). Each tool has its place; using the
wrong one at the wrong time damages the tree.

**Cyclic and seasonal.** Bonsai is not a single operation — it's a cyclical
process over years. Structural pruning in dormancy, maintenance pruning during
growth, wiring year-round. Each cycle brings the tree closer to the ideal form.
You don't make a bonsai in one session.

**Knowing when to stop.** Over-working a bonsai damages it. The cultivator must
recognise when further intervention would harm rather than improve. The
reducer's fixed-point termination: a full cycle with zero acceptances means the
tree is settled.

### The six operations

#### Snip (contravariant sweep: exact, bottom-up)

*Bonsai: maintenance pruning.* Pinching back new shoots to maintain compact
form. The cultivator works tip by tip with sharp shears, reducing each shoot to
the minimum number of nodes. No structural wood is removed, no new growth is
triggered. The tree's shape doesn't change — just the length of its extremities.

*Reducer: value minimization within fixed ranges.* Each encoder (ZeroValue,
BinarySearchToZero, BinarySearchToTarget, ReduceFloat) operates on individual
entries in the `ChoiceSequence`, reducing their values toward zero. The ranges
are fixed by ancestor nodes — snipping doesn't change them. Bottom-up traversal
(depths max → 0) because leaf values are independent within their inherited
ranges.

*Decoder:* `.direct` — `Interpreters.materialize()` replays the candidate
against the existing tree. No re-derivation, no `GuidedMaterializer`. The
materialized output must fail the property. If it doesn't, the candidate is
rejected and the next one is tried.

*Approximation class:* `.exact` — the decoder reproduces the candidate exactly.
No regression possible. The shortlex guard on encoder output is the only
correctness check needed.

*Why bottom-up:* A leaf at depth 3 can be snipped independently of a leaf at
depth 2, because both are constrained by ranges set by their ancestors, not by
each other. Starting at the deepest depth and working toward the root means
each depth's values are settled before they could influence anything above them
(they can't — information flows root-to-leaf in the Kleisli tree, not
leaf-to-root).

#### Prune (deletion sweep: guided, top-down)

*Bonsai: structural pruning.* Removing whole branches with a concave cutter or
saw. The cut changes the tree's silhouette. What grows back into the gap
(regrowth) may be entirely different from what was removed — the tree fills the
light gap with new shoots that the cultivator can train in a later cycle.

*Reducer: span and subtree removal.* Each encoder (DeleteContainerSpans,
DeleteSequenceElements, DeleteSequenceBoundaries, DeleteFreeStandingValues,
DeleteAlignedWindows, SpeculativeDelete, AdaptiveDeletion) removes structural
elements from the `ChoiceSequence` — container groups, sequence elements,
individual entries. The sequence gets shorter. The gap left by deletion is
filled by re-derivation: `GuidedMaterializer` rebuilds the tree from scratch,
producing new content where the old content was removed. Top-down traversal
(depths 0 → max) because removing a root-level span eliminates entire subtrees
— no point pruning the twigs of a branch you're about to saw off.

*Decoder:* `.guided` — `GuidedMaterializer.materialize()` uses a three-tier
resolution: (1) prefix values from the candidate sequence, (2) fallback tree
values clamped to the new valid range, (3) PRNG-generated values. The
materialized output must fail the property and be shortlex-smaller than the
original.

*Approximation class:* `.bounded` — re-derivation can produce content that
differs from the original (PRNG tier). The shortlex guard on the round-trip
(`reDerivedSequence.shortLexPrecedes(original)`) rejects regressions, but the
result may not be the globally optimal re-derivation.

*Why top-down:* Depth-0 deletions can eliminate entire bind regions, making
deeper deletions moot. Pruning the trunk first avoids wasting budget on branch
deletions that a trunk deletion would have subsumed. The dominance lattice is
invalidated after each successful prune (span positions shift), so the lattice
is rebuilt before the next encoder is tried.

#### Train (covariant sweep: guided, root)

*Bonsai: wiring and root pruning.* Wiring bends branches into new positions —
the downstream growth adapts to the new angle. Root pruning cuts back the root
system during repotting, forcing the canopy to respond with more compact growth.
Both operate at or near the base and propagate outward: the trunk angle
determines where every branch goes, and root constraint determines how large
the canopy can be.

*Reducer: inner-value modification with full re-derivation.* The same encoders
that snip (ZeroValue, BinarySearchToZero, etc.) are applied at depth 0 — the
inner/root values of the Kleisli tree. Changing an inner value shifts the bound
ranges at all downstream depths, because those ranges are derived from the inner
values via `._bind`. The entire tree below the modification point is re-derived
by `GuidedMaterializer`. After training, bound values that were at their local
minima within old ranges may have entirely new ranges — creating new snip and
prune targets for the next cycle.

*Decoder:* `.guided` — same as prune. The fallback tree contains
pre-covariant values (from the snip pass), so re-derivation clamps toward
optimized values rather than random ones. This is why snip runs before train:
snipping populates the fallback tree with good values, reducing re-derivation
regression.

*Approximation class:* `.bounded` — same as prune. Re-derivation is
nondeterministic, but the shortlex guard rejects regressions.

*Why at the root:* Inner values (depth 0) are the independent variables in the
Kleisli tree — they determine everything downstream. Training at the root is
the only way to escape a local minimum where all bound values are individually
optimal within their current ranges, but the ranges themselves could be better.
Changing the root changes the ranges, opening new territory for the next snip
pass.

#### Shape (cross-stage redistribution)

*Bonsai: balance assessment.* The cultivator steps back to assess the whole
tree's silhouette. One side is too heavy; another is too sparse. Shaping
redistributes mass between branches — shortening one limb and letting another
extend — to achieve better overall proportion. No material is added or removed;
it's redistributed.

*Reducer: cross-stage mass transfer between coordinates.* Each encoder
(TandemReduction, CrossStageRedistribute, BindAwareRedistribute) operates on
pairs or groups of entries, reducing one value while increasing another, guided
by the shortlex ordering. Individual entries may be locally minimal (no single
value can be reduced further), but the joint configuration isn't optimal — a
position earlier in the sequence carries more shortlex weight than a position
later, so transferring mass from early to late can improve the overall rank.

*Decoder:* `.crossStage` — routes per-candidate based on whether inner values
changed. If inner values shifted, re-derives via `GuidedMaterializer`; if only
bound values changed, uses `.direct`.

*Approximation class:* `.bounded` — the encoder itself introduces approximation
(moving mass between entries is a heuristic, not a certified improvement until
the shortlex guard confirms it).

*Triggered when:* snip and prune have stalled. The tree's individual branches
are as tight as they can be, but the whole-tree silhouette could still improve.
Shaping addresses a different kind of stall from what training addresses:
training changes the landscape (shifts ranges), shaping changes the
distribution within the current landscape.

#### Top-work (branch promotion: `promoteBranches`)

*Bonsai: grafting.* The cultivator identifies a well-formed branch elsewhere in
the tree, takes a scion (cutting) from it, and grafts it onto the position of
a poorly-formed branch. The source stays; a clone of its structure replaces the
target. The result is a simpler tree — a leggy, over-extended branch structure
replaced with a compact, proven form.

*Reducer: replace a complex pick-site fork with a simpler one.* The encoder
walks the `ChoiceTree`, finds all pick-site groups (forks where every child is a
`.branch` node), sorts them by shortlex complexity of their flattened sequences,
and tries replacing complex forks with simpler forks copied from elsewhere in
the tree. The source fork stays in place; its structure is cloned to overwrite
the target fork. The shortlex guard ensures the replacement produces a smaller
overall sequence. The property check confirms the replacement preserves the
failure.

*Why "top-work":* The current name "promote" describes the effect (the simpler
branch is elevated to the position of the complex one). Top-working describes
the technique: replacing undesirable growth with proven material from elsewhere.
The simpler branch is the scion — the desirable variety grafted onto an
existing position.

#### Re-head (branch pivoting: `pivotBranches`)

*Bonsai: leader selection.* At a fork, one branch is the leader — the dominant
shoot that determines the fork's growth direction. Re-heading selects a
different branch at the same fork to be the leader. The cultivator cuts back the
current leader and lets an alternative take over, choosing the one that produces
the most compact downstream growth.

*Reducer: switch the selected branch at a pick site.* The encoder operates on a
single pick-site group. It takes the current `.selected` branch and tries
switching to alternative branches at the same fork, simplest first. The fork
structure stays the same — all branches remain present — but the `.selected`
marker moves to a different branch. The shortlex guard ensures the new selection
produces a smaller overall sequence. The property check confirms the new leader
preserves the failure.

*Distinction from top-working:* Top-working replaces a fork's entire structure
with material from elsewhere in the tree. Re-heading keeps the fork intact and
changes which arm is active. Top-working is transplanting; re-heading is
redirecting.

### The cultivation cycle

```
top-work / re-head   (branch tactics: promote, pivot)
    │
  snip               (contravariant: exact, bottom-up)
    │
  prune              (deletion: guided, top-down)
    │
  train              (covariant: guided, root)
    │
  shape              (redistribution: overall form adjustment)
    │
(repeat until settled)
```

The cycle orders operations by increasing disruption:

1. **Top-work / re-head** first — structural branch changes that may alter the
   tree's topology before value optimization begins.
2. **Snip** — lightest touch. Exact, shape-preserving. Gets leaf values settled
   so that subsequent operations start from the best available state.
3. **Prune** — heavier. Removes structure. Starting from snipped values means
   the fallback tree carries optimized content, so regrowth (re-derivation)
   regresses less.
4. **Train** — heaviest. Changes the root, re-derives everything. Starting from
   snipped + pruned state means re-derivation has the best possible prefix and
   fallback values.
5. **Shape** — whole-tree rebalancing. Only when local operations (snip, prune,
   train) have stalled — the tree's individual branches are as tight as they
   can be, but the overall form isn't optimal.

### Bamboo: the degenerate case

When `maxBindDepth == 0` (no bind generators), the tree has no branching depth.
There are no bound ranges, no Kleisli chain, no directional dependency between
levels. The choice sequence is a flat list of values — a single stalk with
nodes but no forks.

This is still bonsai, but the specimen is a bamboo.

Bamboo bonsai is a real practice, and the techniques simplify accordingly: you
cut back the height and thin the culm, but there are no branches to wire and no
canopy to balance. The three-pass cascade collapses because its justification
(snip before train because inner values determine bound ranges) doesn't apply
when there are no bound ranges. Snip and train merge into a single depth-0
pass. Pruning runs at one level only. Shaping has no cross-stage coordinates to
redistribute between.

The scheduler doesn't detect this explicitly. Empty legs cost zero iterations.
The cascade machinery runs, finds no work at depths that don't exist, and
converges quickly to the same result a flat reducer would produce. The overhead
is negligible; the generality is free.

### Scope: bonsai is reduction only

Bonsai covers the reduction phase — taking a failing choice sequence and
miniaturizing it. It does not extend upstream to the exploration phase
(`#explore`, `HillClimber`, `DefaultSeedPool`, `NoveltyTracker`). Exploration
is the process of finding nursery stock — growing or collecting a tree that has
the right essential character (a failing test case). Bonsai begins after
exploration hands over a specimen.

The separation is clean: exploration produces a `(ChoiceSequence, Output)` pair
that fails the property. Bonsai takes that pair and returns the shortest
`ChoiceSequence` that still fails. The two phases have different goals
(find vs. minimize), different tools (seed pools and hill climbing vs. encoders
and decoders), and different termination conditions (budget exhaustion vs.
fixed point).

### Supporting vocabulary

| Reducer concept | Bonsai term | Notes |
|---|---|---|
| Contravariant sweep | Snip | Maintenance pruning. Pinch back shoots, preserve form |
| Deletion sweep | Prune | Structural pruning. Remove limbs, regrowth fills the gap |
| Covariant sweep | Train | Wiring / root pruning. Redirect growth from the base |
| Redistribution | Shape | Balance assessment. Redistribute mass between branches |
| Branch promotion | Top-work | Graft a proven scion onto an undesirable position |
| Branch pivoting | Re-head | Select a different leader at an existing fork |
| Re-derivation (GuidedMaterializer) | Regrowth | New shoots filling the gap left by pruning or training |
| Dominance lattice | Triage | Decide which techniques are worth attempting |
| Fixed point / termination | Settled | The tree has reached its minimal form |
| Shortlex guard | The pot | Constrains unbounded regrowth — rejects any candidate larger than the original |
| `ChoiceTree` | The tree | The reified Kleisli tree being cultivated |
| Property failure | Essential character | What must be preserved through miniaturization |

### Why bonsai over arboriculture

"Arborist" was the earlier candidate. It's accurate — an arborist works on
trees, and the reducer works on a tree. But "arborist" describes the *agent*
without specifying the *goal*. An arborist might be maintaining a heritage oak
for longevity, or clearing deadwood for safety, or shaping a hedge for
aesthetics. The word doesn't tell you what kind of tree work.

"Bonsai" specifies the goal: **miniaturization while preserving essential
character**. That's exactly test case reduction. The word carries the entire
problem statement in four syllables.

### Why this works

- **It names the goal, not just the activity.** "Bonsai" says "miniaturize a
  tree while preserving its character." That's the reducer's purpose statement.
- **It names the scheduling, not the algebra.** The Sepulveda-Jimenez algebra
  provides the correctness guarantees underneath, but the algebra is
  infrastructure — it doesn't need to be in the name any more than LLVM's
  lattice-theoretic dataflow framework needs to be in the name of `-O2`.
- **It doesn't borrow precision it can't deliver.** "Kleisli" implies categorical
  formalism. "V-cycle" implies multigrid structure. "Coordinate descent" implies
  homogeneous axes. "Bonsai" implies iterative tree miniaturization, which is
  literally true.
- **The metaphor extends naturally.** Every reducer operation maps to a bonsai
  technique without forcing. The philosophy (cyclic, the tree fights back,
  knowing when to stop) maps without any adjustment.
- **The vocabulary is already partially established.** `ChoiceTree`,
  `promoteBranches`, `pivotBranches` are already tree-cultivation terms. The
  name completes an existing metaphor rather than introducing a new one.
- **The intensity ordering is self-evident.** Snip < prune < train < shape is
  intuitive even to someone unfamiliar with the codebase. The escalation from
  pinching shoots to restructuring the root system is obvious.
- **It's evocative without being obscure.** Bonsai is universally understood.
  The word immediately conjures the right mental image: patience, precision,
  iterative refinement, the interplay between cultivator intent and natural
  growth.

---

## The Full Picture

Bonsai is:

> A principled algebra of reductions (Sepulveda-Jimenez), scheduled by a
> compiler-style pass pipeline (snip → prune → train → shape), tuned by
> heuristics (budget allocation, stall detection, adaptive probing).

Three layers, each with its own character:

```
┌─────────────────────────────────────────────────────────────────┐
│  Heuristics (tuning knobs)                                      │
│  Budget caps, stall patience, dominance lattice thresholds,     │
│  beam search width, adaptive probe stepping.                    │
│  Character: empirical. Tuned by benchmarks.                     │
├─────────────────────────────────────────────────────────────────┤
│  Cultivation process (scheduling)                     ← NAME   │
│  Snip → prune → train → shape → repeat.                        │
│  Cascade ordering justified by dependency analysis.             │
│  Character: principled engineering. Analogous to compiler       │
│  optimization pass ordering.                                    │
├─────────────────────────────────────────────────────────────────┤
│  Reduction algebra (infrastructure)                             │
│  (enc, dec, grade) morphisms. Composition closure.              │
│  2-cell dominance. Resource additivity.                         │
│  Character: algebraic. From Sepulveda-Jimenez.                  │
└─────────────────────────────────────────────────────────────────┘
```

The name should come from the middle layer — the cultivation process — because
that's the layer the user is choosing. The algebra is the warranty; the
heuristics are the tuning. The cultivation process is the product.

"KleisliReducer" names the bottom layer (and only one part of it). "Bonsai"
names the middle layer and the goal — iterative miniaturization of a tree while
preserving its essential character.

---

## Naming in Practice

Bonsai is an internal name. It will eventually replace the legacy reducer
entirely, so there will be no user-facing toggle between "bonsai" and
"non-bonsai" — bonsai is just how reduction works. The name appears in internal
type names, doc comments, and design documents. Users don't need to know the
name; they just get better counterexamples.

### Where the vocabulary appears

The bonsai vocabulary (snip, prune, train, shape, top-work, re-head) should
appear primarily in **documentation and doc comments**, followed by precise
engineering definitions of what each term means in practice. The vocabulary is
a communication tool — it gives contributors and maintainers a shared mental
model for the reduction pipeline. It is not a replacement for precise
descriptions of encoders, decoders, approximation classes, and traversal
orders.

For example, a doc comment on the contravariant sweep might read:

```swift
/// Snip: maintenance pruning (contravariant sweep).
///
/// Minimizes values at bound depths within fixed ranges, working
/// bottom-up from depth max to depth 0. Uses `.direct` decoder
/// (exact materialization against the existing tree). Encoders:
/// ZeroValue, BinarySearchToZero, BinarySearchToTarget, ReduceFloat.
///
/// Structure-preserving: the tree's shape doesn't change, only
/// the values at leaf positions. Approximation class: `.exact`.
```

The bonsai term leads; the engineering definition follows. A reader unfamiliar
with the codebase understands the intent from "maintenance pruning"; a reader
familiar with the codebase gets the precise specification from the rest.

### Internal type names

```swift
// The scheduler becomes Bonsai
enum BonsaiReducer {
    static func run(gen:initialTree:config:property:) -> ...
}

// Configuration
struct BonsaiReducerConfiguration: Sendable { ... }

// Entry point (thin dispatch)
static func bonsaiReduce(gen:tree:config:property:) -> ...
```

### Files affected

- `KleisliReducer.swift` → `BonsaiReducer.swift`
- `ReductionScheduler` → `BonsaiReducer`
- `KleisliReducerConfiguration` → `BonsaiReducerConfiguration`
- `KleisliReducerTests.swift` → `BonsaiReducerTests.swift`
- Settings enums: remove `.useKleisliReducer` (bonsai becomes the default)
- Doc references in `kleisli-reducer-paper-audit.md`,
  `materialized-picks-for-kleisli.md`, and the plan document
- Memory files referencing "Kleisli reducer"

### What stays

The Sepulveda-Jimenez algebra doesn't need renaming. The audit document
(`kleisli-reducer-paper-audit.md`) and plan document
(`principled-test-case-reduction-plan.md`) reference the categorical framework
by its proper academic name. The algebra lives in doc comments and design
documents, not in type names — which is where it belongs.
