import Exhaust
import ExhaustCore
import Foundation
import Testing

/// One pinned entry point: a name and a capture that renders the values a seed produces through it.
///
/// Captures go through the public macros (`#exhaust`, `#explore`, `#execute`) rather than the interpreters directly, so the pinned stream is exactly what a user replays. Every generator family, combinator, synthesis form, screening path, and replay-string format that can change what a seed means has an entry here; a new public factory should land with one.
struct ReplayCorpusEntry: Sendable, CustomTestStringConvertible {
    let name: String
    let capture: @Sendable (UInt64) async -> [String]

    var testDescription: String {
        name
    }

    /// Seeds every entry is captured under. Several seeds catch drift that happens to leave one stream unchanged.
    static let seeds: [UInt64] = [1, 42, 67, 99, 1337, 1983, 2508]

    /// Values captured per seed for sampling entries.
    static let sampleCount = 8

    /// Entries whose factory exists only on some platforms. Their corpus lines are recorded where they exist and are not orphans elsewhere.
    static let platformGated: Set<String> = ["cgfloat.default", "int128.default", "uint128.default"]

    static let all: [ReplayCorpusEntry] = numericEntries + largeIntegerEntries + coreGraphicsEntries + stringEntries + foundationEntries + collectionEntries + combinatorEntries + synthesisEntries + screeningEntries + runnerEntries + encodingEntries
}

// MARK: - Numeric

private let numericEntries: [ReplayCorpusEntry] = [
    sampling("int.default", .int(), integer),
    sampling("int.range", .int(in: -100 ... 100), integer),
    sampling("int.rangeLinear", .int(in: 0 ... 1000, scaling: .linear), integer),
    sampling("int.exponentialFrom", .int(in: -1000 ... 1000, scaling: .exponentialFrom(origin: 500)), integer),
    sampling("int8.default", .int8(), integer),
    sampling("int16.default", .int16(), integer),
    sampling("int32.default", .int32(), integer),
    sampling("int64.default", .int64(), integer),
    sampling("uint.default", .uint(), integer),
    sampling("uint8.range", .uint8(in: 10 ... 20), integer),
    sampling("uint16.default", .uint16(), integer),
    sampling("uint32.default", .uint32(), integer),
    sampling("uint64.default", .uint64(), integer),
    sampling("double.default", .double(), floating),
    sampling("double.range", .double(in: -1.5 ... 2.5), floating),
    sampling("float.default", .float(), floating),
    sampling("float.range", .float(in: 0 ... 1), floating),
    sampling("decimal.range", .decimal(in: 0 ... 100)) { $0.description },
    sampling("decimal.minorUnits", .decimal(minorUnits: 0 ... 10000, precision: 2)) { $0.description },
]

/// The 128-bit factories carry an OS availability floor, so their entries join the catalogue only where the platform provides the types.
private var largeIntegerEntries: [ReplayCorpusEntry] {
    if #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) {
        return [
            sampling("int128.default", .int128()) { String($0) },
            sampling("uint128.default", .uint128()) { String($0) },
        ]
    }
    return []
}

/// `CGFloat` factories exist only where CoreGraphics does, matching the factory's own guard.
private var coreGraphicsEntries: [ReplayCorpusEntry] {
    #if canImport(CoreGraphics)
        return [sampling("cgfloat.default", .cgfloat(), floating)]
    #else
        return []
    #endif
}

// MARK: - Strings

// `CharacterSet`-backed factories are deliberately absent: a set's membership comes from the platform's Foundation, so their streams are stable only per platform and Foundation version (see the factory docs), and this corpus pins cross-platform stability.

private let stringEntries: [ReplayCorpusEntry] = [
    sampling("string.default", .string(), quoted),
    sampling("string.length", .string(length: 0 ... 5), quoted),
    sampling("string.asciiString", .asciiString(length: 1 ... 6), quoted),
    sampling("string.scalarRange", .string(in: "a" ... "z", length: 1 ... 4), quoted),
    sampling("character.default", .character()) { quoted(String($0)) },
    sampling("character.range", .character(in: "0" ... "9")) { quoted(String($0)) },
]

// MARK: - Foundation

private let corpusEpoch = Date(timeIntervalSince1970: 1_700_000_000)

