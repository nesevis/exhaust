//
//  ReflectiveGenerator+NumericGenerators.swift
//  Exhaust
//
//  Created by Chris Kolbu on 22/2/2026.
//

#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import ExhaustCore

// MARK: - Floating-point generators

#if arch(arm64) || arch(arm64_32)
    public extension ReflectiveGenerator {
        /// Generates arbitrary `Float16` values within the given range.
        ///
        /// When no range is specified, generates across the full finite half-precision range with size scaling.
        ///
        /// ```swift
        /// let gen = #gen(.float16(in: Float16(-1.0)...Float16(1.0)))
        /// ```
        static func float16(
            in range: ClosedRange<Float16>? = nil,
            scaling: SizeScaling<Float16>? = nil
        ) -> ReflectiveGenerator<Float16> {
            if let range {
                if let scaling {
                    Gen.choose(in: range, scaling: scaling)
                } else if range == -Float16.greatestFiniteMagnitude ... Float16.greatestFiniteMagnitude {
                    Gen.choose(in: range, scaling: Float16.defaultScaling)
                } else {
                    Gen.choose(in: range)
                }
            } else {
                Gen.choose(
                    in: -Float16.greatestFiniteMagnitude
                        ... Float16.greatestFiniteMagnitude,
                    scaling: scaling ?? Float16.defaultScaling
                )
            }
        }
    }
#endif

public extension ReflectiveGenerator {
    /// Generates arbitrary `Double` values within the given range.
    ///
    /// When no range is specified, generates across the full finite double range with size scaling.
    ///
    /// ```swift
    /// let gen = #gen(.double(in: 0.0...1.0))
    /// ```
    static func double(
        in range: ClosedRange<Double>? = nil,
        scaling: SizeScaling<Double>? = nil
    ) -> ReflectiveGenerator<Double> {
        if let range {
            if let scaling {
                Gen.choose(in: range, scaling: scaling)
            } else if range == -Double.greatestFiniteMagnitude ... Double.greatestFiniteMagnitude {
                Gen.choose(in: range, scaling: Double.defaultScaling)
            } else {
                Gen.choose(in: range)
            }
        } else {
            Gen.choose(
                in: -Double.greatestFiniteMagnitude
                    ... Double.greatestFiniteMagnitude,
                scaling: scaling ?? Double.defaultScaling
            )
        }
    }

    /// Generates arbitrary `Float` values within the given range.
    ///
    /// When no range is specified, generates across the full finite float range with size scaling.
    ///
    /// ```swift
    /// let gen = #gen(.float(in: -1.0...1.0))
    /// ```
    static func float(
        in range: ClosedRange<Float>? = nil,
        scaling: SizeScaling<Float>? = nil
    ) -> ReflectiveGenerator<Float> {
        if let range {
            if let scaling {
                Gen.choose(in: range, scaling: scaling)
            } else if range == -Float.greatestFiniteMagnitude ... Float.greatestFiniteMagnitude {
                Gen.choose(in: range, scaling: Float.defaultScaling)
            } else {
                Gen.choose(in: range)
            }
        } else {
            Gen.choose(
                in: -Float.greatestFiniteMagnitude
                    ... Float.greatestFiniteMagnitude,
                scaling: scaling ?? Float.defaultScaling
            )
        }
    }

    /// Convenience overload accepting `ClosedRange<Double>` (for example `0.0...1.0`).
    static func float(
        in range: ClosedRange<Double>,
        scaling: SizeScaling<Float>? = nil
    ) -> ReflectiveGenerator<Float> {
        float(in: Float(range.lowerBound) ... Float(range.upperBound), scaling: scaling)
    }

    #if canImport(CoreGraphics)
        /// Generates arbitrary `CGFloat` values within the given range.
        ///
        /// Delegates to the `Double` generator — on 64-bit Apple platforms `CGFloat` is a typealias for `Double`.
        ///
        /// ```swift
        /// let gen = #gen(.cgfloat(in: 0.0...320.0))
        /// ```
        static func cgfloat(
            in range: ClosedRange<CGFloat>? = nil,
            scaling: SizeScaling<Double>? = nil
        ) -> ReflectiveGenerator<CGFloat> {
            let doubleRange = range.map { Double($0.lowerBound) ... Double($0.upperBound) }
            return ReflectiveGenerator<Double>.double(in: doubleRange, scaling: scaling)
                .mapped(
                    forward: { CGFloat($0) },
                    backward: { Double($0) }
                )
        }

