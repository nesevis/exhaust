import Testing
@testable import ExhaustCore

@Suite("Materializer sources")
struct MaterializerSourcesTests {
    @Test("Missing branches remain fallback-dependent even with no scalar choices")
    func missingBranch() throws {
        let generator = Gen.pick(choices: [(1, Gen.just(1)), (1, Gen.just(2))])
        for value in [1, 2] {
            let tree = try #require(try Interpreters.reflect(generator, with: value))
            let (output, report) = try decode(generator, prefix: [], fallback: tree, emitsFlat: false)
            #expect(output == value)
            #expect(report.totalCount == 0)
            #expect(report.sources == .fallbackTree)
            let (_, replayReport) = try decode(
                generator,
                prefix: ChoiceSequence(tree),
                fallback: tree,
                emitsFlat: false
            )
            #expect(replayReport.sources == .prefix)
        }
    }

    @Test("Missing sequence lengths remain fallback-dependent even with constant elements")
    func missingSequenceLength() throws {
        let generator = Gen.arrayOf(Gen.just(7), within: 0 ... 5)
        for value in [[7], [7, 7, 7]] {
            let tree = try #require(try Interpreters.reflect(generator, with: value))
            let (output, report) = try decode(generator, prefix: [], fallback: tree, emitsFlat: false)
            #expect(output == value)
            #expect(report.totalCount == 0)
            #expect(report.sources == .fallbackTree)
            let (_, replayReport) = try decode(
                generator,
                prefix: ChoiceSequence(tree),
                fallback: tree,
                emitsFlat: false
            )
            #expect(replayReport.sources == .prefix)
        }
    }

    @Test("Fallback zip scoping is not certified by perfect scalar fidelity")
    func missingZipBoundaries() throws {
        let scalar = Gen.choose(in: UInt64(0) ... 10)
        let generator = Gen.zip(scalar, scalar)
        let tree = try #require(try Interpreters.reflect(generator, with: (UInt64(5), UInt64(9))))
        let complete = ChoiceSequence(tree)
        // Preserve the entries and positions but remove the authoritative zip tag.
        var untagged = complete
        untagged[0] = .group(true)
        untagged[untagged.count - 1] = .group(false)
        let (output, report) = try decode(generator, prefix: untagged, fallback: tree, emitsFlat: false)
        #expect(output == (5, 9))
        #expect(report.fidelity == 1)
        #expect(report.sources == [.prefix, .fallbackTree])
        let (_, completeReport) = try decode(generator, prefix: complete, fallback: tree, emitsFlat: false)
        #expect(completeReport.sources == .prefix)
    }

    @Test("A PRNG draw cannot certify independence from future fallbacks")
    func missingScalarWithoutFallback() throws {
        let generator = Gen.choose(in: UInt64(0) ... 10)
        let (_, report) = try decode(generator, prefix: [], fallback: nil, emitsFlat: false)
        #expect(report.sources == .prng)
    }

    @Test("Backtrack auditions remain scoped to their incumbent")
    func backtrack() throws {
        let generator: Generator<Int> = Gen.backtrack(always: [
            (1, Gen.just(Optional(1))),
            (1, Gen.just(Optional(2))),
        ])
        let tree = try #require(try Interpreters.reflect(generator, with: 1))
        let (_, report) = try decode(generator, prefix: ChoiceSequence(tree), fallback: tree, emitsFlat: false)
        #expect(report.sources == [.prefix, .unknown])
    }

    @Test("Screening's depth override revokes prefix certification", arguments: [false, true])
    func screeningDepthOverride(isScreening: Bool) throws {
        let generator = Gen.chooseDepth(in: UInt64(0) ... 5)
        let tree = try #require(try Interpreters.reflect(generator, with: UInt64(1)))
        let result = Materializer.materialize(generator, context: .init(
            prefix: .init(ChoiceSequence(tree)),
            mode: .guided(seed: 42, fallbackTree: tree),
            shouldUseMaximumDepthForScreening: isScreening
        ))
        guard case let .success(value, _, report) = result else {
            Issue.record("Depth replay must succeed")
            return
        }
        #expect(value == (isScreening ? 5 : 1))
        #expect(report?.sources == (isScreening ? .screeningPolicy : .prefix))
    }

    @Test("Tree and flat replay agree on sources and scalar fidelity", arguments: [false, true])
    func reseedSources(reseed: Bool) throws {
        let generator = Gen.choose(in: UInt64(0) ... 10)
        let tree = try #require(try Interpreters.reflect(generator, with: UInt64(5)))
        let prefix = ChoiceSequence(tree)
        let ranges: [ClosedRange<Int>] = reseed ? [0 ... 0] : []
        let treeResult = Materializer.materialize(generator, context: .init(
            prefix: .init(prefix),
            mode: .guided(seed: 42, fallbackTree: tree),
            reseedRanges: ranges
        ))
        let flatResult = Materializer.materializeAnyFlat(generator.erase(), context: .init(
            prefix: .init(prefix),
            mode: .guided(seed: 42, fallbackTree: tree),
            reseedRanges: ranges
        ))
        guard case let .success(value, _, treeReport) = treeResult,
              case let .success(flatValue, _, flatReport) = flatResult
        else {
            Issue.record("Both emission modes must materialize the scalar")
            return
        }
        #expect(flatValue as? UInt64 == value)
        for report in [treeReport, flatReport] {
            let report = try #require(report)
            #expect(report.sources == (reseed ? [.prng, .unknown] : .prefix))
            #expect(report.totalCount == 1)
            #expect(report.reseededResolutionCount == (reseed ? 1 : 0))
            #expect(report.fidelity == (reseed ? 0 : 1))
        }
    }

