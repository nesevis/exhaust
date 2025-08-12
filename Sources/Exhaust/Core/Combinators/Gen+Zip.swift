//
//  Gen+Zip.swift
//  Exhaust
//
//  Created by Chris Kolbu on 21/7/2025.
//

extension Gen {
    @inlinable
    public static func zip<A, B>(
        _ a: ReflectiveGenerator<A>,
        _ b: ReflectiveGenerator<B>
    ) -> ReflectiveGenerator<(A, B)> {
        // TODO: These extensions are good candidates for InlineArrays with declared sizes
        let impure: ReflectiveGenerator<[Any]> = .impure(
            operation: .zip([a.erase(), b.erase()]),
            continuation: { .pure($0 as! [Any]) }
        )

        return impure.mapped(
            forward: { ($0[0] as! A, $0[1] as! B) },
            backward: { [$0.0, $0.1] }
        )
    }
    
    @inlinable
    public static func zip<A, B, C>(
        _ a: ReflectiveGenerator<A>,
        _ b: ReflectiveGenerator<B>,
        _ c: ReflectiveGenerator<C>
    ) -> ReflectiveGenerator<(A, B, C)> {
        let impure: ReflectiveGenerator<[Any]> = .impure(
            operation: .zip([a.erase(), b.erase(), c.erase()]),
            continuation: { .pure($0 as! [Any]) }
        )

        return impure.mapped(
            forward: { ($0[0] as! A, $0[1] as! B, $0[2] as! C) },
            backward: { [$0.0, $0.1, $0.2] }
        )
    }
    
    @inlinable
    public static func zip<A, B, C, D>(
        _ a: ReflectiveGenerator<A>,
        _ b: ReflectiveGenerator<B>,
        _ c: ReflectiveGenerator<C>,
        _ d: ReflectiveGenerator<D>
    ) -> ReflectiveGenerator<(A, B, C, D)> {
        let impure: ReflectiveGenerator<[Any]> = .impure(
            operation: .zip([a.erase(), b.erase(), c.erase(), d.erase()]),
            continuation: { .pure($0 as! [Any]) }
        )

        return impure.mapped(
            forward: { ($0[0] as! A, $0[1] as! B, $0[2] as! C, $0[3] as! D) },
            backward: { [$0.0, $0.1, $0.2, $0.3] }
        )
    }
    
    @inlinable
    public static func zip<A, B, C, D, E>(
        _ a: ReflectiveGenerator<A>,
        _ b: ReflectiveGenerator<B>,
        _ c: ReflectiveGenerator<C>,
        _ d: ReflectiveGenerator<D>,
        _ e: ReflectiveGenerator<E>
    ) -> ReflectiveGenerator<(A, B, C, D, E)> {
        let impure: ReflectiveGenerator<[Any]> = .impure(
            operation: .zip([a.erase(), b.erase(), c.erase(), d.erase(), e.erase()]),
            continuation: { .pure($0 as! [Any]) }
        )

        return impure.mapped(
            forward: { ($0[0] as! A, $0[1] as! B, $0[2] as! C, $0[3] as! D, $0[4] as! E) },
            backward: { [$0.0, $0.1, $0.2, $0.3, $0.4] }
        )
    }
    
    @inlinable
    public static func zip<A, B, C, D, E, F>(
        _ a: ReflectiveGenerator<A>,
        _ b: ReflectiveGenerator<B>,
        _ c: ReflectiveGenerator<C>,
        _ d: ReflectiveGenerator<D>,
        _ e: ReflectiveGenerator<E>,
        _ f: ReflectiveGenerator<F>
    ) -> ReflectiveGenerator<(A, B, C, D, E, F)> {
        let impure: ReflectiveGenerator<[Any]> = .impure(
            operation: .zip([a.erase(), b.erase(), c.erase(), d.erase(), e.erase(), f.erase()]),
            continuation: { .pure($0 as! [Any]) }
        )

        return impure.mapped(
            forward: { ($0[0] as! A, $0[1] as! B, $0[2] as! C, $0[3] as! D, $0[4] as! E, $0[5] as! F) },
            backward: { [$0.0, $0.1, $0.2, $0.3, $0.4, $0.5] }
        )
    }
    
