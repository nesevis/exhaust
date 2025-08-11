//
//  Gen+Zip.swift
//  Exhaust
//
//  Created by Chris Kolbu on 21/7/2025.
//

extension Gen {
    // Zip wraps plain generators in a lens to help them extract from the tuple that is returned when reflecting. If the generator is already a lens, the assumption is that the user is then mapping over the tuple to transform it into something else again.
    public static func zip<A, B>(
        _ a: ReflectiveGenerator<A>,
        _ b: ReflectiveGenerator<B>
    ) -> ReflectiveGenerator<(A, B)> {
        typealias Tuple = (A, B)
        return Gen.lens(extract: \Tuple.0, a).bind { a in
            b.mapped(forward: { b in (a, b) }, backward: \.1)
        }
    }
    
    public static func flatZip<A, B>(
        _ a: ReflectiveGenerator<A>,
        _ b: ReflectiveGenerator<B>
    ) -> ReflectiveGenerator<(A, B)> {
        let impure: ReflectiveGenerator<[Any]> = .impure(
            operation: .zip([a.erase(), b.erase()]),
            continuation: { .pure($0 as! [Any]) }
        )

        // Both these work
        return impure.mapped(
            forward: { ($0[0] as! A, $0[1] as! B) },
            backward: { [$0.0, $0.1] }
        )
    }
    
    public static func zip<A, B, C>(
        _ a: ReflectiveGenerator<A>,
        _ b: ReflectiveGenerator<B>,
        _ c: ReflectiveGenerator<C>
    ) -> ReflectiveGenerator<(A, B, C)> {
        typealias Tuple = (A, B, C)
        return Gen.lens(extract: \Tuple.0, a).bind { a in
            Gen.lens(extract: \Tuple.1, b).bind { b in
                c.mapped(forward: { c in (a, b, c) }, backward: \.2)
            }
        }
    }
    
    public static func zip<A, B, C, D>(
        _ a: ReflectiveGenerator<A>,
        _ b: ReflectiveGenerator<B>,
        _ c: ReflectiveGenerator<C>,
        _ d: ReflectiveGenerator<D>
    ) -> ReflectiveGenerator<(A, B, C, D)> {
        typealias Tuple = (A, B, C, D)
        return Gen.lens(extract: \Tuple.0, a).bind { a in
            Gen.lens(extract: \Tuple.1, b).bind { b in
                Gen.lens(extract: \Tuple.2, c).bind { c in
                    d.mapped(forward: { d in (a, b, c, d) }, backward: \.3)
                }
            }
        }
    }
    
    public static func zip<A, B, C, D, E>(
        _ a: ReflectiveGenerator<A>,
        _ b: ReflectiveGenerator<B>,
        _ c: ReflectiveGenerator<C>,
        _ d: ReflectiveGenerator<D>,
        _ e: ReflectiveGenerator<E>
    ) -> ReflectiveGenerator<(A, B, C, D, E)> {
        typealias Tuple = (A, B, C, D, E)
        return Gen.lens(extract: \Tuple.0, a).bind { a in
            Gen.lens(extract: \Tuple.1, b).bind { b in
                Gen.lens(extract: \Tuple.2, c).bind { c in
                    Gen.lens(extract: \Tuple.3, d).bind { d in
                        e.mapped(forward: { e in (a, b, c, d, e) }, backward: \.4)
                    }
                }
            }
        }
    }
    
    public static func zip<A, B, C, D, E, F>(
        _ a: ReflectiveGenerator<A>,
        _ b: ReflectiveGenerator<B>,
        _ c: ReflectiveGenerator<C>,
        _ d: ReflectiveGenerator<D>,
        _ e: ReflectiveGenerator<E>,
        _ f: ReflectiveGenerator<F>
    ) -> ReflectiveGenerator<(A, B, C, D, E, F)> {
        typealias Tuple = (A, B, C, D, E, F)
        return Gen.lens(extract: \Tuple.0, a).bind { a in
            Gen.lens(extract: \Tuple.1, b).bind { b in
                Gen.lens(extract: \Tuple.2, c).bind { c in
                    Gen.lens(extract: \Tuple.3, d).bind { d in
                        Gen.lens(extract: \Tuple.4, e).bind { e in
                            f.mapped(forward: { f in (a, b, c, d, e, f) }, backward: \.5)
                        }
                    }
                }
            }
        }
    }
    