private let foundationEntries: [ReplayCorpusEntry] = [
    sampling("data.default", .data(), hex),
    sampling("data.length", .data(length: 0 ... 4), hex),
    sampling("data.prefix", .data(prefix: [0xCA, 0xFE], length: 2), hex),
    sampling("date.between", .date(between: corpusEpoch ... corpusEpoch.addingTimeInterval(86400 * 10), interval: .hours(1)), timestamp),
    sampling("date.within", .date(within: .days(3), of: corpusEpoch, interval: .minutes(30)), timestamp),
    sampling("uuid.default", .uuid()) { $0.uuidString },
    sampling("url.default", .url()) { $0.absoluteString },
]

// MARK: - Collections

private struct Item: Equatable, Sendable {
    let id: Int
    let label: String
}

private let items = [Item(id: 1, label: "one"), Item(id: 2, label: "two"), Item(id: 3, label: "three")]

private let collectionEntries: [ReplayCorpusEntry] = [
    sampling("array.default", .array(.int(in: 0 ... 9))) { list($0.map(integer)) },
    sampling("array.length", .array(.int(in: 0 ... 9), length: 0 ... 4, scaling: .constant)) { list($0.map(integer)) },
    sampling("array.exact", .array(.bool(), length: 3)) { list($0.map(boolean)) },
    sampling("set.count", .set(.int(in: 0 ... 9), count: 0 ... 4)) { list($0.map(integer).sorted()) },
    sampling("dictionary.count", .dictionary(.int(in: 0 ... 5), .bool(), count: 0 ... 3)) { dictionary in
        list(dictionary.map { "\(integer($0.key))=\(boolean($0.value))" }.sorted())
    },
    sampling("element.from", .element(from: ["a", "b", "c"]), quoted),
    sampling("element.id", .element(from: items, id: \.id)) { integer($0.id) },
    sampling("slice.collection", .slice(of: Array(1 ... 6))) { list($0.map(integer)) },
    sampling("shuffled", .shuffled(.just([1, 2, 3, 4]))) { list($0.map(integer)) },
    sampling("eachOf", .eachOf([.int(in: 0 ... 9), .int(in: 100 ... 109)])) { list($0.map(integer)) },
    sampling("range", .range(.int(in: 0 ... 100))) { list([integer($0.lowerBound), integer($0.upperBound)]) },
    sampling("closedRange", .closedRange(.int(in: 0 ... 100))) { list([integer($0.lowerBound), integer($0.upperBound)]) },
    sampling("simd2.scalar", .simd2(.int8(in: -5 ... 5))) { list([integer($0.x), integer($0.y)]) },
    sampling("simd4.components", .simd4(.int(in: 0 ... 9), .int(in: 10 ... 19), .int(in: 20 ... 29), .int(in: 30 ... 39))) { list([integer($0.x), integer($0.y), integer($0.z), integer($0.w)]) },
]

// MARK: - Combinators

private indirect enum Tree: Sendable {
    case leaf
    case node([Tree])

    var rendered: String {
        switch self {
            case .leaf:
                "leaf"
            case let .node(children):
                list(children.map(\.rendered))
        }
    }
}

private let combinatorEntries: [ReplayCorpusEntry] = [
    sampling("filter", .int(in: 0 ... 100).filter { $0.isMultiple(of: 3) }, integer),
    sampling("unique", .int(in: 0 ... 20).unique(), integer),
    sampling("optional", .int(in: 0 ... 9).optional()) { $0.map(integer) ?? "null" },
    sampling("oneOf.weighted", .oneOf(weighted: (1, .just("rare")), (5, .just("common"))), quoted),
    sampling("bool", .bool(), boolean),
    sampling("just", .just(7), integer),
    sampling("map", .int(in: 0 ... 9).map { $0 * 2 }, integer),
    sampling("bind", .int(in: 1 ... 3).bind { count in .array(.bool(), length: count) }, { list($0.map(boolean)) }),
    sampling(
        "recursive",
        ReflectiveGenerator<Tree>.recursive(baseValue: .leaf, depthRange: 0 ... 3) { recurse, _ in
            .array(recurse(), length: 0 ... 2, scaling: .constant).map(Tree.node)
        },
        { $0.rendered }
    ),
    sampling(
        "unfold",
        ReflectiveGenerator<Int>.unfold(
            seed: .int(in: 0 ... 5),
            depthRange: 0 ... 4,
            step: { state, _ in .int(in: 1 ... 3).map { UnfoldStep.recurse(state + $0) } },
            finish: { $0 }
        ),
        integer
    ),
    sampling("resize", .int(in: 0 ... 1000, scaling: .linear).resize(10), integer),
    sampling("lazy", .lazy { .int(in: 0 ... 9) }, integer),
    sampling(
        "backtrack.always",
        .anyNonNil(
            always: (1, .just(nil)),
            (2, .int(in: 0 ... 9).map { $0.isMultiple(of: 2) ? $0 : nil }),
            (1, .int(in: 100 ... 109).map { Optional($0) })
        ),
        integer
    ),
    sampling(
        "backtrack.failable",
        .anyNonNil((1, .int(in: 0 ... 9).map { $0.isMultiple(of: 3) ? $0 : nil })),
        { $0.map(integer) ?? "null" }
    ),
]

