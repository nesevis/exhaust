//
//  AdaptiveProbe.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

import Foundation

/// Adaptive probes for efficient shrinking, based on David MacIver's work on Hypothesis https://notebook.drmaciver.com/posts/2019-04-30-13:03.html
///
/// These two algorithms form the backbone of every shrink pass. Their cost is logarithmic in the size of the *output* (or the error of the guess), not the size of the input range.
public enum AdaptiveProbe {
    /// Discovers the **largest** `k` for which `predicate(k)` holds, in O(log k) time.
    ///
    /// `predicate(0)` is assumed true and is not checked. The predicate must be monotonic: once it returns `false` for some value, it must return `false` for all larger values.
    ///
    /// Used wherever a pass needs to find "how many of these can I do at once" — e.g., batch-deleting the largest contiguous run of spans in adaptive span deletion.
    ///
    /// - Parameter predicate: A monotonic predicate where `predicate(0)` is assumed true.
    /// - Returns: The largest `k >= 0` for which `predicate(k)` holds.
    @inlinable
    @inline(__always)
    public static func findInteger<T: FixedWidthInteger>(_ predicate: (T) -> Bool) -> T {
        // Step 1: Linear scan for small answers.
        // Keep this bounded and avoid probing the same value again in step 2.
        var probe: T = 1
        while probe <= 4 {
            if predicate(probe) == false {
                return probe - 1
            }
            probe += 1
        }

        var low: T = 4
        var high: T = 8

        // Step 2: Exponential upward probe
        while predicate(high) {
            low = high
            let (doubled, overflow) = high.multipliedReportingOverflow(by: 2)
            if overflow {
                high = T.max
                if !predicate(high) { break }
                return high
            }
            high = doubled
        }

        // Step 3: Binary search between low...high
        while low + 1 < high {
            let midpoint = low + (high - low) / 2
            if predicate(midpoint) {
                low = midpoint
            } else {
                high = midpoint
            }
        }

        return low
    }

    /// Binary search where you supply a **guess** of the answer.
    ///
    /// Finds `n` such that `lo <= n < hi` and `predicate(n) != predicate(n + 1)`. `predicate(lo)` is assumed to be `true` and `predicate(hi)` is assumed to be `false`.
    ///
    /// The cost is O(log(|guess − answer|)) rather than O(log(hi − lo)). If the guess is good, this approaches O(1). If the guess is maximally wrong, it costs at most 2× a standard binary search — a bounded downside for a potentially large upside.
    ///
    /// The empirical centroid from value metadata provides the guess during value minimisation, encoding distributional knowledge into reduced property invocations.
    ///
    /// - Parameters:
    ///   - low: Lower bound (inclusive). `predicate(low)` is assumed true.
    ///   - high: Upper bound (inclusive). `predicate(high)` is assumed false.
    ///   - guess: A prediction of the answer. Must satisfy `lo <= guess < hi`. If `nil`, defaults to `lo`.
    ///   - predicate: A monotonic predicate that transitions from true to false.
    /// - Returns: The largest value in `low...high` for which `predicate` holds.
    @inlinable
    @inline(__always)
    public static func binarySearchWithGuess<T: FixedWidthInteger>(_ predicate: (T) -> Bool, low: T, high: T, guess: T? = nil) -> T {
        let guess = guess ?? low
        precondition(low <= guess && guess < high)
        let good = predicate(low)

        // Fast path: avoid probing `low` twice when `guess` defaults to `low`.
        if guess == low {
            let upLimit = high - low
            return low + findInteger { n in
                guard n < upLimit else { return false }
                return predicate(low + n) == good
            }
        }

        if predicate(guess) == good {
            // Our guess was equivalent to low, so we want to find some point after it.
            let upLimit = high - guess
            return guess + findInteger { n in
                guard n < upLimit else { return false }
                return predicate(guess + n) == good
            }
        } else {
            // Our guess was equivalent to high, so we want to find some point before it.
            let downLimit = guess - low
            return guess - findInteger { n in
                guard n <= downLimit else { return false }
                return predicate(guess - n) != good
            } - 1
        }
    }
}
