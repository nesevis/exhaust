# Conceptual overview

This page is a map of what Exhaust's pieces are and how they fit together. Read this when you want to understand why the tools are shaped the way they are, or to look a term up. There is a glossary at the bottom.

## Testing as search

The input space of most functions is too large to cover completely, so Exhaust searches it for a **counterexample**: a value that fails. Every run tries new values, so a property that passed yesterday can still fail today.

This is not flakiness. A flaky test fails unpredictably on the same input. A property fails because it reached a new input that happens to fail, and the failure comes with a seed that reproduces it every time.

Each tool on this page is a different search strategy. `#exhaust` searches broadly, `#explore` lets you nudge the search in specific directions or use code coverage as a feedback signal. `#execute` searches sequences of commands. Reduction searches for the minimal form of a failure. `#examine` is the diagnostic: it helps check that the search is reaching the space you intended.

## Properties and generators

To run a search you describe two things: a property and a generator.

A **property** is a claim about your code that should hold for every input. In its simplest form it is a closure in the form `(T) -> Bool`. It is a violation of this claim that the search is trying to find.

A **generator** describes the shape of the inputs to try. It is the search space. `#gen` builds one from primitives and composes them:

```swift
let orders = #gen(.uuid(), itemGenerator.array(), .double()) { id, items, total in
    Order(id: id, items: items, total: total)
}
```

The shaping question for a generator is *what values does my code accept?*, which is usually the input type in the signature, not the narrower set you expect in production. A sort accepts any `[Int]`, so its generator should produce any `[Int]`, including the empty and the enormous.

Two dials shape how a generator fills the space. **Size** is a value from 0 to 100 that Exhaust cycles over a run, so values without explicit ranges start small and grow. **Scaling** is how a given generator turns that size into a concrete length or magnitude.

A **filter** (`.filter {…}`) keeps only values that satisfy a predicate. Exhaust tunes the generator toward valid values rather than generating and discarding, so a sparse constraint stays practical.

## Screening

Because a generator is inspectable, Exhaust can read its parameters and their domains. It uses this to build a catalogue of **problematic values**: the values bugs are known to cluster around. What counts as problematic depends on the type. Range limits and the steps either side of them for integers. NaN, the infinities, and values near the edges of representable precision for floats. Daylight-saving transitions and epoch points for dates. Troublesome Unicode scalars for characters. Lengths 0, 1, 2, and the range's lower bound for collections.

**Screening** is the systematic exercise of these values. If a generator has two parameters, each with its own problematic values, Exhaust tries every pair: each problematic value from the first parameter combined with each problematic value from the second, at least once, budget allowing. Empirical studies find that around 70% of reported defects are triggered by one or two conditions acting together (Kuhn and Reilly, 2002). An overflow that needs one parameter at its maximum and another above zero surfaces the moment that pair is tried together, and stays hidden while they vary one at a time.

## The default search: #exhaust

`#exhaust` is the workhorse. Give it a generator and a property and it runs the property across hundreds of inputs, in two phases.

```swift
  func myDistance(_ a: Double, _ b: Double) -> Double {
      abs(a - b)
  }

  #exhaust(#gen(.double(), .double())) { a, b in
      #expect(myDistance(a, b) >= 0)
  }
  
  // Abbreviated result
  
  Property failed (iteration 1/200)
  Counterexample:
    (
      -inf,
      -inf
    )
```

Screening comes first. Before any random sampling, Exhaust tries the problematic-value combinations described above.

**Random sampling** follows. Once the screening budget is spent, Exhaust draws from the generator's natural distribution, exercising random, varied inputs. Screening and sampling have separate budgets. At the default `.standard` budget you get 200 of each.

A run that finds no failure in either phase passes. The moment either phase produces a failure, Exhaust stops searching and starts reducing.

## Reduction

Finding a failure is only half the search. The other half is **reduction**. The first failing input is often noisy, full of values that aren't relevant to the failure itself. Reducing that input to a **minimal counterexample**, the simplest version that still triggers the failure, is what makes the underlying bug visible.

