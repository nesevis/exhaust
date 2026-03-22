# Dependency Edge Encoder — Design Sketch

## Context

The Bonsai reducer cannot shrink the coupling challenge to `[1, 0]` because no encoder searches the downstream (bound) value space after reducing an upstream (bind-inner) value. When `productSpaceBatch` tries `n=1`, the materializer fills bound content with zeros → `[0, 0]` passes the property. The minimal counterexample `[1, 0]` requires both `n=1` AND specific inner values.

The S-J algebra (Prop 3.2, 7.8) guarantees that composing two valid reduction morphisms across a dependency edge produces a valid composite. This design introduces a **dependency edge encoder** — an encoding entity that operates on both sides of a bind dependency, connected by a materialization bridge.

## Prerequisite: fresh-tree fix

The CoverageRunner fresh-tree fix (already implemented) is a prerequisite. Without it, the reducer receives stale trees and produces wrong results regardless of edge exploration.

## Core concept

Current encoders are **vertex encoders** — they modify values at positions in the sequence. The dependency edge encoder is an **edge encoder** — it operates on the relationship between an upstream vertex (bind-inner value) and its downstream scope (bound content).

In the `ChoiceDependencyGraph`, each bind-inner node has a `scopeRange` identifying the bound subtree it controls. This is the edge: `innerRange → boundRange` in `BindSpanIndex.BindRegion`.

### Kleisli composition (S-J §7)

The edge encoder is a morphism in the **Kleisli category** Kl(T) of the effect monad, not in the base category OptRed_ex. Its three components compose via Kleisli composition (Prop 7.8):

1. **enc_A : V_A → V_A'** — the upstream vertex encoder (reduce n). May be exact or approximate depending on type.
2. **Kleisli extension V_A' → T(Fibre_B)** — the materialization bridge. This is a Kleisli arrow: given a reduced upstream value, it produces a *distribution over* downstream value assignments via PRNG. Inherently effectful.
3. **enc_B : V_B → V_B'** — the downstream vertex encoder (search/refine inner values). Type-dispatched.

The composite `enc_B ⊙ bridge ⊙ enc_A` is a T-effectful reduction (Def 7.7). Its grade is bounded by the product of its components' grades (Prop 8.4, 10.4): if enc_A is exact but the bridge involves PRNG fallback with partial coverage, the composite grade's multiplicative factor reflects the bridge's coverage (seedCount / |domain|). The grade monoid multiplication `γ_{b∘a} = γ_a ⊗ γ_b` tracks this automatically.

## Design

### Core abstraction: `DependencyEdgeEncoder` as a combinator

The edge encoder is a **combinator** — it composes vertex encoders for each end of a dependency edge, connected by a materialization bridge. The vertex encoders at each end are chosen based on the data type at that vertex:

- **Integral types** → `BinarySearchLadder` (halving midpoints toward target)
- **Floating-point types** → float reduction ladder (rational arithmetic steps)
- **Sequences** → sequence-length reduction + element-wise search

This means the same edge encoder framework handles different generator shapes without specialization at the edge level. The edge encoder doesn't know how to reduce — it delegates to type-appropriate vertex encoders at each end.

### Vertex encoder protocol

A vertex encoder produces candidate values for a single position (or range) in the sequence. This is the unit that gets composed — different `TypeTag`s get different vertex encoders.

```swift
/// Produces candidate values for a single vertex in the dependency graph.
///
/// Vertex encoders are the building blocks that the ``DependencyEdgeEncoder``
/// composes across a dependency edge. Each vertex encoder targets a specific
/// position (or range) in the choice sequence and produces candidate values
/// appropriate to the data type at that position.
protocol VertexEncoder {
    /// Initializes the encoder for the value at the given sequence position.
    mutating func start(value: ChoiceSequenceValue.Value)

    /// Returns the next candidate value, or nil when exhausted.
    ///
    /// - Parameter lastAccepted: Whether the previous candidate was accepted.
    mutating func nextCandidate(lastAccepted: Bool) -> ChoiceValue?
}
```

