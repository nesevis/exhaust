#if os(macOS)
    import MacroTesting
    import SwiftSyntaxMacros
    @testable import ExhaustMacros

    /// The macro table every `@StateMachine` expansion suite runs against. Shared so the suites cannot drift apart on which markers are registered.
    nonisolated(unsafe) let testMacros: [String: any Macro.Type] = [
        "StateMachine": StateMachineDeclarationMacro.self,
        "SystemUnderTest": SUTMacro.self,
        "Command": CommandMacro.self,
        "Setup": SetupMacro.self,
        "Invariant": InvariantMacro.self,
        "Equivalence": EquivalenceMacro.self,
    ]

#endif
