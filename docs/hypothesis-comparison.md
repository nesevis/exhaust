# Hypothesis Comparison: What Exhaust's Search is Missing

## The Problem

Exhaust's `SearchCoordinator` currently:

1. Generates a value, recording a `ChoiceTree`
2. Flattens the tree into a `ChoiceSequence` (flat list of structural markers + values)
3. Mutates the flat sequence (perturb values, swap branches, reorder siblings, adjust length)
4. Attempts to **materialize** the mutated sequence back into a value by walking the original generator's tree structure

Step 4 fails for asymmetric generators. When `swapBranch` changes a branch ID from branch 0 to branch 1, the surrounding data in the flat sequence still has the *shape* of branch 0. The materializer either rejects the mismatch or (before the infinite-loop fix) hangs.

Example: `Gen.pick(choices: [(weight: 32, Gen.just(0)), (weight: 1, Gen.choose(in: 1...30))])` — branch 0 produces no choice data; branch 1 needs a value in 1...30. After `swapBranch`, the sequence has branch 1's ID but no data for it to consume.

This is a fundamental architectural limitation: **the flat sequence erases the structural relationship between branch IDs and the data they require**.

---

## How Hypothesis Solves This

Hypothesis (Python's dominant PBT framework) uses what they call an **IR (Intermediate Representation)** approach. The key files are in `hypothesis/internal/conjecture/`.

### 1. Choice Nodes Store Constraints

Each choice point records a `ChoiceNode`:

```python
@dataclass
class ChoiceNode:
    type: str               # "integer" | "boolean" | "float" | "string" | "bytes"
    value: Any              # the actual choice made
    constraints: dict       # the constraints that governed this choice
    was_forced: bool        # whether externally forced
    index: int | None       # position in the sequence
```

The constraints are type-specific:

```python
class IntegerConstraints(TypedDict):
    min_value: int | None
    max_value: int | None
    weights: dict[int, float] | None
    shrink_towards: int
```

**Critical difference from Exhaust**: Hypothesis stores `(value, constraints)` together. Exhaust's `ChoiceSequenceValue.Value` stores `(choice: ChoiceValue, validRanges: [ClosedRange<UInt64>])`, which is structurally similar — but the flat sequence conflates *structural markers* (group open/close, sequence open/close, branch markers) with the data values, making it impossible to replay just the values through a potentially different control flow.

### 2. Replay via Prefix, Not Tree Materialization

This is the core architectural difference.

Hypothesis does **not** try to patch a mutated sequence back into a frozen tree. Instead:

```
mutated choices → prefix of a fresh ConjectureData → re-run the test from scratch
```

When the test function calls `draw_integer(min=1, max=10)`, `ConjectureData._pop_choice()` checks the next prefix value:

```python
def _pop_choice(self, choice_type, constraints, *, forced):
    value = self.prefix[self.index]

    # If type doesn't match, or value is out of bounds:
    if node_choice_type != choice_type or not choice_permitted(value, constraints):
        # MISALIGNMENT: fall back to simplest valid choice
        choice = choice_from_index(0, choice_type, constraints)

    self.index += 1
    return choice
```

Three cases:
- **Value fits current constraints** → use it as-is
- **Value doesn't fit** (misalignment) → substitute the simplest valid choice for the *current* constraints
- **Prefix exhausted** → draw fresh random values from the provider (PRNG)

This means Hypothesis **never needs the mutated sequence to be structurally correct**. The generator re-executes naturally, taking a different path if the prefix leads somewhere new. Misaligned values are quietly replaced with sensible defaults. The run always completes.

### 3. Mutations are Simple Splices

Hypothesis's primary mutation (`generate_mutations_from`) is span-based splicing:

```python
# Find two spans with the same "label" (strategy type)
(start1, end1), (start2, end2) = random.sample(sorted(group), 2)

# Replace both spans with the same sub-sequence
replacement = data.choices[start:end]
attempt = (
    data.choices[:start1] + replacement
    + data.choices[end1:start2] + replacement
    + data.choices[end2:]
)

# Re-run with the spliced prefix
new_data = self.cached_test_function(attempt)
```

They also handle the contained-span case (one span inside another), which amounts to subtree duplication.

No complex tree-aware mutation logic is needed because **the replay mechanism handles misalignment gracefully**.

### 4. The DataTree Tracks Explored Space

Hypothesis maintains a `DataTree` (trie of explored choice sequences). Each `Branch` in the tree stores:

```python
@dataclass
class Branch:
    constraints: dict                     # NOT the value — the constraints
    choice_type: str
    children: dict[ChoiceT, TreeNode]     # values → subtrees
```

`generate_novel_prefix()` walks this tree, at each branch point drawing a value that hasn't been explored yet under those constraints. This guarantees systematic coverage without repeating work.

Key insight: **the tree is indexed by constraints, not by values**. This is what enables the tree to say "at position 3, we need an integer in 1...100, and we've already tried 5, 17, and 42."

---

## Mapping to Exhaust's Architecture

| Hypothesis Concept | Exhaust Equivalent | Gap |
|---|---|---|
| `ChoiceNode(type, value, constraints)` | `ChoiceSequenceValue.Value(choice, validRanges)` | Exhaust already stores constraints! But they're interleaved with structural markers in a flat array. |
| `ConjectureData` with prefix replay | `Interpreters.materialize()` | Exhaust materializes against a frozen tree structure. It needs a "prefix replay" mode that re-runs the generator. |
| Misalignment → simplest valid choice | No equivalent | Exhaust's materializer either matches exactly or fails. No graceful fallback. |
| Prefix exhausted → fresh random | No equivalent | Exhaust doesn't extend beyond the mutated sequence. |
| `DataTree` with constraint-indexed branches | `ChoiceTree` | ChoiceTree stores the full generated structure but isn't used as an exploration trie. |
| Span-based splice mutations | `ChoiceSequenceMutator` (4 strategies) | The mutations themselves are fine — the problem is in replay, not mutation. |

---

## What Exhaust Already Has Right

Exhaust's `ChoiceSequenceValue.Value` stores:
```swift
struct Value {
    let choice: ChoiceValue          // the actual value chosen
    let validRanges: [ClosedRange<UInt64>]  // the valid range constraints
    let isRangeExplicit: Bool        // whether user-specified
}
```

And `ChoiceSequenceValue.Branch` stores:
```swift
struct Branch {
    let id: UInt64            // selected branch
    let validIDs: [UInt64]    // all valid branch IDs
}
```

This is structurally analogous to Hypothesis's `ChoiceNode`. The data is there — it's the *replay mechanism* that's missing.

---

## The Path Forward

### Phase 6: Prefix Replay Interpreter

Instead of materializing against a frozen `ChoiceTree`, add a new interpreter mode that:

1. Takes a mutated `ChoiceSequence` as a **prefix**
2. Re-runs the `ReflectiveGenerator` from scratch
3. At each choice point (`chooseBits`, `pick`, `sequence length`), checks the prefix:
   - If the next prefix entry's type matches and value is in range → use it
   - If misaligned → use the simplest valid value (bottom of valid range, or first branch ID)
   - If prefix exhausted → draw from a PRNG (optionally seeded for determinism)
4. Records a new `ChoiceTree` reflecting the actual choices made (not the prefix)

This is conceptually a new `ValueAndChoiceTreeInterpreter` mode, or a new function alongside `Interpreters.materialize()`. Call it something like `Interpreters.replayPrefix()`.

The signature would look approximately like:

```swift
static func replayPrefix<FinalOutput>(
    _ generator: ReflectiveGenerator<FinalOutput>,
    prefix: ChoiceSequence,
    rng: inout Xoshiro256
) -> (value: FinalOutput, tree: ChoiceTree)?
```

#### Misalignment Handling

At each choice site:
- **`chooseBits`**: If prefix has a `.value(V)` whose `choice` is within `validRanges`, use it. Otherwise use `validRanges[0].lowerBound`.
- **`pick`/branch**: If prefix has a `.branch(B)` whose `id` is in `validIDs`, use it. Otherwise use `validIDs[0]`. **Skip** any prefix entries that belong to the old branch's data (consume until next structural marker at the same depth).
- **`sequence` length**: If prefix has a length value in range, use it. Element sub-sequences are replayed recursively.
- **Structural markers** (`group(true/false)`, `sequence(true/false)`): Match them if present; skip mismatched ones.

The key insight from Hypothesis: **misalignment is normal and expected**. Mutations will often produce sequences that don't structurally match. That's fine — the prefix is a *suggestion*, not a contract.

#### What to Do When a Branch Changes

When `swapBranch` changes a branch ID from A to B:
1. The prefix replay interpreter sees branch B's ID
2. It selects branch B's generator
3. The prefix still has data shaped for branch A — but the interpreter just reads the next prefix entries and applies misalignment rules
4. For the sub-generator under branch B, any prefix values that fit are used; any that don't are replaced with defaults
5. Once the sub-generator finishes, the interpreter resumes from wherever the prefix left off

This naturally handles asymmetric branches because the generator itself dictates the structure — the prefix just provides "hints" for values within that structure.

### Phase 7: Exploration Trie (DataTree Equivalent)

After prefix replay works, add a lightweight trie that tracks:
- At each choice position: the **constraints** (validRanges or validIDs) and which **values** have been explored
- `generateNovelPrefix()` walks the trie, at each node either:
  - Picking a value that hasn't been tried under those constraints, or
  - Traversing into a child that isn't fully exhausted

This replaces the current `NoveltyTracker` (hash + bloom filter approach) with structural, constraint-aware coverage tracking.

This is a larger change and may not be necessary for the immediate performance win. Hypothesis uses it primarily to guarantee exhaustive coverage of small spaces and to avoid repeating work — both valuable, but the prefix replay interpreter alone should unlock effective mutation.

### Phase 8: Strategy Refinement

With prefix replay working, revisit mutation strategies:
- `perturbValues` — should work as-is (values stay within constraints)
- `swapBranch` — now viable because replay handles structural mismatch
- `swapSiblings` — should work as-is (reordering within same generator)
- `adjustSequenceLength` — should work as-is
- **New: splice mutation** (Hypothesis-style) — copy a span from one example and paste it into another at a matching label position. This is Hypothesis's primary mutation and is particularly good at producing duplicate substructures.

---

## Summary of Changes by File

| File | Change |
|---|---|
| New: `Interpreters/Replay/PrefixReplay.swift` | Core prefix replay interpreter |
| `Search/SearchCoordinator.swift` | Replace `Interpreters.materialize()` call in `mutateNext()` with `Interpreters.replayPrefix()`. Remove `materializePicks: true` (no longer needed). Remove `includingAllBranches: true` flattening. Remove debug logging. |
| `Search/InterestingExamplePool.swift` | Store the `ChoiceSequence` from the *actual replay* (not the mutation input), so the pool tracks what was actually explored. |
| `Search/ChoiceSequenceMutator.swift` | No immediate changes; strategies already produce valid mutation candidates. Later: add splice mutation. |
| `Search/NoveltyTracker.swift` | No immediate changes. Later: consider replacing with exploration trie. |
| `Search/ProductivityMonitor.swift` | No immediate changes. `swapBranch` should start producing novel results, which will shift the monitor's strategy weights naturally. |

---

## Verification Plan

1. **Unit tests for prefix replay**:
   - Exact prefix match → same value as direct generation
   - Misaligned value → simplest valid choice used
   - Prefix too short → fresh random values fill remainder
   - Branch swap → new branch's generator used, misaligned data handled
   - Deterministic with same seed + prefix

2. **Integration test**: Run the skewed-config benchmark (`Gen.pick(choices: [(32, Gen.just(0)), (1, Gen.choose(in: 1...30))]).array(length: 8)`) with SearchCoordinator using prefix replay. Expect mutation success rate > 0% and broader distribution than pure generation.

3. **Regression**: All existing tests pass (especially determinism tests for SearchCoordinator and replay independence).
