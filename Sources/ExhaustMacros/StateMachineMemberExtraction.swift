import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// MARK: - Member Extraction

//
// Reads the spec's annotated members into the `*Info` models the synthesis layer consumes. Nothing here emits code.

struct CommandInfo {
    let methodName: String
    let parameters: [CommandParameter]
    let weight: String
    let generatorExprs: [String]
    let isAsync: Bool
    let isThrows: Bool
    /// The return type as written in source, or `nil` for void-returning commands. An explicit Void clause (`-> Void`, `-> ()`, `-> Swift.Void`) normalizes to `nil` so the synthesized `run` reports no response value.
    let returnType: String?
    let syntax: FunctionDeclSyntax?
}

/// One parameter of a `@Command` method, splitting the external argument label from the internal binding name.
///
/// A parameter like `func push(_ value: Int)` has no external label (`firstName` is `_`) but a usable binding name (`value`). Reusing the raw `_` as a value expression produces illegal synthesized code, so the two roles are tracked separately.
struct CommandParameter {
    /// External argument label at the call site, or `nil` when the parameter is unlabeled (source `firstName` is `_`).
    let externalLabel: String?
    /// Identifier for the synthesized enum associated value, pattern binding, and value expression. Never `_` — synthesized as `arg{index}` when the source parameter has no usable internal name.
    let bindingName: String
    /// The parameter's type, used for generator qualification and the enum associated-value declaration.
    let type: String
}

struct InvariantInfo {
    let methodName: String
    let isAsync: Bool
    let syntax: FunctionDeclSyntax
}

struct SUTProperty {
    let name: String
    let type: String?
}

func extractSUTProperties(from members: MemberBlockItemListSyntax) -> [SUTProperty] {
    members.flatMap { member -> [SUTProperty] in
        guard let varDecl = member.decl.as(VariableDeclSyntax.self),
              hasAttribute("SystemUnderTest", on: varDecl)
        else { return [] }

        return varDecl.bindings.map { binding in
            let name = binding.pattern.trimmedDescription

            if let typeAnnotation = binding.typeAnnotation {
                return SUTProperty(name: name, type: typeAnnotation.type.trimmedDescription)
            }

            if let initializer = binding.initializer,
               let call = initializer.value.as(FunctionCallExprSyntax.self)
            {
                let callee = call.calledExpression.trimmedDescription
                if isPlausiblyTypeName(callee) {
                    return SUTProperty(name: name, type: callee)
                }
            }

            return SUTProperty(name: name, type: nil)
        }
    }
}

func extractCommands(from members: MemberBlockItemListSyntax) -> [CommandInfo] {
    members.compactMap { member in
        guard let funcDecl = member.decl.as(FunctionDeclSyntax.self),
              let commandAttr = findAttribute("Command", on: funcDecl)
        else { return nil }

        let methodName = funcDecl.name.trimmedDescription
        let parameters = funcDecl.signature.parameterClause.parameters.enumerated().map { index, param in
            let firstName = param.firstName.trimmedDescription
            let secondName = param.secondName?.trimmedDescription
            let externalLabel = firstName == "_" ? nil : firstName
            let rawBinding = secondName ?? firstName
            let bindingName = rawBinding == "_" ? "arg\(index)" : rawBinding
            return CommandParameter(
                externalLabel: externalLabel,
                bindingName: bindingName,
                type: param.type.trimmedDescription
            )
        }

        // Extract weight and generator expressions from @Command(weight:, #gen(...))
        var weight = "1"
        var generatorExprs: [String] = []

        if let argList = commandAttr.arguments?.as(LabeledExprListSyntax.self) {
            for arg in argList {
                if arg.label?.trimmedDescription == "weight" {
                    weight = arg.expression.trimmedDescription
                } else {
                    generatorExprs.append(arg.expression.trimmedDescription)
                }
            }
        }

        let isAsync = funcDecl.signature.effectSpecifiers?.asyncSpecifier != nil
        let isThrows = funcDecl.signature.effectSpecifiers?.throwsClause != nil
        // An explicit Void return clause (-> Void, -> (), -> Swift.Void) carries no response value, so normalize it to the no-clause path. Capturing `()` as a real return value would compare two empty tuples through structurallyEqual, which rejects them and fabricates a response-level linearizability violation.
        let voidReturnSpellings: Set = ["Void", "()", "Swift.Void"]
        let declaredReturnType = funcDecl.signature.returnClause?.type.trimmedDescription
        let returnType = declaredReturnType.flatMap { spelling -> String? in
            voidReturnSpellings.contains(spelling) ? nil : spelling
        }

        return CommandInfo(
            methodName: methodName,
            parameters: parameters,
            weight: weight,
            generatorExprs: generatorExprs,
            isAsync: isAsync,
            isThrows: isThrows,
            returnType: returnType,
            syntax: funcDecl
        )
    }
}

