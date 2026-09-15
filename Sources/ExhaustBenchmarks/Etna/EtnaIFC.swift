// MARK: - Etna IFC Workload (Register Machine) — Generator Shape Only

//
// Minimal port of IFCMachine types for the mutation benchmarks. Only the types
// and the type-based generator are needed; the property, mutant tables, and
// machine stepper are not.

import Exhaust

// MARK: - Labels

enum IFCLabel: CaseIterable, Equatable, Hashable, Sendable {
    case low
    case mid1
    case mid2
    case high

    static let all: [IFCLabel] = [.low, .mid1, .mid2, .high]
}

// MARK: - Instructions

enum IFCBinaryOperation: CaseIterable, Equatable, Hashable, Sendable {
    case add
    case multiply
    case join
    case flowsTo
    case equal
}

typealias IFCRegisterID = Int

enum IFCInstruction: Equatable, Hashable, Sendable {
    case put(Int, IFCRegisterID)
    case mov(IFCRegisterID, IFCRegisterID)
    case load(IFCRegisterID, IFCRegisterID)
    case store(IFCRegisterID, IFCRegisterID)
    case write(IFCRegisterID, IFCRegisterID)
    case binOp(IFCBinaryOperation, IFCRegisterID, IFCRegisterID, IFCRegisterID)
    case nop
    case halt
    case jump(IFCRegisterID)
    case bnz(Int, IFCRegisterID)
    case bcall(IFCRegisterID, IFCRegisterID, IFCRegisterID)
    case bret
    case lab(IFCRegisterID, IFCRegisterID)
    case pcLab(IFCRegisterID)
    case putLab(IFCLabel, IFCRegisterID)
    case alloc(IFCRegisterID, IFCRegisterID, IFCRegisterID)
    case pGetOff(IFCRegisterID, IFCRegisterID)
    case pSetOff(IFCRegisterID, IFCRegisterID, IFCRegisterID)
    case mSize(IFCRegisterID, IFCRegisterID)
    case mLab(IFCRegisterID, IFCRegisterID)
}

// MARK: - State Types

struct IFCBlock: Equatable, Hashable, Sendable {
    var index: Int
    var stamp: IFCLabel
}

struct IFCPointer: Equatable, Hashable, Sendable {
    var block: IFCBlock
    var offset: Int
}

enum IFCValue: Equatable, Hashable, Sendable {
    case int(Int)
    case pointer(IFCPointer)
    case label(IFCLabel)
}

struct IFCAtom: Equatable, Hashable, Sendable {
    var value: IFCValue
    var label: IFCLabel
}

struct IFCFrame: Equatable, Hashable, Sendable {
    var label: IFCLabel
    var data: [IFCAtom]
}

struct IFCMemory: Equatable, Hashable, Sendable {
    private var frameLists: [[IFCFrame]] = Array(repeating: [], count: IFCLabel.all.count)

    subscript(frames stamp: IFCLabel) -> [IFCFrame] {
        get { frameLists[IFCLabel.all.firstIndex(of: stamp)!] }
        set { frameLists[IFCLabel.all.firstIndex(of: stamp)!] = newValue }
    }
}

struct IFCProgramCounter: Equatable, Hashable, Sendable {
    var address: Int
    var label: IFCLabel
}

struct IFCStackFrame: Equatable, Hashable, Sendable {
    var returnPC: IFCProgramCounter
    var savedRegisters: [IFCAtom]
    var resultRegister: IFCRegisterID
    var resultLabel: IFCLabel
}

struct IFCState: Equatable, Hashable, Sendable {
    var instructions: [IFCInstruction]
    var memory: IFCMemory
    var stack: [IFCStackFrame]
    var registers: [IFCAtom]
    var pc: IFCProgramCounter
}

struct IFCVariation: Equatable, Hashable, Sendable {
    var observer: IFCLabel
    var first: IFCState
    var second: IFCState
}

// MARK: - Type-Based Generator

//
// Faithful port of Etna's QuickChick-derived generator (`Derive Arbitrary` over every type).
// Mirrors RegisterTypeBasedGenerator.swift in ~/Fun/Exhaust-Etna/Sources/IFCBench.

private let ifcLabelGen = #gen(.element(from: IFCLabel.all))
private let ifcBinaryOperationGen = #gen(.element(from: IFCBinaryOperation.allCases))
private let ifcIntGen = #gen(.int(in: -7 ... 7, scaling: .exponential))