        /// Convenience overload accepting `ClosedRange<Double>` (for example `0.0...320.0`).
        static func cgfloat(
            in range: ClosedRange<Double>,
            scaling: SizeScaling<Double>? = nil
        ) -> ReflectiveGenerator<CGFloat> {
            cgfloat(in: CGFloat(range.lowerBound) ... CGFloat(range.upperBound), scaling: scaling)
        }
    #endif
}

// MARK: - Unsigned integer generators

public extension ReflectiveGenerator {
    /// Generates arbitrary `UInt8` values within the given range.
    ///
    /// ```swift
    /// let gen = #gen(.uint8(in: 0...200))
    /// ```
    static func uint8(
        in range: ClosedRange<UInt8>? = nil,
        scaling: SizeScaling<UInt8>? = nil
    ) -> ReflectiveGenerator<UInt8> {
        if let range {
            if let scaling {
                Gen.choose(in: range, scaling: scaling)
            } else if range == UInt8.min ... UInt8.max {
                Gen.choose(in: range, scaling: UInt8.defaultScaling)
            } else {
                Gen.choose(in: range)
            }
        } else {
            Gen.choose(in: UInt8.min ... UInt8.max, scaling: scaling ?? UInt8.defaultScaling)
        }
    }

    /// Convenience overload accepting `ClosedRange<Int>` (for example `0...10`).
    static func uint8(
        in range: ClosedRange<Int>,
        scaling: SizeScaling<UInt8>? = nil
    ) -> ReflectiveGenerator<UInt8> {
        guard let lower = UInt8(exactly: range.lowerBound),
              let upper = UInt8(exactly: range.upperBound)
        else {
            preconditionFailure(
                "Range bounds must be non-negative and fit inside \(UInt8.self)"
            )
        }
        return uint8(in: lower ... upper, scaling: scaling)
    }

    /// Generates arbitrary `UInt16` values within the given range.
    ///
    /// ```swift
    /// let gen = #gen(.uint16(in: 0...1000))
    /// ```
    static func uint16(
        in range: ClosedRange<UInt16>? = nil,
        scaling: SizeScaling<UInt16>? = nil
    ) -> ReflectiveGenerator<UInt16> {
        if let range {
            if let scaling {
                Gen.choose(in: range, scaling: scaling)
            } else if range == UInt16.min ... UInt16.max {
                Gen.choose(in: range, scaling: UInt16.defaultScaling)
            } else {
                Gen.choose(in: range)
            }
        } else {
            Gen.choose(in: UInt16.min ... UInt16.max, scaling: scaling ?? UInt16.defaultScaling)
        }
    }

    /// Convenience overload accepting `ClosedRange<Int>` (for example `0...1000`).
    static func uint16(
        in range: ClosedRange<Int>,
        scaling: SizeScaling<UInt16>? = nil
    ) -> ReflectiveGenerator<UInt16> {
        guard let lower = UInt16(exactly: range.lowerBound),
              let upper = UInt16(exactly: range.upperBound)
        else {
            preconditionFailure(
                "Range bounds must be non-negative and fit inside \(UInt16.self)"
            )
        }
        return uint16(in: lower ... upper, scaling: scaling)
    }

    /// Generates arbitrary `UInt32` values within the given range.
    ///
    /// ```swift
    /// let gen = #gen(.uint32(in: 0...100_000))
    /// ```
    static func uint32(
        in range: ClosedRange<UInt32>? = nil,
        scaling: SizeScaling<UInt32>? = nil
    ) -> ReflectiveGenerator<UInt32> {
        if let range {
            if let scaling {
                Gen.choose(in: range, scaling: scaling)
            } else if range == UInt32.min ... UInt32.max {
                Gen.choose(in: range, scaling: UInt32.defaultScaling)
            } else {
                Gen.choose(in: range)
            }
        } else {
            Gen.choose(in: UInt32.min ... UInt32.max, scaling: scaling ?? UInt32.defaultScaling)
        }
    }

