import Testing
@testable import ExhaustCore

@Suite("SequenceDecoder invariants")
struct SequenceDecoderInvariantTests {
    @Test("Exact decoding leaves shortlex admission to the producer")
    func exactDecodingDefersShortlexToProducer() throws {
        let generator = Gen.choose(in: UInt64(0) ... 10)
        let originalTree = try #require(try Interpreters.reflect(generator, with: UInt64(0)))
        let candidateTree = try #require(try Interpreters.reflect(generator, with: UInt64(1)))
        let originalSequence = ChoiceSequence(originalTree)
        let candidateSequence = ChoiceSequence(candidateTree)
        var filterObservations: [UInt64: FilterObservation] = [:]

        let outcome = try SequenceDecoder.exact().decodeAny(
            candidate: candidateSequence,
            gen: generator.erase(),
            tree: originalTree,
            originalSequence: originalSequence,
            property: { _ in false },
            filterObservations: &filterObservations
        )

        #expect(candidateSequence.shortLexPrecedes(originalSequence) == false)
        #expect(outcome.materializationAttempts == 2)
        guard case .propertyFailed = outcome else {
            Issue.record("Expected the property failure to remain distinct from admission")
            return
        }
        let decoded = try #require(outcome.reduction)
        #expect(decoded.sequence.operativeHash == candidateSequence.operativeHash)
        #expect(decoded.output as? UInt64 == 1)
    }

    @Test("Separates reduction probe terminal outcomes")
    func separatesReductionProbeTerminalOutcomes() throws {
        let generator = Gen.choose(in: UInt64(0) ... 10)
        let originalTree = try #require(try Interpreters.reflect(generator, with: UInt64(10)))
        let candidateTree = try #require(try Interpreters.reflect(generator, with: UInt64(1)))
        let originalSequence = ChoiceSequence(originalTree)
        let candidateSequence = ChoiceSequence(candidateTree)
        let invalidSequence: ChoiceSequence = [
            .value(.init(
                choice: ChoiceValue(UInt64(50), tag: .uint64),
                validRange: 0 ... 100
            )),
        ]
        var filterObservations: [UInt64: FilterObservation] = [:]
        var propertyInvocations = 0

        let materializationRejection = try SequenceDecoder.exact().decodeAny(
            candidate: invalidSequence,
            gen: generator.erase(),
            tree: originalTree,
            originalSequence: originalSequence,
            property: { _ in
                propertyInvocations += 1
                return false
            },
            filterObservations: &filterObservations
        )
        let propertyPass = try SequenceDecoder.exact().decodeAny(
            candidate: candidateSequence,
            gen: generator.erase(),
            tree: originalTree,
            originalSequence: originalSequence,
            property: { _ in
                propertyInvocations += 1
                return true
            },
            filterObservations: &filterObservations
        )
        let propertyFailure = try SequenceDecoder.exact().decodeAny(
            candidate: candidateSequence,
            gen: generator.erase(),
            tree: originalTree,
            originalSequence: originalSequence,
            property: { _ in
                propertyInvocations += 1
                return false
            },
            filterObservations: &filterObservations
        )

        var counts = ReductionProbeCounts()
        counts.recordEmission()
        counts.recordCacheRejection()
        for outcome in [materializationRejection, propertyPass, propertyFailure] {
            counts.recordEmission()
            counts.record(outcome)
        }

        #expect(propertyInvocations == 2)
        #expect(counts.emitted == 4)
        #expect(counts.rejectedByCache == 1)
        #expect(counts.rejectedDuringMaterialization == 1)
        #expect(counts.propertyPassed == 1)
        #expect(counts.propertyFailed == 1)
        #expect(counts.accepted == 1)
        #expect(counts.propertyInvocations == propertyInvocations)
        #expect(counts.terminalOutcomes == counts.emitted)
        #expect(counts.materializationAttempts == 4)

        var stats = ReductionStats()
        stats.record(counts, for: .valueSearch)
        #expect(stats.encoderProbes[.valueSearch] == 4)
        #expect(stats.encoderProbesAccepted[.valueSearch] == 1)
        #expect(stats.encoderProbesRejectedByCache[.valueSearch] == 1)
        #expect(stats.encoderProbesRejectedDuringMaterialization[.valueSearch] == 1)
        #expect(stats.encoderProbesWherePropertyPassed[.valueSearch] == 1)
        #expect(stats.encoderProbesWherePropertyFailed[.valueSearch] == 1)
        #expect(stats.encoderProbesRejectedByDecoder[.valueSearch] == 2)
        #expect(stats.totalMaterializations == 4)
    }

    @Test("Keeps property failure separate from guided shortlex admission")
    func separatesPropertyFailureFromGuidedAdmission() throws {
        let generator = Gen.choose(in: UInt64(0) ... 10)
        let originalTree = try #require(try Interpreters.reflect(generator, with: UInt64(0)))
        let candidateTree = try #require(try Interpreters.reflect(generator, with: UInt64(1)))
        let originalSequence = ChoiceSequence(originalTree)
        let candidateSequence = ChoiceSequence(candidateTree)
        var filterObservations: [UInt64: FilterObservation] = [:]
        var propertyInvocations = 0

        let outcome = try SequenceDecoder.guided(fallbackTree: originalTree).decodeAny(
            candidate: candidateSequence,
            gen: generator.erase(),
            tree: originalTree,
            originalSequence: originalSequence,
            property: { _ in
                propertyInvocations += 1
                return false
            },
            filterObservations: &filterObservations
        )

        #expect(propertyInvocations == 1)
        #expect(outcome.materializationAttempts == 2)
        guard case let .propertyFailed(reduction, _) = outcome else {
            Issue.record("Expected a property failure")
            return
        }
        #expect(reduction == nil)
    }

    @Test("Run-wide counts include structural relax proposals without assigning an encoder")
    func runWideCountsIncludeStructuralRelaxProposals() {
        var encoderCounts = ReductionProbeCounts()
        encoderCounts.recordEmission()
        encoderCounts.record(.materializationRejected(materializationAttempts: 1))

        var relaxCounts = ReductionProbeCounts()
        relaxCounts.recordEmission()
        relaxCounts.record(.propertyPassed(materializationAttempts: 1))

        var stats = ReductionStats()
        stats.record(encoderCounts, for: .valueSearch)
        var relaxStats = ReductionStats()
        relaxStats.recordStructuralRelax(relaxCounts)
        stats.merge(relaxStats)

        #expect(stats.reductionProbes == 2)
        #expect(stats.reductionProbesAccepted == 0)
        #expect(stats.reductionProbesRejectedByCache == 0)
        #expect(stats.reductionProbesRejectedDuringMaterialization == 1)
        #expect(stats.reductionProbesWherePropertyPassed == 1)
        #expect(stats.reductionProbesWherePropertyFailed == 0)
        #expect(stats.totalMaterializations == 2)
        #expect(stats.encoderProbes[.valueSearch] == 1)
        #expect(stats.encoderProbes.values.reduce(0, +) < stats.reductionProbes)
    }
}
