//
//  ChoiceGraph+Classification.swift
//  Exhaust
//

// MARK: - Bind Classification

extension ChoiceGraph {
    /// Classifies the bind at `bindNodeID` by lifting its upstream leaf at the clamped low and high endpoints of the leaf's valid range, comparing the two resulting bound subtrees in lockstep, and recording the verdict on the bind node's ``BindMetadata/classification``.
    ///
    /// Semantic analysis, not search: emits no probes and reports no mutations. Invoked lazily by the scheduler when cheap encoders have stalled and an expensive dependent-node encoder (for example ``GraphComposedEncoder``) is about to dispatch on this bind. The verdict persists on the graph until a reshape or full rebuild clears it, so later dispatches in the same graph state reuse the result.
    ///
    /// Idempotent. If ``BindMetadata/classification`` is already populated the call returns immediately.
    ///
    /// - Parameters:
    ///   - bindNodeID: The ``ChoiceGraphNodeKind/bind(_:)`` node to classify.
    ///   - gen: The erased generator used to materialize each endpoint lift.
    ///   - baseSequence: The live ``ChoiceSequence``. The classifier overwrites a single upstream entry to construct each endpoint candidate.
    ///   - fallbackTree: The live ``ChoiceTree``. Passed to ``Materializer/materializeAny(_:prefix:mode:fallbackTree:materializePicks:)`` as the guided-mode fallback so downstream positions outside the probed endpoint's domain re-resolve coherently.
    ///   - upstreamLeafNodeID: The ``ChoiceGraphNodeKind/chooseBits(_:)`` leaf whose valid range defines the probe endpoints. Typically the bind's inner child.
    func classifyBind(
        at bindNodeID: Int,
        gen: ReflectiveGenerator<Any>,
        baseSequence: ChoiceSequence,
        fallbackTree: ChoiceTree,
        upstreamLeafNodeID: Int
    ) {
        guard bindNodeID < nodes.count, isTombstoned(bindNodeID) == false else { return }
        guard case let .bind(bindMetadata) = nodes[bindNodeID].kind else { return }
        if bindMetadata.classification != nil { return }

        let verdict = computeClassification(
            bindNodeID: bindNodeID,
            bindMetadata: bindMetadata,
            upstreamLeafNodeID: upstreamLeafNodeID,
            gen: gen,
            baseSequence: baseSequence,
            fallbackTree: fallbackTree
        )
        writeClassification(verdict, bindMetadata: bindMetadata, bindNodeID: bindNodeID)
    }

    private func computeClassification(
        bindNodeID: Int,
        bindMetadata: BindMetadata,
        upstreamLeafNodeID: Int,
        gen: ReflectiveGenerator<Any>,
        baseSequence: ChoiceSequence,
        fallbackTree: ChoiceTree
    ) -> (classification: BindClassification, fingerprint: UInt64?) {
        guard upstreamLeafNodeID < nodes.count, isTombstoned(upstreamLeafNodeID) == false else {
            return (BindClassification(topology: .unclassifiable, liftability: .neither), nil)
        }
        guard case let .chooseBits(leafMetadata) = nodes[upstreamLeafNodeID].kind else {
            return (BindClassification(topology: .unclassifiable, liftability: .neither), nil)
        }
        guard let upstreamIndex = nodes[upstreamLeafNodeID].positionRange?.lowerBound else {
            return (BindClassification(topology: .unclassifiable, liftability: .neither), nil)
        }
        if leafMetadata.typeTag.isFloatingPoint {
            // Phase 1 scope: integer-indexed binds only. Float upstreams can be added once the clamp heuristic is extended to the Hedgehog-style signed float encoding.
            return (BindClassification(topology: .unclassifiable, liftability: .both), nil)
        }
        let fullRange = leafMetadata.validRange ?? leafMetadata.typeTag.bitPatternRange
        guard let endpoints = Self.clampedEndpoints(range: fullRange, typeTag: leafMetadata.typeTag) else {
            return (BindClassification(topology: .unclassifiable, liftability: .neither), nil)
        }
        if endpoints.low == endpoints.high {
            // Singleton domain — no structural comparison to perform, and no reason to run composed.
            return (BindClassification(topology: .unclassifiable, liftability: .both), nil)
        }

        let lowLift = lift(
            bitPattern: endpoints.low,
            upstreamIndex: upstreamIndex,
            leafMetadata: leafMetadata,
            gen: gen,
            baseSequence: baseSequence,
            fallbackTree: fallbackTree,
            bindPath: bindMetadata.bindPath
        )
        let highLift = lift(
            bitPattern: endpoints.high,
            upstreamIndex: upstreamIndex,
            leafMetadata: leafMetadata,
            gen: gen,
            baseSequence: baseSequence,
            fallbackTree: fallbackTree,
            bindPath: bindMetadata.bindPath
        )
        let liftability: BindLiftability = switch (lowLift, highLift) {
        case (.some, .some): .both
        case (.some, .none): .lowOnly
        case (.none, .some): .highOnly
        case (.none, .none): .neither
        }
        guard let lowSubtree = lowLift, let highSubtree = highLift else {
            return (BindClassification(topology: .unclassifiable, liftability: liftability), nil)
        }
        let topology: BindTopology = Self.sameTopology(lowSubtree, highSubtree) ? .identical : .divergent
        let fingerprint = Self.subtreeFingerprint(lowSubtree)
        return (BindClassification(topology: topology, liftability: liftability), fingerprint)
    }

