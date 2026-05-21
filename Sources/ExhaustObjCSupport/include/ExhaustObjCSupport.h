#import <Foundation/Foundation.h>

/// Executes a block inside an Objective-C @try/@catch. If the block throws an
/// NSException, it is captured into *caught and the function returns NO.
/// Otherwise the function returns YES and *caught is unchanged.
///
/// Swift cannot catch NSException — it reaches swift_unexpectedError and
/// terminates. This wrapper lets the preemptive concurrent contract runner
/// survive an NSException on a GCD thread, record it as a failure, and
/// continue testing.
FOUNDATION_EXPORT BOOL exhaust_runCatchingObjCException(
    NS_NOESCAPE void (^_Nonnull block)(void),
    NSException *_Nullable *_Nonnull caught
);
