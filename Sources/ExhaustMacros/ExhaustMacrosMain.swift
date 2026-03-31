import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct ExhaustMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        GenerateMacro.self,
        ExhaustTestMacro.self,
        ExhaustAsyncTestMacro.self,
        ExampleMacro.self,
        ExamineMacro.self,
        ExploreMacro.self,
        ExhaustContractMacro.self,
        ExhaustAsyncContractMacro.self,
        ContractDeclarationMacro.self,
        ModelMacro.self,
        SUTMacro.self,
        CommandMacro.self,
        InvariantMacro.self,
    ]
}
