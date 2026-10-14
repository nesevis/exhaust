import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Scoped structural parity")
struct ScopedStructuralParityTests {
    @Test(
        "Scoped structural encoders reproduce each dispatched scope's trace, accounting, and result",
        arguments: StructuralCase.all
    )
    func parity(structuralCase: StructuralCase) throws {
        let fixture = try StructuralFixture(structuralCase)
        let legacyOperations = fixture.drainLegacy()
        let scopedOperations = fixture.drainLegacy()
        try #require(legacyOperations.count == scopedOperations.count)

        for (legacyOperation, scopedOperation) in zip(legacyOperations, scopedOperations) {
            let legacy = fixture.runLegacy(legacyOperation)
            let scoped = try #require(fixture.runScoped(scopedOperation))
            let label = Comment(rawValue: "\(legacyOperation.encoderName)")

            #expect(scoped.events == legacy.events, label)
            #expect(scoped.report.counts == legacy.report.counts, label)
            #expect(scoped.report.anyAccepted == legacy.report.anyAccepted, label)
            #expect(scoped.report.anyRequiresRebuild == legacy.report.anyRequiresRebuild, label)
            #expect(scoped.report.latestTreeIsStripped == legacy.report.latestTreeIsStripped, label)
            #expect(scoped.report.searchReport.hadUnresolvedReplacement == legacy.report.hadUnresolvedReplacement, label)
            #expect(Array(scoped.result.incumbent.sequence) == Array(legacy.state.sequence), label)
            #expect(scoped.result.rejectCache == legacy.state.rejectCache, label)
        }
    }

    @Test("The cases dispatch every structural encoder, with acceptances, rejections, and unresolved replacements")
    func casesCoverEncoders() throws {
        var accepted: Set<EncoderName> = []
        var rejected: Set<EncoderName> = []
        var removalKinds: Set<String> = []
        var hadUnresolvedReplacement = false
        var swapExtended = false
        for structuralCase in StructuralCase.all {
            let fixture = try StructuralFixture(structuralCase)
            for operation in fixture.drainLegacy() {
                let run = fixture.runLegacy(operation)
                if run.report.anyAccepted {
                    accepted.insert(operation.encoderName)
                } else if run.report.probeCount > 0 {
                    rejected.insert(operation.encoderName)
                }
                if case let .remove(scope) = operation, run.report.probeCount > 0 {
                    removalKinds.insert(StructuralFixture.removalKind(scope))
                }
                if case .permute = operation, run.report.probeCount > 1 {
                    swapExtended = true
                }
                hadUnresolvedReplacement = hadUnresolvedReplacement || run.report.hadUnresolvedReplacement
            }
        }

        let structural: Set<EncoderName> = [.deletion, .substitution, .branchPivot, .migration, .siblingSwap, .numericReorder]
        #expect(accepted == structural)
        #expect(rejected == structural)
        #expect(removalKinds == ["elements", "coveringAligned", "window"])
        #expect(hadUnresolvedReplacement)
        #expect(swapExtended)
    }
}

// MARK: - Cases

/// A generated value, the structural shape it exercises, and a property over its flattened leaf values.
struct StructuralCase: CustomStringConvertible, Sendable {
    enum Shape: Sendable {
        /// Arrays of arrays: element, window, and emptying removal, and migration.
        case nestedArrays
        /// Two arrays under one zip: aligned removal across siblings.
        case zippedArrays
        /// A recursive pick: self-similar replacement, descendant promotion, and branch pivot.
        case tree
        /// Five same-shaped arrays under one zip: sibling swaps, extended rightward.
        case siblingArrays
        /// Arrays of signed integers, some in numeric order and some not: numeric reorder.
        case signedArray
    }

    let label: String
    let shape: Shape
    let fails: @Sendable ([UInt64]) -> Bool

    var description: String {
        label
    }

    static let all: [StructuralCase] = [StructuralCase.Shape.nestedArrays, .zippedArrays, .tree, .siblingArrays, .signedArray].flatMap { shape in
        [
            StructuralCase(label: "\(shape), always fails", shape: shape) { _ in true },
            StructuralCase(label: "\(shape), never fails", shape: shape) { _ in false },
            StructuralCase(label: "\(shape), fails while large", shape: shape) { values in values.reduce(0, +) >= 12 },
            StructuralCase(label: "\(shape), fails while long", shape: shape) { values in values.count >= 4 },
        ]
    }
}

// MARK: - Fixture

/// Samples a value of the case's shape and runs each structural scope the current sources dispatch for it.
struct StructuralFixture {
    struct LegacyRun {
        let events: [ProbeTraceRecorder.Event]
        let report: PassReport
        let state: ProbeSessionFixtureState
    }

    struct ScopedRun {
        let events: [ProbeTraceRecorder.Event]
        let report: ScopedPassReport
        let result: ScopedReductionInterpreter.Result
    }

