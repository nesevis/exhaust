/// Runs a directed property test that steers sampling toward each declared direction via per-direction CGS tuning.
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
/// Settings are variadic ``ExploreSettings`` values controlling per-direction budgets (``ExhaustBudget``), deterministic replay, parallel tuning, output suppression, and log verbosity. Each case documents itself. The full mechanism is described in <doc:DirectedExploration>.
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

/// Runs a directed property test with an async property closure, steering sampling toward each declared direction via per-direction CGS tuning.
///
/// Directions are named predicates over the output space. Exhaust tunes the generator toward each direction in turn, draws the budgeted number of matching samples, and reports per-direction coverage, cross-direction overlap, and any counterexample. A direction the generator cannot reach is reported rather than silently skipped. The property closure may `await`, and the expanded call is `async`, so call it with `await`.
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
/// Settings are variadic ``ExploreSettings`` values controlling per-direction budgets (``ExhaustBudget``), deterministic replay, parallel tuning, output suppression, and log verbosity. Each case documents itself. The full mechanism is described in <doc:DirectedExploration>.
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
/// The run inherits `#exhaust`'s covering-array and random-sampling phases, then spends the remaining budget in the mutation phase: exploration from corpus parents, guided by branch-coverage feedback from the instrumented target. Failures are cataloged and clustered rather than terminating the run: opting into a time budget is opting into "find everything you can within it".
///
/// ```swift
/// #explore(messageGen, time: .minutes(15)) { message in
///     try Decoder.decode(message)
/// }
/// ```
///
/// Requires coverage instrumentation on the target under test; without it the test fails immediately with the compiler flags to add, before any budget is consumed. Settings are variadic ``PropertyFuzzSettings`` values controlling deterministic replay, output suppression, and log verbosity.
///
/// Use `directions:` mode instead when the goal is guaranteeing named coverage targets within an iteration budget; the two modes are mutually exclusive.
///
/// - Important: This mode is experimental. Its settings, report format, and search behavior may change in any release; every call site emits a build warning until the mode stabilizes.
///
/// - Returns: A ``FuzzReport`` containing the clustered fault inventory, attempt counts, throughput, and coverage summary.
@freestanding(expression)
@discardableResult
public macro explore<GeneratedValue, PropertyResult>(
    _ gen: ReflectiveGenerator<GeneratedValue>,
    time: TimeSpan,
    _ settings: PropertyFuzzSettings...,
    property: @Sendable (GeneratedValue) throws -> PropertyResult
) -> FuzzReport = #externalMacro(module: "ExhaustMacros", type: "ExploreTimeMacro")

/// Runs a coverage-guided property test with an async property closure, continuing past where `#exhaust` would stop until the time budget is consumed.
///
/// The run inherits `#exhaust`'s covering-array and random-sampling phases, then spends the remaining budget in the mutation phase: exploration from corpus parents, guided by branch-coverage feedback from the instrumented target. Failures are cataloged and clustered rather than terminating the run. The property closure may `await`, and the expanded call is `async`, so call it with `await`.
///
/// ```swift
/// await #explore(messageGen, time: .minutes(15)) { message in
///     try await server.roundTrip(message)
/// }
/// ```
///
/// Requires coverage instrumentation on the target under test; without it the test fails immediately with the compiler flags to add, before any budget is consumed. Settings are variadic ``PropertyFuzzSettings`` values controlling deterministic replay, output suppression, and log verbosity.
///
/// Use `directions:` mode instead when the goal is guaranteeing named coverage targets within an iteration budget; the two modes are mutually exclusive.
///
/// - Important: This mode is experimental. Its settings, report format, and search behavior may change in any release; every call site emits a build warning until the mode stabilizes.
///
/// - Returns: A ``FuzzReport`` containing the clustered fault inventory, attempt counts, throughput, and coverage summary.
@freestanding(expression)
@discardableResult
public macro explore<GeneratedValue, PropertyResult>(
    _ gen: ReflectiveGenerator<GeneratedValue>,
    time: TimeSpan,
    _ settings: PropertyFuzzSettings...,
    property: @Sendable (GeneratedValue) async throws -> PropertyResult
) -> FuzzReport = #externalMacro(module: "ExhaustMacros", type: "ExploreTimeAsyncMacro")

