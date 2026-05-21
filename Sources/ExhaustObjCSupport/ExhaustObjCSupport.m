#import "ExhaustObjCSupport.h"

BOOL exhaust_runCatchingObjCException(
    NS_NOESCAPE void (^_Nonnull block)(void),
    NSException *_Nullable *_Nonnull caught
) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        *caught = exception;
        return NO;
    } @catch (...) {
        *caught = [NSException
            exceptionWithName:@"ExhaustCaughtNonObjCException"
            reason:@"A non-Objective-C exception was thrown during concurrent command execution"
            userInfo:nil];
        return NO;
    }
}