    /// Scopes per case, so a large drain stays fast.
    static let maximumOperations = 60

    let shape: StructuralCase.Shape
    let generator: AnyGenerator
    let tree: ChoiceTree
    let graph: ChoiceGraph
    let sequence: ChoiceSequence
    let output: Any
    let property: (Any) -> Bool
    let hasBind: Bool

    init(_ structuralCase: StructuralCase) throws {
        let fails = structuralCase.fails
        shape = structuralCase.shape
        let digit = Gen.choose(in: UInt64(0) ... 9)
        let sampled: (generator: AnyGenerator, output: Any, tree: ChoiceTree)
        switch structuralCase.shape {
            case .nestedArrays:
                let typed = Gen.arrayOf(Gen.arrayOf(digit, within: 0 ... 4), within: 1 ... 4)
                sampled = try Self.sample(typed) { arrays in arrays.count >= 3 && arrays.allSatisfy { $0.isEmpty == false } }
            case .zippedArrays:
                let typed = Gen.zip(Gen.arrayOf(digit, within: 0 ... 5), Gen.arrayOf(digit, within: 0 ... 5))
                sampled = try Self.sample(typed) { first, second in first.count >= 3 && second.count >= 3 }
            case .tree:
                let typed = Self.treeGenerator(depth: 3)
                sampled = try Self.sample(typed) { leaves in leaves.count >= 4 }
            case .siblingArrays:
                let sibling = Gen.arrayOf(digit, within: 1 ... 2)
                let typed = Gen.zip(sibling, sibling, sibling, sibling, sibling)
                sampled = try Self.sample(typed) { first, second, third, fourth, fifth in
                    // The first sibling is the largest, so an accepted swap can keep pushing it right.
                    let rest = [second, third, fourth, fifth]
                    return rest.allSatisfy { $0.count <= first.count && $0.lexicographicallyPrecedes(first) }
                }
            case .signedArray:
                let typed = Gen.arrayOf(Gen.arrayOf(Gen.choose(in: Int64(-9) ... 9), within: 2 ... 4), within: 2 ... 3)
                sampled = try Self.sample(typed) { arrays in
                    arrays.contains { $0 == $0.sorted() } && arrays.contains { $0 != $0.sorted() && $0.contains { $0 < 0 } }
                }
        }
        generator = sampled.generator
        output = sampled.output
        tree = sampled.tree
        graph = ChoiceGraph.build(from: sampled.tree)
        sequence = ChoiceSequence(sampled.tree)
        property = { output in fails(Self.leafValues(of: output)) == false }
        hasBind = sequence.contains { entry in
            if case .bind = entry {
                return true
            }
            return false
        }
    }

    /// The structural operations today's sources dispatch, in dispatch order. Each call builds fresh scopes, because covering aligned scopes hold a generator that advances as it is read.
    func drainLegacy() -> [GraphOperation] {
        if shape == .signedArray {
            return ReorderingQuery.build(graph: graph).map { [.reorder($0)] } ?? []
        }
        var sources = CandidateSourceBuilder.buildStructuralSources(from: graph)
        var operations: [GraphOperation] = []
        while operations.count < Self.maximumOperations, let index = ChoiceGraphScheduler.highestPrioritySourceIndex(sources) {
            guard let transformation = sources[index].next() else {
                sources.swapAt(index, sources.count - 1)
                sources.removeLast()
                continue
            }
            operations.append(transformation.operation)
        }
        return operations
    }

    func runLegacy(_ operation: GraphOperation) -> LegacyRun {
        var state = ProbeSessionFixtureState(
            sequence: sequence,
            tree: tree,
            output: output,
            graph: graph,
            gen: generator,
            property: property
        )
        let recorder = ProbeTraceRecorder()
        let transformation = GraphTransformation(operation: operation, priority: .zeroBenefit)
        var encoder = ChoiceGraphScheduler.selectEncoder(for: operation, gen: generator)
        encoder.start(scope: EncoderInput(
            transformation: transformation,
            baseSequence: sequence,
            tree: tree,
            graph: graph,
            warmStartRecords: [:]
        ))
        let session = ProbeSession(
            encoder: encoder,
            transformation: transformation,
            boundValueFingerprint: nil,
            baseSequence: sequence,
            hasBind: hasBind,
            observer: { [weak recorder] in recorder?.record($0) }
        )
        let report = session.runToCompletion(state: &state)
        return LegacyRun(events: recorder.events, report: report, state: state)
    }

