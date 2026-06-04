#if os(macOS)
    import MacroTesting
    import SwiftSyntaxMacros
    import Testing
    @testable import ExhaustMacros

    private nonisolated(unsafe) let oracleMacros: [String: any Macro.Type] = [
        "Oracle": OracleMacro.self,
    ]

    @Suite(
        "@Oracle marker macro tests",
        .macros(oracleMacros, record: .failed)
    )
    struct OracleMarkerMacroTests {
        @Test("@Oracle marker macro produces no peer declarations")
        func oracleMarkerMacroProducesNoPeerDeclarations() {
            assertMacro {
                """
                @Oracle
                func check(other: MyCounter) -> Bool { true }
                """
            } expansion: {
                """
                func check(other: MyCounter) -> Bool { true }
                """
            }
        }
    }

#endif