/// One `@Setup`-annotated method: the command shape minus the weight, plus the attribute's generator expressions.
struct SetupInfo {
    let methodName: String
    let parameters: [CommandParameter]
    let generatorExprs: [String]
    let isAsync: Bool
    let isThrows: Bool
    /// Non-nil when the setup method declares a non-void return type. The synthesized dispatch discards the value with `_ =` so the user's build stays warning-free.
    let returnType: String?
    let syntax: FunctionDeclSyntax
}

func extractSetups(from members: MemberBlockItemListSyntax) -> [SetupInfo] {
    members.compactMap { member in
        guard let funcDecl = member.decl.as(FunctionDeclSyntax.self),
              let setupAttr = findAttribute("Setup", on: funcDecl)
        else { return nil }

        let methodName = funcDecl.name.trimmedDescription
        let parameters = funcDecl.signature.parameterClause.parameters.enumerated().map { index, param in
            let firstName = param.firstName.trimmedDescription
            let secondName = param.secondName?.trimmedDescription
            let externalLabel = firstName == "_" ? nil : firstName
            let rawBinding = secondName ?? firstName
            let bindingName = rawBinding == "_" ? "arg\(index)" : rawBinding
            return CommandParameter(
                externalLabel: externalLabel,
                bindingName: bindingName,
                type: param.type.trimmedDescription
            )
        }

        var generatorExprs: [String] = []
        if let argList = setupAttr.arguments?.as(LabeledExprListSyntax.self) {
            for arg in argList {
                generatorExprs.append(arg.expression.trimmedDescription)
            }
        }

        let isAsync = funcDecl.signature.effectSpecifiers?.asyncSpecifier != nil
        let isThrows = funcDecl.signature.effectSpecifiers?.throwsClause != nil
        let voidReturnSpellings: Set = ["Void", "()", "Swift.Void"]
        let declaredReturnType = funcDecl.signature.returnClause?.type.trimmedDescription
        let returnType = declaredReturnType.flatMap { spelling -> String? in
            voidReturnSpellings.contains(spelling) ? nil : spelling
        }

        return SetupInfo(
            methodName: methodName,
            parameters: parameters,
            generatorExprs: generatorExprs,
            isAsync: isAsync,
            isThrows: isThrows,
            returnType: returnType,
            syntax: funcDecl
        )
    }
}

func extractInvariants(from members: MemberBlockItemListSyntax) -> [InvariantInfo] {
    members.compactMap { member in
        guard let funcDecl = member.decl.as(FunctionDeclSyntax.self),
              hasAttribute("Invariant", on: funcDecl)
        else { return nil }
        let isAsync = funcDecl.signature.effectSpecifiers?.asyncSpecifier != nil
        return InvariantInfo(
            methodName: funcDecl.name.trimmedDescription,
            isAsync: isAsync,
            syntax: funcDecl
        )
    }
}

func hasAttribute(_ name: String, on decl: some WithAttributesSyntax) -> Bool {
    decl.attributes.contains { attr in
        attr.as(AttributeSyntax.self)?.attributeName.trimmedDescription == name
    }
}

func findAttribute(_ name: String, on decl: some WithAttributesSyntax) -> AttributeSyntax? {
    decl.attributes.compactMap { attr in
        attr.as(AttributeSyntax.self)
    }.first { $0.attributeName.trimmedDescription == name }
}

struct OracleInfo {
    let methodName: String
    let parameterLabel: String
    let parameterType: String
    let isAsync: Bool
    let isThrows: Bool
    let syntax: FunctionDeclSyntax
}

func extractOracles(from members: MemberBlockItemListSyntax) -> [OracleInfo] {
    members.compactMap { member in
        guard let funcDecl = member.decl.as(FunctionDeclSyntax.self),
              hasAttribute("Oracle", on: funcDecl)
        else { return nil }
        let params = funcDecl.signature.parameterClause.parameters
        guard params.count == 1, let firstParam = params.first else { return nil }
        let isAsync = funcDecl.signature.effectSpecifiers?.asyncSpecifier != nil
        let isThrows = funcDecl.signature.effectSpecifiers?.throwsClause != nil
        return OracleInfo(
            methodName: funcDecl.name.trimmedDescription,
            parameterLabel: firstParam.firstName.trimmedDescription,
            parameterType: firstParam.type.trimmedDescription,
            isAsync: isAsync,
            isThrows: isThrows,
            syntax: funcDecl
        )
    }
}

func oracleMethodsWithWrongParameterCount(from members: MemberBlockItemListSyntax) -> [FunctionDeclSyntax] {
    members.compactMap { member in
        guard let funcDecl = member.decl.as(FunctionDeclSyntax.self),
              hasAttribute("Oracle", on: funcDecl)
        else { return nil }
        let paramCount = funcDecl.signature.parameterClause.parameters.count
        return paramCount == 1 ? nil : funcDecl
    }
}
