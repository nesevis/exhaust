// Which coverage recorder a production `time:` run reads, decided from the registries the loader populated before `main`.

/// Chooses the coverage source for a production run from the registries the loader populated before `main`.
package enum FuzzInstrumentationCheck {
    /// What the registries say about this build's instrumentation.
    package enum Selection {
        /// Exactly one recorder registered, and this reads it.
        case source(any CoverageSource)
        /// No instrumented image registered a region, or the only registered recorder could not allocate its context. The two are one case because the caller's remedy is the same diagnostic and a failed allocation has no better one to offer.
        case notInstrumented
        /// Both recorders registered, with their respective edge counts.
        case conflict(guardEdges: Int, counterEdges: Int)

        /// The resolved source, or nil when this build supports none.
        package var source: (any CoverageSource)? {
            guard case let .source(source) = self else {
                return nil
            }
            return source
        }

        /// The two edge counts when both recorders registered, or nil otherwise.
        package var conflictingEdgeCounts: (guardEdges: Int, counterEdges: Int)? {
            guard case let .conflict(guardEdges, counterEdges) = self else {
                return nil
            }
            return (guardEdges, counterEdges)
        }
    }

    /// What the loader registered, without creating a source.
    package struct RegisteredRecorders {
        /// Whether any image registered `trace-pc-guard` regions.
        package let hasTraceGuards: Bool

        /// Edges across every registered inline-8bit-counter region; zero when none registered.
        package let counterEdges: Int

        /// Whether the only coverage this build can report comes through the thread-bound `trace-pc-guard` context, which records nothing for work that runs off the lane that bound it.
        package var isTraceGuardsOnly: Bool {
            hasTraceGuards && counterEdges == 0
        }
    }

    /// What the registries hold. Allocates nothing, so a dispatch can ask before deciding whether it can run at all.
    package static var registeredRecorders: RegisteredRecorders {
        RegisteredRecorders(
            hasTraceGuards: TracePCGuardCoverageSource.isInstrumented,
            counterEdges: SancovRuntime.currentCounterRegions().reduce(0) { $0 + $1.count }
        )
    }

    /// Which coverage source this build supports, or why it supports none.
    ///
    /// A `trace-pc-guard` build gets the isolated source: its edges route through a thread-bound context, so the run neither shares a table with another run nor pays an O(instrumented edges) clear-and-rescan per attempt. A counter build gets the process-global source, which the driver serializes so two runs never clear each other's counters.
    ///
    /// Both together is a conflict rather than a precedence question. The two recorders number their edges independently, so a signature taken against one says nothing about the other, and a run can attribute coverage against exactly one of them; nothing in the build says which. Silently preferring either produces a run whose coverage describes half the binary while the report describes all of it.
    ///
    /// - Parameter harvestsComparisons: Requests comparison-operand harvesting; the driver passes true only when injection can place the operands.
    package static func productionSource(harvestsComparisons: Bool) -> Selection {
        let registered = registeredRecorders
        let counterEdges = registered.counterEdges
        switch (registered.hasTraceGuards, counterEdges > 0) {
            case (true, true):
                return .conflict(guardEdges: TracePCGuardCoverageSource.edgeTotal, counterEdges: counterEdges)
            case (false, true):
                guard let source = SancovCoverageSource(harvestsComparisons: harvestsComparisons) else {
                    return .notInstrumented
                }
                return .source(source)
            case (true, false):
                guard let source = TracePCGuardCoverageSource(harvestsComparisons: harvestsComparisons) else {
                    return .notInstrumented
                }
                return .source(source)
            case (false, false):
                return .notInstrumented
        }
    }
}
