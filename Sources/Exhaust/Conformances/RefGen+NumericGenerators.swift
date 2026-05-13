//
//  RefGen+NumericGenerators.swift
//  Exhaust
//

#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import ExhaustCore

// MARK: - Floating-point generators

#if arch(arm64) || arch(arm64_32)
    public extension RefGen {
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
        ) -> RefGen<Float16> {
            RefGen<Float16> {
                if let range {
                    return if let scaling {
                        Gen.choose(in: range, scaling: scaling)
                    } else if range == -Float16.greatestFiniteMagnitude ... Float16.greatestFiniteMagnitude {
                        Gen.choose(in: range, scaling: Float16.defaultScaling)
                    } else {
                        Gen.choose(in: range)
                    }
                }
                return Gen.choose(
                    in: nil as ClosedRange<Float16>?,
                    type: Float16.self,
                    isRangeExplicit: false,
                    scaling: (scaling ?? Float16.defaultScaling).erased
                )
            }
        }

        /// Generates arbitrary `Float16` values within the given range.
        static func float16(
            in range: ClosedRange<Double>,
            scaling: SizeScaling<Float16>? = nil
        ) -> RefGen<Float16> {
            float16(in: Float16(range.lowerBound) ... Float16(range.upperBound), scaling: scaling)
        }
    }
#endif

public extension RefGen {
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
    ) -> RefGen<Double> {
        RefGen<Double> {
            if let range {
                return if let scaling {
                    Gen.choose(in: range, scaling: scaling)
                } else if range == -Double.greatestFiniteMagnitude ... Double.greatestFiniteMagnitude {
                    Gen.choose(in: range, scaling: Double.defaultScaling)
                } else {
                    Gen.choose(in: range)
                }
            }
            return Gen.choose(
                in: nil as ClosedRange<Double>?,
                type: Double.self,
                isRangeExplicit: false,
                scaling: (scaling ?? Double.defaultScaling).erased
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
    ) -> RefGen<Float> {
        RefGen<Float> {
            if let range {
                return if let scaling {
                    Gen.choose(in: range, scaling: scaling)
                } else if range == -Float.greatestFiniteMagnitude ... Float.greatestFiniteMagnitude {
                    Gen.choose(in: range, scaling: Float.defaultScaling)
                } else {
                    Gen.choose(in: range)
                }
            }
            return Gen.choose(
                in: nil as ClosedRange<Float>?,
                type: Float.self,
                isRangeExplicit: false,
                scaling: (scaling ?? Float.defaultScaling).erased
            )
        }
    }

    /// Generates arbitrary `Float` values within the given range.
    static func float(
        in range: ClosedRange<Double>,
        scaling: SizeScaling<Float>? = nil
    ) -> RefGen<Float> {
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
        ) -> RefGen<CGFloat> {
            let doubleRange = range.map { Double($0.lowerBound) ... Double($0.upperBound) }
            return RefGen<Double>.double(in: doubleRange, scaling: scaling)
                .mapped(
                    forward: { CGFloat($0) },
                    backward: { Double($0) }
                )
        }

        /// Generates arbitrary `CGFloat` values within the given range.
        static func cgfloat(
            in range: ClosedRange<Double>,
            scaling: SizeScaling<Double>? = nil
        ) -> RefGen<CGFloat> {
            cgfloat(in: CGFloat(range.lowerBound) ... CGFloat(range.upperBound), scaling: scaling)
        }
    #endif
}

// MARK: - Unsigned integer generators

public extension RefGen {
    /// Generates arbitrary `UInt8` values within the given range.
    ///
    /// ```swift
    /// let gen = #gen(.uint8(in: 0...200))
    /// ```
    static func uint8(
        in range: ClosedRange<UInt8>? = nil,
        scaling: SizeScaling<UInt8>? = nil
    ) -> RefGen<UInt8> {
        RefGen<UInt8> {
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
    }

    /// Generates arbitrary values within the given range.
    static func uint8(
        in range: ClosedRange<Int>,
        scaling: SizeScaling<UInt8>? = nil
    ) -> RefGen<UInt8> {
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
    ) -> RefGen<UInt16> {
        RefGen<UInt16> {
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
    }

    /// Generates arbitrary values within the given range.
    static func uint16(
        in range: ClosedRange<Int>,
        scaling: SizeScaling<UInt16>? = nil
    ) -> RefGen<UInt16> {
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
    ) -> RefGen<UInt32> {
        RefGen<UInt32> {
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
    }

    /// Generates arbitrary values within the given range.
    static func uint32(
        in range: ClosedRange<Int>,
        scaling: SizeScaling<UInt32>? = nil
    ) -> RefGen<UInt32> {
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
    ) -> RefGen<UInt64> {
        RefGen<UInt64> {
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
    }

    /// Generates arbitrary values within the given range.
    static func uint64(
        in range: ClosedRange<Int>,
        scaling: SizeScaling<UInt64>? = nil
    ) -> RefGen<UInt64> {
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
    ) -> RefGen<UInt> {
        RefGen<UInt> {
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
    }

    /// Generates arbitrary values within the given range.
    static func uint(
        in range: ClosedRange<Int>,
        scaling: SizeScaling<UInt>? = nil
    ) -> RefGen<UInt> {
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

public extension RefGen {
    /// Generates arbitrary `Int8` values within the given range.
    ///
    /// ```swift
    /// let gen = #gen(.int8(in: -100...100))
    /// ```
    static func int8(
        in range: ClosedRange<Int8>? = nil,
        scaling: SizeScaling<Int8>? = nil
    ) -> RefGen<Int8> {
        RefGen<Int8> {
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
    }

    /// Generates arbitrary values within the given range.
    static func int8(
        in range: ClosedRange<Int>,
        scaling: SizeScaling<Int8>? = nil
    ) -> RefGen<Int8> {
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
    ) -> RefGen<Int16> {
        RefGen<Int16> {
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
    }

    /// Generates arbitrary values within the given range.
    static func int16(
        in range: ClosedRange<Int>,
        scaling: SizeScaling<Int16>? = nil
    ) -> RefGen<Int16> {
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
    ) -> RefGen<Int32> {
        RefGen<Int32> {
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
    }

    /// Generates arbitrary values within the given range.
    static func int32(
        in range: ClosedRange<Int>,
        scaling: SizeScaling<Int32>? = nil
    ) -> RefGen<Int32> {
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
    ) -> RefGen<Int64> {
        RefGen<Int64> {
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
    }

    /// Generates arbitrary values within the given range.
    static func int64(
        in range: ClosedRange<Int>,
        scaling: SizeScaling<Int64>? = nil
    ) -> RefGen<Int64> {
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
    ) -> RefGen<Int> {
        RefGen<Int> {
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
}
