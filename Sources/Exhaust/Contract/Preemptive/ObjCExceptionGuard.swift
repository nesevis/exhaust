#if canImport(ObjectiveC)
// On Apple platforms `exhaust_runCatchingObjCException` comes from the ExhaustObjCSupport target, an Objective-C `@try`/`@catch` wrapper. See ExhaustObjCSupport.h.
#else
    import Foundation

    /// Runs the block directly on platforms without an Objective-C runtime.
    ///
    /// Objective-C does not compile on Linux, so the ExhaustObjCSupport target is excluded from the dependency graph there. No Objective-C runtime also means no code path can raise an `NSException`, so the guard's job disappears on exactly the platforms that cannot build it: this stand-in invokes the block and always reports success, letting the preemptive runner call sites stay identical across platforms. The exception out-parameter is never written and exists only so call sites match the Objective-C wrapper's signature.
    @discardableResult
    func exhaust_runCatchingObjCException(
        _ block: () -> Void,
        _: inout NSException?
    ) -> Bool {
        block()
        return true
    }
#endif
