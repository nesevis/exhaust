import Exhaust
import ExhaustCore
import Foundation
import Testing

#if DEBUG && !EXHAUST_BINARY_CORE
    /// Which recorder a production run picks, driven by what the registries hold. Registers into both process-global registries, so it lives under the serialized registry umbrella.
    extension CoverageRegistryTests {
        @Suite("Coverage source selection")
        struct CoverageSourceSelectionTests {
            @Test("Either recorder alone yields its source; both together are a conflict")
            func productionSourceRefusesAMixedRecorderBuild() throws {
                // Both registries are process-global, so every path here restores them.
                SancovRuntime.resetForTesting()
                TracePCGuardCoverageSource.resetRegistryForTesting()
                defer {
                    SancovRuntime.resetForTesting()
                    TracePCGuardCoverageSource.resetRegistryForTesting()
                }
                let tracePCGuards = TracePCGuardCoverageSource.registerTracePCGuardsForTesting(count: 4)
                defer { tracePCGuards.deallocate() }
                let counters = UnsafeMutablePointer<UInt8>.allocate(capacity: 8)
                counters.update(repeating: 0, count: 8)
                defer { counters.deallocate() }

                // Trace-pc-guards alone: the isolated source.
                let guardsOnly = try #require(FuzzInstrumentationCheck.productionSource(harvestsComparisons: false).source)
                #expect(guardsOnly is TracePCGuardCoverageSource)

                // Both: neither, because the two number their edges independently and nothing says which one the run should read.
                SancovRuntime.registerCounters(start: counters, end: counters + 8)
                let conflict = try #require(
                    FuzzInstrumentationCheck.productionSource(harvestsComparisons: false).conflictingEdgeCounts
                )
                #expect(conflict.guardEdges == 4)
                #expect(conflict.counterEdges == 8)
            }
        }
    }
#endif
