# State-Machine Testing for Exhaust

## Context

Exhaust currently tests pure properties: generate a value, check an invariant. State-machine testing extends this to sequential, stateful systems — generate a sequence of operations, execute them against a system under test (SUT), and verify that the SUT's behavior matches an abstract model at every step. This is the standard approach for finding order-dependent bugs (cache eviction after specific insert/delete patterns, protocol state corruption from unexpected message sequences, etc.).

The existing architecture already anticipates this: `CoveringArray.swift` references Kuhn, Raunak & Kacker's ordered t-way coverage via concatenated covering arrays. The primitives are in place — `Gen.pick` for command selection, `.array` for sequences, the Reducer's span-based strategies for sequence shrinking. What's missing is the user-facing abstraction that ties them together.

---

## 1. User-Facing API: Macro-Based

The user writes a struct annotated with `@StateMachine`. Macros synthesize protocol conformance, a command enum, and a `ReflectiveGenerator` for the entire command sequence.

### Macros

| Macro | Kind | Purpose |
|---|---|---|
| `@StateMachine` | `@attached(member, extension)` | Scans the struct, synthesizes enum + generator + protocol conformance |
| `@Model` | Property annotation | Marks model state properties |
| `@SUT` | Property annotation | Marks the system under test property |
| `@Command(weight:, #gen(...))` | `@attached(peer)` | Marks a method as a command. `#gen(...)` specifies constant argument generators |
| `@Invariant` | Method annotation | Marks a method as a global postcondition, checked after every command |

### Runtime Functions

| Function | Purpose |
|---|---|
| `skip()` | Throws sentinel — command's precondition failed, skip this step |
| `check(_ condition: Bool)` | Throws postcondition failure if false |

### Motivating Example: Bounded Queue

```swift
@StateMachine
struct BoundedQueueSpec {
    @Model var contents: [Int] = []
    @SUT   var queue = BoundedQueue<Int>(capacity: 4)

    @Invariant
    func countMatches() -> Bool {
        queue.count == contents.count
    }

    @Command(weight: 3, #gen(.int(in: 0...99)))
    mutating func enqueue(value: Int) {
        guard contents.count < 4 else { skip() }
        queue.enqueue(value)
        contents.append(value)
    }

    @Command(weight: 2)
    mutating func dequeue() {
        guard !contents.isEmpty else { skip() }
        let result = queue.dequeue()
        contents.removeFirst()
        check(result == contents.first)
    }

    @Command(weight: 1)
    mutating func peek() {
        guard !contents.isEmpty else { skip() }
        let result = queue.peek()
        check(result == contents.first)
    }
}

@Test func boundedQueueBehavior() {
    #exhaust(BoundedQueueSpec.self, commandLimit: 20)
}
```

### Example with Bundles: Database

```swift
@StateMachine
struct DatabaseSpec {
    @Model var expectedUsers: [UserID: User] = [:]
    @SUT   var db = Database()

    let userIDs = Bundle<UserID>()

    @Invariant
    func userCountMatches() -> Bool {
        db.userCount == expectedUsers.count
    }

    @Command(weight: 3, #gen(.string(), .int(in: 18...65)))
    mutating func createUser(name: String, age: Int) {
        let id = db.createUser(name: name, age: age)
        expectedUsers[id] = User(name: name, age: age)
        userIDs.add(id)
    }

    @Command(weight: 2)
    mutating func deleteUser() {
        guard let id = userIDs.draw() else { skip() }
        db.deleteUser(id: id)
        expectedUsers.removeValue(forKey: id)
    }

    @Command(weight: 1)
    mutating func lookupUser() {
        guard let id = userIDs.draw() else { skip() }
        let user = db.getUser(id: id)
        check(user == expectedUsers[id])
    }
}
```

---

## 2. Synthesized Architecture

The `@StateMachine` macro transforms the user's struct into a full state-machine specification:

### Synthesized Enum

One case per `@Command` method. Cases carry `#gen`-specified arguments as associated values:

```swift
// Synthesized by @StateMachine:
enum Command: CustomStringConvertible {
    case enqueue(Int)
    case dequeue
    case peek
}
```

