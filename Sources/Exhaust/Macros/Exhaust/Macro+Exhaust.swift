import ExhaustCore

/// Runs a property test that systematically explores the generator's output space, then reports a reduced counterexample on failure.
///
/// ```swift
/// let counterexample = #exhaust(personGen, .budget(.thorough)) { person in
///     person.age >= 0
/// }
/// ```
///
/// The property closure either returns `Bool` (`true` means pass), or returns `Void` and asserts with `#expect`/`#require`, in which case any assertion failure or thrown error counts as a counterexample. Throwing ``PropertySkip`` (or `XCTSkip`) instead skips that invocation: it counts as neither pass nor failure, and skips are tallied in ``ExhaustReport/skippedInvocations``. A `Void` property is re-run once after reduction without suppression, so assertion failures record against the reduced value.
///
/// Each run moves through three phases: coverage tests every parameter's problematic values (range edges, NaN, DST transitions, and so on) in pairwise combination, random sampling draws from the generator's natural distribution, and the first failure from either phase is reduced to a minimal counterexample and reported with a replay seed. The full mechanism is described in docs/EXHAUST-property-testing.md.
///
/// Settings are variadic ``PropertySettings`` values controlling budgets (``ExhaustBudget``), deterministic replay, parallel sampling, output suppression, and diagnostics. Each case documents itself.
///
/// - Returns: The reduced counterexample if the property fails, or `nil` if all test cases pass.
@freestanding(expression)
@discardableResult
public macro exhaust<GeneratedValue, PropertyResult>(
    _ gen: ReflectiveGenerator<GeneratedValue>,
    _ settings: PropertySettings...,
    property: @Sendable (GeneratedValue) throws -> PropertyResult
) -> GeneratedValue? = #externalMacro(module: "ExhaustMacros", type: "ExhaustTestMacro")

/// Reduces a value you already have instead of searching for one.
///
/// Provide a concrete value you suspect is a counterexample, recovered from a bug report, a saved regression, or a previous failure. Exhaust reflects it back through the generator to recover the choices that produce it, then reduces it to a minimal counterexample. The coverage and random-sampling phases do not run: this overload starts from `reflecting` and only reduces.
///
/// ```swift
/// let minimal = #exhaust(personGen, reflecting: personFromBugReport) { person in
///     person.age >= 0
/// }
/// ```
///
/// - Parameter reflecting: A concrete value to reduce. It must be reachable by `gen`. If the generator cannot reflect it, Exhaust reports an issue and returns the value unreduced.
/// - Returns: The reduced counterexample, or `nil` if the value does not fail the property.
@freestanding(expression)
@discardableResult
public macro exhaust<GeneratedValue, PropertyResult>(
    _ gen: ReflectiveGenerator<GeneratedValue>,
    reflecting: GeneratedValue,
    _ settings: PropertySettings...,
    property: @Sendable (GeneratedValue) throws -> PropertyResult
) -> GeneratedValue? = #externalMacro(module: "ExhaustMacros", type: "ExhaustTestMacro")

/// Runs a property test with an async property closure, systematically exploring the generator's output space and reporting a reduced counterexample on failure.
///
/// ```swift
/// let counterexample = await #exhaust(transactionGen, .budget(.thorough)) { txn in
///     let result = try await ledger.process(txn)
///     #expect(result.balance >= 0)
/// }
/// ```
///
/// Use this when the property needs to `await`. The coverage, reduction, and PRNG core runs on a GCD thread, with the async property closure bridged via `Task` + semaphore.
///
/// The property closure either returns `Bool` (`true` means pass), or returns `Void` and asserts with `#expect`/`#require`, in which case any assertion failure or thrown error counts as a counterexample. Throwing ``PropertySkip`` (or `XCTSkip`) instead skips that invocation: it counts as neither pass nor failure, and skips are tallied in ``ExhaustReport/skippedInvocations``. A `Void` property is re-run once after reduction without suppression, so assertion failures record against the reduced value.
///
/// Each run moves through three phases: coverage tests every parameter's problematic values (range edges, NaN, DST transitions, and so on) in pairwise combination, random sampling draws from the generator's natural distribution, and the first failure from either phase is reduced to a minimal counterexample and reported with a replay seed. The full mechanism is described in docs/EXHAUST-property-testing.md.
///
/// Settings are variadic ``PropertySettings`` values controlling budgets (``ExhaustBudget``), deterministic replay, parallel sampling, output suppression, and diagnostics. Each case documents itself.
///
/// - Returns: The reduced counterexample if the property fails, or `nil` if all test cases pass.
@freestanding(expression)
@discardableResult
public macro exhaust<GeneratedValue, PropertyResult>(
    _ gen: ReflectiveGenerator<GeneratedValue>,
    _ settings: PropertySettings...,
    property: @Sendable (GeneratedValue) async throws -> PropertyResult
) -> GeneratedValue? = #externalMacro(module: "ExhaustMacros", type: "ExhaustAsyncTestMacro")

/// Reduces a value you already have instead of searching for one, with an async property closure.
///
/// Use this when you have a concrete value to investigate and the property must `await`. Exhaust reflects the value back through the generator to recover the choices that produce it, then reduces it to a minimal counterexample. The coverage and random-sampling phases do not run: this overload starts from `reflecting` and only reduces.
///
/// ```swift
/// let minimal = await #exhaust(transactionGen, reflecting: txnFromBugReport) { txn in
///     try await ledger.process(txn).balance >= 0
/// }
/// ```
///
/// - Parameter reflecting: A concrete value to reduce. It must be reachable by `gen`. If the generator cannot reflect it, Exhaust reports an issue and returns the value unreduced.
/// - Returns: The reduced counterexample, or `nil` if the value does not fail the property.
@freestanding(expression)
@discardableResult
public macro exhaust<GeneratedValue, PropertyResult>(
    _ gen: ReflectiveGenerator<GeneratedValue>,
    reflecting: GeneratedValue,
    _ settings: PropertySettings...,
    property: @Sendable (GeneratedValue) async throws -> PropertyResult
) -> GeneratedValue? = #externalMacro(module: "ExhaustMacros", type: "ExhaustAsyncTestMacro")
