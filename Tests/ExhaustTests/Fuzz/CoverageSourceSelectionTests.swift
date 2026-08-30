import Exhaust
import ExhaustCore
import Foundation
import Testing

#if DEBUG
    /// Which recorder a production run picks, driven by what the registries hold. Registers into both process-global registries, so it lives under the serialized registry umbrella.
    extension CoverageRegistryTests {
        @Suite("Coverage source selection")
        struct CoverageSourceSelectionTests {
            @Test("Counters win when both recorders are registered; guards serve alone")
            func productionSourcePrefersCountersWhenBothRegistered() {
                // Both registries are process-global, so every path here restores them.
                SancovRuntime.resetForTesting()
                TracePCGuardCoverageSource.resetRegistryForTesting()
                defer {
                    SancovRuntime.resetForTesting()
                    TracePCGuardCoverageSource.resetRegistryForTesting()
                }
                let guards = TracePCGuardCoverageSource.registerGuardsForTesting(count: 4)
                defer { guards.deallocate() }
                let counters = UnsafeMutablePointer<UInt8>.allocate(capacity: 8)
                counters.update(repeating: 0, count: 8)
                defer { counters.deallocate() }

                // Guards alone: the isolated source.
                #expect(FuzzInstrumentationCheck.productionSource(harvestsComparisons: false) is TracePCGuardCoverageSource)

                // Both: the counters, because a build adds them beside guards only when the guard context cannot see the property's work.
                SancovRuntime.registerCounters(start: counters, end: counters + 8)
                #expect(FuzzInstrumentationCheck.productionSource(harvestsComparisons: false) is SancovCoverageSource)
            }
        }
    }
#endif
