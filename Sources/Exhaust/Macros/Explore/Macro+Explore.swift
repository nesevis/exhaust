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
