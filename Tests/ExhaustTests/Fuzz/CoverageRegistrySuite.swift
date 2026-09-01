import Testing

/// The one place the process-global coverage registries are mutated: the counter and PC-table registries in `SancovRuntime` and the guard registry behind `TracePCGuardCoverageSource`. Both are populated by loader callbacks before `main` in production and never written again; the test paths that append to them exist only for the suites nested here, which exercise the registries themselves. Nesting under one serialized suite keeps those suites from running concurrently with each other. Nothing else in the test suite touches the registries: every run under test takes its coverage source as an explicit parameter.
@Suite("Coverage registries", .serialized)
enum CoverageRegistryTests {}