    private func lift(
        bitPattern: UInt64,
        upstreamIndex: Int,
        leafMetadata: ChooseBitsMetadata,
        gen: ReflectiveGenerator<Any>,
        baseSequence: ChoiceSequence,
        fallbackTree: ChoiceTree,
        bindPath: BindPath
    ) -> ChoiceTree? {
        guard upstreamIndex < baseSequence.count else { return nil }
        var candidate = baseSequence
        let newChoice = ChoiceValue(
            leafMetadata.typeTag.makeConvertible(bitPattern64: bitPattern),
            tag: leafMetadata.typeTag
        )
        candidate[upstreamIndex] = .value(.init(
            choice: newChoice,
            validRange: leafMetadata.validRange,
            isRangeExplicit: leafMetadata.isRangeExplicit
        ))
        guard case let .success(_, freshTree, _) = Materializer.materializeAny(
            gen,
            prefix: candidate,
            mode: .guided(seed: 0, fallbackTree: fallbackTree),
            fallbackTree: fallbackTree,
            materializePicks: true
        ) else {
            return nil
        }
        return Self.extractBoundSubtree(from: freshTree, matchingPath: bindPath)
    }

    private func writeClassification(
        _ verdict: (classification: BindClassification, fingerprint: UInt64?),
        bindMetadata: BindMetadata,
        bindNodeID: Int
    ) {
        let updatedMetadata = BindMetadata(
            fingerprint: bindMetadata.fingerprint,
            isStructurallyConstant: bindMetadata.isStructurallyConstant,
            bindDepth: bindMetadata.bindDepth,
            innerChildIndex: bindMetadata.innerChildIndex,
            boundChildIndex: bindMetadata.boundChildIndex,
            bindPath: bindMetadata.bindPath,
            classification: verdict.classification,
            downstreamFingerprint: verdict.fingerprint
        )
        let node = nodes[bindNodeID]
        nodes[bindNodeID] = ChoiceGraphNode(
            id: node.id,
            kind: .bind(updatedMetadata),
            positionRange: node.positionRange,
            children: node.children,
            parent: node.parent
        )
        // Mirror into the per-graph fingerprint-keyed cache so the verdict survives the next ``ChoiceGraph/build(from:inheriting:)``. The per-node `BindMetadata.classification` field is the in-instance authority; the cache is the across-instance one. Phase 2 keeps both stores updated for compatibility; later phases may demote the per-node field to a derived view populated from the cache at build time.
        bindClassifications[bindMetadata.fingerprint] = verdict.classification
    }

    // MARK: - Passive Topology Observation

