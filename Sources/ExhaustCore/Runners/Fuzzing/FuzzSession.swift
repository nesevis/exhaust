//
//  FuzzSession.swift
//  Exhaust
//

import Foundation

// MARK: - Fuzz Session

/// Sets up and runs one coverage-guided `time:` run: the runner configuration, the coverage source, crash-recovery resume, and the process-wide claim on coverage counters.
///
/// Every outcome that stops the run before it starts comes back as a case of ``Outcome`` rather than as a message, so the caller words configuration failures for its audience.
package enum FuzzSession {
    /// The run's settings, already parsed and validated by the caller.
    package struct Options {
        package var budgetNanoseconds: UInt64
        package var seed: UInt64
        package var stopOnFirstFault: Bool
        package var skipScreening: Bool
        package var stopWhenSaturated: Bool
        package var logConfiguration: ExhaustLog.Configuration

        package init(
            budgetNanoseconds: UInt64,
            seed: UInt64,
            stopOnFirstFault: Bool,
            skipScreening: Bool,
            stopWhenSaturated: Bool,
            logConfiguration: ExhaustLog.Configuration
        ) {
            self.budgetNanoseconds = budgetNanoseconds
            self.seed = seed
            self.stopOnFirstFault = stopOnFirstFault
            self.skipScreening = skipScreening
            self.stopWhenSaturated = stopWhenSaturated
            self.logConfiguration = logConfiguration
        }
    }

    /// How a session ended.
    package enum Outcome {
        /// The runner ran. `resumed` is true when the run continued a predecessor's crash-recovery state.
        case completed(FuzzRunResult, resumed: Bool)
        /// `EXHAUST_FUZZ_EXPERIMENT` is set but does not parse.
        case invalidExperiment(any Error)
        /// The process carries both coverage recorders.
        case mixedRecorders(guardEdges: Int, counterEdges: Int)
        /// No coverage source is available.
        case instrumentationMissing
        /// Another run already holds the process's coverage counters.
        case anotherRunInFlight
    }

    /// Runs one session.
    ///
    /// - Parameters:
    ///   - generatorIsReflective: Whether reflection can place values into the generator's choice tree, which gates the reflective injection paths.
    ///   - source: Where coverage comes from.
    ///   - configure: Tightens the runner configuration after the session has built it.
    ///   - persistence: Crash-recovery state for the call site, or nil to run without it.
    ///   - renderValue: Renders a value for the fault inventory.
    package static func run<Output>(
        gen: Generator<Output>,
        generatorIsReflective: Bool,
        options: Options,
        source coverage: CoverageSourceSelection,
        configure: ((inout FuzzRunnerConfiguration) -> Void)?,
        hooks: FuzzHooks<Output>?,
        persistence: FuzzPersistenceContext?,
        renderValue: @escaping @Sendable (Any) -> String,
        property: @escaping @Sendable (Output) -> FuzzVerdict
    ) -> Outcome {
        var configuration = FuzzRunnerConfiguration(budgetNanoseconds: options.budgetNanoseconds, seed: options.seed)
        configuration.stopOnFirstFault = options.stopOnFirstFault
        if options.skipScreening {
            configuration.skipScreening = true
        }
        if options.stopWhenSaturated {
            configuration.stopWhenSaturated = true
        }
        // The benchmark arm: read once at run start, release builds included, since the measurement venue is a release binary. Setting the variable is the explicit opt-in; a malformed or unknown knob is a hard configuration error — a silently ignored typo would invalidate a benchmark arm.
        if let experimentValue = ProcessInfo.processInfo.environment["EXHAUST_FUZZ_EXPERIMENT"] {
            do {
                configuration.experiments = try FuzzExperiments.parse(environmentValue: experimentValue)
            } catch {
                return .invalidExperiment(error)
            }
        }

        // The whole-value operand reconstructor, derived from the output type's OperandReconstructable conformance and gated on reflectivity: a non-reflective generator means reflection cannot place a reconstructed value. A reflective composite (a struct) has no whole-type conformance, so this is nil there and the field graft handles it instead.
        let reflectionReconstructor = generatorIsReflective
            ? OperandReconstruction.reconstructor(for: Output.self)
            : nil
        // Injection activates on the presence of trace-cmp instrumentation, not a knob: comparand substitution places operands directly into a parent's flat sequence and needs no reflection, so every run can use a harvested operand, and a build without trace-cmp never fills the pool, so the injection arms stay free. There is no init-time way to detect the flag — its presence shows up as a non-empty pool once a comparison fires. The reflective paths (whole-value through the reconstructor, composites through the field graft) additionally require a reflective generator, gated by their own capability flags.

        // A live source always enables comparison-operand harvesting: the drain is a no-op without trace-cmp instrumentation, and comparand substitution can place operands on any generator.
        let resolvedSource: (any CoverageSource)?
        switch coverage {
            case .production:
                switch FuzzInstrumentationCheck.productionSource(harvestsComparisons: true) {
                    case let .source(source):
                        resolvedSource = source
                    case .notInstrumented:
                        resolvedSource = nil
                    case let .conflict(guardEdges, counterEdges):
                        return .mixedRecorders(guardEdges: guardEdges, counterEdges: counterEdges)
                }
            case .none:
                resolvedSource = nil
            case let .injected(injected):
                resolvedSource = injected
        }
        guard let source = resolvedSource else {
            return .instrumentationMissing
        }

        if let persistence {
            configuration.persistence = persistence
            if let document = persistence.resumeDocument {
                // A resumed run continues the logical run: the remaining slice of the declared budget, straight into the mutation phase.
                //
                // Both phases are skipped for any resume document, including one whose predecessor died partway through screening. Nothing records how far screening got, so the only two options are to skip all of it or to redo all of it, and skipping is the better of the two: the restored corpus already holds the admissions from the rows that ran, and redoing would spend the remaining slice re-deriving them before the mutation phase starts. The cost is that rows after the crash point go untested in this run.
                //
                // A run resumes because something ended the predecessor abnormally, which is a defect the user is expected to fix rather than a state to search from repeatedly, so the untested tail is accepted rather than engineered around. Persisting a screening cursor and restarting at it is the fix if that assumption stops holding.
                let consumed = document.metadata.consumedNanoseconds
                configuration.budgetNanoseconds = options.budgetNanoseconds > consumed ? options.budgetNanoseconds - consumed : 0
                configuration.skipScreening = true
                configuration.skipSampling = true
            }
        }
        configure?(&configuration)

        let needsExclusiveCounters = source.requiresExclusiveProcess
        if needsExclusiveCounters, FuzzRunExclusion.tryBeginRun() == false {
            return .anotherRunInFlight
        }
        defer {
            if needsExclusiveCounters {
                FuzzRunExclusion.endRun()
            }
        }

        let result = ExhaustLog.withConfiguration(options.logConfiguration) {
            let runner = FuzzRunner(
                gen: gen,
                property: property,
                source: source,
                configuration: configuration,
                hooks: hooks,
                reflectionReconstructor: reflectionReconstructor,
                // The graft only reaches a zip-shaped generator, so gate it on that static shape here — a non-composite generator otherwise materializes a parent every attempt before discovering it.
                graftReflective: generatorIsReflective && Interpreters.isZipShaped(gen),
                renderValue: renderValue
            )
            let result = runner.run()
            if result.clusters.isEmpty {
                ExhaustLog.notice(
                    category: .propertyTest,
                    event: "explore_time_no_failures",
                    metadata: [
                        "attempts": "\(result.counts.totalAttempts)",
                        "covered_edges": "\(result.coveredEdgeCount)",
                        "seed": "\(result.seed)",
                    ]
                )
            }
            return result
        }
        return .completed(result, resumed: configuration.persistence?.resumeDocument != nil)
    }
}

// MARK: - Run Exclusion

/// Detects the one clean-signal violation the runtime can see without guessing: two coverage-guided runs in flight at once.
///
/// The isolation a `time:` run needs is documented and is the caller's to arrange, because nothing in-process can tell whether another test is executing instrumented code. Two concurrent fuzz runs are different: each one zeroes the process-global counters at the start of every attempt, so they erase each other's measurements, and the runner can count itself. Left undetected the symptom is a search that wanders and a report whose numbers are fiction, with nothing a reader would recognize as wrong.
enum FuzzRunExclusion {
    private static let isRunInFlight = SendableBox(false)

    /// Claims the process's coverage counters for one run. The caller owes a matching ``endRun()`` only when this returns true; a false return means another run holds the claim and nothing was acquired.
    static func tryBeginRun() -> Bool {
        isRunInFlight.withValue { isInFlight in
            guard isInFlight == false else {
                return false
            }
            isInFlight = true
            return true
        }
    }

    /// Releases a finished run's claim. Paired with every ``tryBeginRun()`` that returned true.
    static func endRun() {
        isRunInFlight.value = false
    }
}
