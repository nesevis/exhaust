import Testing
@testable import Exhaust

@Test("Debug proliferate step by step")
func debugProliferateStepByStep() {
    
    // 1. Test String.arbitrary alone
    print("\n=== Testing String.arbitrary ===")
    let stringGen = String.arbitrary
    for i in 0..<3 {
        let generated = Interpreters.generate(stringGen)!
        print("Generated: '\(generated)'")
        if let recipe = Interpreters.reflect(stringGen, with: generated) {
            if let replayed = Interpreters.replay(stringGen, using: recipe) {
                print("✅ Round-trip successful: '\(replayed)'")
            } else {
                print("❌ Replay failed")
            }
        } else {
            print("❌ Reflection failed")
        }
    }
    
    // 2. Test proliferate alone (without map)
    print("\n=== Testing String.arbitrary.proliferate ===")
    let proliferateGen = String.arbitrary.proliferate(with: 1...3)
    for i in 0..<3 {
        let generated = Interpreters.generate(proliferateGen)!
        print("Generated: \(generated)")
        if let recipe = Interpreters.reflect(proliferateGen, with: generated) {
            if let replayed = Interpreters.replay(proliferateGen, using: recipe) {
                print("✅ Round-trip successful: \(replayed)")
            } else {
                print("❌ Replay failed")
            }
        } else {
            print("❌ Reflection failed")
        }
    }
    
    // 3. Test the full chain: proliferate + map
    print("\n=== Testing String.arbitrary.proliferate + map ===")
    let fullGen = String.arbitrary.proliferate(with: 1...3).map { $0.joined() }
    for i in 0..<3 {
        let generated = Interpreters.generate(fullGen)!
        print("Generated: '\(generated)'")
        if let recipe = Interpreters.reflect(fullGen, with: generated) {
            if let replayed = Interpreters.replay(fullGen, using: recipe) {
                print("✅ Round-trip successful: '\(replayed)'")
            } else {
                print("❌ Replay failed")
            }
        } else {
            print("❌ Reflection failed")
        }
    }
}