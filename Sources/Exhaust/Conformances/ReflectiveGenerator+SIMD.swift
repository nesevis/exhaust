//
//  ReflectiveGenerator+SIMD.swift
//  Exhaust
//

import ExhaustCore

// MARK: - SIMD2

public extension ReflectiveGenerator {
    /// Generates arbitrary `SIMD2` vectors by generating each lane with the same scalar generator.
    ///
    /// ```swift
    /// let gen = #gen(.simd2(.float(in: 0...1)))
    /// ```
    static func simd2<Scalar: SIMDScalar>(
        _ scalar: ReflectiveGenerator<Scalar>
    ) -> ReflectiveGenerator<SIMD2<Scalar>> where Output == SIMD2<Scalar> {
        simd2(scalar, scalar)
    }

    /// Generates `SIMD2` vectors with a separate generator for each lane.
    ///
    /// ```swift
    /// let gen = #gen(.simd2(.float(in: 0...1), .float(in: -1...1)))
    /// ```
    static func simd2<Scalar: SIMDScalar>(
        _ x: ReflectiveGenerator<Scalar>,
        _ y: ReflectiveGenerator<Scalar>
    ) -> ReflectiveGenerator<SIMD2<Scalar>> where Output == SIMD2<Scalar> {
        ReflectiveGenerator {
            Gen.contramap(
                { (v: SIMD2<Scalar>) in (v[0], v[1]) },
                Gen.zip(x.gen, y.gen, isOpaque: true).map { a, b in SIMD2(a, b) }
            )
        }
    }
}

// MARK: - SIMD3

public extension ReflectiveGenerator {
    /// Generates arbitrary `SIMD3` vectors by generating each lane with the same scalar generator.
    ///
    /// ```swift
    /// let gen = #gen(.simd3(.double(in: -1...1)))
    /// ```
    static func simd3<Scalar: SIMDScalar>(
        _ scalar: ReflectiveGenerator<Scalar>
    ) -> ReflectiveGenerator<SIMD3<Scalar>> where Output == SIMD3<Scalar> {
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
        _ x: ReflectiveGenerator<Scalar>,
        _ y: ReflectiveGenerator<Scalar>,
        _ z: ReflectiveGenerator<Scalar>
    ) -> ReflectiveGenerator<SIMD3<Scalar>> where Output == SIMD3<Scalar> {
        ReflectiveGenerator {
            Gen.contramap(
                { (v: SIMD3<Scalar>) in (v[0], v[1], v[2]) },
                Gen.zip(x.gen, y.gen, z.gen, isOpaque: true).map { a, b, c in SIMD3(a, b, c) }
            )
        }
    }
}

// MARK: - SIMD4

public extension ReflectiveGenerator {
    /// Generates arbitrary `SIMD4` vectors by generating each lane with the same scalar generator.
    ///
    /// ```swift
    /// let gen = #gen(.simd4(.float(in: 0...1)))
    /// ```
    static func simd4<Scalar: SIMDScalar>(
        _ scalar: ReflectiveGenerator<Scalar>
    ) -> ReflectiveGenerator<SIMD4<Scalar>> where Output == SIMD4<Scalar> {
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
        _ x: ReflectiveGenerator<Scalar>,
        _ y: ReflectiveGenerator<Scalar>,
        _ z: ReflectiveGenerator<Scalar>,
        _ w: ReflectiveGenerator<Scalar>
    ) -> ReflectiveGenerator<SIMD4<Scalar>> where Output == SIMD4<Scalar> {
        ReflectiveGenerator {
            Gen.contramap(
                { (v: SIMD4<Scalar>) in (v[0], v[1], v[2], v[3]) },
                Gen.zip(x.gen, y.gen, z.gen, w.gen, isOpaque: true).map { a, b, c, d in SIMD4(a, b, c, d) }
            )
        }
    }
}

// MARK: - SIMD8

public extension ReflectiveGenerator {
    /// Generates arbitrary `SIMD8` vectors by generating each lane with the same scalar generator.
    ///
    /// Each lane reduces independently.
    ///
    /// ```swift
    /// let gen = #gen(.simd8(.int32(in: 0...255)))
    /// ```
    static func simd8<Scalar: SIMDScalar>(
        _ scalar: ReflectiveGenerator<Scalar>
    ) -> ReflectiveGenerator<SIMD8<Scalar>> where Output == SIMD8<Scalar> {
        refGenFlatSIMD(scalar, lanes: 8)
    }
}

// MARK: - SIMD16

public extension ReflectiveGenerator {
    /// Generates arbitrary `SIMD16` vectors by generating each lane with the same scalar generator.
    ///
    /// Each lane reduces independently.
    ///
    /// ```swift
    /// let gen = #gen(.simd16(.uint8()))
    /// ```
    static func simd16<Scalar: SIMDScalar>(
        _ scalar: ReflectiveGenerator<Scalar>
    ) -> ReflectiveGenerator<SIMD16<Scalar>> where Output == SIMD16<Scalar> {
        refGenFlatSIMD(scalar, lanes: 16)
    }
}

// MARK: - SIMD32

public extension ReflectiveGenerator {
    /// Generates arbitrary `SIMD32` vectors by generating each lane with the same scalar generator.
    ///
    /// Each lane reduces independently.
    ///
    /// ```swift
    /// let gen = #gen(.simd32(.uint8()))
    /// ```
    static func simd32<Scalar: SIMDScalar>(
        _ scalar: ReflectiveGenerator<Scalar>
    ) -> ReflectiveGenerator<SIMD32<Scalar>> where Output == SIMD32<Scalar> {
        refGenFlatSIMD(scalar, lanes: 32)
    }
}

// MARK: - SIMD64

public extension ReflectiveGenerator {
    /// Generates arbitrary `SIMD64` vectors by generating each lane with the same scalar generator.
    ///
    /// Each lane reduces independently.
    ///
    /// ```swift
    /// let gen = #gen(.simd64(.uint8()))
    /// ```
    static func simd64<Scalar: SIMDScalar>(
        _ scalar: ReflectiveGenerator<Scalar>
    ) -> ReflectiveGenerator<SIMD64<Scalar>> where Output == SIMD64<Scalar> {
        refGenFlatSIMD(scalar, lanes: 64)
    }
}

// MARK: - Private helpers

/// Builds a flat opaque zip of `lanes` copies of a scalar generator, then maps the result into a SIMD vector. A single flat group avoids the nested-group reflection issues that half-based recursive composition would cause.
private func refGenFlatSIMD<Scalar: SIMDScalar, Vector: SIMD>(
    _ s: ReflectiveGenerator<Scalar>,
    lanes: Int
) -> ReflectiveGenerator<Vector> where Vector.Scalar == Scalar {
    ReflectiveGenerator<Vector> {
        var erased = ContiguousArray<AnyGenerator>()
        erased.reserveCapacity(lanes)
        for _ in 0 ..< lanes {
            erased.append(s.gen.erase())
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
            impure.map { (values: [Any]) -> Vector in
                var v = Vector()
                for i in 0 ..< lanes {
                    v[i] = values[i] as! Scalar
                }
                return v
            }
        )
    }
}
