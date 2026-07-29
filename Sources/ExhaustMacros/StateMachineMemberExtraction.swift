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
        let parameters = extractParameters(from: funcDecl)

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
        let returnType = nonVoidReturnType(of: funcDecl)

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
        let parameters = extractParameters(from: funcDecl)

        var generatorExprs: [String] = []
        if let argList = setupAttr.arguments?.as(LabeledExprListSyntax.self) {
            for arg in argList {
                generatorExprs.append(arg.expression.trimmedDescription)
            }
        }

        let isAsync = funcDecl.signature.effectSpecifiers?.asyncSpecifier != nil
        let isThrows = funcDecl.signature.effectSpecifiers?.throwsClause != nil
        let returnType = nonVoidReturnType(of: funcDecl)

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

/// Maps a method's parameter list into the binding model the synthesized enum cases and dispatch use.
///
/// An `_` external label becomes no label, and an `_` binding name becomes a positional `arg{n}` so the synthesized `case let` pattern still has something to bind.
func extractParameters(from funcDecl: FunctionDeclSyntax) -> [CommandParameter] {
    funcDecl.signature.parameterClause.parameters.enumerated().map { index, param in
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
}

/// The method's declared return type, or nil when it returns Void in any spelling.
///
/// An explicit Void return clause (-> Void, -> (), -> Swift.Void) carries no response value, so it normalizes to the no-clause path. Capturing `()` as a real return value would make every such command match every ordering on responses, which is what `.returnedVoid` already means, while costing the checker a comparison per replay to learn nothing.
func nonVoidReturnType(of funcDecl: FunctionDeclSyntax) -> String? {
    let voidReturnSpellings: Set = ["Void", "()", "Swift.Void"]
    let declaredReturnType = funcDecl.signature.returnClause?.type.trimmedDescription
    return declaredReturnType.flatMap { spelling -> String? in
        voidReturnSpellings.contains(spelling) ? nil : spelling
    }
}

/// Whether a method is declared `static` or `class`.
///
/// Every synthesized dispatch is instance dispatch (`self.method(...)`, `check(invariant())`), which Swift rejects for type members, so the macro diagnoses these modifiers rather than emitting an expansion that fails with a confusing error inside synthesized code.
func hasTypeMemberModifier(_ funcDecl: FunctionDeclSyntax) -> Bool {
    funcDecl.modifiers.contains { modifier in
        let name = modifier.name.trimmedDescription
        return name == "static" || name == "class"
    }
}

/// Whether a method's parameters are shapes the synthesized `Command`/`SetupStep` enum cannot represent.
///
/// A generic, `inout`, or variadic parameter has no stable stored form to put in an enum payload, so the macro rejects the method rather than synthesizing a case that will not compile.
func hasUnsupportedParameters(_ funcDecl: FunctionDeclSyntax) -> Bool {
    if funcDecl.genericParameterClause != nil {
        return true
    }
    let parameters = funcDecl.signature.parameterClause.parameters
    let hasInoutParam = parameters.contains {
        $0.type.as(AttributedTypeSyntax.self)?.specifiers.contains { $0.trimmedDescription == "inout" } ?? false
    }
    let hasVariadicParam = parameters.contains {
        $0.ellipsis != nil
    }
    return hasInoutParam || hasVariadicParam
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

struct EquivalenceInfo {
    let methodName: String
    let parameterLabel: String
    let parameterType: String
    let isAsync: Bool
    let isThrows: Bool
    let syntax: FunctionDeclSyntax
}

func extractEquivalences(from members: MemberBlockItemListSyntax) -> [EquivalenceInfo] {
    members.compactMap { member in
        guard let funcDecl = member.decl.as(FunctionDeclSyntax.self),
              hasAttribute("Equivalence", on: funcDecl)
        else { return nil }
        let params = funcDecl.signature.parameterClause.parameters
        guard params.count == 1, let firstParam = params.first else { return nil }
        let isAsync = funcDecl.signature.effectSpecifiers?.asyncSpecifier != nil
        let isThrows = funcDecl.signature.effectSpecifiers?.throwsClause != nil
        return EquivalenceInfo(
            methodName: funcDecl.name.trimmedDescription,
            parameterLabel: firstParam.firstName.trimmedDescription,
            parameterType: firstParam.type.trimmedDescription,
            isAsync: isAsync,
            isThrows: isThrows,
            syntax: funcDecl
        )
    }
}

func equivalenceMethodsWithWrongParameterCount(from members: MemberBlockItemListSyntax) -> [FunctionDeclSyntax] {
    members.compactMap { member in
        guard let funcDecl = member.decl.as(FunctionDeclSyntax.self),
              hasAttribute("Equivalence", on: funcDecl)
        else { return nil }
        let paramCount = funcDecl.signature.parameterClause.parameters.count
        return paramCount == 1 ? nil : funcDecl
    }
}
