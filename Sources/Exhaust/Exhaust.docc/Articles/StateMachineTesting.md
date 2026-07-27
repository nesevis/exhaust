# State machine testing with Exhaust

This guide covers testing stateful systems, things with mutable internal state where bugs emerge from sequences of operations rather than single calls. If you've read the <doc:GettingStarted>, you're familiar with `#exhaust` for pure functions. `@StateMachine` is the equivalent for objects with memory. For pure functions over a generator rather than a stateful system, reach for <doc:PropertyTesting> instead.

## When to reach for @StateMachine

A stack, a database connection pool, a bounded queue, an authentication session, an undo stack. These all share a trait: calling `push` alone can't find the bug. The bug lives in `push, push, pop, pop, push, pop`, a specific ordering that leaves the data structure in a state that shouldn't be reachable.

Unit tests for stateful systems tend to be manually-scripted scenarios: set up some state, run a sequence you thought of, assert. State machine testing generates the sequences instead. Exhaust picks the operations, picks their arguments, runs them in generated order, and checks that your invariants hold after every step. When something breaks, you get a minimal sequence that reproduces the failure, often three or four operations where you'd have written a twenty-step test to find the same bug by hand.

## Quick reference

One spec shape serves every mode. Which mode you pass to `#execute` depends on what your system under test is built on:

| Your system under test | How to run it | What it finds |
|---|---|---|
| Synchronous class | `#execute(Spec.self, mode: .sequential)` | Logic bugs: ordering, invariant violations, state corruption |
| Async class with `await` boundaries | `#execute(Spec.self, mode: .tasks)` | Reentrancy and interleaving bugs at `await` boundaries |
| Class with locks, GCD, or atomics | `#execute(Spec.self, mode: .threads)` | Data races in synchronous primitives, which a task-based run steps over |

Moving a spec from one row to the next needs no change to the spec. The rest of this guide walks through each case.

## The shape of a spec

A spec has four required parts: a system under test, commands that operate on it, invariants that must always hold, and a `failureDescription()` method that supplies diagnostic state for failure reports. Optionally, you can maintain a reference model alongside the SUT that commands update in lockstep, so invariants can compare the two.

```swift
@Test func stackBehavesCorrectly() async {
    await #execute(StackSpec.self, mode: .sequential, .commandLimit(15))
}

@StateMachine
final class StackSpec {
    var expected: [Int] = []
    @SystemUnderTest
    var stack = MyStack<Int>()

    @Invariant
    func contentsMatch() -> Bool {
        stack.elements == expected
    }

    @Command(weight: 3, .int(in: 0...9))
    func push(value: Int) throws {
        expected.append(value)
        stack.push(value)
    }

    @Command(weight: 2)
    func pop() throws {
        guard expected.isEmpty == false else { throw skip() }
        let modelValue = expected.removeLast()
        let sutValue = stack.pop()
        try check(modelValue == sutValue, "pop values should match")
    }

    func failureDescription() -> String? {
        "expected: \(expected), stack: \(stack)"
    }
}
```

Each `@Command` method is one operation Exhaust can choose to run. The `weight:` parameter controls how often it appears relative to other commands. A weight-3 command shows up roughly three times as often as a weight-1 command. After every command, all `@Invariant` methods are checked automatically.

Specs must be a `final class`. `@StateMachine` takes no arguments, because how the commands run is a question for the call site: `#execute(StackSpec.self, mode: .sequential)` runs them one at a time and checks `@Invariant` after each step, `mode: .tasks` interleaves them at `await` boundaries, and `mode: .threads` dispatches them to real OS threads. The concurrency sections cover the last two. Every example until then runs one command at a time, which is the most common way to run a spec.

## Models and invariants

A model is a simpler reference implementation maintained alongside the SUT. It is just a plain property — not a macro or special annotation. The model's job is to make invariants trivial to write: with a model, the invariant is just `sut.value == model.value`. Without one, invariants have to derive expected behaviour from the SUT's current state alone.

