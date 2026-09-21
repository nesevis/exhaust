# Frozen Regression Corpus

Each `.json` file here is a frozen reproducer for an engine defect a self-fuzzing run found: the original fuzz case, the violated oracle, and free-form provenance. The replay suite (`RegressionReplayTests`) re-runs every record on each PR — a reintroduced defect fails deterministically, with no fuzzing and no instrumentation.

Freezing a finding is a reviewed action, done alongside the fix it reproduces: copy the record from the run's findings directory (the fuzz entry and `MetaFuzzProbe` write freeze candidates to `METAFUZZ_FINDINGS`) into this directory, and commit it in the same PR as the fix. Records are versioned; one that stops decoding after a recipe-language change fails loudly and must be migrated or retired, also as a reviewed change.

## Record kinds

A record's `kind` names the oracle roster it replays through. `pipelineCase` records come from the pipeline campaign and replay through `MetaFuzz.check`. `screeningCase` records come from the screening campaign (`FuzzEntryTests.screeningVerdictsHoldUnderFuzzing`, or `MetaFuzzProbe --campaign screening`) and replay through `MetaFuzz.checkScreening`, which checks that an exhaustive screening verdict is sound, stable across covering seeds, and consistent with what the recipe grammar says about enumerability.
