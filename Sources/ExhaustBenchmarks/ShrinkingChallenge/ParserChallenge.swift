import Exhaust

// MARK: - Types

struct ParserLang: Equatable, CustomDebugStringConvertible {
    let modules: [ParserMod]
    let funcs: [ParserFunc]
    var debugDescription: String { "Lang(\(modules), \(funcs))" }
}

struct ParserMod: Equatable, CustomDebugStringConvertible {
    let imports: [ParserVar]
    let exports: [ParserVar]
    var debugDescription: String { "Mod(\(imports), \(exports))" }
}

struct ParserFunc: Equatable, CustomDebugStringConvertible {
    let name: ParserVar
    let args: [ParserExp]
    let body: [ParserStmt]
    var debugDescription: String { "Func(\(name), \(args), \(body))" }
}

enum ParserStmt: Equatable, CustomDebugStringConvertible {
    case assign(ParserVar, ParserExp)
    case alloc(ParserVar, ParserExp)
    case ret(ParserExp)
    var debugDescription: String {
        switch self {
        case let .assign(variable, expression): "Assign(\(variable), \(expression))"
        case let .alloc(variable, expression): "Alloc(\(variable), \(expression))"
        case let .ret(expression): "Return(\(expression))"
        }
    }
}

indirect enum ParserExp: Equatable, CustomDebugStringConvertible {
    case int(Int)
    case bool(Bool)
    case add(ParserExp, ParserExp)
    case sub(ParserExp, ParserExp)
    case mul(ParserExp, ParserExp)
    case div(ParserExp, ParserExp)
    case not(ParserExp)
    case and(ParserExp, ParserExp)
    case or(ParserExp, ParserExp)
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

struct ParserVar: Equatable, CustomDebugStringConvertible {
    let name: String
    var debugDescription: String { name }
}

// MARK: - Serializer

func parserSerialize(_ lang: ParserLang) -> String {
    let mods = lang.modules.map { parserSerialize($0) }.joined(separator: ";")
    let fns = lang.funcs.map { parserSerialize($0) }.joined(separator: ";")
    return "Lang (\(mods)) (\(fns))"
}

func parserSerialize(_ mod: ParserMod) -> String {
    let imps = mod.imports.map(\.name).joined(separator: ":")
    let exps = mod.exports.map(\.name).joined(separator: ":")
    return "Mod (\(imps)) (\(exps))"
}

func parserSerialize(_ function: ParserFunc) -> String {
    let args = function.args.map { parserSerialize($0) }.joined(separator: ",")
    let stmts = function.body.map { parserSerialize($0) }.joined(separator: ",")
    return "Func \(function.name.name) (\(args)) (\(stmts))"
}

func parserSerialize(_ stmt: ParserStmt) -> String {
    switch stmt {
    case let .assign(variable, expression):
        "Assign \(variable.name) (\(parserSerialize(expression)))"
    case let .alloc(variable, expression):
        "Alloc \(variable.name) (\(parserSerialize(expression)))"
    case let .ret(expression):
        "Return (\(parserSerialize(expression)))"
    }
}

func parserSerialize(_ expression: ParserExp) -> String {
    switch expression {
    case let .int(value): "Int \(value)"
    case let .bool(value): "Bool \(value)"
    case let .add(lhs, rhs): "Add (\(parserSerialize(lhs))) (\(parserSerialize(rhs)))"
    case let .sub(lhs, rhs): "Sub (\(parserSerialize(lhs))) (\(parserSerialize(rhs)))"
    case let .mul(lhs, rhs): "Mul (\(parserSerialize(lhs))) (\(parserSerialize(rhs)))"
    case let .div(lhs, rhs): "Div (\(parserSerialize(lhs))) (\(parserSerialize(rhs)))"
    case let .not(inner): "Not (\(parserSerialize(inner)))"
    case let .and(lhs, rhs): "And (\(parserSerialize(lhs))) (\(parserSerialize(rhs)))"
    case let .or(lhs, rhs): "Or (\(parserSerialize(lhs))) (\(parserSerialize(rhs)))"
    }
}

// MARK: - Parser (with bugs)

func parserParse(_ input: String) -> ParserLang? {
    var cursor = input[...]
    return parserParseLang(&cursor)
}

private func parserParseLang(_ cursor: inout Substring) -> ParserLang? {
    guard parserConsume("Lang", from: &cursor) else { return nil }
    guard let modsStr = parserParseParenGroup(&cursor) else { return nil }
    guard let funcsStr = parserParseParenGroup(&cursor) else { return nil }
    let mods = parserParseSemicolonSeparated(modsStr) { parserParseMod(&$0) }
    let fns = parserParseSemicolonSeparated(funcsStr) { parserParseFunc(&$0) }
    return ParserLang(modules: mods, funcs: fns)
}

private func parserParseMod(_ cursor: inout Substring) -> ParserMod? {
    guard parserConsume("Mod", from: &cursor) else { return nil }
    guard let impsStr = parserParseParenGroup(&cursor) else { return nil }
    guard let expsStr = parserParseParenGroup(&cursor) else { return nil }
    let imps = parserParseColonSeparated(impsStr).map { ParserVar(name: String($0)) }
    let exps = parserParseColonSeparated(expsStr).map { ParserVar(name: String($0)) }
    return ParserMod(imports: imps, exports: exps)
}

private func parserParseFunc(_ cursor: inout Substring) -> ParserFunc? {
    guard parserConsume("Func", from: &cursor) else { return nil }
    parserSkipSpaces(&cursor)
    guard let name = parserParseWord(&cursor) else { return nil }
    guard let argsStr = parserParseParenGroup(&cursor) else { return nil }
    guard let stmtsStr = parserParseParenGroup(&cursor) else { return nil }
    let args = parserParseCommaSeparated(argsStr) { parserParseExp(&$0) }
    let stmts = parserParseCommaSeparated(stmtsStr) { parserParseStmt(&$0) }
    return ParserFunc(name: ParserVar(name: String(name)), args: args, body: stmts)
}

private func parserParseStmt(_ cursor: inout Substring) -> ParserStmt? {
    parserSkipSpaces(&cursor)
    if parserConsume("Assign", from: &cursor) {
        parserSkipSpaces(&cursor)
        guard let name = parserParseWord(&cursor) else { return nil }
        guard let expStr = parserParseParenGroup(&cursor) else { return nil }
        var expCursor = expStr
        guard let expression = parserParseExp(&expCursor) else { return nil }
        return .assign(ParserVar(name: String(name)), expression)
    } else if parserConsume("Alloc", from: &cursor) {
        parserSkipSpaces(&cursor)
        guard let name = parserParseWord(&cursor) else { return nil }
        guard let expStr = parserParseParenGroup(&cursor) else { return nil }
        var expCursor = expStr
        guard let expression = parserParseExp(&expCursor) else { return nil }
        return .alloc(ParserVar(name: String(name)), expression)
    } else if parserConsume("Return", from: &cursor) {
        guard let expStr = parserParseParenGroup(&cursor) else { return nil }
        var expCursor = expStr
        guard let expression = parserParseExp(&expCursor) else { return nil }
        return .ret(expression)
    }
    return nil
}

private func parserParseExp(_ cursor: inout Substring) -> ParserExp? {
    parserSkipSpaces(&cursor)
    if parserConsume("Int", from: &cursor) {
        parserSkipSpaces(&cursor)
        guard let value = parserParseInt(&cursor) else { return nil }
        return .int(value)
    } else if parserConsume("Bool", from: &cursor) {
        parserSkipSpaces(&cursor)
        if parserConsume("true", from: &cursor) { return .bool(true) }
        if parserConsume("false", from: &cursor) { return .bool(false) }
        return nil
    } else if parserConsume("Add", from: &cursor) {
        return parserParseBinaryExp(&cursor) { .add($0, $1) }
    } else if parserConsume("Sub", from: &cursor) {
        return parserParseBinaryExp(&cursor) { .sub($0, $1) }
    } else if parserConsume("Mul", from: &cursor) {
        return parserParseBinaryExp(&cursor) { .mul($0, $1) }
    } else if parserConsume("Div", from: &cursor) {
        return parserParseBinaryExp(&cursor) { .div($0, $1) }
    } else if parserConsume("Not", from: &cursor) {
        guard let innerStr = parserParseParenGroup(&cursor) else { return nil }
        var innerCursor = innerStr
        guard let inner = parserParseExp(&innerCursor) else { return nil }
        return .not(inner)
    } else if parserConsume("And", from: &cursor) {
        // BUG 1: operands are swapped
        return parserParseBinaryExp(&cursor) { lhs, rhs in .and(rhs, lhs) }
    } else if parserConsume("Or", from: &cursor) {
        // BUG 2: parsed as And with swapped operands
        return parserParseBinaryExp(&cursor) { lhs, rhs in .and(rhs, lhs) }
    }
    return nil
}

private func parserParseBinaryExp(
    _ cursor: inout Substring,
    constructor: (ParserExp, ParserExp) -> ParserExp
) -> ParserExp? {
    guard let lhsStr = parserParseParenGroup(&cursor) else { return nil }
    guard let rhsStr = parserParseParenGroup(&cursor) else { return nil }
    var lhsCursor = lhsStr
    var rhsCursor = rhsStr
    guard let lhs = parserParseExp(&lhsCursor) else { return nil }
    guard let rhs = parserParseExp(&rhsCursor) else { return nil }
    return constructor(lhs, rhs)
}

private func parserSkipSpaces(_ cursor: inout Substring) {
    cursor = cursor.drop(while: { $0 == " " })
}

private func parserConsume(_ prefix: String, from cursor: inout Substring) -> Bool {
    parserSkipSpaces(&cursor)
    if cursor.hasPrefix(prefix) {
        cursor = cursor.dropFirst(prefix.count)
        return true
    }
    return false
}

private func parserParseWord(_ cursor: inout Substring) -> Substring? {
    let word = cursor.prefix(while: { $0.isLetter || $0.isNumber })
    guard word.isEmpty == false else { return nil }
    cursor = cursor.dropFirst(word.count)
    return word
}

private func parserParseInt(_ cursor: inout Substring) -> Int? {
    var numStr = ""
    if cursor.first == "-" {
        numStr.append("-")
        cursor = cursor.dropFirst()
    }
    let digits = cursor.prefix(while: { $0.isNumber })
    guard digits.isEmpty == false else { return nil }
    numStr.append(contentsOf: digits)
    cursor = cursor.dropFirst(digits.count)
    return Int(numStr)
}

private func parserParseParenGroup(_ cursor: inout Substring) -> Substring? {
    parserSkipSpaces(&cursor)
    guard cursor.first == "(" else { return nil }
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

private func parserParseSemicolonSeparated<Result>(
    _ input: Substring,
    parser: (inout Substring) -> Result?
) -> [Result] {
    guard input.isEmpty == false else { return [] }
    return input.split(separator: ";").compactMap { part in
        var cursor = part[...]
        return parser(&cursor)
    }
}

private func parserParseCommaSeparated<Result>(
    _ input: Substring,
    parser: (inout Substring) -> Result?
) -> [Result] {
    guard input.isEmpty == false else { return [] }
    return parserSplitTopLevel(input, separator: ",").compactMap { part in
        var cursor = part[...]
        return parser(&cursor)
    }
}

private func parserParseColonSeparated(_ input: Substring) -> [Substring] {
    guard input.isEmpty == false else { return [] }
    return input.split(separator: ":")
}

private func parserSplitTopLevel(_ input: Substring, separator: Character) -> [Substring] {
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

// MARK: - Size Metric (matches SmartCheck/Hypothesis Support.hs)

func parserSize(_ lang: ParserLang) -> Int {
    lang.modules.map { parserSize($0) }.reduce(0, +)
        + lang.funcs.map { parserSize($0) }.reduce(0, +)
}

func parserSize(_ mod: ParserMod) -> Int {
    mod.imports.count + mod.exports.count
}

func parserSize(_ function: ParserFunc) -> Int {
    function.args.map { parserSize($0) }.reduce(0, +)
        + function.body.map { parserSize($0) }.reduce(0, +)
}

func parserSize(_ stmt: ParserStmt) -> Int {
    switch stmt {
    case let .assign(_, expression): 1 + parserSize(expression)
    case let .alloc(_, expression): 1 + parserSize(expression)
    case let .ret(expression): 1 + parserSize(expression)
    }
}

func parserSize(_ expression: ParserExp) -> Int {
    switch expression {
    case .int, .bool: 1
    case let .not(inner): 1 + parserSize(inner)
    case let .add(lhs, rhs), let .sub(lhs, rhs),
         let .mul(lhs, rhs), let .div(lhs, rhs),
         let .and(lhs, rhs), let .or(lhs, rhs):
        1 + parserSize(lhs) + parserSize(rhs)
    }
}

// MARK: - Generators

var parserVarGen: ReflectiveGenerator<ParserVar> {
    #gen(.int(in: 0 ... 25))
        .mapped(
            forward: { ParserVar(name: String(Character(UnicodeScalar(UInt8(97 + $0))))) },
            backward: { Int($0.name.first?.asciiValue ?? 97) - 97 }
        )
}

func parserExpGen(depth: UInt64) -> ReflectiveGenerator<ParserExp> {
    let intLeaf = #gen(.int(in: -10 ... 10))
        .mapped(
            forward: { ParserExp.int($0) },
            backward: { if case let .int(inner) = $0 { return inner }; return 0 }
        )
    let boolLeaf = #gen(.bool())
        .mapped(
            forward: { ParserExp.bool($0) },
            backward: { if case let .bool(inner) = $0 { return inner }; return false }
        )

    guard depth > 0 else {
        return #gen(.oneOf(weighted: (1, intLeaf), (1, boolLeaf)))
    }

    let child = parserExpGen(depth: depth - 1)

    let notExp = #gen(child)
        .mapped(
            forward: { ParserExp.not($0) },
            backward: { if case let .not(inner) = $0 { return inner }; return .int(0) }
        )

    func binaryExp(
        _ constructor: @Sendable @escaping (ParserExp, ParserExp) -> ParserExp,
        _ destructor: @Sendable @escaping (ParserExp) -> (ParserExp, ParserExp)?
    ) -> ReflectiveGenerator<ParserExp> {
        #gen(child, child)
            .mapped(
                forward: { lhs, rhs in constructor(lhs, rhs) },
                backward: { value in destructor(value) ?? (.int(0), .int(0)) }
            )
    }

    let addExp = binaryExp(ParserExp.add) {
        guard case let .add(lhs, rhs) = $0 else { return nil }
        return (lhs, rhs)
    }
    let subExp = binaryExp(ParserExp.sub) {
        guard case let .sub(lhs, rhs) = $0 else { return nil }
        return (lhs, rhs)
    }
    let mulExp = binaryExp(ParserExp.mul) {
        guard case let .mul(lhs, rhs) = $0 else { return nil }
        return (lhs, rhs)
    }
    let divExp = binaryExp(ParserExp.div) {
        guard case let .div(lhs, rhs) = $0 else { return nil }
        return (lhs, rhs)
    }
    let andExp = binaryExp(ParserExp.and) {
        guard case let .and(lhs, rhs) = $0 else { return nil }
        return (lhs, rhs)
    }
    let orExp = binaryExp(ParserExp.or) {
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

var parserStmtGen: ReflectiveGenerator<ParserStmt> {
    let assignGen = #gen(parserVarGen, parserExpGen(depth: 3))
        .mapped(
            forward: { variable, expression in ParserStmt.assign(variable, expression) },
            backward: { stmt in
                if case let .assign(variable, expression) = stmt { return (variable, expression) }
                return (ParserVar(name: "a"), .int(0))
            }
        )
    let allocGen = #gen(parserVarGen, parserExpGen(depth: 3))
        .mapped(
            forward: { variable, expression in ParserStmt.alloc(variable, expression) },
            backward: { stmt in
                if case let .alloc(variable, expression) = stmt { return (variable, expression) }
                return (ParserVar(name: "a"), .int(0))
            }
        )
    let retGen = #gen(parserExpGen(depth: 3))
        .mapped(
            forward: { ParserStmt.ret($0) },
            backward: { stmt in
                if case let .ret(expression) = stmt { return expression }
                return .int(0)
            }
        )
    return #gen(.oneOf(weighted: (1, assignGen), (1, allocGen), (1, retGen)))
}

var parserFuncGen: ReflectiveGenerator<ParserFunc> {
    #gen(parserVarGen, parserExpGen(depth: 3).array(length: 0 ... 3), parserStmtGen.array(length: 0 ... 3))
        .mapped(
            forward: { name, args, body in ParserFunc(name: name, args: args, body: body) },
            backward: { function in (function.name, function.args, function.body) }
        )
}

var parserModGen: ReflectiveGenerator<ParserMod> {
    #gen(parserVarGen.array(length: 0 ... 3), parserVarGen.array(length: 0 ... 3))
        .mapped(
            forward: { imports, exports in ParserMod(imports: imports, exports: exports) },
            backward: { mod in (mod.imports, mod.exports) }
        )
}

var parserLangGen: ReflectiveGenerator<ParserLang> {
    #gen(parserModGen.array(length: 0 ... 2), parserFuncGen.array(length: 0 ... 2))
        .mapped(
            forward: { modules, funcs in ParserLang(modules: modules, funcs: funcs) },
            backward: { lang in (lang.modules, lang.funcs) }
        )
}

// MARK: - Property

let parserProperty: @Sendable (ParserLang) -> Bool = { lang in
    parserParse(parserSerialize(lang)) == lang
}
