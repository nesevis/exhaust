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
        ExhaustContractMacro.self,
        ContractDeclarationMacro.self,
        ModelMacro.self,
        SUTMacro.self,
        CommandMacro.self,
        InvariantMacro.self,
    ]
}
