# Frozen Regression Corpus

Each `.json` file here is a frozen reproducer for an engine defect a self-fuzzing run found: the original fuzz case, the violated oracle, and free-form provenance. The replay suite (`RegressionReplayTests`) re-runs every record on each PR — a reintroduced defect fails deterministically, with no fuzzing and no instrumentation.

Freezing a finding is a reviewed action, done alongside the fix it reproduces: copy the record from the run's findings directory (the fuzz entry and `MetaFuzzProbe` write freeze candidates to `METAFUZZ_FINDINGS`) into this directory, and commit it in the same PR as the fix. Records are versioned; one that stops decoding after a recipe-language change fails loudly and must be migrated or retired, also as a reviewed change.
