//
//  ReflectiveGenerator+NumericGenerators.swift
//  Exhaust
//
//  Created by Chris Kolbu on 22/2/2026.
//

@_spi(ExhaustInternal) import ExhaustCore

// MARK: - Floating-point generators

public extension ReflectiveGenerator {
    static func double(in range: ClosedRange<Double>? = nil, scaling: SizeScaling<Double>? = nil) -> ReflectiveGenerator<Double> {
        if let range {
            if let scaling {
                Gen.choose(in: range, scaling: scaling)
            } else {
                Gen.choose(in: range)
            }
        } else {
            Gen.choose(in: -Double.greatestFiniteMagnitude ... Double.greatestFiniteMagnitude, scaling: scaling ?? Double.defaultScaling)
        }
    }

    static func float(in range: ClosedRange<Float>? = nil, scaling: SizeScaling<Float>? = nil) -> ReflectiveGenerator<Float> {
        if let range {
            if let scaling {
                Gen.choose(in: range, scaling: scaling)
            } else {
                Gen.choose(in: range)
            }
        } else {
            Gen.choose(in: -Float.greatestFiniteMagnitude ... Float.greatestFiniteMagnitude, scaling: scaling ?? Float.defaultScaling)
        }
    }

    /// Convenience overload accepting `ClosedRange<Double>` (e.g. `0.0...1.0`).
    static func float(in range: ClosedRange<Double>, scaling: SizeScaling<Float>? = nil) -> ReflectiveGenerator<Float> {
        float(in: Float(range.lowerBound) ... Float(range.upperBound), scaling: scaling)
    }
}

// MARK: - Unsigned integer generators

public extension ReflectiveGenerator {
    static func uint8(in range: ClosedRange<UInt8>? = nil, scaling: SizeScaling<UInt8>? = nil) -> ReflectiveGenerator<UInt8> {
        if let range {
            if let scaling {
                Gen.choose(in: range, scaling: scaling)
            } else {
                Gen.choose(in: range)
            }
        } else {
            Gen.choose(in: UInt8.min ... UInt8.max, scaling: scaling ?? UInt8.defaultScaling)
        }
    }

    /// Convenience overload accepting `ClosedRange<Int>` (e.g. `0...10`).
    static func uint8(in range: ClosedRange<Int>, scaling: SizeScaling<UInt8>? = nil) -> ReflectiveGenerator<UInt8> {
        guard let lower = UInt8(exactly: range.lowerBound),
              let upper = UInt8(exactly: range.upperBound)
        else { preconditionFailure("Range bounds must be non-negative and fit inside \(UInt8.self)") }
        return uint8(in: lower ... upper, scaling: scaling)
    }

    static func uint16(in range: ClosedRange<UInt16>? = nil, scaling: SizeScaling<UInt16>? = nil) -> ReflectiveGenerator<UInt16> {
        if let range {
            if let scaling {
                Gen.choose(in: range, scaling: scaling)
            } else {
                Gen.choose(in: range)
            }
        } else {
            Gen.choose(in: UInt16.min ... UInt16.max, scaling: scaling ?? UInt16.defaultScaling)
        }
    }

    /// Convenience overload accepting `ClosedRange<Int>` (e.g. `0...1000`).
    static func uint16(in range: ClosedRange<Int>, scaling: SizeScaling<UInt16>? = nil) -> ReflectiveGenerator<UInt16> {
        guard let lower = UInt16(exactly: range.lowerBound),
              let upper = UInt16(exactly: range.upperBound)
        else { preconditionFailure("Range bounds must be non-negative and fit inside \(UInt16.self)") }
        return uint16(in: lower ... upper, scaling: scaling)
    }

    static func uint32(in range: ClosedRange<UInt32>? = nil, scaling: SizeScaling<UInt32>? = nil) -> ReflectiveGenerator<UInt32> {
        if let range {
            if let scaling {
                Gen.choose(in: range, scaling: scaling)
            } else {
                Gen.choose(in: range)
            }
        } else {
            Gen.choose(in: UInt32.min ... UInt32.max, scaling: scaling ?? UInt32.defaultScaling)
        }
    }

    /// Convenience overload accepting `ClosedRange<Int>` (e.g. `0...100_000`).
    static func uint32(in range: ClosedRange<Int>, scaling: SizeScaling<UInt32>? = nil) -> ReflectiveGenerator<UInt32> {
        guard let lower = UInt32(exactly: range.lowerBound),
              let upper = UInt32(exactly: range.upperBound)
        else { preconditionFailure("Range bounds must be non-negative and fit inside \(UInt32.self)") }
        return uint32(in: lower ... upper, scaling: scaling)
    }

    static func uint64(in range: ClosedRange<UInt64>? = nil, scaling: SizeScaling<UInt64>? = nil) -> ReflectiveGenerator<UInt64> {
        if let range {
            if let scaling {
                Gen.choose(in: range, scaling: scaling)
            } else {
                Gen.choose(in: range)
            }
        } else {
            Gen.choose(in: UInt64.min ... UInt64.max, scaling: scaling ?? UInt64.defaultScaling)
        }
    }

