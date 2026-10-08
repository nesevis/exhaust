#if canImport(ObjectiveC)
    internal import ExhaustObjCSupport
    import Foundation

    /// Runs blocks where an Objective-C exception would otherwise terminate the process.
    package enum ObjCExceptionGuard {
        /// Runs `block` inside an Objective-C `@try`/`@catch`, so an `NSException` raised by the code under test is recorded instead of terminating the process.
        ///
        /// Swift cannot catch an `NSException`: one that unwinds through Swift frames reaches `swift_unexpectedError` and aborts. A caught non-Objective-C exception is reported as an `NSException` named `ExhaustCaughtNonObjCException`. See `ExhaustObjCSupport.h`.
        ///
        /// - Returns: `true` if `block` completed, `false` if it raised. On `false`, `caught` holds the exception.
        @discardableResult
        package static func run(
            _ block: () -> Void,
            _ caught: inout NSException?
        ) -> Bool {
            exhaust_runCatchingObjCException(block, &caught)
        }

        /// Runs `block` inside the Objective-C `@try`/`@catch` and discards any caught exception. Use when only whether `block` completed matters.
        ///
        /// - Returns: `true` if `block` completed, `false` if it raised.
        @discardableResult
        package static func run(_ block: () -> Void) -> Bool {
            var exception: NSException?
            return run(block, &exception)
        }
    }
#else
    /// Stand-in for Foundation's `NSException`, which swift-corelibs-foundation does not provide. Callers only store and nil-check caught exceptions, and on platforms without an Objective-C runtime none can ever be raised, so no instance is ever created.
    package final class NSException {}

    /// Runs blocks where an Objective-C exception would otherwise terminate the process.
    package enum ObjCExceptionGuard {
        /// Runs the block directly on platforms without an Objective-C runtime.
        ///
        /// Objective-C does not compile on Linux, so the ExhaustObjCSupport target is excluded from the dependency graph there. No Objective-C runtime also means no code path can raise an `NSException`, so the guard's job disappears on exactly the platforms that cannot build it: this stand-in invokes the block and always reports success, letting call sites stay identical across platforms. The exception out-parameter is never written and exists only so call sites match the Objective-C wrapper's signature.
        @discardableResult
        package static func run(
            _ block: () -> Void,
            _: inout NSException?
        ) -> Bool {
            block()
            return true
        }

        /// Runs the block directly and reports success, matching the Objective-C overload that discards the exception.
        @discardableResult
        package static func run(_ block: () -> Void) -> Bool {
            var exception: NSException?
            return run(block, &exception)
        }
    }
#endif
