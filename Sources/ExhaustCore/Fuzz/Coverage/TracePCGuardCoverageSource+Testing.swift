// Debug-only seams that let an uninstrumented test binary drive the guard recorder with synthetic guards and comparisons.

internal import ExhaustCoverageRuntime

#if DEBUG
    package extension TracePCGuardCoverageSource {
        /// Registers `count` synthetic guards as one image would, returning the guard array so a test can fire them through ``fireGuardForTesting(_:)``. The registry is process-global; pair with ``resetRegistryForTesting()``.
        static func registerGuardsForTesting(count: Int) -> UnsafeMutablePointer<UInt32> {
            let guards = UnsafeMutablePointer<UInt32>.allocate(capacity: max(count, 1))
            guards.update(repeating: 0, count: max(count, 1))
            __sanitizer_cov_trace_pc_guard_init(guards, guards + count)
            return guards
        }

        /// Fires one guard exactly as an instrumented edge would.
        static func fireGuardForTesting(_ guardPointer: UnsafeMutablePointer<UInt32>) {
            __sanitizer_cov_trace_pc_guard(guardPointer)
        }

        /// Fires one 64-bit comparison exactly as an instrumented `==` would. Every synthetic comparison shares one call-site key (this thunk's return address), so a test can assert on operands and counts but not on per-site grouping.
        static func fireComparisonForTesting(_ lhs: UInt64, _ rhs: UInt64) {
            __sanitizer_cov_trace_cmp8(lhs, rhs)
        }

        /// Forgets every registered guard, unbinds the calling thread, and zeroes the off-lane count. The C symbol exists in debug builds only, so the released binary cannot have its registry cleared.
        static func resetRegistryForTesting() {
            exhaust_tpg_reset_registry_for_testing()
        }
    }
#endif