    @inlinable
    public static func zip<A, B, C, D, E, F, G>(
        _ a: ReflectiveGenerator<A>,
        _ b: ReflectiveGenerator<B>,
        _ c: ReflectiveGenerator<C>,
        _ d: ReflectiveGenerator<D>,
        _ e: ReflectiveGenerator<E>,
        _ f: ReflectiveGenerator<F>,
        _ g: ReflectiveGenerator<G>
    ) -> ReflectiveGenerator<(A, B, C, D, E, F, G)> {
        let impure: ReflectiveGenerator<[Any]> = .impure(
            operation: .zip([a.erase(), b.erase(), c.erase(), d.erase(), e.erase(), f.erase(), g.erase()]),
            continuation: { .pure($0 as! [Any]) }
        )

        return impure.mapped(
            forward: { ($0[0] as! A, $0[1] as! B, $0[2] as! C, $0[3] as! D, $0[4] as! E, $0[5] as! F, $0[6] as! G) },
            backward: { [$0.0, $0.1, $0.2, $0.3, $0.4, $0.5, $0.6] }
        )
    }
    
    @inlinable
    public static func zip<A, B, C, D, E, F, G, H>(
        _ a: ReflectiveGenerator<A>,
        _ b: ReflectiveGenerator<B>,
        _ c: ReflectiveGenerator<C>,
        _ d: ReflectiveGenerator<D>,
        _ e: ReflectiveGenerator<E>,
        _ f: ReflectiveGenerator<F>,
        _ g: ReflectiveGenerator<G>,
        _ h: ReflectiveGenerator<H>
    ) -> ReflectiveGenerator<(A, B, C, D, E, F, G, H)> {
        let impure: ReflectiveGenerator<[Any]> = .impure(
            operation: .zip([a.erase(), b.erase(), c.erase(), d.erase(), e.erase(), f.erase(), g.erase(), h.erase()]),
            continuation: { .pure($0 as! [Any]) }
        )

        return impure.mapped(
            forward: { ($0[0] as! A, $0[1] as! B, $0[2] as! C, $0[3] as! D, $0[4] as! E, $0[5] as! F, $0[6] as! G, $0[7] as! H) },
            backward: { [$0.0, $0.1, $0.2, $0.3, $0.4, $0.5, $0.6, $0.7] }
        )
    }
    
    @inlinable
    public static func zip<A, B, C, D, E, F, G, H, I>(
        _ a: ReflectiveGenerator<A>,
        _ b: ReflectiveGenerator<B>,
        _ c: ReflectiveGenerator<C>,
        _ d: ReflectiveGenerator<D>,
        _ e: ReflectiveGenerator<E>,
        _ f: ReflectiveGenerator<F>,
        _ g: ReflectiveGenerator<G>,
        _ h: ReflectiveGenerator<H>,
        _ i: ReflectiveGenerator<I>
    ) -> ReflectiveGenerator<(A, B, C, D, E, F, G, H, I)> {
        let impure: ReflectiveGenerator<[Any]> = .impure(
            operation: .zip([a.erase(), b.erase(), c.erase(), d.erase(), e.erase(), f.erase(), g.erase(), h.erase(), i.erase()]),
            continuation: { .pure($0 as! [Any]) }
        )

        return impure.mapped(
            forward: { ($0[0] as! A, $0[1] as! B, $0[2] as! C, $0[3] as! D, $0[4] as! E, $0[5] as! F, $0[6] as! G, $0[7] as! H, $0[8] as! I) },
            backward: { [$0.0, $0.1, $0.2, $0.3, $0.4, $0.5, $0.6, $0.7, $0.8] }
        )
    }
    
    @inlinable
    public static func zip<A, B, C, D, E, F, G, H, I, J>(
        _ a: ReflectiveGenerator<A>,
        _ b: ReflectiveGenerator<B>,
        _ c: ReflectiveGenerator<C>,
        _ d: ReflectiveGenerator<D>,
        _ e: ReflectiveGenerator<E>,
        _ f: ReflectiveGenerator<F>,
        _ g: ReflectiveGenerator<G>,
        _ h: ReflectiveGenerator<H>,
        _ i: ReflectiveGenerator<I>,
        _ j: ReflectiveGenerator<J>
    ) -> ReflectiveGenerator<(A, B, C, D, E, F, G, H, I, J)> {
        let impure: ReflectiveGenerator<[Any]> = .impure(
            operation: .zip([a.erase(), b.erase(), c.erase(), d.erase(), e.erase(), f.erase(), g.erase(), h.erase(), i.erase(), j.erase()]),
            continuation: { .pure($0 as! [Any]) }
        )

        return impure.mapped(
            forward: { ($0[0] as! A, $0[1] as! B, $0[2] as! C, $0[3] as! D, $0[4] as! E, $0[5] as! F, $0[6] as! G, $0[7] as! H, $0[8] as! I, $0[9] as! J) },
            backward: { [$0.0, $0.1, $0.2, $0.3, $0.4, $0.5, $0.6, $0.7, $0.8, $0.9] }
        )
    }
}