    /// Nil for an operation no structural encoder runs.
    func runScoped(_ operation: GraphOperation) -> ScopedRun? {
        let input = EncoderInput(
            transformation: GraphTransformation(operation: operation, priority: .zeroBenefit),
            baseSequence: sequence,
            tree: tree,
            graph: graph,
            warmStartRecords: [:]
        )
        let tuning = ScopedReductionTuning()
        let program: ScopedReducer
        switch operation {
            case let .remove(.elements(elementScope)):
                program = ScopedRemovalEncoder(tuning: tuning).reducer(.elements(elementScope), input: input)
            case let .remove(.coveringAligned(alignedScope)):
                program = ScopedRemovalEncoder(tuning: tuning).reducer(.coveringAligned(alignedScope), input: input)
            case let .remove(.window(windowScope)):
                program = ScopedRemovalEncoder(tuning: tuning).reducer(.window(windowScope), input: input)
            case let .replace(.selfSimilar(targetNodeID, donorNodeID, _)):
                program = ScopedSubstitutionEncoder(tuning: tuning).reducer(.selfSimilar(targetNodeID: targetNodeID, donorNodeID: donorNodeID), input: input)
            case let .replace(.descendantPromotion(ancestorPickNodeID, descendantPickNodeID, _)):
                program = ScopedSubstitutionEncoder(tuning: tuning).reducer(
                    .descendantPromotion(ancestorPickNodeID: ancestorPickNodeID, descendantPickNodeID: descendantPickNodeID),
                    input: input
                )
            case let .replace(.branchPivot(pickNodeID, targetBranchID)):
                program = ScopedBranchPivotEncoder(tuning: tuning).reducer(.init(pickNodeID: pickNodeID, targetBranchID: targetBranchID), input: input)
            case let .migrate(scope):
                program = ScopedMigrationEncoder(tuning: tuning).reducer(scope, input: input)
            case let .permute(scope):
                program = ScopedSwapEncoder(tuning: tuning).reducer(scope, input: input)
            case let .reorder(scope):
                program = ScopedReorderEncoder(tuning: tuning).reducer(scope, input: input)
            case .remove(.subtree), .minimize, .exchange:
                return nil
        }
        let recorder = ProbeTraceRecorder()
        let result = ScopedReductionInterpreter.run(
            program,
            context: ScopedReductionInterpreter.Context(
                incumbent: ScopedCounterexample(
                    sequence: sequence,
                    tree: tree,
                    output: ScopedOutputHandle(value: output)
                ),
                graph: graph,
                rejectCache: [],
                decoder: ScopedDecoder(
                    generator: generator,
                    property: property,
                    probeWrapper: nil,
                    hasBind: hasBind
                ),
                encoderName: operation.encoderName,
                observer: { [weak recorder] in recorder?.record($0) }
            )
        )
        return ScopedRun(events: recorder.events, report: result.report, result: result)
    }

    static func removalKind(_ scope: RemovalScope) -> String {
        switch scope {
            case .elements:
                "elements"
            case .subtree:
                "subtree"
            case .coveringAligned:
                "coveringAligned"
            case .window:
                "window"
        }
    }

    // MARK: - Helpers

    /// A recursive pick between a digit and a pair of subtrees, flattened to its leaves. Every level calls the same `pick`, so all levels share one fingerprint.
    private static func treeGenerator(depth: Int) -> Generator<[UInt64]> {
        let leaf = Gen.choose(in: UInt64(0) ... 9).map { [$0] }
        guard depth > 0 else {
            return leaf
        }
        let subtree = treeGenerator(depth: depth - 1)
        return Gen.pick(choices: [
            (weight: 1, generator: leaf),
            (weight: 3, generator: Gen.zip(subtree, subtree).map { left, right in left + right }),
        ])
    }

    private static func sample<Output>(
        _ typed: Generator<Output>,
        where isWanted: (Output) -> Bool
    ) throws -> (generator: AnyGenerator, output: Any, tree: ChoiceTree) {
        var samples = ValueAndChoiceTreeInterpreter(typed, materializePicks: true, seed: 42, maxRuns: 500)
        while let sample = try samples.next() {
            if isWanted(sample.0) {
                return (generator: typed.erase(), output: sample.0, tree: sample.1)
            }
        }
        throw StructuralFixtureError.noSample
    }

    /// Flattens every output shape the cases generate into its leaf values; signed values keep their magnitude.
    private static func leafValues(of output: Any) -> [UInt64] {
        switch output {
            case let arrays as [[UInt64]]:
                arrays.flatMap(\.self)
            case let values as [UInt64]:
                values
            case let (first, second) as ([UInt64], [UInt64]):
                first + second
            case let (first, second, third, fourth, fifth) as ([UInt64], [UInt64], [UInt64], [UInt64], [UInt64]):
                first + second + third + fourth + fifth
            case let arrays as [[Int64]]:
                arrays.flatMap(\.self).map(\.magnitude)
            default:
                preconditionFailure("Unexpected structural fixture output \(type(of: output))")
        }
    }
}

private enum StructuralFixtureError: Error {
    case noSample
}