// MARK: - Synthesis

private struct Point: Sendable {
    let x: Int
    let flag: Bool
}

private struct Decoded: Decodable, Sendable {
    let count: Int
    let name: String
}

private let synthesisEntries: [ReplayCorpusEntry] = [
    sampling("gen.transform", #gen(.int(in: 0 ... 9), .bool()) { x, flag in Point(x: x, flag: flag) }, { "\(integer($0.x)),\(boolean($0.flag))" }),
    sampling("gen.tuple", #gen(.int(in: 0 ... 9), .bool())) { "\(integer($0.0)),\(boolean($0.1))" },
    ReplayCorpusEntry(name: "gen.decodable") { seed in
        let gen: ReflectiveGenerator<Decoded>
        do {
            gen = try #gen(Decoded.self, from: "{\"count\": 3, \"name\": \"x\"}")
        } catch {
            Issue.record("Decodable synthesis failed: \(error)")
            return []
        }
        return sampled(gen, replay: .numeric(seed), sampling: ReplayCorpusEntry.sampleCount) { "\(integer($0.count)),\(quoted($0.name))" }
    },
]

// MARK: - Screening

private let screeningEntries: [ReplayCorpusEntry] = [
    screening("screening.int", .int(in: 0 ... 100), integer),
    screening("screening.character", .character(in: "a" ... "f")) { quoted(String($0)) },
    screening("screening.array", .array(.int(in: 0 ... 3), length: 0 ... 4, scaling: .constant)) { list($0.map(integer)) },
    screening("screening.zip", #gen(.int(in: 0 ... 9), .bool())) { "\(integer($0.0)),\(boolean($0.1))" },
]

// MARK: - Runners

private let runnerEntries: [ReplayCorpusEntry] = [
    ReplayCorpusEntry(name: "explore.directed") { seed in
        let recorder = ValueRecorder()
        #explore(
            .int(in: 0 ... 100),
            directions: [
                ("low", { $0 < 30 }),
                ("high", { $0 > 70 }),
            ],
            .budget(.custom(screening: 0, sampling: ReplayCorpusEntry.sampleCount)),
            .replay(.numeric(seed)),
            .suppress(.all)
        ) { value in
            recorder.record(integer(value))
        }
        return recorder.values
    },
    ReplayCorpusEntry(name: "spec.sampling") { seed in
        CorpusCounterSpec.trace = []
        _ = await #execute(
            CorpusCounterSpec.self,
            mode: .sequential,
            .commandLimit(4),
            .budget(.custom(screening: 0, sampling: 3)),
            .replay(.numeric(seed)),
            .suppress(.all)
        )
        return CorpusCounterSpec.trace
    },
    ReplayCorpusEntry(name: "spec.screening") { seed in
        CorpusCounterSpec.trace = []
        _ = await #execute(
            CorpusCounterSpec.self,
            mode: .sequential,
            .commandLimit(4),
            .budget(.custom(screening: 6, sampling: 0)),
            .replay(.numeric(seed)),
            .suppress(.all)
        )
        return CorpusCounterSpec.trace
    },
]

// MARK: - Encoding

