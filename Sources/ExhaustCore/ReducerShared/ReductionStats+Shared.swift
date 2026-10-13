//
//  ReductionStats+Shared.swift
//  Exhaust
//

// MARK: - Probe Accounting

/// Counts terminal probe outcomes and the producer's subsequent admissions separately.
package struct ReductionProbeCounts: Sendable, Equatable {
    package private(set) var emitted = 0
    package private(set) var accepted = 0
    package private(set) var rejectedByCache = 0
    package private(set) var rejectedDuringMaterialization = 0
    package private(set) var propertyPassed = 0
    package private(set) var propertyFailed = 0
    package private(set) var materializationAttempts = 0

    /// Creates a count value, primarily for restoring or testing completed pass summaries.
    package init(
        emitted: Int = 0,
        accepted: Int = 0,
        rejectedByCache: Int = 0,
        rejectedDuringMaterialization: Int = 0,
        propertyPassed: Int = 0,
        propertyFailed: Int = 0,
        materializationAttempts: Int = 0
    ) {
        self.emitted = emitted
        self.accepted = accepted
        self.rejectedByCache = rejectedByCache
        self.rejectedDuringMaterialization = rejectedDuringMaterialization
        self.propertyPassed = propertyPassed
        self.propertyFailed = propertyFailed
        self.materializationAttempts = materializationAttempts
    }

    /// The number of emitted probes assigned exactly one terminal outcome.
    package var terminalOutcomes: Int {
        rejectedByCache + rejectedDuringMaterialization + propertyPassed + propertyFailed
    }

    /// The number of probes that entered the property.
    package var propertyInvocations: Int {
        propertyPassed + propertyFailed
    }

    /// The combined decoder-rejection view retained for the existing public report property.
    package var decoderRejections: Int {
        rejectedDuringMaterialization + propertyPassed + propertyFailed - accepted
    }

    /// Opens one encoder probe.
    mutating func recordEmission() {
        emitted += 1
    }

    /// Terminates the current probe before materialization.
    mutating func recordCacheRejection() {
        rejectedByCache += 1
    }

    /// Terminates the current probe with its decode outcome. A returned reduction still needs the producer's admission checks.
    mutating func recordOutcome(_ outcome: SequenceDecodingOutcome) {
        materializationAttempts += outcome.materializationAttempts
        switch outcome {
            case .materializationRejected:
                rejectedDuringMaterialization += 1
            case .propertyPassed:
                propertyPassed += 1
            case .propertyFailed:
                propertyFailed += 1
        }
    }

    /// Records one admission after the failing outcome and the producer's policy checks. Provisional admissions remain counted if a later excursion rolls back.
    mutating func recordAcceptance() {
        accepted += 1
    }

    /// Merges another pass after both have finished.
    mutating func merge(_ other: ReductionProbeCounts) {
        emitted += other.emitted
        accepted += other.accepted
        rejectedByCache += other.rejectedByCache
        rejectedDuringMaterialization += other.rejectedDuringMaterialization
        propertyPassed += other.propertyPassed
        propertyFailed += other.propertyFailed
        materializationAttempts += other.materializationAttempts
    }
}

/// How one downstream build in a bound value composition ended. Every outcome follows one generator materialization of the lifted candidate.
package enum BoundValueBuildOutcome: String, Sendable, CaseIterable {
    /// The generator could not materialize the lifted candidate.
    case materializationFailed
    /// The lifted sequence was longer than the live sequence at dispatch, so no downstream candidate could be admitted.
    case liftedTooLong
    /// The bind, its bound subtree, or the nested bind could not be located in the lifted graph.
    case bindNotFound
    /// The lift built another composition one bind deeper.
    case nestedStage
    /// The lift found no leaves to search in the bound subtree.
    case noDownstreamLeaves
    /// The lift built a terminal value search.
    case terminalSearch
    /// An exchange lift changed the sink value; bound-value factories never produce this outcome. Retained to keep the shared-failure diagnostic mapping total.
    case sinkValueMismatch
}

/// One downstream build, keyed by the chain stage that ran it.
package struct BoundValueBuildRecord: Hashable, Sendable {
    package let stage: BoundValueStage
    package let outcome: BoundValueBuildOutcome

    package init(stage: BoundValueStage, outcome: BoundValueBuildOutcome) {
        self.stage = stage
        self.outcome = outcome
    }
}
