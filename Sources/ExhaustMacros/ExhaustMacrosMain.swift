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
        ExploreAsyncMacro.self,
        ExhaustContractMacro.self,
        ExhaustConcurrentContractMacro.self,
        ExhaustGCDContractMacro.self,
        ExhaustAsyncGCDContractMacro.self,
        ContractDeclarationMacro.self,
        ConcurrentContractDeclarationMacro.self,
        ModelMacro.self,
        SUTMacro.self,
        CommandMacro.self,
        InvariantMacro.self,
        OracleMacro.self,
    ]
}
