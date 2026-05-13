//
//  RefGen+SIMD.swift
//  Exhaust
//

import ExhaustCore

// MARK: - SIMD2

public extension RefGen {
    /// Generates arbitrary `SIMD2` vectors by generating each lane with the same scalar generator.
    ///
    /// ```swift
    /// let gen = #gen(.simd2(.float(in: 0...1)))
    /// ```
    static func simd2<Scalar: SIMDScalar>(
        _ scalar: RefGen<Scalar>
    ) -> RefGen<SIMD2<Scalar>> where Output == SIMD2<Scalar> {
        simd2(scalar, scalar)
    }

    /// Generates `SIMD2` vectors with a separate generator for each lane.
    ///
    /// ```swift
    /// let gen = #gen(.simd2(.float(in: 0...1), .float(in: -1...1)))
    /// ```
    static func simd2<Scalar: SIMDScalar>(
        _ x: RefGen<Scalar>,
        _ y: RefGen<Scalar>
    ) -> RefGen<SIMD2<Scalar>> where Output == SIMD2<Scalar> {
        RefGen {
            Gen.contramap(
                { (v: SIMD2<Scalar>) in (v[0], v[1]) },
                Gen.zip(x.gen, y.gen, isOpaque: true)._map { a, b in SIMD2(a, b) }
            )
        }
    }
}

// MARK: - SIMD3

public extension RefGen {
    /// Generates arbitrary `SIMD3` vectors by generating each lane with the same scalar generator.
    ///
    /// ```swift
    /// let gen = #gen(.simd3(.double(in: -1...1)))
    /// ```
    static func simd3<Scalar: SIMDScalar>(
        _ scalar: RefGen<Scalar>
    ) -> RefGen<SIMD3<Scalar>> where Output == SIMD3<Scalar> {
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
        _ x: RefGen<Scalar>,
        _ y: RefGen<Scalar>,
        _ z: RefGen<Scalar>
    ) -> RefGen<SIMD3<Scalar>> where Output == SIMD3<Scalar> {
        RefGen {
            Gen.contramap(
                { (v: SIMD3<Scalar>) in (v[0], v[1], v[2]) },
                Gen.zip(x.gen, y.gen, z.gen, isOpaque: true)._map { a, b, c in SIMD3(a, b, c) }
            )
        }
    }
}

// MARK: - SIMD4

public extension RefGen {
    /// Generates arbitrary `SIMD4` vectors by generating each lane with the same scalar generator.
    ///
    /// ```swift
    /// let gen = #gen(.simd4(.float(in: 0...1)))
    /// ```
    static func simd4<Scalar: SIMDScalar>(
        _ scalar: RefGen<Scalar>
    ) -> RefGen<SIMD4<Scalar>> where Output == SIMD4<Scalar> {
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
        _ x: RefGen<Scalar>,
        _ y: RefGen<Scalar>,
        _ z: RefGen<Scalar>,
        _ w: RefGen<Scalar>
    ) -> RefGen<SIMD4<Scalar>> where Output == SIMD4<Scalar> {
        RefGen {
            Gen.contramap(
                { (v: SIMD4<Scalar>) in (v[0], v[1], v[2], v[3]) },
                Gen.zip(x.gen, y.gen, z.gen, w.gen, isOpaque: true)._map { a, b, c, d in SIMD4(a, b, c, d) }
            )
        }
    }
}

// MARK: - SIMD8

public extension RefGen {
    /// Generates arbitrary `SIMD8` vectors by generating each lane with the same scalar generator.
    ///
    /// Each lane reduces independently.
    ///
    /// ```swift
    /// let gen = #gen(.simd8(.int32(in: 0...255)))
    /// ```
    static func simd8<Scalar: SIMDScalar>(
        _ scalar: RefGen<Scalar>
    ) -> RefGen<SIMD8<Scalar>> where Output == SIMD8<Scalar> {
        refGenFlatSIMD(scalar, lanes: 8)
    }
}

// MARK: - SIMD16

public extension RefGen {
    /// Generates arbitrary `SIMD16` vectors by generating each lane with the same scalar generator.
    ///
    /// Each lane reduces independently.
    ///
    /// ```swift
    /// let gen = #gen(.simd16(.uint8()))
    /// ```
    static func simd16<Scalar: SIMDScalar>(
        _ scalar: RefGen<Scalar>
    ) -> RefGen<SIMD16<Scalar>> where Output == SIMD16<Scalar> {
        refGenFlatSIMD(scalar, lanes: 16)
    }
}

// MARK: - SIMD32

public extension RefGen {
    /// Generates arbitrary `SIMD32` vectors by generating each lane with the same scalar generator.
    ///
    /// Each lane reduces independently.
    ///
    /// ```swift
    /// let gen = #gen(.simd32(.uint8()))
    /// ```
    static func simd32<Scalar: SIMDScalar>(
        _ scalar: RefGen<Scalar>
    ) -> RefGen<SIMD32<Scalar>> where Output == SIMD32<Scalar> {
        refGenFlatSIMD(scalar, lanes: 32)
    }
}

// MARK: - SIMD64

public extension RefGen {
    /// Generates arbitrary `SIMD64` vectors by generating each lane with the same scalar generator.
    ///
    /// Each lane reduces independently.
    ///
    /// ```swift
    /// let gen = #gen(.simd64(.uint8()))
    /// ```
    static func simd64<Scalar: SIMDScalar>(
        _ scalar: RefGen<Scalar>
    ) -> RefGen<SIMD64<Scalar>> where Output == SIMD64<Scalar> {
        refGenFlatSIMD(scalar, lanes: 64)
    }
}

// MARK: - Private helpers

/// Builds a flat opaque zip of `lanes` copies of a scalar generator, then maps the result into a SIMD vector. A single flat group avoids the nested-group reflection issues that half-based recursive composition would cause.
private func refGenFlatSIMD<Scalar: SIMDScalar, Vector: SIMD>(
    _ s: RefGen<Scalar>,
    lanes: Int
) -> RefGen<Vector> where Vector.Scalar == Scalar {
    RefGen<Vector> {
        var erased = ContiguousArray<ReflectiveGenerator<Any>>()
        erased.reserveCapacity(lanes)
        for _ in 0 ..< lanes {
            erased.append(s.gen.erase())
        }

        let impure: ReflectiveGenerator<[Any]> = .impure(
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
}
