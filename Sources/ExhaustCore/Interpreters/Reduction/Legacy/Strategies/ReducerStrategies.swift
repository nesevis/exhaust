//
//  ReducerStrategies.swift
//  Exhaust
//
//  Created by Chris Kolbu on 17/2/2026.
//

/// Namespace for individual reducer strategy functions. Each strategy is defined in its own extension file.
public enum ReducerStrategies {}

// MARK: - Bind-Aware Materialization

public extension ReducerStrategies {
    /// Materializes a candidate sequence, using ``GuidedMaterializer`` when a single
    /// mutated index falls inside a bind's inner subtree (so bound content is re-derived fresh).
    ///
    /// For bind-triggered materializations, the current choice tree is passed as the tier-2
    /// fallback. When inner values change and bound ranges shift, GuidedMaterializer clamps
    /// old bound values to the new ranges rather than randomizing them from PRNG. This
    /// preserves reduction consistency — bound values stay close to their last known state.
    ///
    /// - Parameters:
    ///   - gen: The generator to materialize.
    ///   - tree: The choice tree for standard materialization.
    ///   - candidate: The candidate choice sequence.
    ///   - bindIndex: The bind span index, or `nil` if the generator contains no binds.
    ///   - mutatedIndex: The sequence index that was modified.
    ///   - strictness: Materialization strictness (default `.normal`).
    /// - Returns: The materialized value, or `nil` if materialization failed.
    static func materializeCandidate<Output>(
        _ gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        candidate: ChoiceSequence,
        bindIndex: BindSpanIndex?,
        mutatedIndex: Int,
        strictness: Interpreters.Strictness = .normal,
        maximizeBoundRegionIndices: Set<Int>? = nil,
    ) throws -> Output? {
        if let bindIndex, bindIndex.bindRegionForInnerIndex(mutatedIndex) != nil {
            let seed = ZobristHash.hash(of: candidate)
            switch GuidedMaterializer.materialize(gen, prefix: candidate, seed: seed, fallbackTree: tree, maximizeBoundRegionIndices: maximizeBoundRegionIndices) {
            case let .success(value, _, _):
                return value
            case .filterEncountered, .failed:
                return nil
            }
        }
        return try Interpreters.materialize(gen, with: tree, using: candidate, strictness: strictness)
    }

    /// Materializes a candidate sequence, using ``GuidedMaterializer`` when any of the
    /// mutated indices falls inside a bind's inner subtree.
    ///
    /// See the single-index overload for rationale on using the fallback tree.
    ///
    /// - Parameters:
    ///   - gen: The generator to materialize.
    ///   - tree: The choice tree for standard materialization.
    ///   - candidate: The candidate choice sequence.
    ///   - bindIndex: The bind span index, or `nil` if the generator contains no binds.
    ///   - mutatedIndices: The sequence indices that were modified.
    ///   - strictness: Materialization strictness (default `.normal`).
    /// - Returns: The materialized value, or `nil` if materialization failed.
    static func materializeCandidate<Output>(
        _ gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        candidate: ChoiceSequence,
        bindIndex: BindSpanIndex?,
        mutatedIndices: some Collection<Int>,
        strictness: Interpreters.Strictness = .normal,
        maximizeBoundRegionIndices: Set<Int>? = nil,
    ) throws -> Output? {
        if let bindIndex, bindIndex.isEmpty == false,
           mutatedIndices.contains(where: { bindIndex.bindRegionForInnerIndex($0) != nil })
        {
            let seed = ZobristHash.hash(of: candidate)
            switch GuidedMaterializer.materialize(gen, prefix: candidate, seed: seed, fallbackTree: tree, maximizeBoundRegionIndices: maximizeBoundRegionIndices) {
            case let .success(value, _, _):
                return value
            case .filterEncountered, .failed:
                return nil
            }
        }
        return try Interpreters.materialize(gen, with: tree, using: candidate, strictness: strictness)
    }
}