You don't have to use a model. Specs that only need structural invariants (count within bounds, no duplicates, LIFO ordering) work fine without one.

### Failure descriptions

When a spec fails, Exhaust calls `failureDescription()` to include diagnostic state in the failure report. Every spec must declare it, and the return type must be the optional `String?` (a non-optional `String` does not satisfy the requirement). Include model state, computed diagnostics, or both; return `nil` to omit diagnostic state from the report:

```swift
func failureDescription() -> String? {
    "expected: \(expected), queue: \(queue)"
}
```

## Commands, skip, and check

Commands come in three flavours.

**Commands with generated arguments** use generator expressions in the `@Command` attribute:

```swift
@Command(weight: 3, .int(in: 0...20))
func put(value: Int) throws {
    guard queue.count < queue.capacity else { throw skip() }
    expected.append(value)
    queue.put(value)
}
```

The generator expression (`.int(in: 0...20)`) produces the argument. Multiple arguments get multiple generators, separated by commas.

**`skip()` is a precondition guard.** When a command's precondition fails (popping an empty stack, draining an empty pool), throw `skip()` rather than letting the command execute in an invalid state. Skipped commands don't count as failures. When a failing sequence is found, skipped commands are pruned from it before reduction, so the counterexample only contains commands that contributed to the failure.

**`check(_:_:)` is a postcondition assertion.** It runs inline within the command body, verifying a condition that should hold immediately after the operation:

```swift
@Command(weight: 2)
func get() throws {
    guard queue.isEmpty == false else { throw skip() }
    let expectedValue = expected.removeFirst()
    let actual = queue.get()
    try check(actual == expectedValue, "get must return elements in FIFO order")
}
```

