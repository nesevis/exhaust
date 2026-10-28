import Foundation

/// The versioned wire format of a campaign's runtime report, kept independent of the public `FuzzReport` and free of generator internals. The runtime builds it from a `FuzzReport`; the command decodes it with these types, so a report that does not match the schema fails aggregation.
package struct CampaignWireReport: Codable, Sendable {
    package let termination: Termination
    package let resumedFromCrash: Bool
    package let attempts: Attempts
    package let invocations: Invocations
    package let coverage: Coverage
    package let timing: Timing
    package let clusters: [Finding]
    package let unreducedFailureCounts: [String: Int]
    package let reproduction: Reproduction?

    package init(
        termination: Termination,
        resumedFromCrash: Bool,
        attempts: Attempts,
        invocations: Invocations,
        coverage: Coverage,
        timing: Timing,
        clusters: [Finding],
        unreducedFailureCounts: [String: Int],
        reproduction: Reproduction?
    ) {
        self.termination = termination
        self.resumedFromCrash = resumedFromCrash
        self.attempts = attempts
        self.invocations = invocations
        self.coverage = coverage
        self.timing = timing
        self.clusters = clusters
        self.unreducedFailureCounts = unreducedFailureCounts
        self.reproduction = reproduction
    }

    /// The setting that replays this campaign's own search. A resumed campaign (``resumedFromCrash``) also carries its predecessor's findings, which the setting does not reproduce.
    package struct Reproduction: Codable, Sendable {
        package let setting: String

        package init(setting: String) {
            self.setting = setting
        }
    }

    /// Keeps the reason vocabulary explicit while accommodating the associated budget or message.
    package struct Termination: Codable, Sendable {
        package let reason: CampaignTerminationReason
        package var unusedBudgetSeconds: Double?
        package var message: String?

        package init(reason: CampaignTerminationReason, unusedBudgetSeconds: Double? = nil, message: String? = nil) {
            self.reason = reason
            self.unusedBudgetSeconds = unusedBudgetSeconds
            self.message = message
        }
    }

    /// Preserves the wire fields independently of the public report representation.
    package struct Attempts: Codable, Sendable {
        package let total: Int
        package let evaluated: Int
        /// Evaluated attempts the property passed or failed, excluding discards and evaluations that stalled without a verdict. Zero with a nonzero ``evaluated`` is why such a campaign's outcome is `error`.
        package let judged: Int
        package let rejected: Int
        package let screening: Int
        package let sampling: Int
        package let mutation: Int
        package let discardedByProperty: Int
        package let discardedByMaterializer: Int
        package let duplicatesSkipped: Int
        package let mutationArmAttempts: [String: Int]
        package let mutationArmPassed: [String: Int]
        package let mutationArmFailed: [String: Int]
        package let mutationArmDiscarded: [String: Int]

        package init(
            total: Int,
            evaluated: Int,
            judged: Int,
            rejected: Int,
            screening: Int,
            sampling: Int,
            mutation: Int,
            discardedByProperty: Int,
            discardedByMaterializer: Int,
            duplicatesSkipped: Int,
            mutationArmAttempts: [String: Int],
            mutationArmPassed: [String: Int],
            mutationArmFailed: [String: Int],
            mutationArmDiscarded: [String: Int]
        ) {
            self.total = total
            self.evaluated = evaluated
            self.judged = judged
            self.rejected = rejected
            self.screening = screening
            self.sampling = sampling
            self.mutation = mutation
            self.discardedByProperty = discardedByProperty
            self.discardedByMaterializer = discardedByMaterializer
            self.duplicatesSkipped = duplicatesSkipped
            self.mutationArmAttempts = mutationArmAttempts
            self.mutationArmPassed = mutationArmPassed
            self.mutationArmFailed = mutationArmFailed
            self.mutationArmDiscarded = mutationArmDiscarded
        }
    }

    /// Preserves the wire fields independently of the public report representation.
    package struct Invocations: Codable, Sendable {
        package let total: Int
        package let search: Int
        package let prune: Int
        package let reduction: Int
        package let normalization: Int
        package let classification: Int
        package let recovery: Int

        package init(
            total: Int,
            search: Int,
            prune: Int,
            reduction: Int,
            normalization: Int,
            classification: Int,
            recovery: Int
        ) {
            self.total = total
            self.search = search
            self.prune = prune
            self.reduction = reduction
            self.normalization = normalization
            self.classification = classification
            self.recovery = recovery
        }
    }

    /// Preserves the wire fields independently of the public report representation.
    package struct Coverage: Codable, Sendable {
        package let corpusEntryCount: Int
        package let parentCount: Int
        package let parentRootPhases: [String: Int]
        package let coveredEdges: Int
        package let instrumentedEdges: Int
        package let offLaneHits: Int
        package let incidenceSamples: Int
        package let incidenceTotal: Int
        package let estimatedReachableEdges: FiniteNumber
        package let estimatedNextEdgeProbability: FiniteNumber

        package init(
            corpusEntryCount: Int,
            parentCount: Int,
            parentRootPhases: [String: Int],
            coveredEdges: Int,
            instrumentedEdges: Int,
            offLaneHits: Int,
            incidenceSamples: Int,
            incidenceTotal: Int,
            estimatedReachableEdges: FiniteNumber,
            estimatedNextEdgeProbability: FiniteNumber
        ) {
            self.corpusEntryCount = corpusEntryCount
            self.parentCount = parentCount
            self.parentRootPhases = parentRootPhases
            self.coveredEdges = coveredEdges
            self.instrumentedEdges = instrumentedEdges
            self.offLaneHits = offLaneHits
            self.incidenceSamples = incidenceSamples
            self.incidenceTotal = incidenceTotal
            self.estimatedReachableEdges = estimatedReachableEdges
            self.estimatedNextEdgeProbability = estimatedNextEdgeProbability
        }
    }

    /// Preserves the wire fields independently of the public report representation.
    package struct Timing: Codable, Sendable {
        package let elapsedSeconds: Double
        package let lastDiscoverySeconds: Double
        package let propertySeconds: Double
        package let reductionSeconds: Double
        package let screeningOverheadSeconds: Double
        package let samplingOverheadSeconds: Double
        package let mutationOverheadSeconds: Double
        package let otherSeconds: Double
        package let testingOverheadFraction: FiniteNumber
        package let attemptsPerSecond: FiniteNumber

        package init(
            elapsedSeconds: Double,
            lastDiscoverySeconds: Double,
            propertySeconds: Double,
            reductionSeconds: Double,
            screeningOverheadSeconds: Double,
            samplingOverheadSeconds: Double,
            mutationOverheadSeconds: Double,
            otherSeconds: Double,
            testingOverheadFraction: FiniteNumber,
            attemptsPerSecond: FiniteNumber
        ) {
            self.elapsedSeconds = elapsedSeconds
            self.lastDiscoverySeconds = lastDiscoverySeconds
            self.propertySeconds = propertySeconds
            self.reductionSeconds = reductionSeconds
            self.screeningOverheadSeconds = screeningOverheadSeconds
            self.samplingOverheadSeconds = samplingOverheadSeconds
            self.mutationOverheadSeconds = mutationOverheadSeconds
            self.otherSeconds = otherSeconds
            self.testingOverheadFraction = testingOverheadFraction
            self.attemptsPerSecond = attemptsPerSecond
        }
    }

    /// Correlates a canonical reduced form while retaining each campaign's own evidence.
    package struct Finding: Codable, Sendable {
        package let id: Int
        package let findingID: String
        package let reducedDescription: String
        package let symptoms: [String]
        package let instanceCount: Int
        package let reducedCount: Int
        package let unnormalizedMemberCount: Int
        package let isLikelySplit: Bool
        package let discoveringPhase: String
        package let discoveringSource: String?
        package let firstSeenSeconds: Double
        package let lastSeenSeconds: Double
        package let firstSeenAttempt: Int
        package let discriminatingEdges: [Edge]

        package init(
            id: Int,
            findingID: String,
            reducedDescription: String,
            symptoms: [String],
            instanceCount: Int,
            reducedCount: Int,
            unnormalizedMemberCount: Int,
            isLikelySplit: Bool,
            discoveringPhase: String,
            discoveringSource: String?,
            firstSeenSeconds: Double,
            lastSeenSeconds: Double,
            firstSeenAttempt: Int,
            discriminatingEdges: [Edge]
        ) {
            self.id = id
            self.findingID = findingID
            self.reducedDescription = reducedDescription
            self.symptoms = symptoms
            self.instanceCount = instanceCount
            self.reducedCount = reducedCount
            self.unnormalizedMemberCount = unnormalizedMemberCount
            self.isLikelySplit = isLikelySplit
            self.discoveringPhase = discoveringPhase
            self.discoveringSource = discoveringSource
            self.firstSeenSeconds = firstSeenSeconds
            self.lastSeenSeconds = lastSeenSeconds
            self.firstSeenAttempt = firstSeenAttempt
            self.discriminatingEdges = discriminatingEdges
        }
    }

    /// Keeps optional symbolization separate from the build-local edge index.
    package struct Edge: Codable, Sendable {
        package let edgeIndex: Int
        package let failureHitFraction: FiniteNumber
        package let passingHitFraction: FiniteNumber
        package let symbol: Symbol?

        package init(edgeIndex: Int, failureHitFraction: FiniteNumber, passingHitFraction: FiniteNumber, symbol: Symbol?) {
            self.edgeIndex = edgeIndex
            self.failureHitFraction = failureHitFraction
            self.passingHitFraction = passingHitFraction
            self.symbol = symbol
        }
    }

    /// Retains the names and available source location without requiring symbolization to succeed.
    package struct Symbol: Codable, Sendable {
        package let displayName: String
        package let fullName: String
        package let module: String?
        package let file: String?
        package let line: Int?

        package init(displayName: String, fullName: String, module: String?, file: String?, line: Int?) {
            self.displayName = displayName
            self.fullName = fullName
            self.module = module
            self.file = file
            self.line = line
        }
    }
}

