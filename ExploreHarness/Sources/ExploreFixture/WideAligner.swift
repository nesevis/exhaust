// The second R-class member (matrix fixture MX2d, "WideAlign2"): a wide-alignment fault whose arity and site count deliberately differ from DeepParser's fault R (single 4-ary site, run of 12), so the swarm-suppressed class has more than one geometry — one fixture defining a class is how Q's geometry surprise happened.
//
// ## Shape Coordinates
//
// Trigger class: wide alignment (swarm-suppressed). Coverage surface: flat — no intermediate edge lights on partial alignment (see Flatness). Vocabulary: one generator with two 12-branch `.oneOf` sites feeding arrays. Argument domain: 12 tokens per site. Length scale: alignment runs of 3...6 per site, far inside any length pressure.
//
// ## Ground-Truth Registry
//
// Fault R2 (cross-site pair alignment):
//     Trigger: every alpha equals 7 and every beta equals 2, with both arrays at least 3 long (the generator's own length floor; the arithmetic shortfall guard keeps the requirement explicit against future generator edits).
//     Trigger variable: the fold of XOR mismatches across both arrays.
//     Minimal: alphas [7, 7, 7], betas [2, 2, 2].
//     Effect: throws WideAlignError.
//
// Single planted fault.
//
// ## Flatness
//
// Both arrays are consumed by unconditional loops whose bodies fold mismatches with `|=` — loop-body hit counts track array LENGTH (alignment-uncorrelated), never match progress, and there is no early exit for a prefix match to ride. All four conditions (two alignments, two length floors) fold into one integer before the only branch, so partial alignment lights nothing — the same no-ladder discipline as fault R's depth check.
//
// ## Blind-Improbability Math
//
// Under a uniform 3...6 length draw per site, P(one site aligns) = ((1/12)^3 + (1/12)^4 + (1/12)^5 + (1/12)^6) / 4 ≈ 1.58e-4, and the sites are independent, so the joint blind rate is ≈ 2.5e-8 per attempt — the same magnitude as fault R (~1e-8), reached through a different geometry. A swarm mask that keeps the target branch while suppressing half of each site's arity lifts the per-site alignment by roughly (arity/masked arity)^run ≈ 8-64x per site.
//
// Pinned baseline (MX2e, 2026-07-12, seeds 1-20, 10 s, defaults): 0/20.

import Exhaust

/// Two token arrays drawn from separate 12-branch sites; the planted fault needs both fully aligned on a specific token pair.
public struct AlignedPair: Sendable, Equatable {
    public let alphas: [Int]
    public let betas: [Int]

    public init(alphas: [Int], betas: [Int]) {
        self.alphas = alphas
        self.betas = betas
    }
}

/// A pure function faulting when both arrays align on the planted token pair.
public enum WideAligner {
    /// Checks the alignment fault.
    ///
    /// - Throws: ``WideAlignError`` when every alpha is 7 and every beta is 2, with both arrays at least 3 long.
    public static func check(_ pair: AlignedPair) throws {
        var mismatch = max(0, 3 - pair.alphas.count) | max(0, 3 - pair.betas.count)
        for value in pair.alphas {
            mismatch |= value ^ 7
        }
        for value in pair.betas {
            mismatch |= value ^ 2
        }
        // Fault R2: the only branch; partial alignment lights nothing.
        if mismatch == 0 {
            throw WideAlignError()
        }
    }
}

/// Fault R2's observable effect.
public struct WideAlignError: Error, Equatable, Sendable {
    public init() {}
}

/// The generator and ground-truth minimal reproducer for ``WideAligner``.
public enum WideAlignFixture {
    /// Two independent 12-branch token sites, each feeding an array of 3...6 draws.
    public static var pairGenerator: ReflectiveGenerator<AlignedPair> {
        #gen(
            tokenSite.array(length: 3 ... 6),
            tokenSite.array(length: 3 ... 6)
        ) { alphas, betas in
            AlignedPair(alphas: alphas, betas: betas)
        }
    }

    /// One 12-branch token site: each token is its own generator branch, the seam swarm masking reweights.
    private static var tokenSite: ReflectiveGenerator<Int> {
        .oneOf(
            .just(0), .just(1), .just(2), .just(3),
            .just(4), .just(5), .just(6), .just(7),
            .just(8), .just(9), .just(10), .just(11)
        )
    }

    /// Fault R2's minimal form: three aligned draws per site.
    public static let reproducerR2 = AlignedPair(alphas: [7, 7, 7], betas: [2, 2, 2])
}
