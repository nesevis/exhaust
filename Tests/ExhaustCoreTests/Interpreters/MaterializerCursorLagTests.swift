import ExhaustTestSupport
import Testing
@testable import ExhaustCore

/// The materializer's cursor advances only on content reads, so after a subtree that ends without one, a `.just` and the closes behind it are still unread when the next generator starts. Every decision taken from the cursor position must reach past that slack. Each case here puts a producer that leaves slack directly ahead of a consumer that decides from the position.
@Suite("Materializer: cursor lag")
struct MaterializerCursorLagTests {
    @Test("Exact replay re-emits its own sequence after cursor slack", arguments: LagProducer.allCases, LagConsumer.allCases)
    func exactReplay(producer: LagProducer, consumer: LagConsumer) throws {
        let generator = lagGenerator(producer, consumer)
        for generatedWithPicks in [false, true] {
            let generated = try generate(generator, materializePicks: generatedWithPicks)
            let sequence = ChoiceSequence.flatten(generated.tree)
            for replayWithPicks in [false, true] {
                let result = Materializer.materialize(generator, context: .init(
                    prefix: sequence,
                    mode: .exact,
                    fallbackTree: generated.tree,
                    materializePicks: replayWithPicks
                ))
                guard case let .success(value, tree, _) = result else {
                    Issue.record("Exact replay rejected \(sequence.shortString) (generated with picks: \(generatedWithPicks), replayed with picks: \(replayWithPicks))")
                    continue
                }
                #expect(value == generated.value)
                #expect(ChoiceSequence.flatten(tree) == sequence)
            }
        }
    }

    @Test("Guided replay of an untouched prefix carries every value forward after cursor slack", arguments: LagProducer.allCases, LagConsumer.allCases)
    func guidedCarryForward(producer: LagProducer, consumer: LagConsumer) throws {
        let generator = lagGenerator(producer, consumer)
        let generated = try generate(generator, materializePicks: false)
        let result = Materializer.materialize(generator, context: .init(
            prefix: ChoiceSequence.flatten(generated.tree),
            mode: .guided(seed: 99, fallbackTree: nil)
        ))
        guard case let .success(value, _, report) = result else {
            Issue.record("Guided replay failed on an untouched prefix")
            return
        }
        #expect(value == generated.value)
        #expect(report?.fidelity == 1.0, "Guided replay resolved values from outside the prefix: fidelity \(report?.fidelity ?? -1)")
    }

    @Test("A value reseed right after cursor slack redraws its value", arguments: LagProducer.allCases, LagConsumer.allCases)
    func reseedAfterSlack(producer: LagProducer, consumer: LagConsumer) throws {
        let generator = lagGenerator(producer, consumer)
        let generated = try generate(generator, materializePicks: false)
        let sequence = ChoiceSequence.flatten(generated.tree)
        let valueIndex = try #require(sequence.firstIndex { entry in
            if case .value = entry {
                return true
            }
            return false
        })

        let result = Materializer.materialize(generator, context: .init(
            prefix: sequence,
            mode: .guided(seed: 99, fallbackTree: generated.tree),
            reseedRanges: [valueIndex ... valueIndex]
        ))

        guard case let .success(value, tree, _) = result else {
            Issue.record("Reseeded replay failed")
            return
        }
        let reseeded = ChoiceSequence.flatten(tree)
        #expect(reseeded.count == sequence.count)
        #expect(reseeded[valueIndex] != sequence[valueIndex], "The reseed was not taken: the value carried forward")
        #expect(value != generated.value)
    }

    // MARK: - Cursor Queries

    /// The zip handler's fallback scoping starts from the zip open, and only a prefix that fails to parse reaches it, so the open index is pinned here directly.
    @Test("Position queries on a cursor parked on slack see the zip open past it", arguments: LagProducer.allCases)
    func zipQueriesLookPastSlack(producer: LagProducer) throws {
        let sequence = try flattened(lagGenerator(producer, .zip))
        let zipOpen = try #require(sequence.firstIndex(of: .zip(true)))
        let slackStart = try #require(sequence[..<zipOpen].lastIndex(of: .just))

        let cursor = parkedCursor(on: sequence, at: slackStart)

        let openIndex = cursor.zipOpenIndex
        let childEnds = cursor.zipChildSubtreeEnds(count: 2)
        #expect(openIndex == zipOpen)
        #expect(childEnds != nil)
    }

    @Test("Position queries on a cursor parked on slack see the bind open past it", arguments: LagProducer.allCases)
    func bindQueriesLookPastSlack(producer: LagProducer) throws {
        let sequence = try flattened(lagGenerator(producer, .bindOverZip))
        let bindOpen = try #require(sequence.lastIndex(of: .bind(true)))
        let slackStart = try #require(sequence[..<bindOpen].lastIndex(of: .just))

        var cursor = parkedCursor(on: sequence, at: slackStart)

        cursor.skipBindOpen()
        let openIndex = cursor.zipOpenIndex
        #expect(openIndex == bindOpen + 1)
    }

    @Test("Position queries on a cursor parked on slack see the group open past it", arguments: LagProducer.allCases)
    func groupQueriesLookPastSlack(producer: LagProducer) throws {
        let sequence = try flattened(lagGenerator(producer, .resizedZip))
        let zipOpen = try #require(sequence.firstIndex(of: .zip(true)))
        let groupOpen = zipOpen - 1
        #expect(sequence[groupOpen] == .group(true))
        let slackStart = try #require(sequence[..<groupOpen].lastIndex(of: .just))

        var cursor = parkedCursor(on: sequence, at: slackStart)

        cursor.skipGroupOpen()
        let openIndex = cursor.zipOpenIndex
        #expect(openIndex == zipOpen)
    }
}