### Synthesized Generator

A single `ReflectiveGenerator` for the entire command sequence. Each step:
1. `Gen.pick` selects a command type (weighted, recorded as a pick in the ChoiceSequence)
2. `bind` to the command's `run` method — a `ReflectiveGenerator` that generates arguments, executes the command, and handles bundle draws

```
sequenceGenerator =
    fold(1...sequenceLength) { step in
        Gen.pick(choices: [
            (3, Gen.chooseBits(0...99).bind { value in /* run enqueue(value) */ }),
            (2, .just(()).bind { /* run dequeue, including bundle draw */ }),
            (1, .just(()).bind { /* run peek, including bundle draw */ }),
        ])
    }
```

### Bundle Draws as Effects

`Bundle.draw()` is a `chooseBits(0..<bundle.count)` effect inside the command's `run` generator. Since `run` returns a `ReflectiveGenerator`, the bundle draw is part of the Freer Monad computation — not a separate runtime mechanism.

- During **forward generation** (VACTI): evaluates `0..<bundle.count` at interpretation time, when bundle contents are known from prior steps
- During **replay**: reads the index from the ChoiceSequence
- During **shrinking**: the Reducer can shrink the index, or delete the step that populated the bundle (making later draws invalid → candidate rejected)

All choices — command picks, argument values, bundle indices — live in a single ChoiceSequence. No special-casing.

### Argument Generators Are Constant

`#gen(...)` specs in `@Command` attributes are model-independent. This makes coverage and shrinking significantly more tractable:

- **IPOG** can cover `(command_type, arg1, arg2)` tuples, not just command types
- **Reducer** can freely substitute argument values without model-state validity concerns
- **Replay** is deterministic — same generator, same choice sequence position, same value

For referencing existing entities (the main case requiring model-dependent args), use `Bundle<T>` instead. Bundle draws are the only "dynamic" aspect, and they're a constrained form (just an index choice).

---

## 3. Coverage: Sequence Covering Arrays

### The Concatenation Theorem

An SCA guaranteeing every t-way ordered permutation of command types is mathematically equivalent to concatenating s copies of a standard t-way covering array. Exhaust already has IPOG. No new generation algorithm needed.

### How It Works

`StateMachineCoverageRunner` builds a `FiniteDomainProfile` where:
- Each parameter = a position in the command sequence
- Each parameter's domain = the set of command types (finite, typically small)
- Strength = t (typically 2, selected by `bestFitting` against budget)

IPOG generates the covering array. Each row prescribes a command-type ordering. The runner replays each row. Precondition failures → skip that position.

### Budget

For c command types, sequence length L, strength t: IPOG produces roughly c^t × log(L) rows.
- 5 commands, length 10, strength 2: ~40–50 rows
- 10 commands, length 15, strength 2: ~150–200 rows
- 10 commands, strength 3: `bestFitting` drops to strength 2

Fits within `coverageBudget` (default 2000). Remaining budget → random command sequences.

### What SCA Does NOT Cover

SCA covers command-type *ordering*, not argument *interactions* or bundle-draw correlations. "delete before insert" is covered; "delete the entity created by insert" requires bundle draws and random exploration.

---

## 4. Shrinking

### No New Reducer Strategies Needed

| Existing Strategy | Effect on command sequences |
|---|---|
| Delete container spans | Remove entire commands (pick + arguments + bundle draws) |
| Delete free-standing values | Remove individual commands |
| Promote branches | Try simpler command types (earlier pick indices) |
| Simplify/reduce values | Minimize arguments and bundle indices |
| Reorder siblings | Reorder commands |
| Delete aligned sibling windows | Remove batches of similar commands |

### Precondition and Bundle Validity

- `skip()` in a candidate → sequence treated as passing → Reducer tries another candidate
- Bundle draw on a now-empty bundle → `skip()` → same effect
- Removing a step that populated a bundle → later draws become invalid → candidate rejected
- Reducer converges on shortest valid failing sequence naturally

---

## 5. Failure Reporting

