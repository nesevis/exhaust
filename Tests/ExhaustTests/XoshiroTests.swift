//
//  XoshiroTests.swift
//  Exhaust
//
//  Created by Chris Kolbu on 27/7/2025.
//

import Testing
@testable import Exhaust
@_spi(ExhaustInternal) import ExhaustCore

@Test("Test Xoshiro against reference implementation")
func xoshiroAgainstReference() {
    for n in UInt64(1) ... 50 {
        var xoshiro = Xoshiro256(seed: n)
        #expect(reference[Int(n)] == xoshiro.next())
    }
}

@Test("Test seed stability", .disabled("Size scaling changed from logarithmic to linear"))
func xoshiroSeedStability() {
    let digits = #sample(.int64(), count: 10)
    let expectedDigits: [Int64] = [0, 16238, -6_660_220, -179_123_592, 8_005_708_369, 274_739_608_301, -684_234_672_488, 2_508_988_163_057, 100_069_181_990_740, 943_184_394_974_117]
    #expect(digits == expectedDigits)
}

@Test("Reflect on getSize")
func reflectOnGetsize() throws {
    // Test String.arbitrary
    let gen = String.arbitrary
    var iterator = ValueInterpreter(gen, seed: 123)
    _ = iterator.next()
    let generated = iterator.next()!
    print("Generated string: '\(generated)'")
    let generated2 = iterator.next()!
    let recipe2 = try Interpreters.reflect(gen, with: generated2)
    let replay = try Interpreters.replay(gen, using: #require(recipe2))
    #expect(generated2 == replay)
}

// FIXME: The string generator now varies from N/10...N, not N...N
// @Test("Reflect on resize")
// func testReflectOnResize() throws {
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
// }

private let reference: [UInt64] = [
    0, // 1-indexed
    12_966_619_160_104_079_557,
    1_884_871_951_439_679_575,
    12_740_027_877_540_924_608,
    4_859_480_363_769_805_331,
    5_320_248_114_040_590_185,
    14_149_230_350_423_225_221,
    12_923_355_070_828_475_994,
    15_145_412_344_303_851_199,
    47_656_050_712_223_840,
    17_612_975_809_606_265_341,
    4_118_682_332_196_087_775,
    5_689_283_122_419_574_945,
    4_469_561_385_778_016_610,
    13_314_999_602_426_395_285,
    12_542_531_551_893_687_307,
    16_902_100_344_120_580_418,
    12_137_813_314_099_405_514,
    12_345_541_976_792_374_929,
    14_304_443_378_716_613_530,
    13_410_170_219_743_523_052,
    571_145_536_561_302_545,
    18_309_828_805_644_901_894,
    7_889_123_170_269_411_831,
    15_798_143_355_149_781_125,
    16_451_565_785_717_565_163,
    4_340_813_100_360_493_234,
    5_516_272_454_182_625_941,
    3_819_342_351_951_167_853,
    13_089_932_198_730_976_217,
    1_776_915_815_539_447_989,
    13_073_886_446_125_612_824,
    11_695_019_586_659_716_700,
    6_209_995_197_922_487_984,
    13_345_245_509_964_945_051,
    6_129_360_040_732_747_026,
    12_550_287_581_568_847_256,
    2_144_506_296_987_853_704,
    1_545_300_816_620_268_324,
    561_561_578_061_584_951,
    987_855_142_716_957_534,
    13_225_511_433_842_405_998,
    1_546_998_764_402_558_742,
    10_405_484_009_399_916_488,
    15_073_236_214_822_305_978,
    2_570_041_451_451_268_628,
    12_751_905_173_179_325_561,
    7_108_460_782_855_186_817,
    17_682_118_920_650_799_080,
    12_454_977_798_075_865_833,
    3_448_112_680_314_304_889,
]
