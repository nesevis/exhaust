//
//  DirectionalStepper.swift
//  Exhaust
//

/// Searches a `UInt64` range with interpolation search for large ranges and plain binary search for small ranges. The threshold is ``ReductionTuning/interpolationBinaryThreshold``.
///
/// Exactly one of `binary` or `interpolation` is non-nil at any time. The flat-optional layout avoids the overhead of enum associated-value extraction and reconstruction on every call to ``advance(lastAccepted:)``, which sits on the reducer's tightest per-iteration loop.
struct DirectionalStepper {
    private var binary: BinarySearchStepper?
    private var interpolation: InterpolationSearchStepper?

    var bestAccepted: UInt64 {
        binary?.bestAccepted ?? interpolation?.bestAccepted ?? 0
    }

    var resumeBound: UInt64 {
        binary?.resumeBound ?? interpolation?.resumeBound ?? 0
    }

    /// Picks binary search when `hi - lo` is below `binaryThreshold`, and interpolation search otherwise.
    init(
        lo: UInt64,
        hi: UInt64,
        direction: SearchDirection,
        binaryThreshold: UInt64,
        initialDivisor: UInt64
    ) {
        if hi - lo < binaryThreshold {
            binary = BinarySearchStepper(lo: lo, hi: hi, direction: direction)
        } else {
            interpolation = InterpolationSearchStepper(
                lo: lo,
                hi: hi,
                direction: direction,
                binaryThreshold: binaryThreshold,
                initialDivisor: initialDivisor
            )
        }
    }

    mutating func start() -> UInt64? {
        if binary != nil {
            return binary!.start()
        } else if interpolation != nil {
            return interpolation!.start()
        }
        return nil
    }

    mutating func advance(lastAccepted: Bool) -> UInt64? {
        if binary != nil {
            return binary!.advance(lastAccepted: lastAccepted)
        } else if interpolation != nil {
            return interpolation!.advance(lastAccepted: lastAccepted)
        }
        return nil
    }
}