```
State machine failure in BoundedQueueSpec (BoundedQueueSpecTests.swift:42)

Shrunk command sequence (10 steps):
  1. enqueue(0)
  2. enqueue(0)
  3. enqueue(0)
  4. enqueue(0)
  5. dequeue → 0
  6. dequeue → 0
  7. dequeue → 0
  8. dequeue → 0
  9. enqueue(0)
 10. peek → 0    ✗ postcondition failed

Invariant `countMatches` passed.
check(result == contents.first) failed at BoundedQueueSpec.swift:28

Model: [0]
SUT:   BoundedQueue(count: 1, readIndex: 4, writeIndex: 1)

Replay seed: 0xA3F7...
```

Requires synthesized `Command: CustomStringConvertible`. Framework captures full execution trace for the shrunk report.

---

## 6. `Bundle<T>`

A framework type for referencing entities produced by prior commands.

- `Bundle<T>()` — create an empty bundle
- `bundle.add(_ value: T)` — store a value (typically in a producing command)
- `bundle.draw() -> T?` — draw a value (returns nil if empty, user calls `skip()`)
- `bundle.consume() -> T?` — draw and remove (for exclusive ownership patterns)

Internally, `draw()` produces a `chooseBits(0..<count)` effect in the Freer Monad. The index is recorded in the ChoiceSequence and shrinkable by the Reducer (shrinks toward 0, preferring earlier-produced values).

Bundles solve the "reference existing entities" problem without model-dependent generators. The drawing mechanism is constant — just an index choice. The pool grows during execution, but the choice structure is trivially constrained.

---

## 7. What Changes vs. What Doesn't

### New code
- `@StateMachine`, `@Command`, `@Model`, `@SUT`, `@Invariant` macros — `Sources/ExhaustMacros/`
- `StateMachine` protocol — `Sources/Exhaust/StateMachine/`
- `Bundle<T>` type — `Sources/Exhaust/StateMachine/` or `Sources/ExhaustCore/`
- `StateMachineCoverageRunner` — `Sources/Exhaust/Macros/`
- `#exhaust` state-machine overload — `Sources/Exhaust/Macros/`
- `skip()`, `check()` runtime functions — `Sources/Exhaust/StateMachine/`

### Unchanged
- `ReflectiveOperation` — no new cases (bundle draws use existing `chooseBits`)
- `ChoiceTreeAnalysis` — SCA bypasses this (operates on command-type domain directly)
- `CoveringArray` / IPOG — reused as-is
- `Reducer` / all 13 shrink strategies — work on command sequences without modification
- `FreerMonad`, interpreters, `ChoiceTree`, `ChoiceSequence` — all unchanged

### Key files to reference
- `Sources/ExhaustCore/Analysis/CoveringArray.swift` — IPOG, reuse for SCA
- `Sources/Exhaust/Macros/CoverageRunner.swift` — pattern for StateMachineCoverageRunner
- `Sources/Exhaust/Macros/Macro+Exhaust.swift` — macro pattern
- `Sources/ExhaustCore/Core/Combinators/Gen+Choice.swift` — `Gen.pick`

---

## 8. Open Questions

1. ~~**Macro form for invocation**: `#stateMachine(Spec.self)` vs `#exhaust(Spec.self)` overload vs something else.~~ **Resolved**: `#exhaust(Spec.self, commandLimit: N)` overload.

2. **Async execution**: Supporting `async` command methods. Deferred but worth considering early.

3. **Parallel command sequences**: Interleaving commands from multiple threads. Separate feature; SCA foundation extends to multi-dimensional SCAs.

4. **`#explore` integration**: State-aware scoring (trace → score). Deferred to v2; the generator feeds into `ExploreRunner` naturally.

5. **SCA + argument coverage**: With constant generators, IPOG could cover `(command_type, arg_values)` tuples — not just orderings. Worth exploring whether this yields better fault detection per iteration.

6. **Bundle.consume() semantics**: Does consuming remove from the bundle permanently (affecting all future steps), or only for the current draw? Hypothesis uses permanent removal.
