#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif canImport(WinSDK)
    import WinSDK
#endif

/// Returns the current monotonic time in nanoseconds.
package func monotonicNanoseconds() -> UInt64 {
    #if canImport(Darwin)
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    #elseif canImport(Glibc) || canImport(Musl)
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
    #elseif canImport(WinSDK)
        var counter: Int64 = 0
        var frequency: Int64 = 0
        QueryPerformanceCounter(&counter)
        QueryPerformanceFrequency(&frequency)
        return UInt64(counter) &* 1_000_000_000 / UInt64(frequency)
    #else
        0
    #endif
}
