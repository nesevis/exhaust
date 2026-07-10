/// Runs a classification-aware property test that steers sampling toward each declared direction via per-direction CGS tuning.
///
/// Directions are named predicates over the output space. Exhaust tunes the generator toward each direction in turn, draws the budgeted number of matching samples, and reports per-direction coverage, cross-direction overlap, and any counterexample. A direction the generator cannot reach is reported rather than silently skipped.
///
/// ```swift
/// let report = #explore(crossingGen,
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
/// Settings are variadic ``ExploreSettings`` values controlling per-direction budgets (``ExhaustBudget``), deterministic replay, parallel tuning, output suppression, and log verbosity. Each case documents itself. The full mechanism is described in docs/EXPLORE-directed-exploration.md.
///
/// - Returns: An ``ExploreReport`` containing the counterexample (if any), per-direction coverage, and cross-direction diagnostics.
@freestanding(expression)
@discardableResult
public macro explore<GeneratedValue, PropertyResult>(
    _ gen: ReflectiveGenerator<GeneratedValue>,
    directions: [(String, (GeneratedValue) -> Bool)],
    _ settings: ExploreSettings...,
    property: @Sendable (GeneratedValue) throws -> PropertyResult
) -> ExploreReport<GeneratedValue> = #externalMacro(module: "ExhaustMacros", type: "ExploreMacro")

/// Runs a classification-aware property test with an async property closure, steering sampling toward each declared direction via per-direction CGS tuning.
///
/// Directions are named predicates over the output space. Exhaust tunes the generator toward each direction in turn, draws the budgeted number of matching samples, and reports per-direction coverage, cross-direction overlap, and any counterexample. A direction the generator cannot reach is reported rather than silently skipped. Use this overload when the property needs to `await`. The expanded call is `async`, so call it with `await`.
///
/// ```swift
/// let report = try await #explore(crossingGen,
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
/// Settings are variadic ``ExploreSettings`` values controlling per-direction budgets (``ExhaustBudget``), deterministic replay, parallel tuning, output suppression, and log verbosity. Each case documents itself. The full mechanism is described in docs/EXPLORE-directed-exploration.md.
///
/// - Returns: An ``ExploreReport`` containing the counterexample (if any), per-direction coverage, and cross-direction diagnostics.
@freestanding(expression)
@discardableResult
public macro explore<GeneratedValue, PropertyResult>(
    _ gen: ReflectiveGenerator<GeneratedValue>,
    directions: [(String, (GeneratedValue) -> Bool)],
    _ settings: ExploreSettings...,
    property: @Sendable (GeneratedValue) async throws -> PropertyResult
) -> ExploreReport<GeneratedValue> = #externalMacro(module: "ExhaustMacros", type: "ExploreAsyncMacro")

/// Runs a coverage-guided property test that continues past where `#exhaust` would stop, mutating from a corpus toward novel SUT coverage until the time budget is consumed.
///
/// The run inherits `#exhaust`'s covering-array and random-sampling phases, then sprawls: mutation-based exploration from corpus parents, guided by branch-coverage feedback from the instrumented target. Failures are catalogued and clustered rather than terminating the run — opting into a time budget is opting into "find everything you can within it".
///
/// ```swift
/// #explore(messageGen, time: .minutes(15)) { message in
///     try Decoder.decode(message)
/// }
/// ```
///
/// Requires coverage instrumentation on the target under test; without it the test fails immediately with the compiler flags to add, before any budget is consumed. Settings are variadic ``SprawlSettings`` values controlling deterministic replay, output suppression, and log verbosity.
///
/// Use `directions:` mode instead when the goal is guaranteeing named coverage targets within an iteration budget; the two modes are mutually exclusive.
///
/// - Returns: A ``SprawlReport`` containing the clustered fault inventory, attempt counts, throughput, and coverage summary.
@available(macOS 13.0, iOS 16.0, macCatalyst 16.0, tvOS 16.0, watchOS 9.0, *)
@freestanding(expression)
@discardableResult
public macro explore<GeneratedValue, PropertyResult>(
    _ gen: ReflectiveGenerator<GeneratedValue>,
    time: Duration,
    _ settings: SprawlSettings...,
    property: @Sendable (GeneratedValue) throws -> PropertyResult
) -> SprawlReport = #externalMacro(module: "ExhaustMacros", type: "ExploreTimeMacro")

/// Runs a coverage-guided property test with an async property closure, continuing past where `#exhaust` would stop until the time budget is consumed.
///
/// The run inherits `#exhaust`'s covering-array and random-sampling phases, then sprawls: mutation-based exploration from corpus parents, guided by branch-coverage feedback from the instrumented target. Failures are catalogued and clustered rather than terminating the run. Use this overload when the property needs to `await`. The expanded call is `async`, so call it with `await`.
///
/// ```swift
/// await #explore(messageGen, time: .minutes(15)) { message in
///     try await server.roundTrip(message)
/// }
/// ```
///
/// Requires coverage instrumentation on the target under test; without it the test fails immediately with the compiler flags to add, before any budget is consumed. Settings are variadic ``SprawlSettings`` values controlling deterministic replay, output suppression, and log verbosity.
///
/// Use `directions:` mode instead when the goal is guaranteeing named coverage targets within an iteration budget; the two modes are mutually exclusive.
///
/// - Returns: A ``SprawlReport`` containing the clustered fault inventory, attempt counts, throughput, and coverage summary.
@available(macOS 13.0, iOS 16.0, macCatalyst 16.0, tvOS 16.0, watchOS 9.0, *)
@freestanding(expression)
@discardableResult
public macro explore<GeneratedValue, PropertyResult>(
    _ gen: ReflectiveGenerator<GeneratedValue>,
    time: Duration,
    _ settings: SprawlSettings...,
    property: @Sendable (GeneratedValue) async throws -> PropertyResult
) -> SprawlReport = #externalMacro(module: "ExhaustMacros", type: "ExploreTimeAsyncMacro")