**Type-dispatched implementations** (initial set):

```swift
/// Vertex encoder for integral types. Halving midpoints from current to target.
struct IntegralVertexEncoder: VertexEncoder { ... }
    // Wraps BinarySearchLadder, iterates target-first

/// Vertex encoder for floating-point types. Rational-step ladder.
struct FloatingPointVertexEncoder: VertexEncoder { ... }
    // Wraps FloatShrink ladder construction

/// Vertex encoder for sequence-length positions. Halving toward min length.
struct SequenceLengthVertexEncoder: VertexEncoder { ... }
    // Wraps BinarySearchLadder on the length domain
```

Factory:
```swift
static func vertexEncoder(for tag: TypeTag) -> (any VertexEncoder)?
```

### New type: `DependencyEdgeEncoder`

A value type that explicitly composes two vertex encoders across a dependency edge, connected by a materialization bridge. The composition is visible in the type: `enc_A` (upstream) ⊙ `bridge` ⊙ `enc_B` (downstream).

```swift
/// Composes two vertex encoders across a bind dependency edge via Kleisli
/// composition (S-J §7). The upstream encoder reduces the bind-inner value;
/// the bridge materializes through the generator to populate the bound
/// subtree; the downstream encoder refines values in the new fibre.
struct DependencyEdgeEncoder {
    let name: EncoderName = .dependencyEdge

    // --- Edge identity ---
    let regionIndex: Int
    let upstreamIndex: Int
    let boundRange: ClosedRange<Int>

    // --- enc_A: upstream vertex encoder ---
    var upstreamEncoder: any VertexEncoder

    // --- Bridge: Kleisli arrow V_A' → T(Fibre_B) ---
    let seedCount: Int
    let coverageThreshold: Double

    // --- enc_B: downstream vertex encoder ---
    // Applied to each value position in boundRange after materialization.
    // For the initial implementation, fibre descent serves as enc_B
    // (the driver calls runFibreDescent on the accepted state).
    // Future: per-position VertexEncoder instances for downstream values.
}
```

**Builder**:

```swift
extension DependencyEdgeEncoder {
    static func build(
        from region: BindSpanIndex.BindRegion,
        regionIndex: Int,
        sequence: ChoiceSequence,
        seedCount: Int = 8,
        coverageThreshold: Double = 0.5
    ) -> DependencyEdgeEncoder? {
        // Find the upstream value entry within the inner range.
        var upstreamIndex: Int?
        for index in region.innerRange {
            if sequence[index].value != nil {
                upstreamIndex = index
                break
            }
        }
        guard let upstreamIndex,
              let upstreamValue = sequence[upstreamIndex].value
        else { return nil }

        // Type-dispatched upstream encoder.
        guard var upstream = Self.vertexEncoder(for: upstreamValue.choice.tag) else {
            return nil
        }
        upstream.start(value: upstreamValue)

        return DependencyEdgeEncoder(
            regionIndex: regionIndex,
            upstreamIndex: upstreamIndex,
            boundRange: region.boundRange,
            upstreamEncoder: upstream,
            seedCount: seedCount,
            coverageThreshold: coverageThreshold
        )
    }
}
```

### Scheduling method: `runDependencyEdgeExploration`

Lives in `ReductionState+Bonsai.swift`. Composes the edge encoder's upstream vertex encoder with the materialization bridge and downstream exploitation. This is where the S-J composite morphism is realized.

