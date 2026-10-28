# Explore command validation

Run the argument parsing, campaign planning, test selection, and manifest validation unit tests with `swift test --filter ExploreCommandTests`. These rules are checked without launching child SwiftPM processes.

Run the isolated consumer tests (Swift 6.4+ and `llvm-nm` or `nm`):

```sh
swift -warnings-as-errors -swift-version 6 PluginTests/test_explore_commands.swift
```

These copy the production command/plugin sources into a temporary provider package with no external dependencies. The fixture does not build Exhaust. They exercise command help and argument validation, real SwiftPM plugin discovery, ephemeral manifest overlays, unchanged manifests after success and failure, target validation, release instrumentation, filtered Swift Testing execution, failure exit status, and an ordinary uninstrumented build. Object files verify that the selected library and test module contain coverage callbacks while the dependency and callback runtime do not. On Windows the test module stays uninstrumented, and the script checks that the command rejects instrumenting it.

The `RealConsumer` fixture also exercises the actual Exhaust macro, coverage runtime, report attachments, and command budget override. From the repository root:

```sh
swift package --package-path PluginTests/RealConsumer explore \
    --instrument Parser --test-target ParserTests --filter instrumentedProperty --time 1
```

The following command is expected to fail and report the reduced counterexample:

```sh
swift package --package-path PluginTests/RealConsumer explore \
    --instrument Parser --test-target ParserTests --filter failingProperty --time 1
```

The fixture has no instrumentation hook; the command supplies an ephemeral manifest overlay. The fixture's `BaselineTests` bundle depends on the instrumented library without directly depending on Exhaust, guarding the callback-linkage requirement of separate test bundles. Select the named tests when running this fixture: `failingProperty` is deliberately false when instrumented, `instrumentedProperty` checks campaign coverage, `parameterizedProperty` runs four campaigns at one call site, `stateMachineProperty` runs a spec campaign, `trappingProperty` traps only under `EXHAUST_E2E_TRAP=1`, and `dormantProperty` checks the ordinary suite's inert warning path.

Run the uninstrumented warning check and the real campaign checks with `swift -warnings-as-errors -swift-version 6 PluginTests/run_real_consumer.swift` (also in PowerShell). The script checks that an uninstrumented property remains inert with compiler warnings-as-errors enabled across the dependency graph, then checks, through `report.json` and `events.jsonl`: campaign success and the attachment files the report links; failure reporting, the streamed finding, and a finding ID that stays stable across reruns; parameterized campaigns kept apart; the `--no-parallel` counter recorder; a state machine campaign; and a trap that leaves an interrupted campaign which the next run resumes and reports. Every run also checks that the manifest remains unchanged.

The Explore Harness workflow runs the consumer checks on macOS and Linux, plus an experimental native Windows job. The Windows job exercises the Windows file lock, executable paths, compiler overlay, and real fuzz runtime; Windows support remains experimental until that job has passed. The Swift suite uses the platform's own lock API and inspects both Unix `.o` and Windows `.obj` files.
