# Contract testing with Exhaust

This guide covers testing stateful systems, things with mutable internal state where bugs emerge from sequences of operations rather than single calls. If you've read the [getting started guide](GETTING_STARTED.md), you're familiar with `#exhaust` for pure functions. `@Contract` is the equivalent for objects with memory. For pure functions over a generator rather than a stateful system, reach for [`#exhaust`](EXHAUST-property-testing.md) instead.

## When to reach for `@Contract`

A stack, a database connection pool, a bounded queue, an authentication session, an undo stack. These all share a trait: calling `push` alone can't find the bug. The bug lives in `push, push, pop, pop, push, pop`, a specific ordering that leaves the data structure in a state that shouldn't be reachable.

Unit tests for stateful systems tend to be manually-scripted scenarios: set up some state, run a sequence you thought of, assert. Contract testing generates the sequences instead. Exhaust picks the operations, picks their arguments, runs them in generated order, and checks that your invariants hold after every step. When something breaks, you get a minimal sequence that reproduces the failure, often three or four operations where you'd have written a twenty-step test to find the same bug by hand.

## Quick reference

Which `@Contract` mode you need depends on what your system under test is built on:

| Your SUT | Mode | What it finds |
|---|---|---|
| Synchronous class or actor | `@Contract(.sequential)` | Logic bugs: ordering, invariant violations, state corruption |
| Async class with `await` boundaries | `@Contract(.tasks)` | Reentrancy and interleaving bugs at `await` boundaries |
| Class with locks, GCD, or atomics | `@Contract(.threads)` | Data races in synchronous primitives, invisible to cooperative scheduling |

The rest of this guide walks through each case.

## The shape of a contract

A contract has four parts: a system under test, commands that operate on it, invariants that must always hold, and optionally a model that serves as a reference.

```swift
@Test func stackBehavesCorrectly() {
    #execute(StackContract.self, .commandLimit(15))
}

@Contract(.sequential)
final class StackContract {
    @Model
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
}
```

Each `@Command` method is one operation Exhaust can choose to run. The `weight:` parameter controls how often it appears relative to other commands. A weight-3 command shows up roughly three times as often as a weight-1 command. After every command, all `@Invariant` methods are checked automatically.

Contracts must be a `final class` or an `actor`. The `@Contract` macro takes a required execution mode. `.sequential` runs commands one at a time and checks `@Invariant` after each step. It is the most common mode, and the one this guide uses until the concurrency sections. `.tasks` runs commands concurrently with deterministic interleaving at `await` boundaries. `.threads` dispatches commands to real OS threads and checks an `@Oracle` against a sequential replay.

## Model and invariants

The `@Model` annotation marks properties that track expected state. The model doesn't have to be sophisticated. It just needs to agree with the system under test on whatever the invariants check. A model for a bounded queue might be a plain `[Int]` tracking FIFO order. A model for a counter might be a single `Int`.

The model's job is to make invariants trivial to write. Without a model, invariants have to derive expected behaviour from the system under test's current state alone, which is often hard. With a model, the invariant is just `sut.value == model.value`.

You don't have to use a model. Contracts that only need structural invariants (count within bounds, no duplicates, LIFO ordering) work fine without one.

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

**`skip()` is a precondition guard.** When a command's precondition fails (popping an empty stack, draining an empty pool), throw `skip()` rather than letting the command execute in an invalid state. Skipped commands don't count as failures. They're filtered out during generation, and Exhaust learns to avoid sequences dominated by skipped operations.

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

## Running the test

```swift
@Test func queueMaintainsFIFOOrder() {
    #execute(CircularQueueContract.self, .commandLimit(10), .budget(.thorough))
}
```

Exhaust first runs a coverage phase that systematically covers command-type orderings (every pairwise combination of command types at each position), then switches to random sampling. If a failure is found in either phase, the reducer reduces the command sequence to a minimal counterexample.

The failure report shows the reduced sequence and the execution trace:

