# Running contract tests

`#execute` runs a contract against a system under test: it generates sequences of commands, executes them, and checks invariants after every step. When something breaks, the trace is reduced to the shortest command sequence that reproduces the failure and reported with a replay seed.

For how to write contracts — declaring the system under test, commands, models, and invariants — see [Contract Testing](CONTRACT_TESTING.md). This page covers invocation and settings.

Contract tests use the `#execute` macro with a contract type instead of a generator:

```swift
@Test func counterObeysContract() {
    #execute(CounterContract.self, .commandLimit(10))
}
```

For property tests over a generator rather than a stateful system, see [Running property tests](EXHAUST.md) and the `#exhaust` macro.

## Contract settings

Sync contract tests accept `ContractSettings`:

| Setting | Default | Effect |
|---|---|---|
| `.commandLimit(N)` | auto-estimated | Maximum commands per sequence. Auto-estimated from the command domain when omitted (capped at 100). Reduce for contracts with expensive command bodies. |
| `.budget(...)` | `.thorough` | Coverage and sampling budgets. |
| `.replay(seed)` | — | Deterministic reproduction from a failure report seed. |
| `.suppress(.issueReporting)` | — | Suppress issue reporting. |
| `.includeDiff` | off | Structural diff between the original and reduced counterexample. |
| `.collectOpenPBTStats` | off | Per-example stats in OpenPBTStats format. |
| `.onReport { report in }` | — | Delivers an `ExhaustReport` after the run. |
| `.log(.debug)` | `.error` | Log verbosity. |

## Concurrent contract settings

Async contract tests accept `ConcurrentContractSettings`:

| Setting | Default | Effect |
|---|---|---|
| `.commandLimit(N)` | auto-estimated | Maximum commands per sequence (capped at 40 for async). |
| `.concurrent(N)` | 2 | Number of concurrent execution lanes (1 to 8). |
| `.budget(...)` | `.thorough` | Coverage and sampling budgets. |
| `.idleTimeoutMs(ms)` | 1000 | Drain loop stall detection. |
| `.replay(seed)` | — | Deterministic reproduction. |
| `.suppress(.issueReporting)` | — | Suppress issue reporting. |
| `.collectOpenPBTStats` | off | Per-example stats in OpenPBTStats format. |
| `.onReport { report in }` | — | Delivers an `ExhaustReport` after the run. |
| `.log(.debug)` | `.error` | Log verbosity. |
