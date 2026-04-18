//
//  ParserFixture.swift
//  ExhaustTests
//
//  Shared fixture for the SmartCheck-style "Parser" challenge:
//  https://github.com/mc-imperial/hypothesis-ecoop-2020-artifact/tree/master/smartcheck-benchmarks/evaluations/parser
//

// swiftlint:disable file_length type_body_length

import Foundation
@testable import Exhaust

/// Mini language plus a buggy serializer/parser. The property `parse(serialize(lang)) == lang` (or its `Codable` JSON equivalent) fails because:
///
/// 1. `And` is serialized with swapped operands.
/// 2. `Or` is serialized using the `And` constructor with swapped operands.
///
/// The expected minimal counterexample is the simplest `Lang` wrapping an `Or` expression: `Lang([], [Func(a, [Or(Int(0), Int(0))], [])])`.
enum ParserFixture {
    // MARK: - Types

    struct Lang: Equatable, Codable, CustomDebugStringConvertible {
        let modules: [Mod]
        let funcs: [Func]

        var debugDescription: String { "Lang(\(modules), \(funcs))" }
    }

    struct Mod: Equatable, Codable, CustomDebugStringConvertible {
        let imports: [Var]
        let exports: [Var]

        var debugDescription: String { "Mod(\(imports), \(exports))" }
    }

    struct Func: Equatable, Codable, CustomDebugStringConvertible {
        let name: Var
        let args: [Exp]
        let body: [Stmt]

        var debugDescription: String { "Func(\(name), \(args), \(body))" }
    }

    enum Stmt: Equatable, Codable, CustomDebugStringConvertible {
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

    indirect enum Exp: Equatable, Codable, CustomDebugStringConvertible {
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

        private enum CodingKeys: CodingKey {
            case int, bool, add, sub, mul, div, not, and, or
        }

        private enum IntCodingKeys: CodingKey { case _0 }
        private enum BoolCodingKeys: CodingKey { case _0 }
        private enum AddCodingKeys: CodingKey { case _0, _1 }
        private enum SubCodingKeys: CodingKey { case _0, _1 }
        private enum MulCodingKeys: CodingKey { case _0, _1 }
        private enum DivCodingKeys: CodingKey { case _0, _1 }
        private enum NotCodingKeys: CodingKey { case _0 }
        private enum AndCodingKeys: CodingKey { case _0, _1 }
        private enum OrCodingKeys: CodingKey { case _0, _1 }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            var allKeys = ArraySlice(container.allKeys)
            guard let onlyKey = allKeys.popFirst(), allKeys.isEmpty else {
                throw DecodingError.typeMismatch(Exp.self, DecodingError.Context(codingPath: container.codingPath, debugDescription: "Invalid number of keys found, expected one.", underlyingError: nil))
            }
            switch onlyKey {
            case .int:
                let nested = try container.nestedContainer(keyedBy: IntCodingKeys.self, forKey: .int)
                self = try .int(nested.decode(Int.self, forKey: ._0))
            case .bool:
                let nested = try container.nestedContainer(keyedBy: BoolCodingKeys.self, forKey: .bool)
                self = try .bool(nested.decode(Bool.self, forKey: ._0))
            case .add:
                let nested = try container.nestedContainer(keyedBy: AddCodingKeys.self, forKey: .add)
                self = try .add(nested.decode(Exp.self, forKey: ._0), nested.decode(Exp.self, forKey: ._1))
            case .sub:
                let nested = try container.nestedContainer(keyedBy: SubCodingKeys.self, forKey: .sub)
                self = try .sub(nested.decode(Exp.self, forKey: ._0), nested.decode(Exp.self, forKey: ._1))
            case .mul:
                let nested = try container.nestedContainer(keyedBy: MulCodingKeys.self, forKey: .mul)
                self = try .mul(nested.decode(Exp.self, forKey: ._0), nested.decode(Exp.self, forKey: ._1))
            case .div:
                let nested = try container.nestedContainer(keyedBy: DivCodingKeys.self, forKey: .div)
                self = try .div(nested.decode(Exp.self, forKey: ._0), nested.decode(Exp.self, forKey: ._1))
            case .not:
                let nested = try container.nestedContainer(keyedBy: NotCodingKeys.self, forKey: .not)
                self = try .not(nested.decode(Exp.self, forKey: ._0))
            case .and:
                let nested = try container.nestedContainer(keyedBy: AndCodingKeys.self, forKey: .and)
                self = try .and(nested.decode(Exp.self, forKey: ._0), nested.decode(Exp.self, forKey: ._1))
            case .or:
                let nested = try container.nestedContainer(keyedBy: OrCodingKeys.self, forKey: .or)
                self = try .or(nested.decode(Exp.self, forKey: ._0), nested.decode(Exp.self, forKey: ._1))
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .int(value):
                var nested = container.nestedContainer(keyedBy: IntCodingKeys.self, forKey: .int)
                try nested.encode(value, forKey: ._0)
            case let .bool(value):
                var nested = container.nestedContainer(keyedBy: BoolCodingKeys.self, forKey: .bool)
                try nested.encode(value, forKey: ._0)
            case let .add(lhs, rhs):
                var nested = container.nestedContainer(keyedBy: AddCodingKeys.self, forKey: .add)
                try nested.encode(lhs, forKey: ._0)
                try nested.encode(rhs, forKey: ._1)
            case let .sub(lhs, rhs):
                var nested = container.nestedContainer(keyedBy: SubCodingKeys.self, forKey: .sub)
                try nested.encode(lhs, forKey: ._0)
                try nested.encode(rhs, forKey: ._1)
            case let .mul(lhs, rhs):
                var nested = container.nestedContainer(keyedBy: MulCodingKeys.self, forKey: .mul)
                try nested.encode(lhs, forKey: ._0)
                try nested.encode(rhs, forKey: ._1)
            case let .div(lhs, rhs):
                var nested = container.nestedContainer(keyedBy: DivCodingKeys.self, forKey: .div)
                try nested.encode(lhs, forKey: ._0)
                try nested.encode(rhs, forKey: ._1)
            case let .not(inner):
                var nested = container.nestedContainer(keyedBy: NotCodingKeys.self, forKey: .not)
                try nested.encode(inner, forKey: ._0)
            case let .and(rhs, lhs):
                // BUG 1: operands are swapped on encode.
                var nested = container.nestedContainer(keyedBy: AndCodingKeys.self, forKey: .and)
                try nested.encode(lhs, forKey: ._0)
                try nested.encode(rhs, forKey: ._1)
            case let .or(rhs, lhs):
                // BUG 2: encoded under the And key with operands swapped.
                var nested = container.nestedContainer(keyedBy: AndCodingKeys.self, forKey: .and)
                try nested.encode(lhs, forKey: ._0)
                try nested.encode(rhs, forKey: ._1)
            }
        }
    }