    /// Convenience overload accepting `ClosedRange<Int>` (for example `0...100_000`).
    static func uint32(
        in range: ClosedRange<Int>,
        scaling: SizeScaling<UInt32>? = nil
    ) -> ReflectiveGenerator<UInt32> {
        guard let lower = UInt32(exactly: range.lowerBound),
              let upper = UInt32(exactly: range.upperBound)
        else {
            preconditionFailure(
                "Range bounds must be non-negative and fit inside \(UInt32.self)"
            )
        }
        return uint32(in: lower ... upper, scaling: scaling)
    }

    /// Generates arbitrary `UInt64` values within the given range.
    ///
    /// ```swift
    /// let gen = #gen(.uint64(in: 0...1_000_000))
    /// ```
    static func uint64(
        in range: ClosedRange<UInt64>? = nil,
        scaling: SizeScaling<UInt64>? = nil
    ) -> ReflectiveGenerator<UInt64> {
        if let range {
            if let scaling {
                Gen.choose(in: range, scaling: scaling)
            } else if range == UInt64.min ... UInt64.max {
                Gen.choose(in: range, scaling: UInt64.defaultScaling)
            } else {
                Gen.choose(in: range)
            }
        } else {
            Gen.choose(in: UInt64.min ... UInt64.max, scaling: scaling ?? UInt64.defaultScaling)
        }
    }

    /// Convenience overload accepting `ClosedRange<Int>` (for example `0...10`).
    static func uint64(
        in range: ClosedRange<Int>,
        scaling: SizeScaling<UInt64>? = nil
    ) -> ReflectiveGenerator<UInt64> {
        guard let lower = UInt64(exactly: range.lowerBound),
              let upper = UInt64(exactly: range.upperBound)
        else {
            preconditionFailure(
                "Range bounds must be non-negative and fit inside \(UInt64.self)"
            )
        }
        return uint64(in: lower ... upper, scaling: scaling)
    }

    /// Generates arbitrary `UInt` values within the given range.
    ///
    /// ```swift
    /// let gen = #gen(.uint(in: 0...100))
    /// ```
    static func uint(
        in range: ClosedRange<UInt>? = nil,
        scaling: SizeScaling<UInt>? = nil
    ) -> ReflectiveGenerator<UInt> {
        if let range {
            if let scaling {
                Gen.choose(in: range, scaling: scaling)
            } else if range == UInt.min ... UInt.max {
                Gen.choose(in: range, scaling: UInt.defaultScaling)
            } else {
                Gen.choose(in: range)
            }
        } else {
            Gen.choose(in: UInt.min ... UInt.max, scaling: scaling ?? UInt.defaultScaling)
        }
    }

    /// Convenience overload accepting `ClosedRange<Int>` (for example `0...10`).
    static func uint(
        in range: ClosedRange<Int>,
        scaling: SizeScaling<UInt>? = nil
    ) -> ReflectiveGenerator<UInt> {
        guard let lower = UInt(exactly: range.lowerBound),
              let upper = UInt(exactly: range.upperBound)
        else {
            preconditionFailure(
                "Range bounds must be non-negative and fit inside \(UInt.self)"
            )
        }
        return uint(in: lower ... upper, scaling: scaling)
    }
}

// MARK: - Signed integer generators

public extension ReflectiveGenerator {
    /// Generates arbitrary `Int8` values within the given range.
    ///
    /// ```swift
    /// let gen = #gen(.int8(in: -100...100))
    /// ```
    static func int8(
        in range: ClosedRange<Int8>? = nil,
        scaling: SizeScaling<Int8>? = nil
    ) -> ReflectiveGenerator<Int8> {
        if let range {
            if let scaling {
                Gen.choose(in: range, scaling: scaling)
            } else if range == Int8.min ... Int8.max {
                Gen.choose(in: range, scaling: Int8.defaultScaling)
            } else {
                Gen.choose(in: range)
            }
        } else {
            Gen.choose(in: Int8.min ... Int8.max, scaling: scaling ?? Int8.defaultScaling)
        }
    }

    /// Convenience overload accepting `ClosedRange<Int>` (for example `-10...10`).
    static func int8(
        in range: ClosedRange<Int>,
        scaling: SizeScaling<Int8>? = nil
    ) -> ReflectiveGenerator<Int8> {
        guard let lower = Int8(exactly: range.lowerBound),
              let upper = Int8(exactly: range.upperBound)
        else { preconditionFailure("Range bounds must fit inside \(Int8.self)") }
        return int8(in: lower ... upper, scaling: scaling)
    }