private let ifcBlockGen = #gen(ifcIntGen, ifcLabelGen).map { IFCBlock(index: $0, stamp: $1) }
private let ifcPointerGen = #gen(ifcBlockGen, ifcIntGen).map { IFCPointer(block: $0, offset: $1) }

private let ifcValueGen: ReflectiveGenerator<IFCValue> = .oneOf(
    ifcIntGen.map { IFCValue.int($0) },
    ifcPointerGen.map { IFCValue.pointer($0) },
    ifcLabelGen.map { IFCValue.label($0) }
)

private let ifcAtomGen = #gen(ifcValueGen, ifcLabelGen).map { IFCAtom(value: $0, label: $1) }
private let ifcAtomListGen = ifcAtomGen.array(length: 0 ... 7, scaling: .exponential)
private let ifcPCGen = #gen(ifcIntGen, ifcLabelGen).map { IFCProgramCounter(address: $0, label: $1) }

private let ifcInstructionGen: ReflectiveGenerator<IFCInstruction> = {
    let reg = ifcIntGen
    let int = ifcIntGen
    return .oneOf(
        #gen(int, reg).map { IFCInstruction.put($0, $1) },
        #gen(reg, reg).map { IFCInstruction.mov($0, $1) },
        #gen(reg, reg).map { IFCInstruction.load($0, $1) },
        #gen(reg, reg).map { IFCInstruction.store($0, $1) },
        #gen(reg, reg).map { IFCInstruction.write($0, $1) },
        #gen(ifcBinaryOperationGen, reg, reg, reg).map { IFCInstruction.binOp($0, $1, $2, $3) },
        .just(.nop),
        .just(.halt),
        reg.map { IFCInstruction.jump($0) },
        #gen(int, reg).map { IFCInstruction.bnz($0, $1) },
        #gen(reg, reg, reg).map { IFCInstruction.bcall($0, $1, $2) },
        .just(.bret),
        #gen(reg, reg).map { IFCInstruction.lab($0, $1) },
        reg.map { IFCInstruction.pcLab($0) },
        #gen(ifcLabelGen, reg).map { IFCInstruction.putLab($0, $1) },
        #gen(reg, reg, reg).map { IFCInstruction.alloc($0, $1, $2) },
        #gen(reg, reg).map { IFCInstruction.pGetOff($0, $1) },
        #gen(reg, reg, reg).map { IFCInstruction.pSetOff($0, $1, $2) },
        #gen(reg, reg).map { IFCInstruction.mSize($0, $1) },
        #gen(reg, reg).map { IFCInstruction.mLab($0, $1) }
    )
}()

private let ifcFrameGen = #gen(ifcLabelGen, ifcAtomListGen).map { IFCFrame(label: $0, data: $1) }
private let ifcFrameListGen = ifcFrameGen.array(length: 0 ... 7, scaling: .exponential)

private let ifcMemoryGen: ReflectiveGenerator<IFCMemory> =
    #gen(
        ifcLabelGen.array(length: 0 ... 7, scaling: .exponential),
        ifcFrameListGen.array(length: 0 ... 7, scaling: .exponential)
    ).map { keys, values in
        var memory = IFCMemory()
        for (key, value) in zip(keys, values) {
            memory[frames: key] = value
        }
        return memory
    }

private let ifcStackFrameGen = #gen(ifcPCGen, ifcAtomListGen, ifcIntGen, ifcLabelGen).map {
    IFCStackFrame(returnPC: $0, savedRegisters: $1, resultRegister: $2, resultLabel: $3)
}

let ifcStateGen: ReflectiveGenerator<IFCState> =
    #gen(
        ifcInstructionGen.array(length: 0 ... 7, scaling: .exponential),
        ifcMemoryGen,
        ifcStackFrameGen.array(length: 0 ... 7, scaling: .exponential),
        ifcAtomListGen,
        ifcPCGen
    ).map { instructions, memory, stack, registers, pc in
        IFCState(instructions: instructions, memory: memory, stack: stack, registers: registers, pc: pc)
    }

let ifcVariationGen: ReflectiveGenerator<IFCVariation> =
    #gen(ifcLabelGen, ifcStateGen, ifcStateGen).map { IFCVariation(observer: $0, first: $1, second: $2) }
