//
//  Generator+SIMD.swift
//  Exhaust
//

import ExhaustCore

// MARK: - SIMD2

package extension Generator {
    /// Generates arbitrary `SIMD2` vectors by generating each lane with the same scalar generator.
    ///
    /// ```swift
    /// let gen = #gen(.simd2(.float(in: 0...1)))
    /// ```
    static func simd2<Scalar: SIMDScalar>(
        _ scalar: Generator<Scalar>
    ) -> Generator<SIMD2<Scalar>> where Value == SIMD2<Scalar> {
        simd2(scalar, scalar)
    }

    /// Generates `SIMD2` vectors with a separate generator for each lane.
    ///
    /// ```swift
    /// let gen = #gen(.simd2(.float(in: 0...1), .float(in: -1...1)))
    /// ```
    static func simd2<Scalar: SIMDScalar>(
        _ x: Generator<Scalar>,
        _ y: Generator<Scalar>
    ) -> Generator<SIMD2<Scalar>> where Value == SIMD2<Scalar> {
        Gen.zip(x, y, isOpaque: true)._mapped(
            forward: { a, b in SIMD2(a, b) },
            backward: { v in (v[0], v[1]) }
        )
    }
}

// MARK: - SIMD3

package extension Generator {
    /// Generates arbitrary `SIMD3` vectors by generating each lane with the same scalar generator.
    ///
    /// ```swift
    /// let gen = #gen(.simd3(.double(in: -1...1)))
    /// ```
    static func simd3<Scalar: SIMDScalar>(
        _ scalar: Generator<Scalar>
    ) -> Generator<SIMD3<Scalar>> where Value == SIMD3<Scalar> {
        simd3(scalar, scalar, scalar)
    }

    /// Generates `SIMD3` vectors with a separate generator for each lane.
    ///
    /// ```swift
    /// let gen = #gen(.simd3(
    ///     .float(in: 0...1), .float(in: 0...1), .float(in: -1...0)
    /// ))
    /// ```
    static func simd3<Scalar: SIMDScalar>(
        _ x: Generator<Scalar>,
        _ y: Generator<Scalar>,
        _ z: Generator<Scalar>
    ) -> Generator<SIMD3<Scalar>> where Value == SIMD3<Scalar> {
        Gen.zip(x, y, z, isOpaque: true)._mapped(
            forward: { a, b, c in SIMD3(a, b, c) },
            backward: { v in (v[0], v[1], v[2]) }
        )
    }
}

// MARK: - SIMD4

package extension Generator {
    /// Generates arbitrary `SIMD4` vectors by generating each lane with the same scalar generator.
    ///
    /// ```swift
    /// let gen = #gen(.simd4(.float(in: 0...1)))
    /// ```
    static func simd4<Scalar: SIMDScalar>(
        _ scalar: Generator<Scalar>
    ) -> Generator<SIMD4<Scalar>> where Value == SIMD4<Scalar> {
        simd4(scalar, scalar, scalar, scalar)
    }

    /// Generates `SIMD4` vectors with a separate generator for each lane.
    ///
    /// ```swift
    /// let gen = #gen(.simd4(
    ///     .float(in: 0...1), .float(in: 0...1),
    ///     .float(in: 0...1), .float(in: 0...1)
    /// ))
    /// ```
    static func simd4<Scalar: SIMDScalar>(
        _ x: Generator<Scalar>,
        _ y: Generator<Scalar>,
        _ z: Generator<Scalar>,
        _ w: Generator<Scalar>
    ) -> Generator<SIMD4<Scalar>> where Value == SIMD4<Scalar> {
        Gen.zip(x, y, z, w, isOpaque: true)._mapped(
            forward: { a, b, c, d in SIMD4(a, b, c, d) },
            backward: { v in (v[0], v[1], v[2], v[3]) }
        )
    }
}

// MARK: - SIMD8

package extension Generator {
    /// Generates arbitrary `SIMD8` vectors by generating each lane with the same scalar generator.
    ///
    /// Each lane reduces independently.
    ///
    /// ```swift
    /// let gen = #gen(.simd8(.int32(in: 0...255)))
    /// ```
    static func simd8<Scalar: SIMDScalar>(
        _ scalar: Generator<Scalar>
    ) -> Generator<SIMD8<Scalar>> where Value == SIMD8<Scalar> {
        flatSIMD(scalar, lanes: 8)
    }
}

// MARK: - SIMD16

package extension Generator {
    /// Generates arbitrary `SIMD16` vectors by generating each lane with the same scalar generator.
    ///
    /// Each lane reduces independently.
    ///
    /// ```swift
    /// let gen = #gen(.simd16(.uint8()))
    /// ```
    static func simd16<Scalar: SIMDScalar>(
        _ scalar: Generator<Scalar>
    ) -> Generator<SIMD16<Scalar>> where Value == SIMD16<Scalar> {
        flatSIMD(scalar, lanes: 16)
    }
}

// MARK: - SIMD32

package extension Generator {
    /// Generates arbitrary `SIMD32` vectors by generating each lane with the same scalar generator.
    ///
    /// Each lane reduces independently.
    ///
    /// ```swift
    /// let gen = #gen(.simd32(.uint8()))
    /// ```
    static func simd32<Scalar: SIMDScalar>(
        _ scalar: Generator<Scalar>
    ) -> Generator<SIMD32<Scalar>> where Value == SIMD32<Scalar> {
        flatSIMD(scalar, lanes: 32)
    }
}

// MARK: - SIMD64

package extension Generator {
    /// Generates arbitrary `SIMD64` vectors by generating each lane with the same scalar generator.
    ///
    /// Each lane reduces independently.
    ///
    /// ```swift
    /// let gen = #gen(.simd64(.uint8()))
    /// ```
    static func simd64<Scalar: SIMDScalar>(
        _ scalar: Generator<Scalar>
    ) -> Generator<SIMD64<Scalar>> where Value == SIMD64<Scalar> {
        flatSIMD(scalar, lanes: 64)
    }
}

// MARK: - Private helpers

/// Builds a flat opaque zip of `lanes` copies of a scalar generator, then maps the result into a SIMD vector. A single flat group avoids the nested-group reflection issues that half-based recursive composition would cause.
private func flatSIMD<Scalar: SIMDScalar, Vector: SIMD>(
    _ s: Generator<Scalar>,
    lanes: Int
) -> Generator<Vector> where Vector.Scalar == Scalar {
    var erased = ContiguousArray<AnyGenerator>()
    erased.reserveCapacity(lanes)
    for _ in 0 ..< lanes {
        erased.append(s.erase())
    }

    let impure: Generator<[Any]> = .impure(
        operation: .zip(erased, isOpaque: true),
        continuation: { .pure($0 as! [Any]) }
    )

    return Gen.contramap(
        { (vector: Vector) -> [Any] in
            var values: [Any] = []
            values.reserveCapacity(lanes)
            for i in 0 ..< lanes {
                values.append(vector[i])
            }
            return values
        },
        impure._map { (values: [Any]) -> Vector in
            var v = Vector()
            for i in 0 ..< lanes {
                v[i] = values[i] as! Scalar
            }
            return v
        }
    )
}
