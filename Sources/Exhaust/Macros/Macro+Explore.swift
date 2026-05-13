import ExhaustCore

/// Runs a classification-aware property test that steers sampling toward each declared direction via per-direction CGS tuning.
///
/// Given a list of named directions (predicate-labeled regions of the output space), `#explore` tunes the generator per direction, draws K samples per direction, and reports per-direction coverage alongside cross-direction overlap and diagnostic findings.
///
/// Pass the property as a trailing closure to capture source location for better failure messages:
///
/// ```swift
/// let report = #explore(crossingGen, .budget(.expensive),
///     directions: [
///         ("northward", { $0.from > 0 && $0.to < 0 }),
///         ("southward", { $0.from < 0 && $0.to > 0 }),
///     ]
/// ) { value in
///     flightController.updatePosition(value)
///     #expect(flightController.heading.isValid)
/// }
/// ```
///
/// Or pass a function reference when source capture is not needed:
///
/// ```swift
/// let report = #explore(crossingGen, directions: directions, property: isValid)
/// ```
///
/// ## Settings
///
/// - `.budget(_)`: per-direction hit target and attempt budget. Presets: `.expedient` (30 hits, default), `.expensive` (100 hits), `.exorbitant` (300 hits).
/// - `.replay(_)`: fixed seed for deterministic reproduction.
/// - `.suppress(.issueReporting)`: skips `reportIssue()` — useful when the caller asserts on the returned report.
/// - `.suppress(.logs)`: silences all console output.
/// - `.logging(_)`: controls log verbosity.
///
/// - Returns: An ``ExploreReport`` containing the counterexample (if any), per-direction coverage, and cross-direction diagnostics.
@freestanding(expression)
@discardableResult
public macro explore<GeneratedValue, PropertyResult>(
    _ gen: RefGen<GeneratedValue>,
    _ settings: ExploreSettings...,
    directions: [(String, (GeneratedValue) -> Bool)],
    property: (GeneratedValue) throws -> PropertyResult
) -> ExploreReport<GeneratedValue> = #externalMacro(module: "ExhaustMacros", type: "ExploreMacro")

/// Runs a classification-aware property test that steers sampling toward each declared direction via per-direction CGS tuning.
///
/// Given a list of named directions (predicate-labeled regions of the output space), `#explore` tunes the generator per direction, draws K samples per direction, and reports per-direction coverage alongside cross-direction overlap and diagnostic findings. Must be called with `await` since the expanded function is `async`.
///
/// ```swift
/// let report = try await #explore(crossingGen, .budget(.expensive),
///     directions: [
///         ("northward", { $0.from > 0 && $0.to < 0 }),
///         ("southward", { $0.from < 0 && $0.to > 0 }),
///     ]
/// ) { value in
///     try await flightController.updatePosition(value)
///     #expect(flightController.heading.isValid)
/// }
/// ```
///
/// ## Settings
///
/// - `.budget(_)`: per-direction hit target and attempt budget. Presets: `.expedient` (30 hits, default), `.expensive` (100 hits), `.exorbitant` (300 hits).
/// - `.replay(_)`: fixed seed for deterministic reproduction.
/// - `.suppress(.issueReporting)`: skips `reportIssue()` — useful when the caller asserts on the returned report.
/// - `.suppress(.logs)`: silences all console output.
/// - `.logging(_)`: controls log verbosity.
///
/// - Returns: An ``ExploreReport`` containing the counterexample (if any), per-direction coverage, and cross-direction diagnostics.
@freestanding(expression)
@discardableResult
public macro explore<GeneratedValue, PropertyResult>(
    _ gen: RefGen<GeneratedValue>,
    _ settings: ExploreSettings...,
    directions: [(String, (GeneratedValue) -> Bool)],
    property: (GeneratedValue) async throws -> PropertyResult
) -> ExploreReport<GeneratedValue> = #externalMacro(module: "ExhaustMacros", type: "ExploreAsyncMacro")
