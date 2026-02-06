//
//  XoshiroTests.swift
//  Exhaust
//
//  Created by Chris Kolbu on 27/7/2025.
//

@testable import Exhaust
import Testing

@Test("Test Xoshiro against reference implementation")
func testXoshiroAgainstReference() throws {
    for n in UInt64(1)...50 {
        var xoshiro = Xoshiro256(seed: n)
        #expect(reference[Int(n)] == xoshiro.next())
    }
}

@Test("Test spread of generator")
func testGeneratorIterator() {
    let iterator = ValueInterpreter(Int64.arbitrary, seed: 0)
    let ten = Array(iterator.prefix(10))
    let expected: [Int64] = [-1, -20, -1634, 30680, 118758, -519187, 668934, -951278, 3301282, 2736585]
    #expect(ten == expected)
}

@Test("Reflect on getSize")
func testReflectOnGetsize() throws {
    // Test String.arbitrary
    let gen = String.arbitrary
    var iterator = ValueInterpreter(gen, seed: 123)
    let _ = iterator.next()
    let generated = iterator.next()!
    print("Generated string: '\(generated)'")
    let generated2 = iterator.next()!
    let recipe2 = try Interpreters.reflect(gen, with: generated2)
    let replay = try Interpreters.replay(gen, using: recipe2!)
    #expect(generated2 == replay)
    print()
}

// FIXME: The string generator now varies from N/10...N, not N...N
//@Test("Reflect on resize")
//func testReflectOnResize() throws {
//    // Test String.arbitrary
//    let gen = Gen.resize(50, String.arbitrary)
//    var iterator = GeneratorIterator(gen)
//    let first = iterator.next()!
//    let second = iterator.next()!
//    #expect(first.count == second.count)
//    let recipe = try Interpreters.reflect(gen, with: first)
//    let replay = try Interpreters.replay(gen, using: recipe!)
//    #expect(replay == first)
//    print("String reflection succeeded!")
//}

private let reference: [UInt64] = [
    0, // 1-indexed
    12966619160104079557,
    1884871951439679575,
    12740027877540924608,
    4859480363769805331,
    5320248114040590185,
    14149230350423225221,
    12923355070828475994,
    15145412344303851199,
    47656050712223840,
    17612975809606265341,
    4118682332196087775,
    5689283122419574945,
    4469561385778016610,
    13314999602426395285,
    12542531551893687307,
    16902100344120580418,
    12137813314099405514,
    12345541976792374929,
    14304443378716613530,
    13410170219743523052,
    571145536561302545,
    18309828805644901894,
    7889123170269411831,
    15798143355149781125,
    16451565785717565163,
    4340813100360493234,
    5516272454182625941,
    3819342351951167853,
    13089932198730976217,
    1776915815539447989,
    13073886446125612824,
    11695019586659716700,
    6209995197922487984,
    13345245509964945051,
    6129360040732747026,
    12550287581568847256,
    2144506296987853704,
    1545300816620268324,
    561561578061584951,
    987855142716957534,
    13225511433842405998,
    1546998764402558742,
    10405484009399916488,
    15073236214822305978,
    2570041451451268628,
    12751905173179325561,
    7108460782855186817,
    17682118920650799080,
    12454977798075865833,
    3448112680314304889
]
