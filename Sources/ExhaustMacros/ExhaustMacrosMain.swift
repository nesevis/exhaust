import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct ExhaustMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        GenerateMacro.self,
        ExhaustTestMacro.self,
        ExtractMacro.self,
        ExamineMacro.self,
        ExploreMacro.self,
        StateMachineMacro.self,
        StateMachineDeclarationMacro.self,
        ModelMacro.self,
        SUTMacro.self,
        CommandMacro.self,
        InvariantMacro.self,
    ]
}
