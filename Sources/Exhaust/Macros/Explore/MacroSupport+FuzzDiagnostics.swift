// The configuration diagnostics `#explore(time:)` fails a run with: missing, unobservable, and conflicting coverage instrumentation.

import ExhaustCore

package extension __ExhaustRuntime {
    // MARK: - Instrumentation Diagnostics

    /// The hard-failure diagnostic for an instrumented build whose coverage the run cannot observe, naming the two causes in order of likelihood.
    ///
    /// An optimized build inlines small functions from the instrumented library into an uninstrumented caller, and the inlined copies record nothing; that is the common case in a release fuzz target with flags on the library alone. The other cause is executor isolation under `trace-pc-guard`: work on an executor the run did not bind is invisible to the thread-bound context, and `inline-8bit-counters` records it at the cost of requiring the run to have the process to itself.
    static var unreachableCoverageMessage: String {
        """
        #explore(time:) evaluated the property and recorded no coverage at all, so the search had no signal to follow. A run that reaches \(FuzzTunables.coverageUnreachableAttemptThreshold) attempts this way stops early rather than spending the budget; a shorter run reports it when it ends.

        The build is instrumented, so this is not a missing-flags problem. It means the code the property exercises runs without instrumentation. Two causes, in order of likelihood:

        1. An optimized build inlined the code under test into a module that has no coverage flags. In release configuration the compiler copies small functions into their callers, and a copy compiled as part of an uninstrumented module records nothing. Add the coverage flags to the module that calls the code under test (usually the test target) as well as to the library, and keep `-assert-config Debug` alongside them so `assert` oracles survive.

        2. The property's work runs on an executor the run did not bind: a `@MainActor` function, an actor with a custom executor, or a detached task. `trace-pc-guard` records only on the run's own thread. Switch to counter-based instrumentation, which records regardless of executor:

        .unsafeFlags(["-sanitize=undefined",
                      "-sanitize-coverage=inline-8bit-counters,pc-table"])

        Replace the `trace-pc-guard` flags rather than adding to them: a build carrying both recorders is refused, because the two number their edges independently and nothing says which one a run should read. Counter-based coverage is process-global, so give the run the process to itself: `swift test --no-parallel`, or filter down to the single fuzz test.
        """
    }

    /// The hard-failure diagnostic for a build that compiled in both coverage recorders.
    ///
    /// The two number their edges independently, so a signature taken against one carries no information about the other, and a run attributes coverage against exactly one. Nothing in the build says which, and picking silently gives the run a coverage map of part of the binary under a report that describes all of it.
    static func mixedRecorderMessage(guardEdges: Int, counterEdges: Int) -> String {
        """
        #explore(time:) found both coverage recorders compiled into this process: trace-pc-guard over \(guardEdges) edges and inline-8bit-counters over \(counterEdges) edges.

        A run reads one recorder. The two number their edges independently, so coverage measured against one says nothing about the other, and nothing in the build says which one you meant. Compile with one set of coverage flags:

        .unsafeFlags(["-sanitize=undefined",
                      "-sanitize-coverage=edge,trace-pc-guard,pc-table"])

        or, when the property's work runs on an executor the run does not bind (a `@MainActor` function, an actor with a custom executor, a detached task):

        .unsafeFlags(["-sanitize=undefined",
                      "-sanitize-coverage=inline-8bit-counters,pc-table"])

        Counter-based coverage is process-global, so a run using it needs the process to itself: `swift test --no-parallel`, or filter down to the single fuzz test. Check every target in the dependency graph, not only the one under test: flags on a library and different flags on the test target put both recorders in the same process.
        """
    }

    /// The hard-failure diagnostic for an async sequential spec searched on a `trace-pc-guard` build below macOS 15.
    ///
    /// Calling `async` code from the synchronous search needs a bridge. Above the floor the bridge runs the spec's continuations on the lane that bound the coverage context; below it the only bridge available hands them to the cooperative pool and puts that lane to sleep, so a thread-bound recorder sees none of the work. Counter-based coverage is process-global and has no such lane, which is why it is the way out rather than raising the deployment target.
    static var asyncSequentialNeedsCountersMessage: String {
        """
        #explore(Spec.self, time:) cannot search an async sequential spec on this build: the target is below macOS 15 (iOS 18, tvOS 18, watchOS 11, visionOS 2) and its only coverage instrumentation is `trace-pc-guard`.

        Below that version the bridge from the search to your `async` commands runs them on the cooperative pool, while `trace-pc-guard` records only on the thread the run bound its context to. Every edge your spec reaches would fire on the wrong thread and be dropped, so the search would have no signal and the run would report no coverage at all.

        Instrument with counters instead, which record wherever the work runs:

        .unsafeFlags(["-sanitize=undefined",
                      "-sanitize-coverage=inline-8bit-counters,pc-table"])

        Replace the `trace-pc-guard` flags rather than adding to them; a build carrying both recorders is refused. Counter-based coverage is process-global, so give the run the process to itself: `swift test --no-parallel`, or filter down to the single fuzz test.

        A synchronous spec is unaffected, and so is any spec on macOS 15 or later.
        """
    }

    /// The hard-failure diagnostic for a build without coverage instrumentation, with the flags ready to copy-paste.
    static var missingInstrumentationMessage: String {
        """
        #explore(time:) requires coverage instrumentation, and no instrumented module is loaded. Add the following to the swiftSettings of the target whose coverage you want tracked (typically the library under test):

        .unsafeFlags(["-sanitize=undefined",
                      "-sanitize-coverage=edge,trace-pc-guard,pc-table"],
                     .when(configuration: .debug))

        For a dedicated fuzz target built with `-c release`, drop the `.when(configuration:)` gate, add "-assert-config", "Debug" to the list, and apply the same flags to the test target that calls the code under test. The CoverageGuidedFuzzing article has both recipes.
        """
    }
}
