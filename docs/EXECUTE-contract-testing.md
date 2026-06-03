# Contract testing with Exhaust

This guide covers testing stateful systems, things with mutable internal state where bugs emerge from sequences of operations rather than single calls. If you've read the [getting started guide](GETTING_STARTED.md), you're familiar with `#exhaust` for pure functions. `@Contract` is the equivalent for objects with memory.

You declare a contract with `@Contract` (or `@ConcurrentContract`, for systems built on threads, locks, or atomics rather than Swift's async/await) and run it with `#execute`. `#execute` generates command sequences, runs them against a fresh system under test, checks every invariant after each step, and — when something breaks — reduces the trace to the shortest sequence that still reproduces the failure and reports it with a replay seed. For pure functions over a generator rather than a stateful system, reach for [`#exhaust`](EXHAUST-property-testing.md) instead.

## Choosing a contract style

| What you're testing | Macro | Concurrency setting | How it runs |
|---|---|---|---|
| Synchronous SUT, operations in sequence | `@Contract` (struct) | — | Sequential |
| Async SUT (actors, async functions), operations in sequence | `@Contract` (final class or actor) | — | Sequential, async-bridged |
| Pure Swift concurrency — data races across `await` boundaries | `@Contract` (final class or actor) | `.concurrent(N)` | Cooperative: deterministic interleaving at `await`, reproducible seeds |
| Multithreading behind an async facade — locks, dispatch queues, atomics | `@ConcurrentContract` (final class) | `.concurrent(N)` | Preemptive: real GCD threads, non-deterministic, `@Oracle` comparison |
| The same, with synchronous command bodies | `@ConcurrentContract` (final class, sync commands) | `.concurrent(N)` | Preemptive: real GCD threads, no async bridging |

The two concurrent rows split on what the system under test is built on: pure Swift concurrency (async functions, actors), or multithreading primitives — locks, dispatch queues, atomics — behind an async facade. [Where interleaving can happen](#where-interleaving-can-happen) explains how that changes where the runner can interleave, and what each choice trades away.

## When to reach for `@Contract`

A stack, a database connection pool, a bounded queue, an authentication session, an undo stack. These all share a trait: calling `push` alone can't find the bug. The bug lives in `push, push, pop, pop, push, pop`, a specific ordering that leaves the data structure in a state it shouldn't be reachable to.

Unit tests for stateful systems tend to be manually-scripted scenarios: set up some state, run a sequence you thought of, assert. Contract testing generates the sequences instead. Exhaust picks the operations, picks their arguments, runs them in generated order, and checks that your invariants hold after every step. When something breaks, you get a minimal sequence that reproduces the failure, often three or four operations where you'd have written a twenty-step test to find the same bug by hand.

## The shape of a contract

A contract has four parts: a system under test, commands that operate on it, invariants that must always hold, and optionally a model that serves as an oracle.

```swift
@Test func stackBehavesCorrectly() {
    #execute(StackContract.self, .commandLimit(15))
}

@Contract
struct StackContract {
    @Model
    var expected: [Int] = []
    @SystemUnderTest
    var stack = MyStack<Int>()

    @Invariant
    func contentsMatch() -> Bool {
        stack.elements == expected
    }

    @Command(weight: 3, .int(in: 0...9))
    mutating func push(value: Int) throws {
        expected.append(value)
        stack.push(value)
    }

    @Command(weight: 2)
    mutating func pop() throws {
        guard !expected.isEmpty else { throw skip() }
        let modelValue = expected.removeLast()
        let sutValue = stack.pop()
        try check(modelValue == sutValue, "pop values should match")
    }
}
```

Each `@Command` method is one operation Exhaust can choose to run. The `weight:` parameter controls how often it appears relative to other commands. A weight-3 command shows up roughly three times as often as a weight-1 command. After every command, all `@Invariant` methods are checked automatically.

`.commandLimit(N)` sets the maximum length of generated command sequences. When omitted, Exhaust estimates a limit from the command domain size and the coverage budget (capped at 100 for sequential contracts, 40 for concurrent). Longer sequences explore deeper states but take longer to test and to reduce. The overhead scales linearly with command limit. A contract with cheap commands runs in under 15ms even at the 40-command cap. Contracts with expensive command bodies (I/O, network calls, heavy computation) should use a lower limit, since the per-command cost multiplies across every coverage row and every reduction probe.

## Model-based oracles

The `@Model` annotation marks properties that track expected state. The model doesn't have to be sophisticated. It just needs to agree with the system under test (SUT) on whatever the invariants check. A model for a bounded queue might be a plain `[Int]` tracking FIFO order. A model for a counter might be a single `Int`.

The model's job is to make invariants trivial to write. Without a model, invariants have to derive expected behaviour from the system under test's current state alone, which is often hard. With a model, the invariant is just `sut.value == model.value`.

You don't have to use a model. Contracts that only need structural invariants (count within bounds, no duplicates, LIFO ordering) work fine without one.

### Certifying a fake

The model doesn't have to be a bare value. When `@Model` holds a standalone type that conforms to the same protocol as the SUT, the contract validates it as a faithful stand-in. After the contract passes, other tests can inject the fake instead of the real implementation — fast, deterministic, and backed by every command sequence the contract exercised.

```swift
protocol Queue<Element> {
    associatedtype Element
    mutating func enqueue(_ value: Element)
    mutating func dequeue() -> Element?
    var count: Int { get }
    var elements: [Element] { get }
}

@Contract
struct QueueContract {
    @Model var fake = ListQueue<Int>()
    @SystemUnderTest var queue = CircularBufferQueue<Int>(capacity: 8)

    @Invariant
    func agree() -> Bool {
        fake.elements == queue.elements
    }

    @Command(weight: 3, .int(in: 0...99))
    mutating func enqueue(value: Int) throws {
        guard fake.count < 8 else { throw skip() }
        fake.enqueue(value)
        queue.enqueue(value)
    }

    @Command(weight: 2)
    mutating func dequeue() throws {
        guard fake.count > 0 else { throw skip() }
        let expected = fake.dequeue()
        let actual = queue.dequeue()
        try check(expected == actual, "dequeue must return same value")
    }
}
```

`ListQueue` is a real type with its own methods. The contract proves it agrees with `CircularBufferQueue` across hundreds of random command sequences. Any test that depends on `Queue` can now use `ListQueue` with confidence — the plumbing to inject it is ordinary dependency injection, not something Exhaust needs to provide.

This pattern is most useful when the real implementation is expensive (databases, network services, file systems) and multiple test suites need a cheap substitute. For components where the real implementation is trivial to instantiate, the contract still finds bugs, but extracting a fake adds nothing — just use the real thing.

The idea of using contract-tested fakes for compositional integration testing comes from Stevan Andjelkovic's [The Sad State of Property-Based Testing Libraries](https://stevana.github.io/the_sad_state_of_property-based_testing_libraries.html), which demonstrates the pattern across queues, file systems, and multi-layer component hierarchies.

## Commands, skip, and check

Commands come in three flavours.

**Commands with generated arguments** use generator expressions in the `@Command` attribute:

```swift
@Command(weight: 3, .int(in: 0...20))
mutating func put(value: Int) throws {
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
mutating func get() throws {
    guard !queue.isEmpty else { throw skip() }
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

## Async contracts

When your system under test has async methods (actors, network services, databases), declare the contract as a `final class` or an `actor` and make commands `async`:

```swift
@Contract
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

Three differences from sync contracts: the contract is a `final class` or `actor` (not a struct), commands drop `mutating` (reference-type semantics), and the test call needs `await`:

```swift
@Test func counterBehavesCorrectly() async {
    await #execute(AsyncCounterContract.self, .commandLimit(10))
}
```

Exhaust detects async methods and generates the correct conformance automatically.

### Actors as contracts

When the contract is an `actor`, Exhaust generates `AsyncContractSpec` conformance regardless of whether commands are explicitly `async`. Actor isolation makes all methods implicitly async from outside, so the async contract runner is always used. Sync commands still dispatch without `await` internally.

Actors are a natural fit when the contract's own state should be isolated from other tests running in parallel. `@TaskLocal` injection works inside command bodies, so dependency injection via task-locals scopes correctly to each command's execution.

> [!NOTE]
> `@ConcurrentContract` on an actor has no effect. Actor isolation serialises all command dispatch, which prevents the interleaving that concurrent testing requires. Use a `final class` for `@ConcurrentContract`.

## Where interleaving can happen

The two concurrent runners differ in one thing: where one lane's work can be interleaved with another's.

Code written in pure Swift concurrency gives up the thread only at an `await` — between two `await`s, a task runs to completion without interruption (the scheduling term is *cooperative*). The cooperative runner (`@Contract` with async commands and `.concurrent`) drives the tasks itself and chooses which lane to resume at each suspension point. Because the only places an interleaving can occur are the `await`s your command bodies actually reach, the runner can enumerate and replay them exactly: the same seed reproduces the same interleaving, and the reducer reduces the lane assignments alongside the command sequence. The limitation follows from the same fact. A race that lives entirely in synchronous code, with no `await` between the two conflicting accesses, gives the scheduler nowhere to interleave, so it stays invisible.

The preemptive runner (`@ConcurrentContract`) gives up that control to reach those races. It dispatches commands to real GCD threads, which the operating system can interrupt at any instruction, including the synchronous stretches a cooperative scheduler treats as atomic. That reaches races inside the multithreading primitives an async facade hides — locks, dispatch queues, atomics — which the cooperative runner steps straight over. The price is determinism. The OS chooses the interleaving, so the same seed no longer reproduces the same run, and the runner compensates by repeating each sequence and comparing its final state against a race-free sequential replay through an `@Oracle` method, rather than checking invariants at every intermediate step.

So the choice comes down to where the race lives. A race that straddles an `await` is the cooperative runner's territory — deterministic, reproducible, and faster to reduce. A race hidden in synchronous code, behind locks or atomics, needs the preemptive runner, at the cost of reproducibility.

## Cooperative concurrent testing

The cooperative runner executes commands concurrently across multiple execution lanes, deterministically interleaving at every `await` suspension point. This finds bugs that only manifest under concurrent access: lost updates, check-then-act races, non-atomic read-modify-write patterns that straddle a suspension boundary.

```swift
@Test func counterIsSafeUnderConcurrency() async {
    await #execute(
        NonAtomicCounterContract.self,
        .concurrent(2),
        .commandLimit(6),
        .budget(.thorough)
    )
}
```

`.concurrent(2)` means commands are distributed across two concurrent lanes. The cooperative scheduler controls interleaving deterministically. The same seed always produces the same interleaving. When a failure is found, the reducer reduces both the command sequence and the lane assignments, discovering the minimal concurrency needed to trigger the bug.

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

The cooperative scheduler interleaves at `await` suspension points, wherever a command body suspends (via `Task.yield()`, an actor call, or any other suspension point). It cannot interleave within synchronous code. A race between two statements with no `await` between them is invisible to the scheduler.

SUTs that have races at suspension points (the `let v = state; await Task.yield(); state = v + 1` pattern) are exactly what this tool finds well. SUTs whose races are in synchronous code behind an async facade — locks, dispatch queues, atomics — need the [preemptive runner](#preemptive-concurrent-testing) instead.

### Concurrency level

`.concurrent(N)` controls how many concurrent lanes commands are distributed across. The default is 2, which suffices for most data races. A study of 105 real-world concurrency bugs in MySQL, Apache, Mozilla, and OpenOffice found that 96% manifest with just two threads (Lu et al., [Learning from Mistakes](https://dl.acm.org/doi/10.1145/1346281.1346323), ASPLOS 2008). Use 3 or more when you suspect the bug requires three-way interleaving (for example, ABA problems or three-participant lost updates). The maximum is 8.

`.concurrent(1)` runs everything sequentially, useful as a baseline to confirm that the bug genuinely requires concurrency to manifest. Actor-based contracts can use `.concurrent(1)` to test sequential command behavior through the async contract runner.

### Idle timeout

If a command body suspends to an executor outside the cooperative scheduler (a custom-executor actor, `Task.sleep`, blocking I/O), the drain loop stalls because the continuation never arrives back. The `.idleTimeoutMs(ms)` setting (default 1000ms) detects this and reports the stalling command sequence without attempting reduction.

### When replay is deterministic

The cooperative runner is fully deterministic when the system under test is async-native: all suspension points are explicit `await`s on actors, `Task.yield()`, or other Swift Concurrency primitives. Same seed, same interleaving, every time.

Two things can break that guarantee:

**Foreign executors.** When the system under test bridges to GCD internally (for example, `withCheckedContinuation` wrapping a `DispatchQueue` callback), the continuation arrives on an OS thread outside the drain loop. The runner's lock prevents data races on its internal state, but not timing races: whether the continuation is visible at the next dequeue depends on OS thread scheduling. Same seed, same choice sequence, but a different run can produce a different set of pending jobs at each drain step and therefore a different actual interleaving. If you observe the same seed passing on one run and failing on another, a foreign executor bridge is the most likely cause. For systems built on GCD, locks, or atomics, use [`@ConcurrentContract`](#preemptive-concurrent-testing) instead.

**Schedule exhaustion.** The schedule array has one entry per non-prefix command, but the drain loop consumes one entry per dequeued job, including mid-command continuations from internal `await`s. Commands that suspend multiple times consume entries meant for later commands, exhausting the schedule early. Once exhausted, lane assignment falls back to deterministic round-robin. This fallback is itself deterministic, so it does not break replay. It does mean the reducer can only target command-level lane assignments, not continuation-level interleavings within a single command. For most systems under test this is not a practical limitation, because the bugs live at the command boundary, not between a command's internal suspension points.

## Preemptive concurrent testing

The preemptive runner dispatches commands to real GCD threads, letting the OS scheduler create actual thread-level interleaving. This catches races that the cooperative scheduler cannot reach: bugs inside locks, dispatch queues, atomics, and other synchronous primitives hidden behind async facades.

Preemptive contracts use `@ConcurrentContract` instead of `@Contract`. The difference is the `@Oracle` method, which defines what "equivalent" means when comparing concurrent state against a sequential replay.

```swift
@ConcurrentContract
final class AsyncRacyCounterContract {
    @SystemUnderTest
    var counter: AsyncRacyCounter = .init()

    @Oracle
    func valuesMatch(other: AsyncRacyCounter) -> Bool {
        counter.value == other.value
    }

    @Invariant
    func isNonNegative() -> Bool {
        counter.value >= 0
    }

    @Command(weight: 3)
    func increment() async throws {
        await counter.increment()
    }

    @Command(weight: 2)
    func decrement() async throws {
        guard counter.value > 0 else { throw skip() }
        await counter.decrement()
    }
}
```

The `@Oracle` method receives the SUT state from a sequential (race-free) replay of the same command sequence. If the concurrent execution produces a different result, the oracle returns `false` and Exhaust reports a failure. The oracle checks final state rather than intermediate states, which is the right tradeoff for non-deterministic scheduling — intermediate invariants would fail spuriously when the OS happens to interleave in a valid-but-unexpected order.

Running the test:

```swift
@Test func counterIsSafeUnderConcurrency() async {
    await #execute(
        AsyncRacyCounterContract.self,
        .concurrent(2),
        .commandLimit(6),
        .budget(.custom(coverage: 0, sampling: 200))
    )
}
```

### Non-determinism and repetition

The same seed does not guarantee the same interleaving. OS thread scheduling is unpredictable, so the preemptive runner compensates with repetition: it runs each candidate sequence multiple times during reduction to confirm that the failure is reproducible. A bug that manifests on one in ten runs will still be found and reduced, but reduction takes longer because each probe requires several executions.

The cooperative runner is the better choice when both can find the bug. Deterministic interleaving means faster reduction and reproducible seeds. Reach for the preemptive runner when the race is inside synchronous primitives that the cooperative scheduler cannot see.

### Synchronous commands

`@ConcurrentContract` also works with synchronous commands. When all commands and invariants are synchronous, Exhaust generates `ConcurrentContractSpec` conformance and dispatches directly to GCD threads with no async bridging:

```swift
@ConcurrentContract
final class SyncCounterContract {
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
}
```

## Settings reference

All contract styles accept settings as variadic arguments to `#execute`:

| Setting | Default | Effect |
|---------|---------|--------|
| `.commandLimit(N)` | auto-estimated | Maximum commands per generated sequence. Capped at 100 (sync sequential) or 40 (concurrent). |
| `.concurrent(N)` | 2 | Number of concurrent lanes (concurrent contracts only, 1...8). |
| `.budget(.thorough)` | `.standard` | Controls coverage rows and random sampling iterations. |
| `.idleTimeoutMs(ms)` | 1000 | Milliseconds before declaring a drain-loop stall (cooperative runner only). |
| `.replay("seed")` | — | Deterministic replay from a failure report seed. |
| `.suppress(.issueReporting)` | — | Suppresses issue reporting (useful when asserting on the result directly). |
| `.includeDiff` | off | Includes a structural diff between the original and reduced command sequences (sequential only). |
| `.collectOpenPBTStats` | off | Records per-example stats in OpenPBTStats JSON Lines format. |
| `.onReport { report in }` | — | Delivers an `ExhaustReport` with per-phase timing, invocation counts, and reduction stats after the run. |
| `.log(.debug)` | `.error` | Log verbosity. |

## Designing good contracts

A few patterns that tend to produce effective contracts:

**Start with an invariant, add commands that stress it.** "Count is never negative" plus commands that add and remove aggressively. The simpler the invariant, the more clearly the failure report communicates the bug.

**Keep the model simpler than the SUT.** A hash map's model is a dictionary. A ring buffer's model is an array. If your model is as complex as your SUT, they'll share bugs rather than catching them.

**Use skip() liberally for preconditions.** Don't let commands execute in states they weren't designed for. Skipping invalid operations is cheaper than debugging invariant violations caused by undefined behaviour in precondition-violating calls.

**Weight common operations higher.** If `insert` happens ten times more often than `clear` in production, reflect that in the weights. Exhaust's coverage phase explores all command orderings regardless of weight, but the random sampling phase and the reducer benefit from realistic relative frequencies.

**Test the boundary between "works alone" and "breaks together."** A contract that only has one command rarely finds anything. The bugs live in the interactions: two commands that race for the same resource, three operations whose order matters, a sequence that fills a buffer to capacity and then overflows.