private let encodingEntries: [ReplayCorpusEntry] = [
    ReplayCorpusEntry(name: "encoding.formats") { seed in
        [
            ReplaySeed.encodeRawSeed(seed),
            ReplaySeed.encode(seed: seed, iteration: 5),
            ReplaySeed.encodeScreeningRow(seed: seed, row: 3, tierLength: nil),
            ReplaySeed.encodeScreeningRow(seed: seed, row: 3, tierLength: 4),
        ]
    },
    ReplayCorpusEntry(name: "iteration.addressed") { seed in
        sampled(.int(in: -100 ... 100), replay: .encoded(ReplaySeed.encode(seed: seed, iteration: 5)), sampling: 5, render: integer)
    },
]

// MARK: - Capture Helpers

/// Captures the first ``ReplayCorpusEntry/sampleCount`` sampled values of `gen` under `seed`, in invocation order.
private func sampling<Output>(
    _ name: String,
    _ gen: ReflectiveGenerator<Output>,
    _ render: @escaping @Sendable (Output) -> String
) -> ReplayCorpusEntry {
    ReplayCorpusEntry(name: name) { seed in
        sampled(gen, replay: .numeric(seed), sampling: ReplayCorpusEntry.sampleCount, render: render)
    }
}

/// Captures the first ``ReplayCorpusEntry/sampleCount`` screening rows of `gen` under `seed`, with sampling disabled.
private func screening<Output>(
    _ name: String,
    _ gen: ReflectiveGenerator<Output>,
    _ render: @escaping @Sendable (Output) -> String
) -> ReplayCorpusEntry {
    ReplayCorpusEntry(name: name) { seed in
        sampled(gen, replay: .numeric(seed), screening: ReplayCorpusEntry.sampleCount, sampling: 0, render: render)
    }
}

/// Runs `gen` through `#exhaust` under `replay` and returns every value the property saw, rendered, in order.
///
/// The property closure is a single Bool expression so the macro takes its predicate form; the multi-statement form would route through assertion detection instead.
private func sampled<Output>(
    _ gen: ReflectiveGenerator<Output>,
    replay: ReplaySeed,
    screening: Int = 0,
    sampling: Int,
    render: @escaping @Sendable (Output) -> String
) -> [String] {
    let recorder = ValueRecorder()
    #exhaust(
        gen,
        .replay(replay),
        .budget(.custom(screening: screening, sampling: sampling)),
        .suppress(.all)
    ) { value in
        recorder.record(render(value))
    }
    return recorder.values
}

/// Accumulates rendered values from a property closure.
///
/// Marked `@unchecked Sendable`: the corpus suite is serialized and never enables `.parallelize`, so the property closure runs on one thread at a time and no append is ever concurrent.
private final class ValueRecorder: @unchecked Sendable {
    private(set) var values: [String] = []

    /// Appends a rendering and returns true so the call can stand alone as a passing predicate.
    func record(_ rendering: String) -> Bool {
        values.append(rendering)
        return true
    }
}

// MARK: - Renderers

// Renderings are the corpus's stable currency: each maps a value to text whose equality is exact and platform-independent. Floating-point values use Swift's shortest round-trip description, which the Swift runtime computes without Foundation, so NaN, infinities, and negative zero all render distinctly and identically everywhere.

private func integer(_ value: some BinaryInteger) -> String {
    String(value)
}

private func floating(_ value: some BinaryFloatingPoint & CustomStringConvertible) -> String {
    value.description
}

private func boolean(_ value: Bool) -> String {
    value ? "true" : "false"
}

private func quoted(_ value: String) -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}

private func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

private func timestamp(_ date: Date) -> String {
    date.timeIntervalSince1970.description
}

private func list(_ renderings: [String]) -> String {
    "[\(renderings.joined(separator: ","))]"
}

// MARK: - Spec Fixture

/// Records every executed command so the corpus can pin the command sequences a seed produces. Commands never throw, so every run passes and the sweep runs to completion.
@StateMachine
private final class CorpusCounterSpec {
    nonisolated(unsafe) static var trace: [String] = []
    @SystemUnderTest var counter = CorpusCounter()

    @Command(weight: 2, .int(in: 1 ... 5))
    func add(amount: Int) throws {
        counter.total += amount
        Self.trace.append("add(\(amount))")
    }

    @Command(weight: 1)
    func reset() throws {
        counter.total = 0
        Self.trace.append("reset")
    }

    func failureDescription() -> String? {
        nil
    }
}

private struct CorpusCounter {
    var total = 0
}