    /// Observes bind topology from the current graph state and classifies binds whose upstream value has changed since the last observation.
    ///
    /// For each non-getSize bind node, reads the upstream leaf's current bit pattern from the graph and computes the bound subtree's topology fingerprint from `tree`. Compares against the stored ``BindTopologyObservation``:
    /// - Upstream unchanged: updates the stored downstream fingerprint (structural ops may have changed it independently).
    /// - Upstream changed, downstream fingerprint same: classifies as `.identical` — the bind produces the same shape for different upstream values.
    /// - Upstream changed, downstream fingerprint different: classifies as `.divergent` — the bind reshapes under upstream variation.
    ///
    /// Call after each graph rebuild. Avoids the two materialisation probes that ``classifyBind`` requires by observing natural upstream variation across rebuild cycles.
    func observeBindTopologies(tree: ChoiceTree) {
        for (nodeID, node) in nodes.enumerated() {
            guard isTombstoned(nodeID) == false else { continue }
            guard case let .bind(metadata) = node.kind else { continue }
            guard metadata.isStructurallyConstant == false else { continue }
            if bindClassifications[metadata.fingerprint] != nil { continue }
            guard node.children.count >= 2 else { continue }

            let innerChildID = node.children[metadata.innerChildIndex]
            guard innerChildID < nodes.count else { continue }
            guard case let .chooseBits(leafMetadata) = nodes[innerChildID].kind else { continue }

            let boundChildID = node.children[metadata.boundChildIndex]
            guard boundChildID < nodes.count else { continue }

            guard let boundSubtree = Self.extractBoundSubtree(
                from: tree,
                matchingPath: metadata.bindPath
            ) else { continue }

            let upstreamBitPattern = leafMetadata.value.bitPattern64
            let downstreamFingerprint = Self.subtreeFingerprint(boundSubtree)

            let newObservation = BindTopologyObservation(
                upstreamBitPattern: upstreamBitPattern,
                downstreamFingerprint: downstreamFingerprint
            )

            guard let previous = bindTopologyObservations[metadata.fingerprint] else {
                bindTopologyObservations[metadata.fingerprint] = newObservation
                continue
            }

            if previous.upstreamBitPattern == upstreamBitPattern {
                bindTopologyObservations[metadata.fingerprint] = newObservation
                continue
            }

            let topology: BindTopology = previous.downstreamFingerprint == downstreamFingerprint
                ? .identical
                : .divergent
            let classification = BindClassification(topology: topology, liftability: .both)
            bindClassifications[metadata.fingerprint] = classification
            bindTopologyObservations.removeValue(forKey: metadata.fingerprint)
        }
    }

    // MARK: - Endpoint Clamp

    /// Clamps a leaf's valid bit-pattern range into a window centered on the type's semantic zero so that probing stays inside any reasonable consumer's distribution.
    ///
    /// Unsigned tags clamp to `0 ... 10_000`; signed tags clamp to `simplestBitPattern ± 10_000` — the sign-magnitude encoding is order-preserving, so that window covers semantic `-10_000 ... 10_000`. Floating-point tags are not called here (handled upstream as ``BindTopology/unclassifiable``).
    ///
    /// Returns nil when the clamped window does not intersect the valid range.
    static func clampedEndpoints(
        range: ClosedRange<UInt64>,
        typeTag: TypeTag
    ) -> (low: UInt64, high: UInt64)? {
        let windowRadius: UInt64 = 10_000
        let clampLow: UInt64
        let clampHigh: UInt64
        if typeTag.isSigned {
            let simplest = typeTag.simplestBitPattern
            clampLow = simplest &- windowRadius
            clampHigh = simplest &+ windowRadius
        } else {
            clampLow = 0
            clampHigh = windowRadius
        }
        let low = max(range.lowerBound, clampLow)
        let high = min(range.upperBound, clampHigh)
        guard low <= high else { return nil }
        return (low, high)
    }

    // MARK: - Topology Walker