// MARK: - Fixtures

/// A bind inner that ends without a content read, so the cursor still stands behind it when the bound starts. Every producer yields zero, so the bind's backward is a constant.
enum LagProducer: CaseIterable, CustomStringConvertible, Sendable {
    /// A bare `.just`.
    case just
    /// A pick whose arms are all `.just`, so it ends on a `.just` and its group close.
    case justArmPick
    /// A just-arm pick inside a just-arm pick, so two group closes trail the `.just`.
    case nestedJustArmPick
    /// A bind whose inner and bound are both `.just`, so a bind close trails the `.just`.
    case bindOfJust

    var description: String {
        switch self {
            case .just:
                "just"
            case .justArmPick:
                "just-arm pick"
            case .nestedJustArmPick:
                "nested just-arm pick"
            case .bindOfJust:
                "bind of just"
        }
    }

    var generator: Generator<UInt64> {
        switch self {
            case .just:
                Gen.just(UInt64(0))
            case .justArmPick:
                Gen.pick(choices: [
                    (weight: 1, generator: Gen.just(UInt64(0))),
                    (weight: 1, generator: Gen.just(UInt64(0))),
                ])
            case .nestedJustArmPick:
                Gen.pick(choices: [
                    (weight: 1, generator: Gen.pick(choices: [
                        (weight: 1, generator: Gen.just(UInt64(0))),
                        (weight: 1, generator: Gen.just(UInt64(0))),
                    ])),
                    (weight: 1, generator: Gen.just(UInt64(0))),
                ])
            case .bindOfJust:
                Gen.just(UInt64(0))._bound(
                    forward: { _ in Gen.just(UInt64(0)) },
                    backward: { _ in UInt64(0) }
                )
        }
    }
}

/// A bound whose first read or scope decision is taken from the cursor position. Every consumer produces values from a wide range, so a reseeded draw differs from the original.
enum LagConsumer: CaseIterable, CustomStringConvertible, Sendable {
    /// A zip, which parses its child spans from the position.
    case zip
    /// A zip whose first child is a zip, so the outer zip's marker skip can carry the cursor past the inner zip's open.
    case zipOfZip
    /// A bind whose inner is a zip, so a bind open stands between the slack and the zip open.
    case bindOverZip
    /// A resized zip, so a group open stands between the slack and the zip open.
    case resizedZip
    /// An array, which reads its sequence open from the position.
    case array
    /// A pick whose arms are zips.
    case pickOfZips
    /// A bind with a value inner and a zip bound.
    case bindWithValueBound

    var description: String {
        switch self {
            case .zip:
                "zip"
            case .zipOfZip:
                "zip of zip"
            case .bindOverZip:
                "bind over zip"
            case .resizedZip:
                "resized zip"
            case .array:
                "array"
            case .pickOfZips:
                "pick of zips"
            case .bindWithValueBound:
                "bind with value bound"
        }
    }

    var generator: Generator<[UInt64]> {
        switch self {
            case .zip:
                widePair
            case .zipOfZip:
                Gen.zip(widePair, wide).map { pair, last in pair + [last] }
            case .bindOverZip:
                widePair._bound(
                    forward: { pair in Gen.just(pair) },
                    backward: { pair in pair }
                )
            case .resizedZip:
                Gen.resize(5, widePair)
            case .array:
                Gen.arrayOf(wide, Gen.choose(in: UInt64(2) ... 3))
            case .pickOfZips:
                Gen.pick(choices: [
                    (weight: 1, generator: widePair),
                    (weight: 1, generator: widePair),
                ])
            case .bindWithValueBound:
                wide._bound(
                    forward: { controller in Gen.zip(wide, Gen.just(controller)).map { free, controller in [controller, free] } },
                    backward: { pair in pair[0] }
                )
        }
    }
}

private let wide: Generator<UInt64> = Gen.choose(in: UInt64(0) ... 1_000_000)

private let widePair: Generator<[UInt64]> = Gen.zip(wide, wide).map { first, second in [first, second] }

// MARK: - Helpers

/// The producer as a bind inner with the consumer as its bound, so the bound starts with the cursor still behind the producer's trailing markers.
private func lagGenerator(_ producer: LagProducer, _ consumer: LagConsumer) -> Generator<[UInt64]> {
    let bound = consumer.generator
    return producer.generator._bound(
        forward: { _ in bound },
        backward: { _ in UInt64(0) }
    )
}

private func flattened(_ generator: Generator<[UInt64]>) throws -> ChoiceSequence {
    try ChoiceSequence.flatten(generate(generator, materializePicks: false).tree)
}

/// A cursor over `sequence` standing at `position`, as one does after the reads before it.
private func parkedCursor(on sequence: ChoiceSequence, at position: Int) -> Materializer.Cursor {
    var cursor = Materializer.Cursor(from: sequence)
    if position > 0 {
        cursor.jump(past: 0 ... position - 1)
    }
    return cursor
}

private func generate(_ generator: Generator<[UInt64]>, materializePicks: Bool) throws -> (value: [UInt64], tree: ChoiceTree) {
    var iterator = ValueAndChoiceTreeInterpreter(generator, materializePicks: materializePicks, seed: 42)
    return try #require(try iterator.next())
}
