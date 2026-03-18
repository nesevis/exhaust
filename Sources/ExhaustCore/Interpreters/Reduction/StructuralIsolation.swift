//
//  StructuralIsolation.swift
//  Exhaust
//

// MARK: - Phase 0: Structural Independence Isolation
//
// Prepended to the V-cycle as a one-shot pass. Identifies leaf positions
// that no structural node (bind-inner or branch-selector) can influence,
// zeros them to domain minimum, and verifies the property still fails.
// This reduces noise for subsequent reduction passes without touching
// structurally coupled positions.

/// One-shot pre-pass that zeros structurally independent positions before the V-cycle begins.
enum StructuralIsolation {
    /// Result of a successful isolation pass.
    struct IsolationResult<Output> {
        let sequence: ChoiceSequence
        let tree: ChoiceTree
        let output: Output
    }

    /// Zeros all structurally independent value positions and verifies the property still fails.
    ///
    /// Returns the zeroed result if the property still fails with independent positions at their domain minimum, or `nil` if there are no independent positions or zeroing causes the property to pass.
    static func isolate<Output>(
        gen: ReflectiveGenerator<Output>,
        sequence: ChoiceSequence,
        tree: ChoiceTree,
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
        for index in 0..<sequence.count {
            if case .branch = sequence[index] {
                if let groupRange = DependencyDAG.smallestContainingGroupSpan(
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
        for index in 0..<sequence.count {
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

        guard case let .success(value, freshTree) = result else {
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

private extension StructuralIsolation {
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
