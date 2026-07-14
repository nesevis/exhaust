#if os(macOS)
    import SwiftSyntax
    import SwiftSyntaxBuilder
    import Testing
    @testable import ExhaustMacros

    @Suite("Property closure classification")
    struct ClosureClassificationTests {
        @Test("Single throwing Void call selects the assertion path")
        func singleThrowingVoidCallSelectsAssertionPath() throws {
            let expression: ExprSyntax = "{ value in try validate(value) }"
            let closure = try #require(expression.as(ClosureExprSyntax.self))

            #expect(closureIsVoidReturning(closure))
        }
    }
#endif
