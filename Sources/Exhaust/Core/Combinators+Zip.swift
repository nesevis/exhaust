//
//  Gen+Zip.swift
//  Exhaust
//
//  Created by Chris Kolbu on 21/7/2025.
//

extension Gen {
    // Zip wraps plain generators in a lens to help them extract from the tuple that is returned when reflecting. If the generator is already a lens, the assumption is that the user is then mapping over the tuple to transform it into something else again.
    static func zip<A, B>(
        _ a: ReflectiveGenerator<Any, A>,
        _ b: ReflectiveGenerator<Any, B>
    ) -> ReflectiveGenerator<Any, (A, B)> {
        typealias Tuple = (A, B)
        return Gen.lens(extract: \Tuple.0, a).bind { a in
            b.mapped(forward: { b in (a, b) }, backward: \.1)
        }
    }
    
    static func zip<A, B, C>(
        _ a: ReflectiveGenerator<Any, A>,
        _ b: ReflectiveGenerator<Any, B>,
        _ c: ReflectiveGenerator<Any, C>
    ) -> ReflectiveGenerator<Any, (A, B, C)> {
        typealias Tuple = (A, B, C)
        return Gen.lens(extract: \Tuple.0, a).bind { a in
            Gen.lens(extract: \Tuple.1, b).bind { b in
                c.mapped(forward: { c in (a, b, c) }, backward: \.2)
            }
        }
    }
    
    static func zip<A, B, C, D>(
        _ a: ReflectiveGenerator<Any, A>,
        _ b: ReflectiveGenerator<Any, B>,
        _ c: ReflectiveGenerator<Any, C>,
        _ d: ReflectiveGenerator<Any, D>
    ) -> ReflectiveGenerator<Any, (A, B, C, D)> {
        typealias Tuple = (A, B, C, D)
        return Gen.lens(extract: \Tuple.0, a).bind { a in
            Gen.lens(extract: \Tuple.1, b).bind { b in
                Gen.lens(extract: \Tuple.2, c).bind { c in
                    d.mapped(forward: { d in (a, b, c, d) }, backward: \.3)
                }
            }
        }
    }
    
    static func zip<A, B, C, D, E>(
        _ a: ReflectiveGenerator<Any, A>,
        _ b: ReflectiveGenerator<Any, B>,
        _ c: ReflectiveGenerator<Any, C>,
        _ d: ReflectiveGenerator<Any, D>,
        _ e: ReflectiveGenerator<Any, E>
    ) -> ReflectiveGenerator<Any, (A, B, C, D, E)> {
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
    
    static func zip<A, B, C, D, E, F>(
        _ a: ReflectiveGenerator<Any, A>,
        _ b: ReflectiveGenerator<Any, B>,
        _ c: ReflectiveGenerator<Any, C>,
        _ d: ReflectiveGenerator<Any, D>,
        _ e: ReflectiveGenerator<Any, E>,
        _ f: ReflectiveGenerator<Any, F>
    ) -> ReflectiveGenerator<Any, (A, B, C, D, E, F)> {
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
    
    static func zip<A, B, C, D, E, F, G>(
        _ a: ReflectiveGenerator<Any, A>,
        _ b: ReflectiveGenerator<Any, B>,
        _ c: ReflectiveGenerator<Any, C>,
        _ d: ReflectiveGenerator<Any, D>,
        _ e: ReflectiveGenerator<Any, E>,
        _ f: ReflectiveGenerator<Any, F>,
        _ g: ReflectiveGenerator<Any, G>
    ) -> ReflectiveGenerator<Any, (A, B, C, D, E, F, G)> {
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
    
    static func zip<A, B, C, D, E, F, G, H>(
        _ a: ReflectiveGenerator<Any, A>,
        _ b: ReflectiveGenerator<Any, B>,
        _ c: ReflectiveGenerator<Any, C>,
        _ d: ReflectiveGenerator<Any, D>,
        _ e: ReflectiveGenerator<Any, E>,
        _ f: ReflectiveGenerator<Any, F>,
        _ g: ReflectiveGenerator<Any, G>,
        _ h: ReflectiveGenerator<Any, H>
    ) -> ReflectiveGenerator<Any, (A, B, C, D, E, F, G, H)> {
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
    
    static func zip<A, B, C, D, E, F, G, H, I>(
        _ a: ReflectiveGenerator<Any, A>,
        _ b: ReflectiveGenerator<Any, B>,
        _ c: ReflectiveGenerator<Any, C>,
        _ d: ReflectiveGenerator<Any, D>,
        _ e: ReflectiveGenerator<Any, E>,
        _ f: ReflectiveGenerator<Any, F>,
        _ g: ReflectiveGenerator<Any, G>,
        _ h: ReflectiveGenerator<Any, H>,
        _ i: ReflectiveGenerator<Any, I>
    ) -> ReflectiveGenerator<Any, (A, B, C, D, E, F, G, H, I)> {
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
    
    static func zip<A, B, C, D, E, F, G, H, I, J>(
        _ a: ReflectiveGenerator<Any, A>,
        _ b: ReflectiveGenerator<Any, B>,
        _ c: ReflectiveGenerator<Any, C>,
        _ d: ReflectiveGenerator<Any, D>,
        _ e: ReflectiveGenerator<Any, E>,
        _ f: ReflectiveGenerator<Any, F>,
        _ g: ReflectiveGenerator<Any, G>,
        _ h: ReflectiveGenerator<Any, H>,
        _ i: ReflectiveGenerator<Any, I>,
        _ j: ReflectiveGenerator<Any, J>
    ) -> ReflectiveGenerator<Any, (A, B, C, D, E, F, G, H, I, J)> {
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
