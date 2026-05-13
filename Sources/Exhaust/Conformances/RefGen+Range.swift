//
//  RefGen+Range.swift
//  Exhaust
//

import ExhaustCore

public extension RefGen {
    /// Generates arbitrary `ClosedRange` values from two independently generated bounds.
    ///
    /// The two generated values are sorted so the smaller becomes the lower bound and the larger becomes the upper bound. This is fully bidirectional — the backward pass extracts the bounds directly.
    ///
    /// ```swift
    /// let gen = #gen(.closedRange(.int(in: 0...100)))
    /// ```
    ///
    /// - Parameter bounds: Generator for the range bound values.
    /// - Returns: A generator producing closed ranges where lower bound is at most the upper bound.
    static func closedRange<Bound: Comparable & Sendable>(
        _ bounds: RefGen<Bound>
    ) -> RefGen<ClosedRange<Bound>> where Output == ClosedRange<Bound> {
        RefGen<(Bound, Bound)> {
            Gen.zip(bounds.gen, bounds.gen)
        }.mapped(
            forward: { first, second in
                min(first, second) ... max(first, second)
            },
            backward: { range in
                (range.lowerBound, range.upperBound)
            }
        )
    }

    /// Generates arbitrary half-open `Range` values from two independently generated bounds.
    ///
    /// The two generated values are sorted so the smaller becomes the lower bound and the larger becomes the upper bound. When both values are equal, the range is empty.
    ///
    /// ```swift
    /// let gen = #gen(.range(.int(in: 0...100)))
    /// ```
    ///
    /// - Parameter bounds: Generator for the range bound values.
    /// - Returns: A generator producing ranges where lower bound is at most the upper bound.
    static func range<Bound: Comparable & Sendable>(
        _ bounds: RefGen<Bound>
    ) -> RefGen<Range<Bound>> where Output == Range<Bound> {
        RefGen<(Bound, Bound)> {
            Gen.zip(bounds.gen, bounds.gen)
        }.mapped(
            forward: { first, second in
                min(first, second) ..< max(first, second)
            },
            backward: { range in
                (range.lowerBound, range.upperBound)
            }
        )
    }
}
