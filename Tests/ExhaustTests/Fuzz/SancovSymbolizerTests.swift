import ExhaustCore
import Foundation
import Testing
@testable import Exhaust

@Suite("Symbol classification")
struct SymbolClassificationTests {
    @Test("Compiler-generated globals are recognized on the mangled name")
    func mangledClassification() {
        // A type metadata accessor, a reabstraction thunk, an outlined copy, a merged function, and a protocol witness thunk.
        for mangled in ["$s4STLC10STLCConfigVMa", "$s4STLC1fyyFTR", "$s4STLC8STLCExprOWOy", "$s4STLC1gyyFTm", "$s4STLC4TypeVSQAASQ2eeoiySbx_xtFZTW"] {
            #expect(SancovSymbolizer.isCompilerGenerated(mangled: mangled), "\(mangled)")
        }
        // A plain function, a specialization of one, a C symbol, and a getter.
        for mangled in ["$s4STLC11stlcGetTypeySo0A4TypeVSgSayADG_AA0A4ExprOtF", "$s4STLC1fyyFTf4d_n", "_exhaust_tpg_bind", "$s4STLC8RegLabelV8allBelowSayACGvg"] {
            #expect(SancovSymbolizer.isCompilerGenerated(mangled: mangled) == false, "\(mangled)")
        }
    }

    @Test("The module is the first identifier of a mangled Swift name")
    func moduleName() {
        #expect(SancovSymbolizer.moduleName(ofMangled: "$s4STLC11stlcGetTypeySo0A4TypeVSgSayADG_AA0A4ExprOtF") == "STLC")
        #expect(SancovSymbolizer.moduleName(ofMangled: "$s10IFCMachine8RegLabelO8allBelowSayACGvg") == "IFCMachine")
        #expect(SancovSymbolizer.moduleName(ofMangled: "$sSa6appendyyxF") == "Swift")
        #expect(SancovSymbolizer.moduleName(ofMangled: "_exhaust_tpg_bind") == nil)
    }

    @Test("Specialization wrappers strip to the function in both demangler forms")
    func specializationStripping() {
        #expect(SancovSymbolizer.stripSpecialization("function signature specialization <Arg[2] = Dead> of STLC.stlcGetType([STLC.STLCType], STLC.STLCExpr) -> STLC.STLCType?") == "STLC.stlcGetType([STLC.STLCType], STLC.STLCExpr) -> STLC.STLCType?")
        #expect(SancovSymbolizer.stripSpecialization("specialized stlcGetType(_:_:)") == "stlcGetType(_:_:)")
        #expect(SancovSymbolizer.stripSpecialization("stlcGetType(_:_:)") == "stlcGetType(_:_:)")
    }

    #if os(macOS)
        @Test("The simplifier renders the debugger's form for the shapes the IFC and STLC dumps produced", .enabled(if: swiftDemangleIsAvailable, "swift-demangle is not installed"))
        func simplifiedNames() throws {
            let names = SancovSymbolizer.simplifiedNames(forMangled: [
                "$s4STLC11stlcGetTypeySo0A4TypeVSgSayADG_AA0A4ExprOtF",
                "$s10IFCMachine8RegLabelO8allBelowSayACGvg",
                "$s4STLC13stlcSubstImpl33_1954C2AFCB1824DC713E91E170B31520LLyAA0A4ExprOSi_A2E6configAA0A6ConfigVtF",
                "$s4STLC11stlcGetTypeySo0A4TypeVSgSayADG_AA0A4ExprOtFTf4d_n",
            ])
            // The trait skips this test where the toolchain tool is absent. Past that point an empty result is a defect, not a missing tool.
            try #require(names.isEmpty == false, "swift-demangle was found but rendered nothing")
            #expect(names["$s4STLC11stlcGetTypeySo0A4TypeVSgSayADG_AA0A4ExprOtF"] == "stlcGetType(_:_:)")
            #expect(names["$s10IFCMachine8RegLabelO8allBelowSayACGvg"] == "RegLabel.allBelow.getter")
            #expect(names["$s4STLC13stlcSubstImpl33_1954C2AFCB1824DC713E91E170B31520LLyAA0A4ExprOSi_A2E6configAA0A6ConfigVtF"]?.hasPrefix("stlcSubstImpl(") == true)
            #expect(names["$s4STLC11stlcGetTypeySo0A4TypeVSgSayADG_AA0A4ExprOtFTf4d_n"] == "stlcGetType(_:_:)")
        }
    #endif
}

// MARK: - Helpers

/// Whether the toolchain's `swift-demangle` can be located, resolved once so the spawn is not repeated per test.
private let swiftDemangleIsAvailable: Bool = {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["--find", "swift-demangle"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return false
    }
    process.waitUntilExit()
    return process.terminationStatus == 0
}()
