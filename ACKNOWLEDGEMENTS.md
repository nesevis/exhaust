# Acknowledgements

Work on what would become Exhaust started in [early 2025](https://hachyderm.io/@nesevis/113789286635356164) after I came across Harrison Goldstein’s PhD dissertation _Property-based Testing for the People_. I’ve had a longstanding interest in PBT and testing more generally, and have been fascinated by the integrated test case reduction in [Hypothesis](https://hypothesis.works/).

I wanted a similarly powerful and ergonomic PBT library for Swift. Exhaust is my attempt at creating that.

Along the way I went down many rabbit holes; sometimes I even came back up with rabbits.

## Harrison Goldstein

Exhaust would not exist without the foundation laid out in his thesis: the Freer monad-based reflective generator that reifies effects as inspectable data; the notion of _interpreting_ a generator bidirectionally; Choice Gradient optimisation.

- [Property-based Testing for the People](https://repository.upenn.edu/server/api/core/bitstreams/8abd65a8-7b3c-43c4-b004-fb756f3bc466/content) (2024)
- [Tuning Random Generators: Property-Based Testing as Probabilistic Programming](https://arxiv.org/abs/2508.14394) (2025, Goldstein as co-author)
- [Reflecting on Random Generation](https://dl.acm.org/doi/10.1145/3607842) (2023)
- [Tyche: Making Sense of PBT Effectiveness](https://dl.acm.org/doi/10.1145/3654777.3676407) (2024)

## David MacIver, Alastair Donaldson and Hypothesis

Exhaust shamelessly adopts three insights from Hypothesis and this paper:
- The generator as a parser of randomness (via Goldstein)
- [Shortlex](https://en.wikipedia.org/wiki/Shortlex_order) optimisation as the reduction order: shorter is better, if equal simpler is better
- Internal reduction: reduce the generator choices that led to the output value, not the output value itself

…And many implementations:
- Float shortlex ordering and reduction
- Adaptive binary search
- Unit tests to verify edge cases
- The notion of a `Bundle` for stateful contract testing


- [Test Case Reduction via Test Case Generation: Insights from the Hypothesis Reducer](https://www.semanticscholar.org/paper/Test-Case-Reduction-via-Test-Case-Generation%3A-from-MacIver-Donaldson/6d72e1bd7743f12b48e20f7d234407e37b67e009) (2020)
- [Improving Binary Search by Guessing](https://notebook.drmaciver.com/posts/2019-04-30-13:03.html)

## Alfredo Sepúlveda-Jiménez

The categorical framework for _optimisation_ laid out in this preprint provides Exhaust with an organisational algebra for test case reduction:
- Each reduction “strategy” is a self-contained encoder-decoder pair that composes cleanly when chained
- A Kleisli generalisation extends this composition through an effectful step (“lift”) which makes it nondeterministic, but ensures the same guarantees as deterministic composition
- A dominance lattice to help prune redundant strategies within each phase
- A “relax-round” pattern to escape local minima

_The phase ordering itself comes from fibration theory._

- [Categories of Optimization Reductions](https://www.researchgate.net/publication/399656065_CATEGORIES_OF_OPTIMIZATION_REDUCTIONS) (2026)

## Renée Bryce & Charles Colbourn

Their _Density_ algorithm provides a way to do pull-based/lazy covering array generation. This is used by Exhaust to perform exhaustive generation of values for finite domains and boundary coverage of interesting values for larger domains.

- [A density-based greedy algorithm for higher strength covering arrays](https://onlinelibrary.wiley.com/doi/epdf/10.1002/stvr.393) (2009) (paywall)

## Other influences

### Hillel Wayne

Hillel’s primary area of focus is formal methods (he’s got a book out!) but he has written extensively about testing and PBT in particular for a long time. [Blog](https://www.hillelwayne.com)

### Johannes Link

Johannes Link’s [Shrinking Challenge](https://github.com/jlink/shrinking-challenge) repository was a perfect test bed for refining Exhaust’s test case reducer.

### Swift Testing

Exhaust’s macros were modelled on those in Swift Testing, including naming conventions and its closure analysis code.

### Hedgehog

Hedgehog’s size cycling and scaling API was a big inspiration for how Exhaust manages complexity scaling during random generation. [Github](https://github.com/jkachmar/haskell-hedgehog/)

### Fast-check, jqwik, and CsCheck

I used tests from these libraries to help verify Exhaust’s reduction code

- [Fast-check](https://fast-check.dev/) JS/TS
- [jqwik](https://jqwik.net/) Java/Kotlin
- [CsCheck](https://github.com/AnthonyLloyd/CsCheck) C#

### Pointfree

[Pointfree](https://www.pointfree.co)'s excellent libraries [Custom Dump](https://github.com/pointfreeco/swift-custom-dump) is used to output counterexamples and diffs in a standardised way, and [Swift Issue Reporting](https://github.com/pointfreeco/swift-issue-reporting) is used for surfacing issues in Swift Testing and XCTest.