```swift
private func runDependencyEdgeExploration(budget: inout Int) throws -> Bool {
    guard hasBind, let bindSpanIndex = bindIndex else { return false }

    for (regionIndex, region) in bindSpanIndex.regions.enumerated() {
        guard var edgeEncoder = DependencyEdgeEncoder.build(
            from: region, regionIndex: regionIndex, sequence: sequence
        ) else { continue }

        // ── enc_A: iterate upstream vertex encoder ──
        var lastUpstreamAccepted = false
        while let upstreamValue = edgeEncoder.upstreamEncoder.nextCandidate(
            lastAccepted: lastUpstreamAccepted
        ) {
            lastUpstreamAccepted = false

            // Build candidate with upstream value modified.
            guard let existingValue = sequence[edgeEncoder.upstreamIndex].value else { continue }
            var candidate = sequence
            candidate[edgeEncoder.upstreamIndex] = .value(.init(
                choice: upstreamValue,
                validRange: existingValue.validRange,
                isRangeExplicit: existingValue.isRangeExplicit
            ))

            // ── Bridge: Kleisli arrow V_A' → T(Fibre_B) ──
            // Materialize with multiple seeds to explore the downstream fibre.
            for seed in 0 ..< edgeEncoder.seedCount {
                guard budget > 0 else { return false }
                budget -= 1

                let prefix = ChoiceSequence(candidate)
                let result = ReductionMaterializer.materialize(
                    gen, prefix: prefix,
                    mode: .guided(seed: UInt64(seed), fallbackTree: nil)
                )

                switch result {
                case let .success(value, freshTree, decodingReport):
                    // Coverage gate: on first seed, check bridge quality.
                    if seed == 0,
                       let report = decodingReport,
                       report.coverage < edgeEncoder.coverageThreshold
                    {
                        break // Bridge too noisy → skip remaining seeds
                    }

                    let freshSequence = ChoiceSequence(freshTree)
                    if property(value) == false,
                       freshSequence.shortLexPrecedes(sequence)
                    {
                        accept(
                            ReductionResult(
                                sequence: freshSequence, tree: freshTree,
                                output: value, evaluations: 1,
                                decodingReport: decodingReport
                            ),
                            structureChanged: true
                        )
                        lastUpstreamAccepted = true

                        // ── enc_B: downstream vertex encoder ──
                        // Run fibre descent on accepted state to refine
                        // the downstream values within the new fibre.
                        var fibreBudget = min(budget, 200)
                        let dag = ChoiceDependencyGraph.build(
                            from: sequence, tree: tree, bindIndex: bindSpanIndex
                        )
                        _ = try runFibreDescent(budget: &fibreBudget, dag: dag)
                        budget -= (min(budget, 200) - fibreBudget)

                        return true
                    }

                case .rejected, .failed:
                    continue
                }
            }
        }
    }
    return false
}
```

The three components of the Kleisli composite are clearly separated:
- **enc_A** (outer loop): the upstream `VertexEncoder` produces candidate values for the bind-inner position
- **Bridge** (inner loop): `ReductionMaterializer.materialize` with multiple seeds explores the downstream fibre, gated by `DecodingReport.coverage`
- **enc_B** (on acceptance): fibre descent refines the downstream values within the freshly materialized sequence

### Adaptive coverage gate via lift report

The `DecodingReport` from `ReductionMaterializer.materialize` already reports per-coordinate resolution tiers — exact (prefix hit), fallback (tree hit), or PRNG. This directly measures the **bridge quality**: the fidelity of the Kleisli arrow `V_A' → T(Fibre_B)`.

- **High coverage** (most coordinates resolved by prefix/fallback): the upstream encoder's choice of A is faithfully reflected in B's fibre. Joint optimization across the edge is meaningful → **use the edge encoder**.
- **Low coverage** (many coordinates resolved by PRNG): B's fibre is partially random. Joint optimization is noisy and the outer encoder's result may not be reproducible if the same inner value is proposed again → **fall back** to the current sequential phase approach.

The driver uses this as an adaptive gate:

```
for each upstream candidate:
    materialize once with seed 0 → get (value, freshTree, decodingReport)
    bridgeCoverage = decodingReport.coverage
    if bridgeCoverage < threshold (say 0.5):
        skip remaining seeds for this upstream candidate
        (bridge too noisy for reliable joint optimization)
    else:
        proceed with multi-seed exploration
```