    /// Whether two lifted bound subtrees have the same skeleton.
    ///
    /// Same node kind at each corresponding position, and same child counts at every non-leaf position, with these relaxations:
    /// - Leaf-level descriptors on ``ChoiceTree/choice(_:_:)`` (tag, width, range) are not compared — they are the signal expensive encoders operate on.
    /// - ``ChoiceTree/sequence(length:elements:_:)`` element counts may differ; elements are compared pairwise up to the shared prefix. A sequence that shifts length but keeps element shape stable (Coupling's `int(in: 0...n).array(length: 2 ... max(2, n+1))`) remains ``BindTopology/identical``.
    /// - Transparent wrappers (``ChoiceTree/branch(fingerprint:weight:id:branchIDs:choice:)``, ``ChoiceTree/selected(_:)``) pass through without requiring a matching wrapper on the other side.
    static func sameTopology(_ low: ChoiceTree, _ high: ChoiceTree) -> Bool {
        // Strip transparent wrappers symmetrically before comparing.
        let lhs = unwrapTransparent(low)
        let rhs = unwrapTransparent(high)
        switch (lhs, rhs) {
        case (.choice, .choice):
            return true
        case (.just, .just):
            return true
        case (.getSize, .getSize):
            return true
        case let (.sequence(_, lowElements, _), .sequence(_, highElements, _)):
            let shared = min(lowElements.count, highElements.count)
            var index = 0
            while index < shared {
                if sameTopology(lowElements[index], highElements[index]) == false {
                    return false
                }
                index += 1
            }
            return true
        case let (.bind(_, lowInner, lowBound), .bind(_, highInner, highBound)):
            return sameTopology(lowInner, highInner) && sameTopology(lowBound, highBound)
        case let (.group(lowArray, _), .group(highArray, _)):
            if lowArray.count != highArray.count { return false }
            var index = 0
            while index < lowArray.count {
                if sameTopology(lowArray[index], highArray[index]) == false {
                    return false
                }
                index += 1
            }
            return true
        case let (.resize(_, lowChoices), .resize(_, highChoices)):
            if lowChoices.count != highChoices.count { return false }
            var index = 0
            while index < lowChoices.count {
                if sameTopology(lowChoices[index], highChoices[index]) == false {
                    return false
                }
                index += 1
            }
            return true
        default:
            return false
        }
    }

    /// Strips through transparent tree wrappers (``ChoiceTree/branch(fingerprint:weight:id:branchIDs:choice:)`` and ``ChoiceTree/selected(_:)``) so the caller can compare the underlying structure without tripping on wrapper asymmetry.
    private static func unwrapTransparent(_ tree: ChoiceTree) -> ChoiceTree {
        switch tree {
        case let .branch(_, _, _, _, choice):
            return unwrapTransparent(choice)
        case let .selected(inner):
            return unwrapTransparent(inner)
        default:
            return tree
        }
    }

    // MARK: - Fingerprint

    /// Hashes the bound subtree's structural skeleton so a caller can detect whether a cached classification still matches the live subtree. Ignores leaf descriptors (tags, widths, values) — same skeleton, different leaf values hash to the same fingerprint.
    static func subtreeFingerprint(_ tree: ChoiceTree) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037 // FNV-1a offset basis
        fold(tree, into: &hash)
        return hash
    }

    private static func fold(_ tree: ChoiceTree, into hash: inout UInt64) {
        let marker: UInt64
        switch tree {
        case .choice: marker = 1
        case .just: marker = 2
        case .getSize: marker = 3
        case .sequence: marker = 4
        case .branch: marker = 5
        case .group: marker = 6
        case .resize: marker = 7
        case .bind: marker = 8
        case .selected: marker = 9
        }
        hash = (hash ^ marker) &* 1_099_511_628_211
        switch tree {
        case .choice, .just, .getSize:
            return
        case let .sequence(_, elements, _):
            hash = (hash ^ UInt64(elements.count)) &* 1_099_511_628_211
            for element in elements {
                fold(element, into: &hash)
            }
        case let .branch(_, _, _, _, choice):
            fold(choice, into: &hash)
        case let .group(array, _):
            hash = (hash ^ UInt64(array.count)) &* 1_099_511_628_211
            for child in array {
                fold(child, into: &hash)
            }
        case let .resize(_, choices):
            hash = (hash ^ UInt64(choices.count)) &* 1_099_511_628_211
            for child in choices {
                fold(child, into: &hash)
            }
        case let .bind(_, inner, bound):
            fold(inner, into: &hash)
            fold(bound, into: &hash)
        case let .selected(inner):
            fold(inner, into: &hash)
        }
    }
}
