# Memory Harness

This package keeps deterministic, high-budget memory profiles out of the default `swift test`
lane. The `Memory Profiles` workflow builds the package once, then runs each suite in a fresh,
serial test process so one profile's allocator high-water mark cannot contaminate another.

The profiles cover:

- a passing `#exhaust` run over nested collections;
- a passing sequential `#execute` run with generated command payloads; and
- a controlled collection failure that exercises counterexample reduction; and
- repeated `#exhaust` runs with process-footprint samples between runs, exposing retained growth.

Run a profile locally after building the test product:

```sh
swift build --package-path MemoryHarness --build-tests
swift test --package-path MemoryHarness --skip-build --no-parallel \
  --filter PropertyMemoryProfileTests
```

CI reports maximum resident set size, peak memory footprint, and the retained-memory curve without
enforcing a threshold. Thresholds should be introduced only after enough runs establish normal
variation on the pinned macOS and Xcode runner.