/// Runs a coverage-guided spec test under the given ``SearchableExecutionModel`` until the time budget is consumed.
///
/// Where the generator form searches values, this form searches command sequences: the spec's `@Command` methods are drawn, mutated, and reduced as a sequence. Requires coverage instrumentation on the target under test; without it the test fails immediately with the compiler flags to add, before any budget is consumed. The run skips the covering-array screening phase and begins with random sampling, then spends the remaining budget in the mutation phase: exploration from corpus parents guided by branch-coverage feedback. Failures are cataloged and clustered rather than terminating the run.
///
/// `mode: .tasks` on a synchronous spec runs one command at a time, because interleaving needs `await` boundaries. The mode is a ``SearchableExecutionModel``, which has no `.threads`: coverage novelty assumes an attempt's coverage follows from its command sequence, and preemptive scheduling makes it follow from an OS schedule the run can neither observe nor replay. Run those specs under `#execute`, whose race detection relies on repetition rather than coverage.
///
/// ```swift
/// @Test func boundedQueueFuzz() async {
///     await #explore(BoundedQueueSpec.self, mode: .sequential, time: .minutes(5))
/// }
/// ```
///
/// Settings are variadic ``StateMachineFuzzSettings`` values controlling deterministic replay, output suppression, log verbosity, and the per-sequence command limit (``StateMachineFuzzSettings/commandLimit(_:)``).
///
/// - Important: This mode is experimental. Its settings, report format, and search behavior may change in any release; every call site emits a build warning until the mode stabilizes.
///
/// - Note: A spec's `failureDescription()` is not surfaced in `time:` mode; the reported counterexample is the reduced command sequence.
///
/// - Returns: A ``FuzzReport`` containing the clustered fault inventory, attempt counts, throughput, and coverage summary.
@freestanding(expression)
@discardableResult
public macro explore<Spec: StateMachineSpec>(
    _ specType: Spec.Type,
    mode: SearchableExecutionModel,
    time: TimeSpan,
    _ settings: StateMachineFuzzSettings...
) -> FuzzReport = #externalMacro(module: "ExhaustMacros", type: "ExploreSpecTimeMacro")

/// Runs a coverage-guided spec test for an async spec under the given ``SearchableExecutionModel`` until the time budget is consumed.
///
/// Where the generator form searches values, this form searches command sequences: the spec's `@Command` methods are drawn, mutated, and reduced as a sequence. Requires coverage instrumentation on the target under test; without it the test fails immediately with the compiler flags to add, before any budget is consumed. The run skips the covering-array screening phase and begins with random sampling, then spends the remaining budget in the mutation phase: exploration from corpus parents guided by branch-coverage feedback. Failures are cataloged and clustered rather than terminating the run.
///
/// `mode: .sequential` runs the commands one at a time, each awaited in turn. `mode: .tasks` drains each sequence through the cooperative scheduler: every command carries a lane-assigning schedule marker drawn as part of the generated input, so the interleaving itself is searched, mutated, and reduced alongside the commands (``StateMachineFuzzSettings/parallelize(lanes:)`` sets the lane count, defaulting to two). It requires macOS 15, iOS 18, tvOS 18, watchOS 11, or visionOS 2. The mode is a ``SearchableExecutionModel``, which has no `.threads`: coverage novelty assumes an attempt's coverage follows from its command sequence, and preemptive scheduling makes it follow from an OS schedule the run can neither observe nor replay. Run those specs under `#execute`, whose race detection relies on repetition rather than coverage.
///
/// ```swift
/// @Test func concurrentQueueFuzz() async {
///     await #explore(ConcurrentQueueSpec.self, mode: .tasks, time: .minutes(5), .parallelize(lanes: .two))
/// }
/// ```
///
/// Settings are variadic ``StateMachineFuzzSettings`` values controlling deterministic replay, output suppression, log verbosity, the per-sequence command limit (``StateMachineFuzzSettings/commandLimit(_:)``), and the lane count (``StateMachineFuzzSettings/parallelize(lanes:)``).
///
/// - Important: This mode is experimental. Its settings, report format, and search behavior may change in any release; every call site emits a build warning until the mode stabilizes.
///
/// - Note: A spec's `failureDescription()` is not surfaced in `time:` mode; the reported counterexample is the reduced command sequence.
///
/// - Returns: A ``FuzzReport`` containing the clustered fault inventory, attempt counts, throughput, and coverage summary.
@freestanding(expression)
@discardableResult
public macro explore<Spec: AsyncStateMachineSpec>(
    _ specType: Spec.Type,
    mode: SearchableExecutionModel,
    time: TimeSpan,
    _ settings: StateMachineFuzzSettings...
) -> FuzzReport = #externalMacro(module: "ExhaustMacros", type: "ExploreSpecTimeAsyncMacro")

/// Names the missing property closure on a `directions:` call written without one.
///
/// Every expansion of this overload is a compile error; it never runs a test. It exists so that a call missing its trailing closure reaches macro expansion, which reports `#explore requires a property (trailing closure or 'property:' argument)` at the call site. Without it the compiler stops at overload resolution and reports `no exact matches in call to macro 'explore'`, which names neither the missing closure nor the overload the caller meant.
@freestanding(expression)
@discardableResult
public macro explore<GeneratedValue>(
    _ gen: ReflectiveGenerator<GeneratedValue>,
    directions: [(String, (GeneratedValue) -> Bool)],
    _ settings: ExploreSettings...
) -> ExploreReport<GeneratedValue> = #externalMacro(module: "ExhaustMacros", type: "ExploreMacro")

/// Names the missing property closure on a `time:` call written without one.
///
/// Every expansion of this overload is a compile error; it never runs a test. It exists so that a call missing its trailing closure reaches macro expansion, which reports `#explore requires a property (trailing closure or 'property:' argument)` at the call site. Without it the compiler stops at overload resolution and reports `no exact matches in call to macro 'explore'`, which names neither the missing closure nor the overload the caller meant.
@freestanding(expression)
@discardableResult
public macro explore<GeneratedValue>(
    _ gen: ReflectiveGenerator<GeneratedValue>,
    time: TimeSpan,
    _ settings: PropertyFuzzSettings...
) -> FuzzReport = #externalMacro(module: "ExhaustMacros", type: "ExploreTimeMacro")