```
Contract failure (found via coverage)

Command sequence (4 steps, reduced from 8):
  1. put(7) [ok]
  2. put(12) [ok]
  3. put(5) [ok]
  4. get() ✗ get must return elements in FIFO order

Model: [12, 5]
SUT:   BuggyCircularQueue(count: 2, capacity: 6)

Reproduce: .replay("3JK4M2-5")
```

The replay seed lets you re-run the exact same sequence deterministically for debugging.

`.commandLimit(N)` sets the maximum length of generated command sequences. When omitted, Exhaust estimates a limit from the command domain size and the coverage budget (capped at 100 for sequential contracts, 40 for concurrent). Longer sequences explore deeper states but take longer to test and to reduce. The overhead scales linearly with command limit. Contracts with expensive command bodies (I/O, network calls, heavy computation) should use a lower limit, since the per-command cost multiplies across every coverage row and every reduction probe.

## Your SUT uses async/await

When the system under test has async methods (actors, network services, databases), make the commands `async`. A `.sequential` contract with async commands runs them one at a time, the same as a sync contract:

```swift
@Contract(.sequential)
final class AsyncCounterContract {
    @Model
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
}
```

The test call needs `await`:

```swift
@Test func counterBehavesCorrectly() async {
    await #execute(AsyncCounterContract.self, .commandLimit(10))
}
```

Exhaust detects async methods and generates the correct conformance automatically.

### Actors as contracts

When the contract is an `actor`, it must use `.sequential`. Exhaust treats all commands as async regardless of whether they carry an explicit `async` keyword, because actor isolation makes them implicitly async from outside, and serialises all dispatch, so there's nowhere to interleave.

Actors are a natural fit when the contract's own state should be isolated from other tests running in parallel, and `@TaskLocal` injection works inside command bodies. For concurrent testing, use a `final class`.

## Finding concurrency bugs in async code

The `.sequential` contracts shown above run each command one at a time. Some bugs only show up when two operations overlap. `@Contract(.tasks)` runs commands concurrently across multiple execution lanes, and Exhaust's cooperative scheduler controls the interleaving deterministically at every `await` suspension point.

```swift
@Test func counterIsSafeUnderConcurrency() async {
    await #execute(
        NonAtomicCounterContract.self,
        .concurrent(.two),
        .commandLimit(6),
        .budget(.thorough)
    )
}
```

The same seed always produces the same interleaving, and the reducer reduces both the command sequence and the lane assignments, discovering the minimal concurrency needed to trigger the bug.

A typical failure report:

```
Concurrent contract failure (found via random sampling)

Reduced from 6 to 3 commands.

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

### What the scheduler can and cannot find

The cooperative scheduler interleaves at `await` suspension points, wherever a command body suspends via `Task.yield()`, an actor call, or any other suspension point. It cannot interleave within synchronous code. A race between two statements with no `await` between them is invisible to the scheduler.

SUTs that have races at suspension points (the `let v = state; await Task.yield(); state = v + 1` pattern) are exactly what `.tasks` concurrent testing finds well. SUTs whose races are in synchronous code behind an async facade (locks, dispatch queues, atomics) need `.threads` instead.

### Concurrency level

`.concurrent(N)` controls how many concurrent lanes commands are distributed across. The default is 2, which suffices for most data races. A study of 105 real-world concurrency bugs in MySQL, Apache, Mozilla, and OpenOffice found that 96% manifest with just two threads (Lu et al., [Learning from Mistakes](https://dl.acm.org/doi/10.1145/1346281.1346323), ASPLOS 2008). Use three or more when you suspect the bug requires three-way interleaving (for example, ABA problems or three-participant lost updates). The maximum is 8.

`.concurrent(.one)` runs everything sequentially, useful as a baseline to confirm that the bug genuinely requires concurrency to manifest.

### Idle timeout

If a command body suspends to an executor outside the cooperative scheduler (a custom-executor actor, `Task.sleep`, blocking I/O), the drain loop stalls because the continuation never arrives back. The `.idleTimeoutMs(ms)` setting (default 1000ms) detects this and reports the stalling command sequence without attempting reduction.

## Finding concurrency bugs in threaded code

Some systems use synchronous concurrency primitives internally (`os_unfair_lock`, `DispatchQueue`, atomics, `NSLock`), with or without an async facade on top. The cooperative scheduler treats the code between two `await`s as atomic, so it steps straight over these races.

`@Contract(.threads)` dispatches commands to real GCD threads, letting the OS scheduler interleave at any instruction. This reaches races inside the synchronous primitives that `.tasks` cannot see.

The tradeoff is determinism. The OS chooses the interleaving, so the same seed no longer reproduces the same run. Exhaust compensates with repetition during reduction (running each candidate sequence multiple times to confirm the failure), and with a different checking mechanism: instead of `@Invariant`, `.threads` contracts use `@Oracle`.

### Oracles

An `@Oracle` method defines what "equivalent" means for the SUT. Exhaust runs the command sequence concurrently, then replays the same commands sequentially on a fresh instance. The oracle receives the sequential (race-free) result and returns whether the concurrent state matches:

```swift
@Contract(.threads)
final class RacyCounterContract {
    @SystemUnderTest
    var counter: RacyCounter = .init()