    public static func zip<A, B, C, D, E, F, G>(
        _ a: ReflectiveGenerator<A>,
        _ b: ReflectiveGenerator<B>,
        _ c: ReflectiveGenerator<C>,
        _ d: ReflectiveGenerator<D>,
        _ e: ReflectiveGenerator<E>,
        _ f: ReflectiveGenerator<F>,
        _ g: ReflectiveGenerator<G>
    ) -> ReflectiveGenerator<(A, B, C, D, E, F, G)> {
        typealias Tuple = (A, B, C, D, E, F, G)
        return Gen.lens(extract: \Tuple.0, a).bind { a in
            Gen.lens(extract: \Tuple.1, b).bind { b in
                Gen.lens(extract: \Tuple.2, c).bind { c in
                    Gen.lens(extract: \Tuple.3, d).bind { d in
                        Gen.lens(extract: \Tuple.4, e).bind { e in
                            Gen.lens(extract: \Tuple.5, f).bind { f in
                                g.mapped(forward: { g in (a, b, c, d, e, f, g) }, backward: \.6)
                            }
                        }
                    }
                }
            }
        }
    }
    
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
        typealias Tuple = (A, B, C, D, E, F, G, H)
        return Gen.lens(extract: \Tuple.0, a).bind { a in
            Gen.lens(extract: \Tuple.1, b).bind { b in
                Gen.lens(extract: \Tuple.2, c).bind { c in
                    Gen.lens(extract: \Tuple.3, d).bind { d in
                        Gen.lens(extract: \Tuple.4, e).bind { e in
                            Gen.lens(extract: \Tuple.5, f).bind { f in
                                Gen.lens(extract: \Tuple.6, g).bind { g in
                                    h.mapped(forward: { h in (a, b, c, d, e, f, g, h) }, backward: \.7)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
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
        typealias Tuple = (A, B, C, D, E, F, G, H, I)
        return Gen.lens(extract: \Tuple.0, a).bind { a in
            Gen.lens(extract: \Tuple.1, b).bind { b in
                Gen.lens(extract: \Tuple.2, c).bind { c in
                    Gen.lens(extract: \Tuple.3, d).bind { d in
                        Gen.lens(extract: \Tuple.4, e).bind { e in
                            Gen.lens(extract: \Tuple.5, f).bind { f in
                                Gen.lens(extract: \Tuple.6, g).bind { g in
                                    Gen.lens(extract: \Tuple.7, h).bind { h in
                                        i.mapped(forward: { i in (a, b, c, d, e, f, g, h, i) }, backward: \.8)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
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
        typealias Tuple = (A, B, C, D, E, F, G, H, I, J)
        return Gen.lens(extract: \Tuple.0, a).bind { a in
            Gen.lens(extract: \Tuple.1, b).bind { b in
                Gen.lens(extract: \Tuple.2, c).bind { c in
                    Gen.lens(extract: \Tuple.3, d).bind { d in
                        Gen.lens(extract: \Tuple.4, e).bind { e in
                            Gen.lens(extract: \Tuple.5, f).bind { f in
                                Gen.lens(extract: \Tuple.6, g).bind { g in
                                    Gen.lens(extract: \Tuple.7, h).bind { h in
                                        Gen.lens(extract: \Tuple.8, i).bind { i in
                                            j.mapped(forward: { j in (a, b, c, d, e, f, g, h, i, j) }, backward: \.9)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
