# Branch Promotion Failure in the Kleisli Reducer

## Problem

`promoteBranches` produces no candidates in the Kleisli reducer, even when the
initial tree is fully materialized with all branch alternatives present. The
Calculator shrinking challenge demonstrates this: the Kleisli cannot collapse
recursive expression depth, while the legacy reducer does so in 14 invocations.

## What we know

The initial tree passed to the Kleisli IS fully materialized — debugger output
confirms all 3 branches (value, add, div) at every pick site, with `✅` marking
the selected branch. This rules out the `materializePicks` theory.

The `PromoteBranchesEncoder.encode` produces candidates by:
1. Extracting all branch group nodes from the tree
2. Sorting by shortlex complexity (flattened with `includingAllBranches: true`)
3. Trying to replace complex branches with simpler ones
4. Flattening the modified tree and checking `shortLexPrecedes`

The legacy reducer's `ReducerStrategies.promoteBranches` uses identical logic and
succeeds (14 property invocations, collapsing 4 levels to 2).

## Impact

The Calculator shrinking challenge demonstrates the issue. The expression
`div(value(-9), div(value(6), div(value(6), div(value(-1), value(6)))))` has
4 levels of recursion, each with a pick site choosing between `value`, `add`,
and `div`.

**Legacy reducer** (with materialized picks): `promoteBranches` collapses the
inner `div(div(div(...)))` to `add(value(10), value(-10))` in one step (14
invocations). The final result is `div(value(0), add(value(0), value(0)))` —
depth 2.

**Kleisli reducer** (without materialized picks): `promoteBranches` produces no
candidates. The reducer can only zero values, reaching
`div(value(0), div(value(0), div(value(0), div(value(0), value(-1)))))` — all
4 levels preserved, none collapsed.

## What needs to happen

The tree passed to both reducers must have full branch alternatives at every pick
site. The fix belongs in `MacroSupport.swift` (line 570), after
`Interpreters.reflect(gen, with: value)` produces the reflected tree.

The reflected tree must be replayed through `ValueAndChoiceTreeInterpreter` with
`materializePicks: true` to produce a tree with all branch alternatives. The
challenge: VACTI generates from a seed, not from an existing sequence. The
reflected sequence needs to be fed as a deterministic source of choices.

Options:

1. **Add a `materializePicks` parameter to `Interpreters.materialize(gen, with:, using:)`**
   — the tree-driven materializer already visits every pick site. Adding a flag to
   record non-selected branches alongside the selected one would produce the needed
   tree without requiring VACTI.

2. **Add a replay-from-sequence mode to VACTI** — accept a `ChoiceSequence` as
   the source of choices (instead of PRNG), with `materializePicks: true`. This
   is conceptually clean but requires a new VACTI init or a separate interpreter.

3. **Post-process the tree** — walk the reflected tree and the generator together,
   adding branch alternatives from the generator's `.pick(choices)` operations at
   each pick site. This doesn't require any interpreter changes but duplicates
   logic from VACTI/GuidedMaterializer.

Option 1 is the smallest change: `Interpreters.materialize` already has the
generator, tree, and sequence. At each `.pick` operation, it currently selects the
matching branch and continues. With `materializePicks: true`, it would also record
the non-selected branches in the output tree.

## What needs investigation

The tree is fully materialized, so the issue is NOT `materializePicks`. Possible
causes to investigate:

1. **Materialization failure**: `Interpreters.materialize(gen, with: candidateTree,
   using: candidateSequence, strictness: .relaxed)` may return nil for all promoted
   candidates. The promoted tree has a different recursive structure than the
   generator expects. Add logging to the branch leg to see how many candidates are
   produced and how many fail materialization vs shortlex check vs property check.

2. **Shortlex comparison mismatch**: The encoder flattens the promoted tree via
   `ChoiceSequence.flatten(candidateTree)` (selected-only). If the candidate
   sequence is the same length as the original but with different branch selections,
   the shortlex comparison might reject all candidates. Check whether any candidate
   passes `candidateSequence.shortLexPrecedes(sequence)`.

3. **Tree/sequence mismatch**: The scheduler's `sequence` might not match
   `ChoiceSequence.flatten(tree)` if a previous `accept` re-derivation changed
   one without the other. In cycle 1 this shouldn't apply (no prior accept), but
   verify by comparing `sequence` and `ChoiceSequence.flatten(tree)` at the start
   of the branch leg.

4. **GuidedMaterializer stripping alternatives**: After `accept(structureChanged: true)`,
   the tree is re-derived by GuidedMaterializer, which only records selected branches.
   This only affects cycles 2+, not cycle 1. But if cycle 1's `zeroValue` or another
   encoder triggers `accept` before branches run... branches run FIRST (pre-cycle),
   so this shouldn't apply. Verify execution order.

## Reflection path (separate concern)

Trees from reflection (`Interpreters.reflect(gen, with: value)`) DO only record
the selected branch. For generators with picks, the reflected tree will have
`.group([.selected(branch)])` — one element per group. `promoteBranches` requires
`branches.count >= 2`, so it silently produces no candidates.

This is a real issue for the `.reflecting(value)` path, but it's separate from the
Calculator failure (which uses `.replay(seed)` and gets a fully materialized tree).
The fix for reflection belongs in `MacroSupport.swift` (line 570) — re-derive the
reflected tree with `materializePicks: true` before passing to the reducer.
