import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct ExhaustMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        GenerateMacro.self,
        GenerateFromDecodableMacro.self,
        GenerateFromCodableInstanceMacro.self,
        ExhaustTestMacro.self,
        ExhaustAsyncTestMacro.self,
        ExampleMacro.self,
        ExamineMacro.self,
        ExploreMacro.self,
        ExploreAsyncMacro.self,
        ExploreTimeMacro.self,
        ExploreTimeAsyncMacro.self,
        ExhaustStateMachineMacro.self,
        ExhaustAsyncStateMachineMacro.self,
        ExecuteTimeMacro.self,
        StateMachineDeclarationMacro.self,
        SUTMacro.self,
        CommandMacro.self,
        InvariantMacro.self,
        OracleMacro.self,
    ]
}
