# ``Exhaust``

A property-based testing library for Swift that integrates with Swift Testing and XCTest.

## Overview

Describe what your code should do, and Exhaust checks that claim across hundreds of inputs. When it finds a failure, it reduces it to the minimal counterexample.

```swift
@Test func mySortProducesAscendingOrder() {
    #exhaust(.int().array(length: 0...100)) { array in
        let result = mySort(array)
        let expected = array.sorted()
        #expect(result == expected)
    }
}
```

Exhaust builds generators with the `#gen` macro. Each generator is an inspectable data structure that Exhaust can run forward to produce values, replay for deterministic reproduction, and run backward to reconstruct a known value's choices. Reduction, screening of problematic values, and filter optimisation all follow from inspection.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:ConceptualOverview>

### Generators

- <doc:BuildingGenerators>
- ``ExhaustCore/ReflectiveGenerator``
- ``ExhaustCore/SizeScaling``
- ``ExhaustCore/UnfoldStep``
- ``ExhaustCore/FilterType``
- ``ExhaustCore/ReplaySeed``
- ``ExhaustCore/GeneratorError``
- ``ExhaustCore/ReflectionError``
- ``ExhaustCore/DateStride``

### Property Testing

- <doc:PropertyTesting>
- <doc:DirectedExploration>
- <doc:CoverageGuidedFuzzing>
- <doc:GeneratorTesting>

### State Machine Testing

- <doc:StateMachineTesting>

### Reduction

- <doc:HowReductionWorks>

### Test Framework Integration

- <doc:SwiftTestingIntegration>
- <doc:XCTestCompatibility>

### Macros

- <doc:MacroGen>
- <doc:MacroExhaust>
- <doc:MacroExplore>
- <doc:MacroExecute>
- <doc:MacroExamine>
- <doc:MacroExample>
- ``StateMachine(_:)``
- ``SystemUnderTest()``
- ``Command(weight:_:)``
- ``Invariant()``
- ``Oracle()``
- ``exhaust(_:_:property:)-8d0i6``
- ``exhaust(_:_:property:)-4t75u``
- ``exhaust(_:reflecting:_:property:)-78cpf``
- ``exhaust(_:reflecting:_:property:)-2bzvp``
- ``explore(_:directions:_:property:)-8mzym``
- ``explore(_:directions:_:property:)-6teom``
- ``execute(_:_:)-8h2ke``
- ``execute(_:_:)-7m2bv``
- ``examine(_:_:)``
- ``examine(_:_:replayCheck:)``
- ``example(_:seed:)``
- ``example(_:count:seed:)``
- ``gen(_:transform:)``
- ``gen(_:)-68sjg``
- ``gen(_:)-2tl2t``
- ``gen(_:from:)-69u5b``
- ``gen(_:from:)-3jh2y``
- ``gen(from:)``

### Property Settings

- ``ExhaustBudget``
- ``PropertySettings``
- ``SuppressOption``
- ``PropertySkip``

### Explore Settings

- ``ExploreSettings``

### Fuzz Settings

- ``FuzzSettings``
- ``FuzzReport``
- ``TimeBudget``

### Examine Settings

- ``ExamineSettings``
- ``ExamineSeverity``

### State Machine Configuration

- ``StateMachineSpec``
- ``AsyncStateMachineSpec``
- ``StateMachineSpecBase``
- ``StateMachineSettings``
- ``ExecutionModel``
- ``ConcurrencyLevel``
- ``StateMachineSkip``
- ``StateMachineCheckFailure``
- ``CommandResponse``

### Results and Reports

- ``ExhaustReport``
- ``ExploreReport``
- ``ExploreTermination``
- ``DirectionCoverage``
- ``DirectionOutcome``
- ``DirectionWarmup``
- ``WarmupStats``
- ``ExamineReport``
- ``ExamineFailure``
- ``StateMachineResult``
- ``StateMachineDiscoveryMethod``
- ``TraceStep``
- ``DiagnosticSnapshot``
- ``ExhaustCore/ReductionStats``
- ``ExhaustCore/CouplingEdge``
- ``ExhaustCore/ChoiceGraphStats``
- ``ExhaustCore/EncoderName``
- ``ExhaustCore/FilterObservation``
- ``ExhaustCore/FilterSourceLocation``
- ``ExhaustCore/NumericTypeCoverage``
- ``ExhaustCore/CoOccurrenceMatrix``
- ``ExhaustCore/OpenPBTStatsLine``

### Swift Testing Traits

- ``ExhaustTrait``
- ``ExhaustTraitOption``
- ``ExhaustTraitConfiguration``
- ``ExhaustSuiteTrait``
- ``ExhaustSuiteTraitOption``

### Logging

- ``ExhaustCore/LogLevel``
- ``ExhaustCore/LogFormat``

### Modules

- ``ExhaustCore``