This connects the S-J grade theory to a practical adaptive strategy: the coverage metric IS the multiplicative factor in the composite grade. High coverage ≈ grade factor near 1.0 (faithful). Low coverage ≈ grade factor near 0 (lossy). The threshold is the minimum grade at which joint optimization is expected to outperform independent phases.

The metric is already computed — `guided_materialization_fidelity` is already logged during Tier 1/2 evaluation. The edge encoder reuses the same `DecodingReport` infrastructure.

### Pipeline placement

In the Bonsai cycle's exploration phase, **just before** `runRelaxRound`. The edge encoder is speculative (non-monotone intermediate state, same as RelaxRound) and runs after the deterministic phases have stalled:

```
Bonsai cycle:
  1. runBaseDescent (branch simplification → structural deletion → bind-inner reduction)
  2. runFibreDescent (leaf-range values → covariant depth sweep → redistribution)
  3. → NEW: runDependencyEdgeExploration (only in value-sensitive regime)
  4. runRelaxRound (speculative redistribution → exploit)
```

The edge encoder runs in the exploration phase because it is inherently speculative: reducing the upstream value and materializing with PRNG seeds may produce intermediate states that are shortlex-worse before fibre descent improves them. This is the same pattern as `runRelaxRound` — checkpoint/rollback with pipeline acceptance.

The regime probe from `runJointBindInnerReduction` (step 1) tells us whether we're in value-sensitive mode. If the regime is elimination (simplest values already fail), the edge exploration is skipped entirely.

### Multi-hop composition (A → B → C)

For nested binds, `BindSpanIndex.regions` is ordered by depth. The edge exploration iterates regions outer-to-inner. When an outer edge encoder reduces A and accepts, the sequence is updated. The next iteration's edge encoder for B → C operates on the already-reduced sequence, with B's domain constrained by the new A value.

This is sequential composition: `(A→B) ; (B→C)`. The S-J guarantee (Prop 3.2) ensures the composite is valid. The materialization between steps handles the domain update.

### Exhaustive mode for tiny fibres

When the downstream domain is small enough to enumerate (for example, `{0,1}^2` = 4 candidates for `n=1` in the coupling challenge), exhaustive enumeration is more reliable than PRNG sampling.

Detection: after materializing once for a given upstream value, inspect the fresh tree's bound subtree. If the total domain size (product of all leaf ranges in the bound scope) ≤ `exhaustiveThreshold` (say 32), enumerate all value assignments instead of sampling seeds.

This is an optimization that can be added later. The multi-seed approach works for the coupling challenge because 8 seeds over a 4-element domain has high hit probability (1 - (3/4)^8 ≈ 90%).

## Files to change

| File | Change |
|------|--------|
| `Sources/ExhaustCore/Interpreters/Reduction/Encoders/VertexEncoder.swift` | **New file**: `VertexEncoder` protocol + `IntegralVertexEncoder` (wraps `BinarySearchLadder`) |
| `Sources/ExhaustCore/Interpreters/Reduction/Encoders/DependencyEdgeEncoder.swift` | **New file**: `DependencyEdgeEncoder` type composing two vertex encoders across a bind edge |
| `Sources/ExhaustCore/Interpreters/Reduction/SequenceEncoder.swift` | Add `.dependencyEdge` to `EncoderName` |
| `Sources/ExhaustCore/Interpreters/Reduction/ReductionState+Bonsai.swift` | Add `runDependencyEdgeExploration(budget:)` method; call in exploration phase before `runRelaxRound` |

## Verification

1. `swift test --filter "couplingChallenge"` — should shrink to `[1, 0]`
2. All shrinking challenge tests pass (`swift test --filter "Shrinking"`)
3. `swift test --filter "CoveringArray"` — integration tests pass
4. Budget impact: total property invocations should not increase significantly for non-bind generators (edge exploration guarded by `hasBind` + value-sensitive regime)
