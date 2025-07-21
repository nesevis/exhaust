//
//  Gen+Zip.swift
//  Exhaust
//
//  Created by Chris Kolbu on 21/7/2025.
//

extension Gen {
    private static func lensIfNot<Input, NewInput>(
        extract path: some PartialPath<NewInput, Input>,
        _ next: ReflectiveGenerator<Any, Input>
    ) -> ReflectiveGenerator<Any, Input> {
        guard next.isLens == false else {
            return next
        }
        return comap(path.extract(from:), next)
    }
    // Zip wraps plain generators in a lens to help them extract from the tuple that is returned when reflecting. If the generator is already a lens, the assumption is that the user is then mapping over the tuple to transform it into something else again.
    static func zip<A, B>(
        _ a: ReflectiveGenerator<Any, A>,
        _ b: ReflectiveGenerator<Any, B>
    ) -> ReflectiveGenerator<Any, (A, B)> {
        typealias Tuple = (A, B)
        return Gen.lensIfNot(extract: \Tuple.0, a).bind { a in
            Gen.lensIfNot(extract: \Tuple.1, b).map { b in
                (a, b)
            }
        }
    }
    
    static func zip<A, B, C>(
        _ a: ReflectiveGenerator<Any, A>,
        _ b: ReflectiveGenerator<Any, B>,
        _ c: ReflectiveGenerator<Any, C>
    ) -> ReflectiveGenerator<Any, (A, B, C)> {
        typealias Tuple = (A, B, C)
        return Gen.lensIfNot(extract: \Tuple.0, a).bind { a in
            Gen.lensIfNot(extract: \Tuple.1, b).bind { b in
                Gen.lensIfNot(extract: \Tuple.2, c).map { c in
                    (a, b, c)
                }
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
        return Gen.lensIfNot(extract: \Tuple.0, a)
            .bind { a in
                Gen.lensIfNot(extract: \Tuple.1, b).bind { b in
                    Gen.lensIfNot(extract: \Tuple.2, c).bind { c in
                        Gen.lensIfNot(extract: \Tuple.3, d).map { d in
                            (a, b, c, d)
                        }
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
        return Gen.lensIfNot(extract: \Tuple.0, a)
            .bind { a in
                Gen.lensIfNot(extract: \Tuple.1, b).bind { b in
                    Gen.lensIfNot(extract: \Tuple.2, c).bind { c in
                        Gen.lensIfNot(extract: \Tuple.3, d).bind { d in
                            Gen.lensIfNot(extract: \Tuple.4, e).map { e in
                                (a, b, c, d, e)
                            }
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
        return Gen.lensIfNot(extract: \Tuple.0, a)
            .bind { a in
                Gen.lensIfNot(extract: \Tuple.1, b).bind { b in
                    Gen.lensIfNot(extract: \Tuple.2, c).bind { c in
                        Gen.lensIfNot(extract: \Tuple.3, d).bind { d in
                            Gen.lensIfNot(extract: \Tuple.4, e).bind { e in
                                Gen.lensIfNot(extract: \Tuple.5, f).map { f in
                                    (a, b, c, d, e, f)
                                }
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
        return Gen.lensIfNot(extract: \Tuple.0, a)
            .bind { a in
                Gen.lensIfNot(extract: \Tuple.1, b).bind { b in
                    Gen.lensIfNot(extract: \Tuple.2, c).bind { c in
                        Gen.lensIfNot(extract: \Tuple.3, d).bind { d in
                            Gen.lensIfNot(extract: \Tuple.4, e).bind { e in
                                Gen.lensIfNot(extract: \Tuple.5, f).bind { f in
                                    Gen.lensIfNot(extract: \Tuple.6, g).map { g in
                                        (a, b, c, d, e, f, g)
                                    }
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
        return Gen.lensIfNot(extract: \Tuple.0, a)
            .bind { a in
                Gen.lensIfNot(extract: \Tuple.1, b).bind { b in
                    Gen.lensIfNot(extract: \Tuple.2, c).bind { c in
                        Gen.lensIfNot(extract: \Tuple.3, d).bind { d in
                            Gen.lensIfNot(extract: \Tuple.4, e).bind { e in
                                Gen.lensIfNot(extract: \Tuple.5, f).bind { f in
                                    Gen.lensIfNot(extract: \Tuple.6, g).bind { g in
                                        Gen.lensIfNot(extract: \Tuple.7, h).map { h in
                                            (a, b, c, d, e, f, g, h)
                                        }
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
        return Gen.lensIfNot(extract: \Tuple.0, a)
            .bind { a in
                Gen.lensIfNot(extract: \Tuple.1, b).bind { b in
                    Gen.lensIfNot(extract: \Tuple.2, c).bind { c in
                        Gen.lensIfNot(extract: \Tuple.3, d).bind { d in
                            Gen.lensIfNot(extract: \Tuple.4, e).bind { e in
                                Gen.lensIfNot(extract: \Tuple.5, f).bind { f in
                                    Gen.lensIfNot(extract: \Tuple.6, g).bind { g in
                                        Gen.lensIfNot(extract: \Tuple.7, h).bind { h in
                                            Gen.lensIfNot(extract: \Tuple.8, i).map { i in
                                                (a, b, c, d, e, f, g, h, i)
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
        return Gen.lensIfNot(extract: \Tuple.0, a)
            .bind { a in
                Gen.lensIfNot(extract: \Tuple.1, b).bind { b in
                    Gen.lensIfNot(extract: \Tuple.2, c).bind { c in
                        Gen.lensIfNot(extract: \Tuple.3, d).bind { d in
                            Gen.lensIfNot(extract: \Tuple.4, e).bind { e in
                                Gen.lensIfNot(extract: \Tuple.5, f).bind { f in
                                    Gen.lensIfNot(extract: \Tuple.6, g).bind { g in
                                        Gen.lensIfNot(extract: \Tuple.7, h).bind { h in
                                            Gen.lensIfNot(extract: \Tuple.8, i).bind { i in
                                                Gen.lensIfNot(extract: \Tuple.9, j).map { j in
                                                    (a, b, c, d, e, f, g, h, i, j)
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
}