    struct Var: Equatable, Codable, CustomDebugStringConvertible {
        let name: String

        var debugDescription: String { name }
    }

    // MARK: - Property

    /// Property under test: round-tripping through `JSONEncoder`/`JSONDecoder` returns the original value. Fails for any expression containing `And` (operands swapped) or `Or` (re-encoded as `And`).
    @Sendable
    static func property(_ lang: Lang) -> Bool {
        do {
            let encoded = try JSONEncoder().encode(lang)
            let decoded = try JSONDecoder().decode(Lang.self, from: encoded)
            return decoded == lang
        } catch {
            return false
        }
    }

    // MARK: - Generators

    static var varGen: ReflectiveGenerator<Var> {
        // Single lowercase ASCII letter — avoids Unicode/empty-name edge cases that would break the serializer/parser roundtrip for non-bug reasons.
        #gen(.int(in: 0 ... 25, scaling: .constant))
            .mapped(
                forward: { Var(name: String(Character(UnicodeScalar(UInt8(97 + $0))))) },
                backward: { Int($0.name.first?.asciiValue ?? 97) - 97 }
            )
    }

    static func expGen(depth: UInt64) -> ReflectiveGenerator<Exp> {
        let intLeaf = #gen(.int(in: -10 ... 10, scaling: .constant))
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
                        if let pair = destructor(value) { return pair }
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
        #gen(varGen, expGen(depth: 3).array(length: 1 ... 3, scaling: .constant), stmtGen.array(length: 0 ... 3, scaling: .constant))
            .mapped(
                forward: { name, args, body in Func(name: name, args: args, body: body) },
                backward: { function in (function.name, function.args, function.body) }
            )
    }

    static var modGen: ReflectiveGenerator<Mod> {
        #gen(varGen.array(length: 0 ... 3, scaling: .constant), varGen.array(length: 0 ... 3, scaling: .constant))
            .mapped(
                forward: { imports, exports in Mod(imports: imports, exports: exports) },
                backward: { mod in (mod.imports, mod.exports) }
            )
    }

    static var langGen: ReflectiveGenerator<Lang> {
        #gen(modGen.array(length: 1 ... 2, scaling: .constant), funcGen.array(length: 1 ... 2, scaling: .constant))
            .mapped(
                forward: { modules, funcs in Lang(modules: modules, funcs: funcs) },
                backward: { lang in (lang.modules, lang.funcs) }
            )
    }

    // MARK: - Size Metric

    /// Counts AST nodes, matching the SmartCheck evaluation metric (Support.hs). Does not count `Lang`, `Func`, `Mod`, or `Var` — only `Exp` nodes and `Stmt` wrappers.
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

// swiftlint:enable file_length type_body_length