Reduction is automatic. You never write a reduction function. The reducer runs the property against smaller and smaller candidates, keeping a change only if the property still fails, until nothing it tries makes the input simpler.

Because it understands how the parts of an input relate, it can delete an element, collapse nested structures, drive a number toward zero, or move magnitude between coupled values. <doc:HowReductionWorks> walks through a complete example.

## What makes it work: inspectable generators

All of this rests on one design choice: an Exhaust generator is an inspectable data structure, not an opaque closure. Exhaust can look inside it and read its parameters, its branches, and their domains. This capability is **inspection**, and it is what powers everything else. Screening reads a generator's parameters to find their domain's problematic values. Filter tuning tweaks its branching points. Reduction operates on the recorded choices rather than the output value.

Because the generator is data, Exhaust can run it more than one way. There are three modes. **Generation** runs it forward to produce a value, recording each **choice** (which branch, which integer, which length) as it goes. **Replay** feeds a recorded sequence of choices back in to reproduce a value exactly. **Reflection** runs a generator backward. Given a concrete value from a bug report or another source, it recovers a usable choice tree so `#exhaust(…, reflecting:)` can start reduction from that value. `#examine` checks that generated values make a coherent reflection round-trip. Every operation on the reflected path must support reflection (see <doc:BuildingGenerators#Bidirectional-transforms>). Exhaust still generates and replays values through forward-only `.map` and `.bind` operations, and reduces generated counterexamples from their recorded choices.

It helps to think of a generator as a *parser of randomness*. Forward, it parses raw randomness into a structured value. `#exhaust(…, reflecting:)` runs it backward to recover choices from a concrete value.

This design comes from reflective generators (Goldstein et al., [Reflecting on Random Generation](https://dl.acm.org/doi/10.1145/3607842)). You do not need the theory to use Exhaust, but it is there if you want it.

## Directed search: #explore

`#exhaust` searches broadly, but it cannot promise it reached any particular region of the input space. A property can pass across hundreds of inputs and still never have generated the case you were worried about. `#explore` aims to close that gap.

You give it **directions**: named predicates over the output, each describing a region you want the search to reach.

```swift
#explore(orderGen, directions: [
    ("Has refund",        { $0.hasRefund }),
    ("Refund + partial",  { $0.hasRefund && $0.fulfilment == .partial }),
]) { order in
    #expect(order.balance.isValid)
}
```

Exhaust steers toward each direction using **Choice Gradient Sampling (CGS)**: a short pass that measures which of the generator's choices lead toward a direction, then reweights the generator to favour them. If a direction is reachable, CGS makes hitting it much more likely than untuned sampling would.

If a direction turns out to be unreachable, because some constraint in the generator rules it out, Exhaust tells you. You find the gap in your generator rather than a false silence.

A direction is an active target. Its passive cousin is **classification** (`.classify(…)`), in the QuickCheck tradition, which only reports how often generated values fell into named buckets after the test run has finished.

## Searching over sequences: @StateMachine

The tools so far test pure functions: one input, one output. Stateful systems fail differently. A stack, a cache, or a connection pool can pass every single-operation test and still break under a particular ordering that leaves it in a state it should not be possible to reach. The fault is not in any one call, but in an exact series of them.

`@StateMachine` searches over sequences. You declare a **system under test** (the real implementation), a set of **commands** Exhaust may call on it, and **invariants** that must hold after every command. Exhaust generates command sequences, runs them, checks the invariants after each step, and when one breaks it reduces the sequence to the few commands that still reproduce the failure.

Invariants get much simpler if you maintain a **model**: a simpler reference implementation that the commands update in lockstep, so an invariant becomes "the system agrees with the model." The model is acting as an **oracle**, the trusted source of what the right answer is. For systems whose races hide in real threads rather than at `await` points, a separate **`@Oracle`** compares the concurrent result against a race-free sequential replay.

The execution mode (`.sequential`, `.tasks`, or `.threads`) tells Exhaust how to run the commands. `.sequential` runs commands one at a time: the right choice for testing logic. `.tasks` runs commands concurrently with deterministic interleaving at every `await`, so the same seed reproduces the same run. `.threads` hands off to real OS threads to reach races inside locks and atomics, trading reproducibility for that reach. <doc:StateMachineTesting> covers all three.

## Testing without an oracle: metamorphic testing

An oracle is not always within reach. Sometimes you cannot compute the right answer cheaply enough to check against it, or at all. Metamorphic testing is a way to test without one.

Rather than checking a single output against an expected value, you check a **metamorphic relation**: how the output should change when you transform the input in a known way. You never need to know what the output is, only how two related outputs must relate. A bug can show up as a broken relation even when neither output looks wrong on its own. Sorting twice gives the same result as sorting once. A broader search returns at least what the narrower one did. Adding background noise to audio leaves the transcription unchanged.

The `.metamorph` generator combinator builds the relation into the generator, pairing the original input with transformed copies so the property reads as a plain assertion over them. When a failure is found, the original reduces and the copies follow.

## Coverage-guided search: time budgets

> Experiment: `#explore(time:)` and `#execute(time:)` are experimental. Settings, report format, and search behaviour may change in any release.

`#exhaust` and `#explore(directions:)` run a fixed number of iterations and stop. Some bugs hide behind branches the generator's natural distribution never reaches. `#explore(time:)` takes a wall-clock **time budget** instead of an iteration count and uses code coverage as a feedback signal: when a generated input reaches a branch nothing previous has reached, that input is kept and becomes the basis for further modifications. Over time, the search accumulates a **corpus** of inputs that collectively cover more of the code under test than random sampling alone.

The search has three phases. Screening and random sampling run first, the same as `#exhaust`. Then **mutation** takes over: Exhaust modifies inputs from the corpus, keeps those that reach new branches, and discards those that don't. When the time budget runs out or new branches stop appearing, the run terminates.

Unlike `#exhaust`, a coverage-guided run does not stop at the first failure. Failures are reduced to minimal counterexamples and grouped into **fault clusters**. Two failures that reduce to the same minimal form are one cluster. The report lists each distinct fault with its reduced counterexample.

`#execute(time:)` applies the same search to `@StateMachine` specs, mutating command sequences instead of values. <doc:CoverageGuidedFuzzing> covers instrumentation setup, isolation requirements, and how to read the report.

## Reproducing a find: seeds and replay

Every failure Exhaust reports comes with a **seed**, a short code that pins where in the search the failure was found.

```
Reproduce: .replay("7MK2N9-4")
```

**Replay** re-runs the search from that seed to reproduce the counterexample. The point to hold onto is what a seed pins: a position in the search, not a fixed input.

It re-runs generation, so if you change the generator, the same seed lands on a different case. This is true of seeds in every property-based testing library. A seed is a coordinate in a search, and the search depends on the generator.

A **regression seed** is a seed pinned to a test (`.exhaust(.regressions("…"))`) so its case runs before the random search every time. While the generator is unchanged it re-tests the same case and catches that regression the moment it returns. To pin an exact input permanently, regardless of later generator changes, commit the literal value and pass it to `#exhaust(…, reflecting:)`. When you need the value itself rather than a re-run, `#example(gen, seed: "…")` extracts the input a failure seed points at.

## Glossary

### Generation

- **Choice**: a single decision a generator records as it runs (which branch, which integer, which length).
- **Choice Gradient Sampling (CGS)**: the technique that biases a generator toward a goal by measuring which choices lead toward it and reweighting them.
- **Classification**: a report of how often generated values fall into named buckets (`.classify(…)`). It observes, it does not steer.
- **Filter**: a constraint that keeps only values satisfying a predicate. Exhaust tunes the generator toward valid values rather than discarding.
- **Generator**: a description of the shape of inputs to try. The search space.
- **Scaling**: how a generator turns the current size into a concrete length or magnitude.
- **Size**: the 0 to 100 dial Exhaust ramps over a run, so values without explicit ranges start small and grow.

### The run

- **Counterexample**: an input for which the property fails. After reduction, the minimal counterexample, the simplest input that still fails.
- **Pairwise**: covering every pair of problematic values from different parameters in at least one case.
- **Problematic value**: a value bugs cluster around, from a fixed per-type catalogue (range limits for integers, NaN and the infinities for floats, daylight-saving transitions for dates, troublesome Unicode scalars for characters, short lengths for collections).
- **Property**: a claim about your code that should hold for every generated input. What `#exhaust` and `#explore` check.
- **Random sampling**: the second phase, drawing from the generator's natural distribution.
- **Reduction**: reducing a failing input to the minimal counterexample, automatically and for every type.
- **Screening**: the systematic exercise of known-problematic values at pairwise strength. Runs as the first phase of `#exhaust`, `#explore`, and coverage-guided search. Screening of the input space, not code coverage.

### Exploration

- **Direction**: a named region of the output that `#explore` steers toward via CGS.

### Coverage-guided search

- **Corpus**: the collection of inputs that reached distinct branches during a coverage-guided run. New inputs enter the corpus when they cover branches nothing previous has covered.
- **Fault cluster**: a group of failures that reduce to the same minimal counterexample.
- **Mutation**: modifying a corpus input to produce a new candidate and checking whether it reaches new branches.

### Inspection

- **Inspection**: the foundation that makes generators inspectable data structures, so Exhaust can read their parameters, branches, and domains. It powers screening, CGS, and reduction.
- **Reflection**: running a generator backward to recover the choices behind a concrete value. `#exhaust(…, reflecting:)` uses those choices to start reduction. `#examine` checks the generated-value round trip. Reflection requires bidirectional transforms.
- **Bidirectional**: a transform that supplies both directions (`mapped`, `bound`). A generator built only from these is reflectable.
- **Forward-only**: a generator that generates and reduces but cannot reflect, because it contains a one-way `.map` or `.bind`.
- **Reflection round-trip**: `#examine`'s check that a generated value reflects back to the choices that made it.

### State machine specs

- **Command**: one operation Exhaust may invoke on the SUT.
- **State machine spec**: a specification of a stateful system that Exhaust checks by generating command sequences and verifying invariants after each step.
- **Cooperative / preemptive**: the two concurrent runners. Cooperative interleaves deterministically at `await` points. Preemptive uses real threads to reach races in locks and atomics.
- **Invariant**: a property checked after every command.
- **Model**: a simpler reference implementation maintained alongside the SUT, so invariants can compare the two. This is a pattern for writing effective invariants rather than a macro.
- **Oracle**: the trusted source of the right answer a spec checks against. For `.threads` specs, the `@Oracle` method compares the concurrent end state against a sequential replay.
- **System under test (SUT)**: the real implementation a spec exercises.

### Reproduction

- **Regression seed**: a seed pinned to a test so its case runs before the random search every time.
- **Replay**: re-running the search from a seed to reproduce a counterexample.
- **Seed**: a short code that pins a position in Exhaust's search. It carries neither the value nor its choices.

### Metamorphic

- **Metamorph**: the combinator that builds a metamorphic relation into a generator.
- **Metamorphic testing**: checking a relation between related outputs instead of any single output, so you need no oracle.

### Easily confused

- **"Coverage" has several meanings depending on context.** The `#exhaust` phase that tries problematic values is called **screening**, not coverage. `#examine`'s **domain coverage** is how much of a generator's output space the samples reached. `#explore(directions:)`'s **direction coverage** is how many samples hit each direction. In coverage-guided fuzzing (`#explore(time:)`), **coverage** refers to which branches in the instrumented code each input reached.
- **"Reflection" is narrower than in most languages.** In Swift and Java, "reflection" typically means examining a value's structure at runtime. In Exhaust, inspection is the word for reading a generator's structure. Reflection means running a generator backward to recover the choices behind a concrete value. `#exhaust(…, reflecting:)` uses those choices to start reduction, while `#examine` checks the generated-value round trip.