    @Oracle
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
}
```

The oracle checks final state rather than intermediate states. That's the right tradeoff for non-deterministic scheduling. Intermediate invariants would fail spuriously when the OS happens to interleave in a valid-but-unexpected order.

The oracle is always required for `.threads` contracts and always written by hand. `@Invariant` and `@Model` are not available under `.threads`, because there's no deterministic per-step state to check them against.

Running the test:

```swift
@Test func counterIsThreadSafe() {
    #execute(
        RacyCounterContract.self,
        .concurrent(.two),
        .commandLimit(6),
        .budget(.thorough)
    )
}
```

### Async commands with `.threads`

`.threads` also works when command bodies are `async`. Each lane gets a real OS thread, and async execution is bridged via `Task` + semaphore. This catches races in synchronous primitives hidden behind an async facade:

```swift
@Contract(.threads)
final class AsyncRacyCounterContract {
    @SystemUnderTest
    var counter: AsyncRacyCounter = .init()

    @Oracle
    func valuesMatch(other: AsyncRacyCounter) -> Bool {
        counter.value == other.value
    }

    @Command(weight: 3)
    func increment() async throws {
        await counter.increment()
    }
}
```

### `.tasks` or `.threads`?

When both could find the bug, prefer `.tasks`. Deterministic interleaving means faster reduction and reproducible seeds. Reach for `.threads` when the race is inside synchronous primitives that the cooperative scheduler cannot see.

## Settings reference

All settings are passed as variadic arguments to `#execute`:

| Setting | Default | Effect |
|---------|---------|--------|
| `.commandLimit(N)` | auto-estimated | Maximum commands per generated sequence. Capped at 100 (sequential) or 40 (concurrent). |
| `.concurrent(N)` | 2 | Number of concurrent lanes (1 through 8). |
| `.budget(.thorough)` | `.standard` | Controls coverage rows and random sampling iterations. |
| `.idleTimeoutMs(ms)` | 1000 | Milliseconds before declaring a drain-loop stall (`.tasks` concurrent only). |
| `.replay("seed")` | — | Deterministic replay from a failure report seed. |
| `.suppress(.issueReporting)` | — | Suppresses issue reporting (useful when asserting on the result directly). |
| `.includeDiff` | off | Includes a structural diff between the original and reduced command sequences. |
| `.collectOpenPBTStats` | off | Records per-example stats in OpenPBTStats JSON Lines format. |
| `.onReport { report in }` | — | Delivers an `ExhaustReport` with per-phase timing, invocation counts, and reduction stats after the run. |
| `.log(.debug)` | `.error` | Log verbosity. |

## Designing good contracts

A few patterns that tend to produce effective contracts:

**Start with an invariant, add commands that stress it.** "Count is never negative" plus commands that add and remove aggressively. The simpler the invariant, the more clearly the failure report communicates the bug.

**Keep the model simpler than the SUT.** A hash map's model is a dictionary. A ring buffer's model is an array. If your model is as complex as your SUT, they'll share bugs rather than catching them.

**Use `skip()` liberally for preconditions.** Don't let commands execute in states they weren't designed for. Skipping invalid operations is cheaper than debugging invariant violations caused by undefined behaviour in precondition-violating calls.

**Weight common operations higher.** If `insert` happens ten times more often than `clear` in production, reflect that in the weights. Exhaust's coverage phase explores all command orderings regardless of weight, but the random sampling phase and the reducer benefit from realistic relative frequencies.

**Test the boundary between "works alone" and "breaks together."** A contract that only has one command rarely finds anything. The bugs live in the interactions: two commands that race for the same resource, three operations whose order matters, a sequence that fills a buffer to capacity and then overflows.

## Certifying a fake

The model doesn't have to be a bare value. When `@Model` holds a standalone type that conforms to the same protocol as the SUT, the contract validates it as a faithful stand-in. After the contract passes, other tests can inject the fake instead of the real implementation, backed by every command sequence the contract exercised.

```swift
protocol Queue<Element> {
    associatedtype Element
    func enqueue(_ value: Element)
    func dequeue() -> Element?
    var count: Int { get }
    var elements: [Element] { get }
}

@Contract(.sequential)
final class QueueContract {
    @Model var fake = ListQueue<Int>()
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
}
```

`ListQueue` is a real type with its own methods. The contract proves it agrees with `CircularBufferQueue` across hundreds of random command sequences. Any test that depends on `Queue` can now use `ListQueue` with confidence. The plumbing to inject it is ordinary dependency injection, not something Exhaust needs to provide.

This pattern is most useful when the real implementation is expensive (databases, network services, file systems) and multiple test suites need a cheap substitute. For components where the real implementation is trivial to instantiate, the contract still finds bugs, but extracting a fake adds nothing.

The idea of using contract-tested fakes for compositional integration testing comes from Stevan Andjelkovic's [The Sad State of Property-Based Testing Libraries](https://stevana.github.io/the_sad_state_of_property-based_testing_libraries.html), which demonstrates the pattern across queues, file systems, and multi-layer component hierarchies.

## Replay determinism

The `.tasks` cooperative runner is fully deterministic when the system under test is async-native: all suspension points are explicit `await`s on actors, `Task.yield()`, or other Swift Concurrency primitives. Same seed, same interleaving, every time.

Two things can break that guarantee:

**Foreign executors.** When the system under test bridges to GCD internally (for example, `withCheckedContinuation` wrapping a `DispatchQueue` callback), the continuation arrives on an OS thread outside the drain loop. The runner's lock prevents data races on its internal state, but not timing races: whether the continuation is visible at the next dequeue depends on OS thread scheduling. Same seed, same choice sequence, but a different run can produce a different set of pending jobs at each drain step and therefore a different actual interleaving. If you observe the same seed passing on one run and failing on another, a foreign executor bridge is the most likely cause. For systems built on GCD, locks, or atomics, use `@Contract(.threads)` instead.

**Schedule exhaustion.** The schedule array has one entry per non-prefix command, but the drain loop consumes one entry per dequeued job, including mid-command continuations from internal `await`s. Commands that suspend multiple times consume entries meant for later commands, exhausting the schedule early. Once exhausted, lane assignment falls back to deterministic round-robin. This fallback is itself deterministic, so it does not break replay. It does mean the reducer can only target command-level lane assignments, not continuation-level interleavings within a single command. For most systems under test this is not a practical limitation, because the bugs live at the command boundary, not between a command's internal suspension points.

The `.threads` preemptive runner is never deterministic. OS thread scheduling is unpredictable, so the same seed does not guarantee the same interleaving. The runner compensates with repetition during reduction, running each candidate sequence multiple times to confirm the failure is reproducible.
