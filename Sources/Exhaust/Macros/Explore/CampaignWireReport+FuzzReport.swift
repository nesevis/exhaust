import ExhaustSupport
import Foundation

extension CampaignWireReport {
    init(report: FuzzReport, context: FuzzCampaignContext) {
        let reproduction: Reproduction? = switch report.attempts.total > 0 {
            case true:
                Reproduction(setting: ".replay(\(report.seed))")
            case false:
                nil
        }
        self.init(
            termination: Termination(report.termination),
            resumedFromCrash: report.resumedFromCrash,
            attempts: Attempts(report),
            invocations: Invocations(report),
            coverage: Coverage(report),
            timing: Timing(report),
            clusters: report.clusters.map { Finding(cluster: $0, context: context) },
            unreducedFailureCounts: report.unreducedFailureCounts,
            reproduction: reproduction
        )
    }
}

extension CampaignWireReport.Termination {
    init(_ termination: FuzzReport.Termination) {
        switch termination {
            case .budgetExhausted:
                self.init(reason: .budgetExhausted)
            case let .coveragePlateau(unused):
                self.init(reason: .coveragePlateau, unusedBudgetSeconds: unused.seconds)
            case .instrumentationMissing:
                self.init(reason: .instrumentationMissing)
            case .coverageUnreachable:
                self.init(reason: .coverageUnreachable)
            case let .invalidConfiguration(message):
                self.init(reason: .invalidConfiguration, message: message)
            case let .generationFailed(message):
                self.init(reason: .generationFailed, message: message)
            case .attemptLimitReached:
                self.init(reason: .attemptLimitReached)
            case .firstFaultFound:
                self.init(reason: .firstFaultFound)
            case .uncontainedAsyncWork:
                self.init(reason: .uncontainedAsyncWork)
        }
    }
}

extension CampaignWireReport.Attempts {
    init(_ report: FuzzReport) {
        self.init(
            total: report.attempts.total,
            evaluated: report.attempts.evaluated,
            judged: report.attempts.judged,
            rejected: report.attempts.rejected,
            screening: report.attempts.screening,
            sampling: report.attempts.sampling,
            mutation: report.attempts.mutation,
            discardedByProperty: report.attempts.discardedByProperty,
            discardedByMaterializer: report.attempts.discardedByMaterializer,
            duplicatesSkipped: report.attempts.duplicatesSkipped,
            mutationArmAttempts: report.attempts.mutationArmAttempts,
            mutationArmPassed: report.attempts.mutationArmPassed,
            mutationArmFailed: report.attempts.mutationArmFailed,
            mutationArmDiscarded: report.attempts.mutationArmDiscarded
        )
    }
}

extension CampaignWireReport.Invocations {
    init(_ report: FuzzReport) {
        self.init(
            total: report.invocations.total,
            search: report.invocations.search,
            prune: report.invocations.prune,
            reduction: report.invocations.reduction,
            normalization: report.invocations.normalization,
            classification: report.invocations.classification,
            recovery: report.invocations.recovery
        )
    }
}

extension CampaignWireReport.Coverage {
    init(_ report: FuzzReport) {
        self.init(
            corpusEntryCount: report.coverage.corpusEntryCount,
            parentCount: report.coverage.parentCount,
            parentRootPhases: report.coverage.parentRootPhases,
            coveredEdges: report.coverage.coveredEdges,
            instrumentedEdges: report.coverage.instrumentedEdges,
            offLaneHits: report.coverage.offLaneHits,
            incidenceSamples: report.coverage.incidenceSamples,
            incidenceTotal: report.coverage.incidenceTotal,
            estimatedReachableEdges: FiniteNumber(report.coverage.estimatedReachableEdges),
            estimatedNextEdgeProbability: FiniteNumber(report.coverage.estimatedNextEdgeProbability)
        )
    }
}

extension CampaignWireReport.Timing {
    init(_ report: FuzzReport) {
        self.init(
            elapsedSeconds: report.timing.elapsed.seconds,
            lastDiscoverySeconds: report.timing.lastDiscovery.seconds,
            propertySeconds: report.timing.property.seconds,
            reductionSeconds: report.timing.reduction.seconds,
            screeningOverheadSeconds: report.timing.screeningOverhead.seconds,
            samplingOverheadSeconds: report.timing.samplingOverhead.seconds,
            mutationOverheadSeconds: report.timing.mutationOverhead.seconds,
            otherSeconds: report.timing.other.seconds,
            testingOverheadFraction: FiniteNumber(report.timing.testingOverheadFraction),
            attemptsPerSecond: FiniteNumber(report.attemptsPerSecond)
        )
    }
}

extension CampaignWireReport.Finding {
    init(cluster: FuzzReport.Cluster, context: FuzzCampaignContext) {
        self.init(
            id: cluster.id,
            findingID: context.findingID(cluster),
            reducedDescription: cluster.reducedDescription,
            symptoms: cluster.symptoms,
            instanceCount: cluster.instanceCount,
            reducedCount: cluster.reducedCount,
            unnormalizedMemberCount: cluster.unnormalizedMemberCount,
            isLikelySplit: cluster.isLikelySplit,
            discoveringPhase: cluster.discoveringPhase.rawValue,
            discoveringSource: cluster.discoveringSource?.rawValue,
            firstSeenSeconds: cluster.firstSeen.seconds,
            lastSeenSeconds: cluster.lastSeen.seconds,
            firstSeenAttempt: cluster.firstSeenAttempt,
            discriminatingEdges: cluster.discriminatingEdges.map(CampaignWireReport.Edge.init)
        )
    }
}

extension CampaignWireReport.Edge {
    init(_ edge: FuzzReport.DiscriminatingEdge) {
        self.init(
            edgeIndex: edge.edgeIndex,
            failureHitFraction: FiniteNumber(edge.failureHitFraction),
            passingHitFraction: FiniteNumber(edge.passingHitFraction),
            symbol: edge.symbol.map(CampaignWireReport.Symbol.init)
        )
    }
}

extension CampaignWireReport.Symbol {
    init(_ symbol: FuzzReport.SymbolLocation) {
        self.init(
            displayName: symbol.displayName,
            fullName: symbol.fullName,
            module: symbol.module,
            file: symbol.file,
            line: symbol.line
        )
    }
}