    @Test("Audition rollback restores scalar counts while retaining discarded sources")
    func rollbackKeepsDependency() throws {
        var context = Materializer.Context(prefix: .init(ChoiceSequence()), mode: .guided(seed: 42, fallbackTree: nil))
        context.decodingReport?.record(tier: .exactCarryForward)
        let snapshot = context.auditionSnapshot()
        context.decodingReport?.record(tier: .fallbackTree)
        context.decodingReport?.record(tier: .prng)

        context.restore(snapshot)

        let restoredReport = context.decodingReport
        let report = try #require(restoredReport)
        #expect(report.totalCount == 1)
        #expect(report.fallbackResolutionCount == 0)
        #expect(report.fidelity == 1)
        #expect(report.sources == [.prefix, .fallbackTree, .prng, .unknown])
    }

    @Test("A replay reports every scalar source", arguments: [false, true], [false, true])
    func mixedSources(usesFallback: Bool, emitsFlat: Bool) throws {
        let leaf = Gen.choose(in: UInt64(0) ... 10)
        let generator = Gen.arrayOf(leaf, exactly: 2)
        let tree = try #require(try Interpreters.reflect(generator, with: [UInt64(5), 9]))
        var prefix = ChoiceSequence(tree)
        let positions = prefix.indices.filter { prefix[$0].value != nil }
        // Keep balanced sequence markers so the fixed length still resolves from the prefix.
        prefix.removeSubrange(positions[1] ... positions[1])
        let fallback: ChoiceTree? = usesFallback ? tree : nil

        let (output, report) = try decode(generator, prefix: prefix, fallback: fallback, emitsFlat: emitsFlat)

        #expect(output.count == 2)
        #expect(output[0] == 5)
        let expected: MaterializationSources = usesFallback ? [.prefix, .fallbackTree] : [.prefix, .prng]
        #expect(report.sources == expected)
        #expect(report.sources.contains(.prefix))
        #expect(report.sources != .prefix)
        #expect(report.totalCount == 2)
    }

    @Test("A discarded backtrack arm retains sources but not scalar counts", arguments: [false, true])
    func discardedBacktrackArm(emitsFlat: Bool) throws {
        let withdrawn: Generator<Int?> = Gen.choose(in: 0 ... 10).map { _ in nil }
        let generator: Generator<Int> = Gen.backtrack(always: [
            (1, withdrawn),
            (1, Gen.just(Optional(7))),
        ])
        // Select the withdrawing arm without supplying its scalar value.
        let prefix: ChoiceSequence = [.branch(.init(id: 0, branchCount: 2, fingerprint: 0))]

        let (output, report) = try decode(generator, prefix: prefix, fallback: nil, emitsFlat: emitsFlat)

        #expect(output == 7)
        #expect(report.totalCount == 0)
        #expect(report.sources == [.prefix, .prng, .unknown])
    }

    @Test("Filter retries retain uncertainty while restoring discarded scalar counts", arguments: [false, true])
    func discardedFilterAttempt(emitsFlat: Bool) throws {
        var attempts = 0
        let generator = Gen.filter(
            Gen.choose(in: UInt64(0) ... 10),
            type: .rejectionSampling,
            predicate: { _ in
                attempts += 1
                return attempts == 2
            },
            sourceLocation: FilterSourceLocation(
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column
            )
        )

        let (_, report) = try decode(generator, prefix: [], fallback: nil, emitsFlat: emitsFlat)

        #expect(attempts == 2)
        #expect(report.totalCount == 1)
        #expect(report.sources == [.prng, .unknown])
    }

    @Test("An unobserved report stays unknown after recording prefix data")
    func unobservedDependencies() {
        var report = DecodingReport()
        report.record(tier: .exactCarryForward)
        #expect(report.sources == [.prefix, .unknown])
    }

    /// Requires source diagnostics in both emission modes so missing reports cannot hide provenance regressions.
    private func decode<Value>(
        _ generator: Generator<Value>,
        prefix: ChoiceSequence,
        fallback: ChoiceTree?,
        emitsFlat: Bool
    ) throws -> (Value, DecodingReport) {
        let context = Materializer.Context(
            prefix: .init(prefix),
            mode: .guided(seed: 42, fallbackTree: fallback)
        )
        switch emitsFlat {
            case true:
                let result = Materializer.materializeAnyFlat(generator.erase(), context: context)
                guard case let .success(value, _, report) = result else {
                    throw TestFailure.failedToMaterialize
                }
                return try (#require(value as? Value), #require(report))
            case false:
                let result = Materializer.materialize(generator, context: context)
                guard case let .success(value, _, report) = result else {
                    throw TestFailure.failedToMaterialize
                }
                return try (value, #require(report))
        }
    }

    private enum TestFailure: Error {
        case failedToMaterialize
    }
}
