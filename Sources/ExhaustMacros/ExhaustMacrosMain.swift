import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct ExhaustMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        GenerateMacro.self,
        ExhaustTestMacro.self,
        SampleMacro.self,
        ExploreMacro.self,
    ]
}