    /// Convenience overload accepting `ClosedRange<Int>` (e.g. `0...10`).
    static func uint64(in range: ClosedRange<Int>, scaling: SizeScaling<UInt64>? = nil) -> ReflectiveGenerator<UInt64> {
        guard let lower = UInt64(exactly: range.lowerBound),
              let upper = UInt64(exactly: range.upperBound)
        else { preconditionFailure("Range bounds must be non-negative and fit inside \(UInt64.self)") }
        return uint64(in: lower ... upper, scaling: scaling)
    }

    static func uint(in range: ClosedRange<UInt>? = nil, scaling: SizeScaling<UInt>? = nil) -> ReflectiveGenerator<UInt> {
        if let range {
            if let scaling {
                Gen.choose(in: range, scaling: scaling)
            } else {
                Gen.choose(in: range)
            }
        } else {
            Gen.choose(in: UInt.min ... UInt.max, scaling: scaling ?? UInt.defaultScaling)
        }
    }

    /// Convenience overload accepting `ClosedRange<Int>` (e.g. `0...10`).
    static func uint(in range: ClosedRange<Int>, scaling: SizeScaling<UInt>? = nil) -> ReflectiveGenerator<UInt> {
        guard let lower = UInt(exactly: range.lowerBound),
              let upper = UInt(exactly: range.upperBound)
        else { preconditionFailure("Range bounds must be non-negative and fit inside \(UInt.self)") }
        return uint(in: lower ... upper, scaling: scaling)
    }
}

// MARK: - Signed integer generators

public extension ReflectiveGenerator {
    static func int8(in range: ClosedRange<Int8>? = nil, scaling: SizeScaling<Int8>? = nil) -> ReflectiveGenerator<Int8> {
        if let range {
            if let scaling {
                Gen.choose(in: range, scaling: scaling)
            } else {
                Gen.choose(in: range)
            }
        } else {
            Gen.choose(in: Int8.min ... Int8.max, scaling: scaling ?? Int8.defaultScaling)
        }
    }

    /// Convenience overload accepting `ClosedRange<Int>` (e.g. `-10...10`).
    static func int8(in range: ClosedRange<Int>, scaling: SizeScaling<Int8>? = nil) -> ReflectiveGenerator<Int8> {
        guard let lower = Int8(exactly: range.lowerBound),
              let upper = Int8(exactly: range.upperBound)
        else { preconditionFailure("Range bounds must fit inside \(Int8.self)") }
        return int8(in: lower ... upper, scaling: scaling)
    }

    static func int16(in range: ClosedRange<Int16>? = nil, scaling: SizeScaling<Int16>? = nil) -> ReflectiveGenerator<Int16> {
        if let range {
            if let scaling {
                Gen.choose(in: range, scaling: scaling)
            } else {
                Gen.choose(in: range)
            }
        } else {
            Gen.choose(in: Int16.min ... Int16.max, scaling: scaling ?? Int16.defaultScaling)
        }
    }

    /// Convenience overload accepting `ClosedRange<Int>` (e.g. `-1000...1000`).
    static func int16(in range: ClosedRange<Int>, scaling: SizeScaling<Int16>? = nil) -> ReflectiveGenerator<Int16> {
        guard let lower = Int16(exactly: range.lowerBound),
              let upper = Int16(exactly: range.upperBound)
        else { preconditionFailure("Range bounds must fit inside \(Int16.self)") }
        return int16(in: lower ... upper, scaling: scaling)
    }

    static func int32(in range: ClosedRange<Int32>? = nil, scaling: SizeScaling<Int32>? = nil) -> ReflectiveGenerator<Int32> {
        if let range {
            if let scaling {
                Gen.choose(in: range, scaling: scaling)
            } else {
                Gen.choose(in: range)
            }
        } else {
            Gen.choose(in: Int32.min ... Int32.max, scaling: scaling ?? Int32.defaultScaling)
        }
    }

    /// Convenience overload accepting `ClosedRange<Int>` (e.g. `-100_000...100_000`).
    static func int32(in range: ClosedRange<Int>, scaling: SizeScaling<Int32>? = nil) -> ReflectiveGenerator<Int32> {
        guard let lower = Int32(exactly: range.lowerBound),
              let upper = Int32(exactly: range.upperBound)
        else { preconditionFailure("Range bounds must fit inside \(Int32.self)") }
        return int32(in: lower ... upper, scaling: scaling)
    }

    static func int64(in range: ClosedRange<Int64>? = nil, scaling: SizeScaling<Int64>? = nil) -> ReflectiveGenerator<Int64> {
        if let range {
            if let scaling {
                Gen.choose(in: range, scaling: scaling)
            } else {
                Gen.choose(in: range)
            }
        } else {
            Gen.choose(in: Int64.min ... Int64.max, scaling: scaling ?? Int64.defaultScaling)
        }
    }

    /// Convenience overload accepting `ClosedRange<Int>` (e.g. `-10...10`).
    static func int64(in range: ClosedRange<Int>, scaling: SizeScaling<Int64>? = nil) -> ReflectiveGenerator<Int64> {
        int64(in: Int64(range.lowerBound) ... Int64(range.upperBound), scaling: scaling)
    }

    static func int(in range: ClosedRange<Int>? = nil, scaling: SizeScaling<Int>? = nil) -> ReflectiveGenerator<Int> {
        if let range {
            if let scaling {
                Gen.choose(in: range, scaling: scaling)
            } else {
                Gen.choose(in: range)
            }
        } else {
            Gen.choose(in: Int.min ... Int.max, scaling: scaling ?? Int.defaultScaling)
        }
    }
}
