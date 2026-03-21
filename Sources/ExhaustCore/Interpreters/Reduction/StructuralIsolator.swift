//
//  StructuralIsolator.swift
//  Exhaust
//

// MARK: - Phase 0: Structural Independence Isolation

//
// Prepended to the V-cycle as a one-shot pass. Identifies leaf positions
// that no structural node (bind-inner or branch-selector) can influence,
// zeros them to domain minimum, and verifies the property still fails.
// This reduces noise for subsequent reduction passes without touching
// structurally coupled positions.
//
// Categorical framing (Bakirtzis, Savvas & Topcu, JMLR 26, 2025, Defs. 6, 32):
// The choice positions of a trace form a partial order under structural
// inclusion — a *subobject lattice*. A *subobject* here is a subset of
// positions closed under the dependency relations imposed by bind and branch
// entries: no position in the subobject can be reached from outside it by
// following a bind-inner or branch-selector edge. Any two subobjects that
// both witness the property failure can be intersected via the *pullback*
// construction — the categorical fiber product — to yield a strictly smaller
// subobject that also witnesses it. StructuralIsolator takes one step in this
// direction: it identifies the subobject of structurally independent positions
// (those not reachable from any bind-inner or branch-selector) and projects
// them to their domain minimum. If the property still fails, the witness is
// carried entirely by the complementary structural subobject, making Phase 0
// a single pullback step toward the minimal subobject in the lattice.

/// Fibre projection: zeros structurally independent values before the main reduction loop begins.
///
/// Categorically, this is a retraction within the fibre — it projects the value assignment onto the shortlex-minimal point that agrees with the original on all structurally coupled coordinates. No base change occurs. In Bonsai terms, it strips the leaves that no branch or bind can reach, reducing noise before the tree is pruned and shaped. In plain language, it finds every value that cannot affect any structural decision, sets each one to its simplest possible value, and checks whether the bug still reproduces.
enum StructuralIsolator {
    /// Result of a successful projection pass.
    struct IsolationResult<Output> {
        let sequence: ChoiceSequence
        let tree: ChoiceTree
        let output: Output
    }

    /// Projects structurally independent value positions to their domain minimum and verifies the property still fails.
    ///
    /// Returns the projected result if the property still fails with independent positions at their domain minimum, or `nil` if there are no independent positions or projecting causes the property to pass.
    static func project<Output>(
        gen: ReflectiveGenerator<Output>,
        sequence: ChoiceSequence,
        bindIndex: BindSpanIndex?,
        property: @escaping (Output) -> Bool,
        isInstrumented: Bool
    ) -> IsolationResult<Output>? {
        // Build connected ranges: every bind span and every branch-containing group.
        var connectedRanges: [ClosedRange<Int>] = []

        if let bindIndex {
            for region in bindIndex.regions {
                connectedRanges.append(region.bindSpanRange)
            }
        }

        let containerSpans = ChoiceSequence.extractContainerSpans(from: sequence)
        for index in 0 ..< sequence.count {
            if case .branch = sequence[index] {
                if let groupRange = ChoiceDependencyGraph.smallestContainingGroupSpan(
                    at: index,
                    among: containerSpans
                ) {
                    connectedRanges.append(groupRange)
                }
            }
        }

        // Find independent .value positions not inside any connected range.
        var inConnected = [Bool](repeating: false, count: sequence.count)
        for range in connectedRanges {
            for i in range {
                inConnected[i] = true
            }
        }
        var independentPositions: [Int] = []
        for index in 0 ..< sequence.count {
            guard case .value = sequence[index] else {
                continue
            }
            if inConnected[index] == false {
                independentPositions.append(index)
            }
        }

        guard independentPositions.isEmpty == false else {
            if isInstrumented {
                ExhaustLog.debug(
                    category: .reducer,
                    event: "phase0_isolation",
                    metadata: ["independent_count": "0", "accepted": "false"]
                )
            }
            return nil
        }

        // Build candidate with independent positions zeroed to domain minimum.
        var candidate = sequence
        for index in independentPositions {
            guard case let .value(value) = candidate[index] else {
                continue
            }
            let target = simplestTarget(for: value)
            candidate[index] = .value(.init(
                choice: target,
                validRange: value.validRange,
                isRangeExplicit: value.isRangeExplicit
            ))
        }

        // Materialize and verify the property still fails.
        // No fallback tree needed: exact mode reads all values from the prefix,
        // and omitting it avoids scope-limit conflicts in handleZip when bind
        // markers sit between zip children.
        let result = ReductionMaterializer.materialize(
            gen,
            prefix: candidate,
            mode: .exact
        )

        guard case let .success(value, freshTree, _) = result else {
            if isInstrumented {
                ExhaustLog.debug(
                    category: .reducer,
                    event: "phase0_isolation",
                    metadata: [
                        "independent_count": "\(independentPositions.count)",
                        "accepted": "false",
                    ]
                )
            }
            return nil
        }

        guard property(value) == false else {
            if isInstrumented {
                ExhaustLog.debug(
                    category: .reducer,
                    event: "phase0_isolation",
                    metadata: [
                        "independent_count": "\(independentPositions.count)",
                        "accepted": "false",
                    ]
                )
            }
            return nil
        }

        if isInstrumented {
            ExhaustLog.debug(
                category: .reducer,
                event: "phase0_isolation",
                metadata: [
                    "independent_count": "\(independentPositions.count)",
                    "accepted": "true",
                ]
            )
        }

        return IsolationResult(
            sequence: ChoiceSequence(freshTree),
            tree: freshTree,
            output: value
        )
    }
}

// MARK: - Private Helpers

private extension StructuralIsolator {
    /// Returns the simplest valid target for a value.
    ///
    /// Replicates the logic from ``ZeroValueEncoder/simplestTarget(for:)`` — when the value is within its recorded range, targets the range minimum if zero doesn't fit. When the value is outside its recorded range, targets zero.
    static func simplestTarget(for value: ChoiceSequenceValue.Value) -> ChoiceValue {
        let simplified = value.choice.semanticSimplest
        let isWithinRecordedRange = value.isRangeExplicit && value.choice.fits(in: value.validRange)
        if isWithinRecordedRange, simplified.fits(in: value.validRange) == false {
            guard let range = value.validRange else {
                return simplified
            }
            return ChoiceValue(
                value.choice.tag.makeConvertible(bitPattern64: range.lowerBound),
                tag: value.choice.tag
            )
        }
        return simplified
    }
}