/// Encodes unavailable estimates as JSON null, retaining the schema's distinction from an absent field.
package struct FiniteNumber: Codable, Sendable {
    package let value: Double?

    package init(_ value: Double) {
        self.value = switch value.isFinite {
            case true:
                value
            case false:
                nil
        }
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try container.decode(Double?.self)
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// Keeps stopping reasons exhaustive in the wire report.
package enum CampaignTerminationReason: String, Codable, Sendable {
    case budgetExhausted
    case coveragePlateau
    case instrumentationMissing
    case coverageUnreachable
    case invalidConfiguration
    case generationFailed
    case attemptLimitReached
    case firstFaultFound
    case uncontainedAsyncWork
}

/// Carries enough context for a finding event to be useful without joining its start event.
package struct CampaignFinding: Codable, Sendable {
    package let finding: CampaignWireReport.Finding
    package let seed: String
    package let source: CampaignSource
    package let kind: FuzzCampaignKind
    package let testID: String?
    package let testName: String?
    /// Set by the command when it collects the event; the runtime leaves it absent.
    package var recordPath: String?

    package init(
        finding: CampaignWireReport.Finding,
        seed: String,
        source: CampaignSource,
        kind: FuzzCampaignKind,
        testID: String?,
        testName: String?
    ) {
        self.finding = finding
        self.seed = seed
        self.source = source
        self.kind = kind
        self.testID = testID
        self.testName = testName
    }
}