    /// Generates arbitrary `Int16` values within the given range.
    ///
    /// ```swift
    /// let gen = #gen(.int16(in: -1000...1000))
    /// ```
    static func int16(
        in range: ClosedRange<Int16>? = nil,
        scaling: SizeScaling<Int16>? = nil
    ) -> ReflectiveGenerator<Int16> {
        if let range {
            if let scaling {
                Gen.choose(in: range, scaling: scaling)
            } else if range == Int16.min ... Int16.max {
                Gen.choose(in: range, scaling: Int16.defaultScaling)
            } else {
                Gen.choose(in: range)
            }
        } else {
            Gen.choose(in: Int16.min ... Int16.max, scaling: scaling ?? Int16.defaultScaling)
        }
    }

    /// Convenience overload accepting `ClosedRange<Int>` (for example `-1000...1000`).
    static func int16(
        in range: ClosedRange<Int>,
        scaling: SizeScaling<Int16>? = nil
    ) -> ReflectiveGenerator<Int16> {
        guard let lower = Int16(exactly: range.lowerBound),
              let upper = Int16(exactly: range.upperBound)
        else { preconditionFailure("Range bounds must fit inside \(Int16.self)") }
        return int16(in: lower ... upper, scaling: scaling)
    }

    /// Generates arbitrary `Int32` values within the given range.
    ///
    /// ```swift
    /// let gen = #gen(.int32(in: -100_000...100_000))
    /// ```
    static func int32(
        in range: ClosedRange<Int32>? = nil,
        scaling: SizeScaling<Int32>? = nil
    ) -> ReflectiveGenerator<Int32> {
        if let range {
            if let scaling {
                Gen.choose(in: range, scaling: scaling)
            } else if range == Int32.min ... Int32.max {
                Gen.choose(in: range, scaling: Int32.defaultScaling)
            } else {
                Gen.choose(in: range)
            }
        } else {
            Gen.choose(in: Int32.min ... Int32.max, scaling: scaling ?? Int32.defaultScaling)
        }
    }

    /// Convenience overload accepting `ClosedRange<Int>` (for example `-100_000...100_000`).
    static func int32(
        in range: ClosedRange<Int>,
        scaling: SizeScaling<Int32>? = nil
    ) -> ReflectiveGenerator<Int32> {
        guard let lower = Int32(exactly: range.lowerBound),
              let upper = Int32(exactly: range.upperBound)
        else { preconditionFailure("Range bounds must fit inside \(Int32.self)") }
        return int32(in: lower ... upper, scaling: scaling)
    }

    /// Generates arbitrary `Int64` values within the given range.
    ///
    /// ```swift
    /// let gen = #gen(.int64(in: -1_000_000...1_000_000))
    /// ```
    static func int64(
        in range: ClosedRange<Int64>? = nil,
        scaling: SizeScaling<Int64>? = nil
    ) -> ReflectiveGenerator<Int64> {
        if let range {
            if let scaling {
                Gen.choose(in: range, scaling: scaling)
            } else if range == Int64.min ... Int64.max {
                Gen.choose(in: range, scaling: Int64.defaultScaling)
            } else {
                Gen.choose(in: range)
            }
        } else {
            Gen.choose(in: Int64.min ... Int64.max, scaling: scaling ?? Int64.defaultScaling)
        }
    }

    /// Convenience overload accepting `ClosedRange<Int>` (for example `-10...10`).
    static func int64(
        in range: ClosedRange<Int>,
        scaling: SizeScaling<Int64>? = nil
    ) -> ReflectiveGenerator<Int64> {
        int64(in: Int64(range.lowerBound) ... Int64(range.upperBound), scaling: scaling)
    }

    /// Generates arbitrary `Int` values within the given range.
    ///
    /// ```swift
    /// let gen = #gen(.int(in: 0...100))
    /// ```
    static func int(
        in range: ClosedRange<Int>? = nil,
        scaling: SizeScaling<Int>? = nil
    ) -> ReflectiveGenerator<Int> {
        if let range {
            if let scaling {
                Gen.choose(in: range, scaling: scaling)
            } else if range == Int.min ... Int.max {
                Gen.choose(in: range, scaling: Int.defaultScaling)
            } else {
                Gen.choose(in: range)
            }
        } else {
            Gen.choose(in: Int.min ... Int.max, scaling: scaling ?? Int.defaultScaling)
        }
    }
}
