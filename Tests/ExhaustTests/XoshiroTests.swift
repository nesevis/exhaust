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
    let iterator = GeneratorIterator(UInt64.arbitrary, seed: 45)
    let ten = Array(iterator.prefix(10))
    let expected: [UInt64] = [99876816768981180, 11691770335020048077, 13545138161154263945, 17727692801448316443, 14201128549946055586, 927403297019764740, 104068003673161583, 9072136623944855643, 10104744834570070889, 7900884376915045024]
    #expect(ten == expected)
}

@Test("Test speed of generator")
func testGeneratorIteratorThing() throws {
    struct Person: Equatable {
        let age: Int
        let height: Double
        let firstName: String
        let lastName: String
    }
    let gen = Gen.zip(
        Int.arbitrary,
        Double.arbitrary,
        String.arbitrary,
        String.arbitrary
    )
        .mapped(
            forward:{ Person(age: $0.0, height: $0.1, firstName: $0.2, lastName: $0.3) },
            backward: { ($0.age, $0.height, $0.firstName, $0.lastName) }
        )
    
    var iterator = GeneratorIterator(gen, seed: 250883)
    let generated = iterator.next()!
    let recipe = try Interpreters.reflect(gen, with: iterator.next()!)

    let reference = Person(
        age: -125408598803298769,
        height: 4.9569959933472683e-26,
        firstName: "춊뛍ᇚ欁ᩂ쏜녜៚蔆Ⲷ뽅旌㌽稔껞쏔䚉Ą镪熬彽ꢳ줏낅᷼鸥둔䄤塁⨼ㅇᥓᕢ댭䩓韀Ꮜ뱧꿼财䰞曠驘⨿㷉騥ᜆ韔睸눖Ѭ寛೟资矠Ф梲熃寋癓䳦䬯㹶舡鿀⽺㩃쁾딟ᗻ␈䰋ཋ吲⋽絆嫓㡫嫗媏ཛᩫ딛۹鉊╻趨鵱䬩暶ߓ갲늏㥩ᔶ紫ꘒ榌항裮隖鬤Π횴৫힏ଭẃ墶↢ۑ㑇砫璍漮",
        lastName: "ꊾ䘐鰉犲垣꽬嫎⦡뻇ᦫ灂틦饅Ꮯ톮丙ᱎ磈੪뜓㐼ꟑ邵爂큧閳㪐쨬ꎾ㌇縼䊸麀퀸⺽キ瘷줶瀀ᗫꇏ绨쎞彚꤃䒳ᓾ鄗絑㷘ꯜ璱䬲᪉偸㫊仴᝵惟㴲먗䗠ᐹꜻ녝셄㠴忻ϥ虫ⵘ斢秬푥ꯞ⺖ḟ㞫⪅⓲졼勓楨롫땜⬧鿜ᡊ㧟‗炞᭖⫻碥ཱུᠣꧧ甋꫞ꉨ쮊㸁琼钥⨄ⷘ퀸쒝짜椎ꂹ"
    )
    let next = Array(iterator.prefix(10))
    print()
    #expect(generated == reference)
}

@Test("Reflect on getSize")
func testReflectOnGetsize() throws {
    // Test String.arbitrary
    let gen = String.arbitrary
    var iterator = GeneratorIterator(gen, seed: 123)
    let _ = iterator.next()
    let generated = iterator.next()!
    print("Generated string: '\(generated)'")
    let generated2 = iterator.next()!
    let recipe2 = try Interpreters.reflect(gen, with: generated2)
    let replay = try Interpreters.replay(gen, using: recipe2!)
    print("String reflection succeeded! \(recipe2!.debugDescription)")
    print()
}

@Test("Reflect on resize")
func testReflectOnResize() throws {
    // Test String.arbitrary
    let gen = Gen.resize(50, String.arbitrary)
    var iterator = GeneratorIterator(gen)
    let first = iterator.next()!
    let second = iterator.next()!
    #expect(first.count == second.count)
    let recipe = try Interpreters.reflect(gen, with: first)
    let replay = try Interpreters.replay(gen, using: recipe!)
    #expect(replay == first)
    print("String reflection succeeded!")
}

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
