//
//  ReflectiveGenerator+Range.swift
//  Exhaust
//

import ExhaustCore

public extension ReflectiveGenerator {
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
    static func closedRange<Bound: Comparable>(
        _ bounds: ReflectiveGenerator<Bound>
    ) -> ReflectiveGenerator<ClosedRange<Bound>> where Value == ClosedRange<Bound> {
        Gen.zip(bounds, bounds).mapped(
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
    static func range<Bound: Comparable>(
        _ bounds: ReflectiveGenerator<Bound>
    ) -> ReflectiveGenerator<Range<Bound>> where Value == Range<Bound> {
        Gen.zip(bounds, bounds).mapped(
            forward: { first, second in
                min(first, second) ..< max(first, second)
            },
            backward: { range in
                (range.lowerBound, range.upperBound)
            }
        )
    }
}
