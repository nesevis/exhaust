//
//  Parser.swift
//  Exhaust
//
//  Created by Chris Kolbu on 21/3/2026.
//

import Foundation
import Testing
@testable import Exhaust

@Suite("Shrinking Challenge: Parser")
struct ParserShrinkingChallenge {
    /*
     https://github.com/mc-imperial/hypothesis-ecoop-2020-artifact/tree/master/smartcheck-benchmarks/evaluations/parser
     Based on the SmartCheck paper. A simple language AST is serialized to a string
     and then parsed back. The parser has two bugs:
       1. `And` is parsed with swapped operands.
       2. `Or` is parsed as `And` with swapped operands.
     The property `parse(serialize(lang)) == lang` fails for any AST containing
     `And` with non-equal operands (bug 1 swaps them) or any `Or` expression
     (bug 2 changes Or to And).

     The expected minimal counterexample is the simplest Lang wrapping an Or
     expression: `Lang([], [Func(a, [Or(Int(0), Int(0))], [])])`.
     Even equal operands trigger bug 2 since it changes the constructor.
     */

    @Test("Parser, Full")
    func parserFull() throws {
//        ExhaustLog.setConfiguration(.init(isEnabled: true, minimumLevel: .info, categoryMinimumLevels: [.reducer: .debug], format: .human))
        var report: ExhaustReport?
        let output = try #require(
            #exhaust(
                Self.langGen,
//                .randomOnly, // coverage takes a long time
                .suppressIssueReporting,
                .onReport { report = $0 }
            ) { lang in
                Self.parse(Self.serialize(lang)) == lang
            }
        )
        if let report { print("[PROFILE] Parser: \(report.profilingSummary)") }

        print("Output: \(output)")
        #expect(Self.parse(Self.serialize(output)) != output)

        // Size metric matches the SmartCheck/Hypothesis evaluation.
        // Hypothesis achieves ~3.31, QuickCheck ~3.99, SmartCheck ~4.08.
        // Exhaust averages ~3.67
        let outputSize = Self.size(output)
        print("Size: \(outputSize)")
        #expect(outputSize <= 4)
    }

    // MARK: - Types

    struct Lang: Equatable, CustomDebugStringConvertible {
        let modules: [Mod]
        let funcs: [Func]

        var debugDescription: String {
            "Lang(\(modules), \(funcs))"
        }
    }

    struct Mod: Equatable, CustomDebugStringConvertible {
        let imports: [Var]
        let exports: [Var]

        var debugDescription: String {
            "Mod(\(imports), \(exports))"
        }
    }

    struct Func: Equatable, CustomDebugStringConvertible {
        let name: Var
        let args: [Exp]
        let body: [Stmt]

        var debugDescription: String {
            "Func(\(name), \(args), \(body))"
        }
    }

    enum Stmt: Equatable, CustomDebugStringConvertible {
        case assign(Var, Exp)
        case alloc(Var, Exp)
        case ret(Exp)

        var debugDescription: String {
            switch self {
            case let .assign(variable, expression):
                "Assign(\(variable), \(expression))"
            case let .alloc(variable, expression):
                "Alloc(\(variable), \(expression))"
            case let .ret(expression):
                "Return(\(expression))"
            }
        }
    }

    indirect enum Exp: Equatable, CustomDebugStringConvertible {
        case int(Int)
        case bool(Bool)
        case add(Exp, Exp)
        case sub(Exp, Exp)
        case mul(Exp, Exp)
        case div(Exp, Exp)
        case not(Exp)
        case and(Exp, Exp)
        case or(Exp, Exp)

        var debugDescription: String {
            switch self {
            case let .int(value): "Int(\(value))"
            case let .bool(value): "Bool(\(value))"
            case let .add(lhs, rhs): "Add(\(lhs), \(rhs))"
            case let .sub(lhs, rhs): "Sub(\(lhs), \(rhs))"
            case let .mul(lhs, rhs): "Mul(\(lhs), \(rhs))"
            case let .div(lhs, rhs): "Div(\(lhs), \(rhs))"
            case let .not(inner): "Not(\(inner))"
            case let .and(lhs, rhs): "And(\(lhs), \(rhs))"
            case let .or(lhs, rhs): "Or(\(lhs), \(rhs))"
            }
        }
    }

    struct Var: Equatable, CustomDebugStringConvertible {
        let name: String

        var debugDescription: String {
            name
        }
    }

    // MARK: - Serializer

    static func serialize(_ lang: Lang) -> String {
        let mods = lang.modules.map { serialize($0) }.joined(separator: ";")
        let fns = lang.funcs.map { serialize($0) }.joined(separator: ";")
        return "Lang (\(mods)) (\(fns))"
    }

    static func serialize(_ mod: Mod) -> String {
        let imps = mod.imports.map(\.name).joined(separator: ":")
        let exps = mod.exports.map(\.name).joined(separator: ":")
        return "Mod (\(imps)) (\(exps))"
    }

    static func serialize(_ function: Func) -> String {
        let args = function.args.map { serialize($0) }.joined(separator: ",")
        let stmts = function.body.map { serialize($0) }.joined(separator: ",")
        return "Func \(function.name.name) (\(args)) (\(stmts))"
    }

    static func serialize(_ stmt: Stmt) -> String {
        switch stmt {
        case let .assign(variable, expression):
            "Assign \(variable.name) (\(serialize(expression)))"
        case let .alloc(variable, expression):
            "Alloc \(variable.name) (\(serialize(expression)))"
        case let .ret(expression):
            "Return (\(serialize(expression)))"
        }
    }

    static func serialize(_ expression: Exp) -> String {
        switch expression {
        case let .int(value):
            "Int \(value)"
        case let .bool(value):
            "Bool \(value)"
        case let .add(lhs, rhs):
            "Add (\(serialize(lhs))) (\(serialize(rhs)))"
        case let .sub(lhs, rhs):
            "Sub (\(serialize(lhs))) (\(serialize(rhs)))"
        case let .mul(lhs, rhs):
            "Mul (\(serialize(lhs))) (\(serialize(rhs)))"
        case let .div(lhs, rhs):
            "Div (\(serialize(lhs))) (\(serialize(rhs)))"
        case let .not(inner):
            "Not (\(serialize(inner)))"
        case let .and(lhs, rhs):
            "And (\(serialize(lhs))) (\(serialize(rhs)))"
        case let .or(lhs, rhs):
            "Or (\(serialize(lhs))) (\(serialize(rhs)))"
        }
    }

    // MARK: - Parser (with bugs)

    /// Parses a Lang from its serialized string representation.
    /// Contains two intentional bugs matching the SmartCheck paper:
    ///   1. `And` is parsed with swapped operands.
    ///   2. `Or` is parsed as `And` with swapped operands.
    static func parse(_ input: String) -> Lang? {
        var cursor = input[...]
        return parseLang(&cursor)
    }

    private static func parseLang(_ cursor: inout Substring) -> Lang? {
        guard consume("Lang", from: &cursor) else {
            return nil
        }
        guard let modsStr = parseParenGroup(&cursor) else {
            return nil
        }
        guard let funcsStr = parseParenGroup(&cursor) else {
            return nil
        }
        let mods = parseSemicolonSeparated(modsStr) { parseMod(&$0) }
        let fns = parseSemicolonSeparated(funcsStr) { parseFunc(&$0) }
        return Lang(modules: mods, funcs: fns)
    }

    private static func parseMod(_ cursor: inout Substring) -> Mod? {
        guard consume("Mod", from: &cursor) else {
            return nil
        }
        guard let impsStr = parseParenGroup(&cursor) else {
            return nil
        }
        guard let expsStr = parseParenGroup(&cursor) else {
            return nil
        }
        let imps = parseColonSeparated(impsStr).map { Var(name: String($0)) }
        let exps = parseColonSeparated(expsStr).map { Var(name: String($0)) }
        return Mod(imports: imps, exports: exps)
    }

    private static func parseFunc(_ cursor: inout Substring) -> Func? {
        guard consume("Func", from: &cursor) else {
            return nil
        }
        skipSpaces(&cursor)
        guard let name = parseWord(&cursor) else {
            return nil
        }
        guard let argsStr = parseParenGroup(&cursor) else {
            return nil
        }
        guard let stmtsStr = parseParenGroup(&cursor) else {
            return nil
        }
        let args = parseCommaSeparated(argsStr) { parseExp(&$0) }
        let stmts = parseCommaSeparated(stmtsStr) { parseStmt(&$0) }
        return Func(name: Var(name: String(name)), args: args, body: stmts)
    }

    private static func parseStmt(_ cursor: inout Substring) -> Stmt? {
        skipSpaces(&cursor)
        if consume("Assign", from: &cursor) {
            skipSpaces(&cursor)
            guard let name = parseWord(&cursor) else {
                return nil
            }
            guard let expStr = parseParenGroup(&cursor) else {
                return nil
            }
            var expCursor = expStr
            guard let expression = parseExp(&expCursor) else {
                return nil
            }
            return .assign(Var(name: String(name)), expression)
        } else if consume("Alloc", from: &cursor) {
            skipSpaces(&cursor)
            guard let name = parseWord(&cursor) else {
                return nil
            }
            guard let expStr = parseParenGroup(&cursor) else {
                return nil
            }
            var expCursor = expStr
            guard let expression = parseExp(&expCursor) else {
                return nil
            }
            return .alloc(Var(name: String(name)), expression)
        } else if consume("Return", from: &cursor) {
            guard let expStr = parseParenGroup(&cursor) else {
                return nil
            }
            var expCursor = expStr
            guard let expression = parseExp(&expCursor) else {
                return nil
            }
            return .ret(expression)
        }
        return nil
    }

    private static func parseExp(_ cursor: inout Substring) -> Exp? {
        skipSpaces(&cursor)
        if consume("Int", from: &cursor) {
            skipSpaces(&cursor)
            guard let value = parseInt(&cursor) else {
                return nil
            }
            return .int(value)
        } else if consume("Bool", from: &cursor) {
            skipSpaces(&cursor)
            if consume("true", from: &cursor) {
                return .bool(true)
            } else if consume("false", from: &cursor) {
                return .bool(false)
            }
            return nil
        } else if consume("Add", from: &cursor) {
            return parseBinaryExp(&cursor) { .add($0, $1) }
        } else if consume("Sub", from: &cursor) {
            return parseBinaryExp(&cursor) { .sub($0, $1) }
        } else if consume("Mul", from: &cursor) {
            return parseBinaryExp(&cursor) { .mul($0, $1) }
        } else if consume("Div", from: &cursor) {
            return parseBinaryExp(&cursor) { .div($0, $1) }
        } else if consume("Not", from: &cursor) {
            guard let innerStr = parseParenGroup(&cursor) else {
                return nil
            }
            var innerCursor = innerStr
            guard let inner = parseExp(&innerCursor) else {
                return nil
            }
            return .not(inner)
        } else if consume("And", from: &cursor) {
            // BUG 1: operands are swapped
            return parseBinaryExp(&cursor) { lhs, rhs in .and(rhs, lhs) }
        } else if consume("Or", from: &cursor) {
            // BUG 2: parsed as And with swapped operands
            return parseBinaryExp(&cursor) { lhs, rhs in .and(rhs, lhs) }
        }
        return nil
    }

    private static func parseBinaryExp(
        _ cursor: inout Substring,
        constructor: (Exp, Exp) -> Exp
    ) -> Exp? {
        guard let lhsStr = parseParenGroup(&cursor) else {
            return nil
        }
        guard let rhsStr = parseParenGroup(&cursor) else {
            return nil
        }
        var lhsCursor = lhsStr
        var rhsCursor = rhsStr
        guard let lhs = parseExp(&lhsCursor) else {
            return nil
        }
        guard let rhs = parseExp(&rhsCursor) else {
            return nil
        }
        return constructor(lhs, rhs)
    }

    // MARK: - Parser Helpers

    private static func skipSpaces(_ cursor: inout Substring) {
        cursor = cursor.drop(while: { $0 == " " })
    }

    private static func consume(_ prefix: String, from cursor: inout Substring) -> Bool {
        skipSpaces(&cursor)
        if cursor.hasPrefix(prefix) {
            cursor = cursor.dropFirst(prefix.count)
            return true
        }
        return false
    }

    private static func parseWord(_ cursor: inout Substring) -> Substring? {
        let word = cursor.prefix(while: { $0.isLetter || $0.isNumber })
        guard word.isEmpty == false else {
            return nil
        }
        cursor = cursor.dropFirst(word.count)
        return word
    }

    private static func parseInt(_ cursor: inout Substring) -> Int? {
        var numStr = ""
        if cursor.first == "-" {
            numStr.append("-")
            cursor = cursor.dropFirst()
        }
        let digits = cursor.prefix(while: { $0.isNumber })
        guard digits.isEmpty == false else {
            return nil
        }
        numStr.append(contentsOf: digits)
        cursor = cursor.dropFirst(digits.count)
        return Int(numStr)
    }

    /// Parses a `(...)` group, returning the content between the parens.
    private static func parseParenGroup(_ cursor: inout Substring) -> Substring? {
        skipSpaces(&cursor)
        guard cursor.first == "(" else {
            return nil
        }
        cursor = cursor.dropFirst()
        var depth = 1
        var endIndex = cursor.startIndex
        while endIndex < cursor.endIndex {
            if cursor[endIndex] == "(" {
                depth += 1
            } else if cursor[endIndex] == ")" {
                depth -= 1
                if depth == 0 {
                    let content = cursor[cursor.startIndex ..< endIndex]
                    cursor = cursor[cursor.index(after: endIndex)...]
                    return content
                }
            }
            endIndex = cursor.index(after: endIndex)
        }
        return nil
    }

    private static func parseSemicolonSeparated<Result>(
        _ input: Substring,
        parser: (inout Substring) -> Result?
    ) -> [Result] {
        guard input.isEmpty == false else {
            return []
        }
        return input.split(separator: ";").compactMap { part in
            var cursor = part[...]
            return parser(&cursor)
        }
    }

    private static func parseCommaSeparated<Result>(
        _ input: Substring,
        parser: (inout Substring) -> Result?
    ) -> [Result] {
        guard input.isEmpty == false else {
            return []
        }
        return splitTopLevel(input, separator: ",").compactMap { part in
            var cursor = part[...]
            return parser(&cursor)
        }
    }

    private static func parseColonSeparated(_ input: Substring) -> [Substring] {
        guard input.isEmpty == false else {
            return []
        }
        return input.split(separator: ":")
    }

    /// Splits on a separator character, but only at the top level (not inside parentheses).
    private static func splitTopLevel(_ input: Substring, separator: Character) -> [Substring] {
        var results: [Substring] = []
        var depth = 0
        var start = input.startIndex
        var index = input.startIndex
        while index < input.endIndex {
            let character = input[index]
            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
            } else if character == separator, depth == 0 {
                results.append(input[start ..< index])
                start = input.index(after: index)
            }
            index = input.index(after: index)
        }
        results.append(input[start ..< input.endIndex])
        return results
    }

    // MARK: - Generators

    static var varGen: ReflectiveGenerator<Var> {
        // Single lowercase ASCII letter — avoids Unicode/empty-name edge cases
        // that would break the serializer/parser roundtrip for non-bug reasons.
        #gen(.int(in: 0 ... 25))
            .mapped(
                forward: { Var(name: String(Character(UnicodeScalar(UInt8(97 + $0))))) },
                backward: { Int($0.name.first?.asciiValue ?? 97) - 97 }
            )
    }

    static func expGen(depth: UInt64) -> ReflectiveGenerator<Exp> {
        let intLeaf = #gen(.int(in: -10 ... 10))
            .mapped(
                forward: { Exp.int($0) },
                backward: { value in
                    if case let .int(inner) = value { return inner }
                    return 0
                }
            )
        let boolLeaf = #gen(.bool())
            .mapped(
                forward: { Exp.bool($0) },
                backward: { value in
                    if case let .bool(inner) = value { return inner }
                    return false
                }
            )

        guard depth > 0 else {
            return #gen(.oneOf(weighted: (1, intLeaf), (1, boolLeaf)))
        }

        let child = expGen(depth: depth - 1)

        let notExp = #gen(child)
            .mapped(
                forward: { Exp.not($0) },
                backward: { value in
                    if case let .not(inner) = value { return inner }
                    return .int(0)
                }
            )

        func binaryExp(
            _ constructor: @Sendable @escaping (Exp, Exp) -> Exp,
            _ destructor: @Sendable @escaping (Exp) -> (Exp, Exp)?
        ) -> ReflectiveGenerator<Exp> {
            #gen(child, child)
                .mapped(
                    forward: { lhs, rhs in constructor(lhs, rhs) },
                    backward: { value in
                        if let pair = destructor(value) {
                            return pair
                        }
                        return (.int(0), .int(0))
                    }
                )
        }

        let addExp = binaryExp(Exp.add) {
            guard case let .add(lhs, rhs) = $0 else { return nil }
            return (lhs, rhs)
        }
        let subExp = binaryExp(Exp.sub) {
            guard case let .sub(lhs, rhs) = $0 else { return nil }
            return (lhs, rhs)
        }
        let mulExp = binaryExp(Exp.mul) {
            guard case let .mul(lhs, rhs) = $0 else { return nil }
            return (lhs, rhs)
        }
        let divExp = binaryExp(Exp.div) {
            guard case let .div(lhs, rhs) = $0 else { return nil }
            return (lhs, rhs)
        }
        let andExp = binaryExp(Exp.and) {
            guard case let .and(lhs, rhs) = $0 else { return nil }
            return (lhs, rhs)
        }
        let orExp = binaryExp(Exp.or) {
            guard case let .or(lhs, rhs) = $0 else { return nil }
            return (lhs, rhs)
        }

        return #gen(.oneOf(weighted:
            (3, intLeaf),
            (3, boolLeaf),
            (1, notExp),
            (10, addExp),
            (10, subExp),
            (10, mulExp),
            (10, divExp),
            (10, andExp),
            (10, orExp)))
    }

    static var stmtGen: ReflectiveGenerator<Stmt> {
        let assignGen = #gen(varGen, expGen(depth: 3))
            .mapped(
                forward: { variable, expression in Stmt.assign(variable, expression) },
                backward: { stmt in
                    if case let .assign(variable, expression) = stmt { return (variable, expression) }
                    return (Var(name: "a"), .int(0))
                }
            )
        let allocGen = #gen(varGen, expGen(depth: 3))
            .mapped(
                forward: { variable, expression in Stmt.alloc(variable, expression) },
                backward: { stmt in
                    if case let .alloc(variable, expression) = stmt { return (variable, expression) }
                    return (Var(name: "a"), .int(0))
                }
            )
        let retGen = #gen(expGen(depth: 3))
            .mapped(
                forward: { Stmt.ret($0) },
                backward: { stmt in
                    if case let .ret(expression) = stmt { return expression }
                    return .int(0)
                }
            )
        return #gen(.oneOf(weighted: (1, assignGen), (1, allocGen), (1, retGen)))
    }

    static var funcGen: ReflectiveGenerator<Func> {
        #gen(varGen, expGen(depth: 3).array(length: 1 ... 3), stmtGen.array(length: 1 ... 3))
            .mapped(
                forward: { name, args, body in Func(name: name, args: args, body: body) },
                backward: { function in (function.name, function.args, function.body) }
            )
    }

    static var modGen: ReflectiveGenerator<Mod> {
        #gen(varGen.array(length: 1 ... 3), varGen.array(length: 1 ... 3))
            .mapped(
                forward: { imports, exports in Mod(imports: imports, exports: exports) },
                backward: { mod in (mod.imports, mod.exports) }
            )
    }

    static var langGen: ReflectiveGenerator<Lang> {
        #gen(modGen.array(length: 1 ... 2), funcGen.array(length: 1 ... 2))
            .mapped(
                forward: { modules, funcs in Lang(modules: modules, funcs: funcs) },
                backward: { lang in (lang.modules, lang.funcs) }
            )
    }

    // MARK: - Size Metric

    /// Counts AST nodes, matching the SmartCheck evaluation metric (Support.hs).
    /// Does not count Lang, Func, Mod, or Var — only Exp nodes and Stmt wrappers.
    static func size(_ lang: Lang) -> Int {
        lang.modules.map { size($0) }.reduce(0, +)
            + lang.funcs.map { size($0) }.reduce(0, +)
    }

    static func size(_ mod: Mod) -> Int {
        mod.imports.count + mod.exports.count
    }

    static func size(_ function: Func) -> Int {
        function.args.map { size($0) }.reduce(0, +)
            + function.body.map { size($0) }.reduce(0, +)
    }

    static func size(_ stmt: Stmt) -> Int {
        switch stmt {
        case let .assign(_, expression):
            1 + size(expression)
        case let .alloc(_, expression):
            1 + size(expression)
        case let .ret(expression):
            1 + size(expression)
        }
    }

    static func size(_ expression: Exp) -> Int {
        switch expression {
        case .int, .bool:
            1
        case let .not(inner):
            1 + size(inner)
        case let .add(lhs, rhs), let .sub(lhs, rhs),
             let .mul(lhs, rhs), let .div(lhs, rhs),
             let .and(lhs, rhs), let .or(lhs, rhs):
            1 + size(lhs) + size(rhs)
        }
    }
}