The distinction between `@Invariant` and `check`: invariants run after every command (including commands that didn't write the check). Postconditions run only inside the command that defines them. Use invariants for properties that must always hold. Use postconditions for return-value checks and per-operation guarantees.

## Referencing entities from earlier commands

Some commands operate on things a previous command created: delete a user that `createUser` made, merge a heap into another heap, withdraw a token that was deposited. The command can't take the entity itself as an argument, because the entity doesn't exist until the sequence runs.

The pattern is to take a plain generated index and resolve it against spec-owned state inside the command:

```swift
@StateMachine
final class DatabaseSpec {
    var userIDs: [UserID] = []
    @SystemUnderTest var db = Database()

    @Command(weight: 3, .string(), .int(in: 18...65))
    func createUser(name: String, age: Int) {
        userIDs.append(db.createUser(name: name, age: age))
    }

    @Command(weight: 2, .int(in: 0...99))
    func deleteUser(index: Int) throws {
        guard userIDs.isEmpty == false else { throw skip() }
        let id = userIDs.remove(at: index % userIDs.count)
        db.deleteUser(id: id)
    }

    func failureDescription() -> String? {
        "live users: \(userIDs)"
    }
}
```

The wrap-around (`index % userIDs.count`) means any index range works: the range's width only affects how evenly selection spreads. Guard on empty and `skip()` when there is nothing to reference yet. To reference without destroying, subscript instead of removing. For reference types, resolving the same index twice yields the same object, so aliasing scenarios (merging a heap with itself, say) come for free.

Keep this state on the spec, next to the model. A command's behaviour then depends only on its arguments and the spec's own state, which is what reduction and replay rely on: remove a `createUser` from the sequence and every later `deleteUser` still resolves to *some* live user, rather than crashing or silently targeting stale storage.

## Generated setup with @Setup

Some specs need a generated starting configuration: a table created with generated options before any record command runs, a queue whose capacity should vary across probes. Without `@Setup`, the workarounds are duplicating the spec type per configuration, or promoting configuration to a `@Command` that every other command must `skip()` around until it lands, which wastes most of the discovery budget on sequences that never reach the interesting state.

`@Setup` marks one method whose parameter values Exhaust draws from the attribute's generators, exactly like a command:

```swift
@StateMachine
final class BoundedQueueSpec {
    var model: [Int] = []
    @SystemUnderTest var queue: BoundedQueue?

    @Setup(.int(in: 1 ... 32), .int(in: 0 ... 9).array(length: 0 ... 8))
    func configure(capacity: Int, preload: [Int]) {
        let queue = BoundedQueue(capacity: capacity)
        for value in preload where queue.enqueue(value) {
            model.append(value)
        }
        self.queue = queue
    }
    // ...
}
```

The setup method runs once on every fresh spec instance, before any command, on every execution model. Its values replay from seeds and reduce with the counterexample: reduction first minimises the setup value with the command sequence held fixed, then reduces the commands with the setup held fixed, so Exhaust reports the failure at the simplest configuration that still fails. The reduced value is available programmatically as ``StateMachineResult/setup``, and the trace renders it ahead of the commands:

```
1. configure(capacity: 1, preload: []) (setup)
2. enqueue(value: 0) ✗ invariant 'countMatchesModel'
```

Setup consumes generated values, so it counts as a step in the report's header: the trace above is reported as two steps, not one.

The rules, and how setup differs from a command:

- A spec allows at most one `@Setup` method. Multi-phase setup merges into one method whose body runs the phases in order.
- Setup cannot `skip()`, reduction never deletes it, and Exhaust does not check invariants after it: setup is construction, and the first command's invariant check is the first model-versus-SUT assertion. A setup throw fails the run. A setup domain that admits throwing values is a generator problem worth surfacing.
- Setup runs on every probe: every screening row, every sampling iteration, every reduction probe, and once per spec instance that a concurrent probe constructs. Keep it cheap. Fixed, non-generated construction belongs in `init()`, and teardown belongs in `deinit`, both of which work today without `@Setup`.
- A `@SystemUnderTest` property only needs to become `Optional` when the SUT's own construction consumes generated values, as above. A setup that mutates an already-constructed SUT keeps a non-optional property with its default initialiser.
- Adding `@Setup` to an existing spec stops its recorded regression seeds reproducing, so they need re-recording. Specs without `@Setup` are unaffected.

## Running the test

```swift
@Test func queueMaintainsFIFOOrder() async {
    await #execute(CircularQueueSpec.self, mode: .sequential, .commandLimit(10), .budget(.thorough))
}
```

`#execute` is always awaited, so the test function must be `async`. This holds for every mode, including a run whose commands are all synchronous.

Exhaust first runs a screening phase that systematically covers command-type orderings (every pairwise combination of command types at each position), then switches to random sampling. If a failure is found in either phase, the reducer reduces the command sequence to a minimal counterexample.

The failure report shows the reduced sequence and the execution trace:

```
State machine failure (found via screening)

Command sequence (4 steps, reduced from 8):
  1. put(7) [ok]
  2. put(12) [ok]
  3. put(5) [ok]
  4. get() ✗ get must return elements in FIFO order

State: expected: [12, 5], queue: BuggyCircularQueue(count: 2, capacity: 6)

Reproduce: .replay("3JK4M2-5")
```

The replay seed lets you re-run the exact same sequence deterministically for debugging.

`.commandLimit(N)` sets the maximum length of generated command sequences. When omitted, Exhaust estimates a limit from the command domain size and the screening budget: the estimate's budget-derived ceiling tops out at 100, with a floor of three appearances per command type. `mode: .tasks` caps the estimate at 40. A spec that declares an `@Equivalence` gets a flat 10 under either concurrent mode, the same default `mode: .threads` uses, because both then search the orders a run could have taken and that search grows multinomially in the sequence length. Longer sequences explore deeper states but take longer to test and to reduce. Specs with expensive command bodies (I/O, network calls, heavy computation) should use a lower limit, since the per-command cost multiplies across every screening row and every reduction probe.

## Your SUT uses async/await

When the system under test has async methods (actors, network services, databases), make the commands `async`. Async commands run one at a time in the default mode, exactly as synchronous ones do:

```swift
@StateMachine
final class AsyncCounterSpec {
    var expected: Int = 0
    @SystemUnderTest
    var counter: AsyncCounter = .init()

    @Invariant
    func valueMatches() -> Bool {
        counter.value == expected
    }

    @Command(weight: 3)
    func increment() async throws {
        expected += 1
        await counter.increment()
    }

    @Command(weight: 2)
    func decrement() async throws {
        guard expected > 0 else { throw skip() }
        expected -= 1
        await counter.decrement()
    }

    func failureDescription() -> String? {
        "expected: \(expected), counter: \(counter)"
    }
}
```

The test call needs `await`:

```swift
@Test func counterBehavesCorrectly() async {
    await #execute(AsyncCounterSpec.self, mode: .sequential, .commandLimit(10))
}
```

Exhaust detects async methods and generates the correct conformance automatically.

### Actors as the system under test

An `actor` cannot be a spec — actor isolation serialises every command, so no mode could interleave them, and the macro rejects the declaration. What an actor can be is the `@SystemUnderTest` of an ordinary `final class` spec, and that combination is fully supported, including under `mode: .tasks`: the scheduler drives a default actor's suspensions the same way it drives any other `await`, which is exactly what reaches actor reentrancy bugs — a method that checks isolated state, suspends, and acts on the stale answer. An actor with a custom executor is the exception: its continuations leave the scheduler's control, and the run reports an idle timeout rather than an interleaving.

## Finding concurrency bugs in async code

The runs shown above take one command at a time. Some bugs only show up when two operations overlap. Under `mode: .tasks`, Exhaust runs the commands concurrently across lanes and controls the interleaving itself, deterministically, at every `await` suspension point.

```swift
@Test func counterIsSafeUnderConcurrency() async {
    await #execute(
        NonAtomicCounterSpec.self,
        mode: .tasks,
        .parallelize(lanes: .two),
        .commandLimit(6),
        .budget(.thorough)
    )
}
```

The same seed always produces the same interleaving, and the reducer reduces both the command sequence and the lane assignments, discovering the minimal concurrency needed to trigger the bug.

> Note:
> Mark test suites that use `mode: .tasks` as `.serialized`. The drain loop that interleaves the lanes occupies a thread while it runs, and several such suites running in parallel can starve the shared thread pool.

A typical failure report:

```
Concurrent spec failure (found via random sampling)

Reduced from 6 to 3 steps.

Sequential prefix:
  1. refill

Lane A:
  1A. tryConsume

Lane B:
  1B. refill

Execution trace:
  1. refill (prefix)
  2. 1A tryConsume (started)
  3. 1A tryConsume (suspended)
  4. 1B refill (completed) ✗ invariant 'matchesModel'

Reproduce: .replay("7MK2N9-4")
```

The trace shows exactly where the interleaving happened. The reducer drove the first `refill` command from a concurrent lane into the sequential prefix (proving it doesn't need to be concurrent), leaving only `tryConsume` and the second `refill` as the concurrent pair that triggers the race.

### Which claims survive a change of order

Concurrency brings in an order the default mode never has to think about. Once the commands could have run in more than one order, some of a spec's claims stop making sense.

An `@Invariant` is a claim that holds whatever order the commands ran in. Exhaust checks it wherever it has a settled state to check against — after each command in the default mode, at every point where no lane sits mid-command under `mode: .tasks`, and along the sequential replays under `mode: .threads`.

Not every claim is like that. Two increments commute, so `counter.value == expected` holds however they interleave, and it is a true invariant. Two writes to the same register do not commute, so which value survives depends on which write landed last, and a comparison against one fixed expectation would fail for a register with nothing wrong with it. A claim of that shape belongs in an `@Equivalence`. Exhaust judges one by re-running the commands sequentially and accepting the concurrent run when some valid order produces an equivalent result. The `mode: .threads` section below covers how to write one.

One question sorts them. Could a different valid order change this check's answer? If it could, the check is an equivalence rather than an invariant.

### Invariants run when no lane is mid-command

Every lane runs against one spec instance, so the model is shared. A command body updates the model and then calls the system under test, and when that call suspends, the model has moved and the system under test has not. An invariant comparing them is false at that instant for a system under test with no defect at all.

Exhaust therefore checks invariants only when no lane is inside a command body. A command that completes while another lane sits mid-update records as completed and defers the check. Whichever command finishes last always runs it, so every probe is checked at least once with the model and the system under test back in agreement.

What that costs is a violation that exists only while another lane is suspended and heals before that lane returns. For a model-versus-system invariant, that transient state is not a defect. For a structural invariant over the system under test alone (`count >= 0`), the window between two lanes goes unobserved.

Settling the state before comparing does not rescue a claim whose answer depends on the order. That claim is still wrong under some of the orders the scheduler can produce, and it wants an `@Equivalence` instead. Declaring one here is optional, and it adds the linearizability check the next section describes, run against an interleaving a seed reproduces rather than whatever the OS chose.

### What the scheduler can and cannot find

A task-based run interleaves at `await` suspension points, wherever a command body suspends via `Task.yield()`, an actor call, or anything else that suspends. It cannot interleave within synchronous code. A race between two statements with no `await` between them is invisible to it.

A system under test whose race sits at a suspension point (the `let v = state; await Task.yield(); state = v + 1` pattern) is exactly what `mode: .tasks` finds well. One whose race is in synchronous code behind an async facade (locks, dispatch queues, atomics) needs `mode: .threads`.

### Lane count

`.parallelize(lanes:)` controls how many concurrent lanes commands are distributed across. The default is 2, which suffices for most data races. A study of 105 real-world concurrency bugs in MySQL, Apache, Mozilla, and OpenOffice found that 96% manifest with just two threads (Lu et al., [Learning from Mistakes](https://dl.acm.org/doi/10.1145/1346281.1346323), ASPLOS 2008). Use three or more when you suspect the bug requires three-way interleaving (for example, ABA problems or three-participant lost updates). The maximum is four.

`.parallelize(lanes: .one)` runs everything sequentially, useful as a baseline to confirm that the bug genuinely requires concurrency to manifest.

### Idle timeout

If a command body suspends onto an executor Exhaust does not drive (a custom-executor actor, `Task.sleep`, blocking I/O), the drain loop stalls because the continuation never arrives back. The `.idleTimeout(.seconds(2))` setting (default) bounds that wait so a stalled probe cannot wedge the run.

A timed-out probe counts as a **pass**, not a failure. The timeout cannot distinguish a hung system from a machine under load, and treating it as a counterexample would let a busy CI runner manufacture failures. What surfaces instead is a runtime warning once timed-out probes reach a quarter of those attempted, reporting the rate so a run that never exercised the system does not pass silently.

The consequence is worth stating plainly: a spec that deadlocks does not fail on that account. If the deadlock is reliable, most probes time out, the warning fires, and the rate tells you. If it only happens on a few interleavings, the run can stay under the threshold and pass. A green run with a nonzero timeout count is not evidence of liveness.

## Finding concurrency bugs in threaded code

Some systems use synchronous concurrency primitives internally (`os_unfair_lock`, `DispatchQueue`, atomics, `NSLock`), with or without an async facade on top. A task-based run treats the code between two `await`s as atomic, so it steps straight over these races.

`mode: .threads` dispatches the commands to real OS threads and lets the operating system interleave them at any instruction. That reaches races inside the synchronous primitives a task-based run cannot see.

The trade-off is determinism. The OS chooses the interleaving, so the same seed no longer reproduces the same run. Exhaust compensates with repetition: during reduction it runs each candidate sequence many times to keep the race reproducing, and it confirms every reported failure by replaying it across the valid orders before believing it.

Real-thread scheduling leaves no settled intermediate state for an invariant to be checked against, so Exhaust checks invariants where one command runs at a time. Every probe replays the same commands sequentially and checks invariants after each of them, and the linearizability search checks them again along each order it tries. A failure in that first replay is a bug needing no interleaving at all, and the report says so.

### Equivalence and linearizability

A concurrent run is correct when everything it observed could have come from running the same commands one at a time, in some order that keeps each lane's own commands in the order that lane issued them and never reorders two commands when one had observably returned before the other began. That property is called linearizability, and it is what a thread-based run checks. Exhaust timestamps every command's call and return, so an order that inverts observed real-time precedence is never accepted as an explanation, and a command that reads stale state after another lane's write has provably completed is caught rather than explained away.

Two things get compared against each candidate order: what every command returned, and the final state. Exhaust captures the return values for you — a `@Command` that returns a value (`func getOrElse(key:) -> Int`) has its result recorded per lane during the concurrent run. The final state is compared through an `@Equivalence` you write:

```swift
@StateMachine
final class RacyCounterSpec {
    @SystemUnderTest
    var counter: RacyCounter = .init()

    @Equivalence
    func valuesMatch(other: RacyCounter) -> Bool {
        counter.value == other.value
    }

    @Command(weight: 3)
    func increment() throws {
        counter.increment()
    }

    @Command(weight: 2)
    func decrement() throws {
        guard counter.value > 0 else { throw skip() }
        counter.decrement()
    }

    func failureDescription() -> String? {
        "\(counter)"
    }
}
```

An `@Equivalence` method defines what "the same result" means for your system under test. To confirm a suspected failure, Exhaust enumerates the valid sequential orders, replays the commands on a fresh instance for each one, and checks the recorded return values and the equivalence's verdict on the final state. If any order reproduces what the concurrent run observed, that run was linearizable and Exhaust discards it. If none does, the bug is real.

Checking every order, instead of one fixed order, is what keeps order-independent operations from reporting false positives. Two `set("key", to:)` commands on a lock-synchronised store can land in either order. Both are valid while the two overlap in time, so whichever the threads chose, some ordering reproduces it; once one has observably returned before the other starts, only the real order counts. A check that only compared against array order would flag the other half of the overlapping runs as failures.

Capturing return values is what catches bugs the final state hides. A hash map whose buggy `delete` resurrects a key can settle into a final state that coincidentally matches a valid ordering, while a `getOrElse` caught mid-race returns a value no ordering would ever produce. The final-state comparison alone passes that run. The recorded response does not.

When no ordering reproduces a return value, the report names the command that returned it:

```
LoweHashMapSpec failure (iteration 141/2000, found via random sampling, seed 1C3-141)

Reduced from 8 to 5 steps.

Sequential prefix:
  1. update(1, 4)

Lane A:
  1A. update(0, 0)
  2A. getOrElse(1) → -1  ← no sequential ordering reproduces this response

Lane B:
  1B. update(1, 0)
  2B. delete(0)

Execution trace:
  1. update(1, 4) (prefix)
  2. 1B update(1, 0)
  3. 2B delete(0)
  4. 1A update(0, 0)
  5. 2A getOrElse(1) → -1  ← no sequential ordering reproduces this response

Expected state (from sequential replay):
  map: [0: 0, 1: 0]

Actual state (from concurrent execution):
  map: [1: 0]

Command sequences tested: 792

Reproduce: .replay("1C3-141")

* Preemptive scheduling depends on OS thread timing and may not reproduce on every run. Run the test repeatedly to reproduce.
```

The `→` annotation on each lane command shows what it returned during the concurrent run. The marked command is the one whose response no valid ordering reproduces: `getOrElse(1)` returned `-1` (not found) because it ran while the racing `update(1, 0)` had left key 1's slot mid-write, and no sequential ordering of these commands ever loses key 1. When the divergence is only in the final state, with no single command to blame, there is no marker and only the expected-versus-actual block appears.

The equivalence compares final state rather than intermediate state. That is the right trade-off for non-deterministic scheduling: a comparison against intermediate state would fail whenever the OS interleaved in a valid but unexpected order, whereas a command's return value is a real observation that some valid order has to be able to explain.

An `@Equivalence` is required under `mode: .threads`, and Exhaust says so at the start of the run rather than part-way through it. Invariants are welcome alongside it, judged in the sequential replays described above.

> Important: Under `mode: .threads`, every lane's commands run against one shared spec instance on real OS threads. The system under test is expected to defend itself, because that is the claim under test. Anything else a command body touches has to be thread-safe or absent.
>
> An unsynchronised model property written from two lanes at once is a data race, which is undefined behaviour rather than a false positive: two threads growing the same array can corrupt memory. ThreadSanitizer reports that case, and it is the quickest way to tell it apart from a real race in the system under test. A model built to take concurrent access — a collection behind a `Mutex`, an atomic counter — is genuinely shared and works as written.
>
> The system under test must also be a reference type. A value type reached through the shared spec has nothing to defend. Exhaust reports both requirements when the run starts, before any command executes.

Running the test:

```swift
@Test func counterIsThreadSafe() async {
    await #execute(
        RacyCounterSpec.self,
        mode: .threads,
        .parallelize(lanes: .two),
        .commandLimit(6),
        .budget(.thorough)
    )
}
```

### Async commands under mode: .threads

`mode: .threads` also works when command bodies are `async`. Each lane gets a real OS thread, and Exhaust bridges the async execution onto it. That catches races in synchronous primitives hidden behind an async facade:

```swift
@StateMachine
final class AsyncRacyCounterSpec {
    @SystemUnderTest
    var counter: AsyncRacyCounter = .init()

    @Equivalence
    func valuesMatch(other: AsyncRacyCounter) -> Bool {
        counter.value == other.value
    }

    @Command(weight: 3)
    func increment() async throws {
        await counter.increment()
    }

    func failureDescription() -> String? {
        "\(counter)"
    }
}
```

### Which concurrent mode?

When both could find the bug, prefer `mode: .tasks`. Deterministic interleaving means faster reduction and reproducible seeds, and an `@Equivalence` works there too: the same linearizability check runs against an interleaving a seed reproduces, so a counterexample comes back on every run rather than on some of them. Reach for `mode: .threads` when the race is inside synchronous primitives a task-based run cannot see.

## Settings reference

All settings are passed as variadic arguments to `#execute`:

| Setting | Default | Effect |
|---------|---------|--------|
| `.commandLimit(N)` | auto-estimated (10 with an `@Equivalence`) | Maximum commands per generated sequence. Estimated from the command domain and screening budget. `mode: .tasks` caps the estimate at 40, and a spec that declares an `@Equivalence` gets a flat 10 under either concurrent mode. |
| `.parallelize(lanes:)` | 2 | Number of concurrent lanes (1 through 4). |
| `.budget(.thorough)` | `.standard` | Controls screening rows and random sampling iterations. |
| `.idleTimeout(.seconds(2))` | `.seconds(2)` | Wall-clock bound on a stalled probe: a drain-loop stall under `mode: .tasks`, a wedged lane or a deadlocked system under test under `mode: .threads`. A timed-out probe counts as a pass; the run warns once a quarter of probes time out. `.zero` disables. |
| `.replay("seed")` | — | Deterministic replay from a failure report seed. |
| `.suppress(.issueReporting)` | — | Suppresses issue reporting (useful when asserting on the result directly). |
| `.onReport { report in }` | — | Delivers an `ExhaustReport` with per-phase timing, invocation counts, and reduction stats after the run. |
| `.log(.debug)` | `.error` | Log verbosity. |

## Designing good specs

A few patterns that tend to produce effective specs:

**Start with an invariant, add commands that stress it.** "Count is never negative" plus commands that add and remove aggressively. The simpler the invariant, the more clearly the failure report communicates the bug.

**Keep the model simpler than the SUT.** A hash map's model is a dictionary. A ring buffer's model is an array. If your model is as complex as your SUT, they'll share bugs rather than catching them.

**Use `skip()` liberally for preconditions.** Don't let commands execute in states they weren't designed for. Skipping invalid operations is cheaper than debugging invariant violations caused by undefined behaviour in precondition-violating calls.

**Weight common operations higher.** If `insert` happens ten times more often than `clear` in production, reflect that in the weights. Exhaust's screening phase explores all command orderings regardless of weight, but the random sampling phase and the reducer benefit from realistic relative frequencies.

**Test the boundary between "works alone" and "breaks together."** A spec that only has one command rarely finds anything. The bugs live in the interactions: two commands that race for the same resource, three operations whose order matters, a sequence that fills a buffer to capacity and then overflows.

## Certifying a fake

The model doesn't have to be a bare value. When a model property holds a standalone type that conforms to the same protocol as the SUT, the spec validates it as a faithful stand-in. After the spec passes, other tests can inject the fake instead of the real implementation, backed by every command sequence the spec exercised.

```swift
protocol Queue<Element> {
    associatedtype Element
    func enqueue(_ value: Element)
    func dequeue() -> Element?
    var count: Int { get }
    var elements: [Element] { get }
}

@StateMachine
final class QueueSpec {
    var fake = ListQueue<Int>()
    @SystemUnderTest var queue = CircularBufferQueue<Int>(capacity: 8)

    @Invariant
    func agree() -> Bool {
        fake.elements == queue.elements
    }

    @Command(weight: 3, .int(in: 0...99))
    func enqueue(value: Int) throws {
        guard fake.count < 8 else { throw skip() }
        fake.enqueue(value)
        queue.enqueue(value)
    }

    @Command(weight: 2)
    func dequeue() throws {
        guard fake.count > 0 else { throw skip() }
        let expected = fake.dequeue()
        let actual = queue.dequeue()
        try check(expected == actual, "dequeue must return same value")
    }

    func failureDescription() -> String? {
        "fake: \(fake.elements), queue: \(queue.elements)"
    }
}
```

`ListQueue` is a real type with its own methods. The spec proves it agrees with `CircularBufferQueue` across hundreds of random command sequences. Any test that depends on `Queue` can now use `ListQueue` with confidence. The plumbing to inject it is ordinary dependency injection, not something Exhaust needs to provide.

This pattern is most useful when the real implementation is expensive (databases, network services, file systems) and multiple test suites need a cheap substitute. For components where the real implementation is trivial to instantiate, the spec still finds bugs, but extracting a fake adds nothing.

The idea of using spec-tested fakes for compositional integration testing comes from Stevan Andjelkovic's [The Sad State of Property-Based Testing Libraries](https://stevana.github.io/the_sad_state_of_property-based_testing_libraries.html), which demonstrates the pattern across queues, file systems, and multi-layer component hierarchies.

## Replay determinism

A task-based run is fully deterministic when the system under test is async-native: every suspension point is an explicit `await` on an actor, `Task.yield()`, or another Swift Concurrency primitive. Same seed, same interleaving, every time.

One thing can break that guarantee:

**Foreign executors.** When the system under test bridges to GCD internally (for example, `withCheckedContinuation` wrapping a `DispatchQueue` callback), the continuation arrives on an OS thread Exhaust does not drive. Whether it is visible at the next scheduling step depends on OS thread timing, so the same seed can produce a different interleaving on different runs. If you see the same seed passing on one run and failing on another, a bridge like that is the most likely cause. For systems built on GCD, locks, or atomics, use `mode: .threads` instead.

A thread-based run is never deterministic. OS thread scheduling is unpredictable, so the same seed does not guarantee the same interleaving. Exhaust compensates with repetition during reduction, running each candidate sequence several times to confirm the failure still reproduces.
