# Getting started with Exhaust

This is a guide for working developers who've written tests but haven't done property-based testing before. You'll already know how to write `#expect(result == expected)` for a few hand-picked inputs, and that's the foundation we're building on. 

The examples throughout are Swift Testing, which is what Exhaust integrates with most closely, but Exhaust works fine with XCTest too — the macros are the same, but `XCTAssert…`-style assertions in the property closure are not supported in the same way Swift Testing's `#expect` and `#require` are. 

The guide aims to build up the thinking that makes Exhaust pay off — how to spot properties worth testing in code you're already writing, how to write generators that produce the inputs that matter, and when to reach for each of Exhaust's tools. The tools will come up as they become useful.

## Where you are now

You have a function and you want to test it, so you write something like this:

```swift
@Test func sortingJumbledArrayResultsInAscendingOrder() {
    #expect(mySort([3, 1, 2]) == [1, 2, 3])
}

@Test func sortingReverseSortedArrayResultsInAscendingOrder() {
    #expect(mySort([5, 4, 3, 2, 1]) == [1, 2, 3, 4, 5])
}

@Test func sortingArrayWithDuplicatesResultsInAscendingOrder() {
    #expect(mySort([3, 1, 2, 1, 3]) == [1, 1, 2, 3, 3])
}
```

Three tests, all in service of the same claim: *mySort produces its output in ascending order*. Each test is a single example of that claim, exercising it from a different angle: a jumbled array, a reverse-sorted one, an array with duplicates. The test names announce the claim and the assertions supply instances. The more examples you add, the more confident you get that the implicit claim holds.

Fine as far as it goes. These tests catch regressions, document intent, and run in milliseconds — everything you want from unit tests. But they share a quiet weakness: every assertion is a hand-picked input that you thought of. The bugs you find are the bugs you imagined, and the bugs you didn't imagine (`sort` panicking on a ten-thousand-element array, mishandling negative numbers, returning the wrong thing for an empty or singleton array) sit in your code unfound until production hits the cases you missed.

Looked at from a certain angle, what you're doing with hand-picked tests is *searching* the input space for bugs. Each test case is a probe — a single point in a vast domain of possible inputs — and triangulation is just what manual search looks like when you can only afford a handful of probes. It works when bugs live in regions you think to probe, and it fails silently when they don't. Property-based testing is the same search, but mechanised: Exhaust picks the probes, covers far more of the space than you could by hand, and is willing to search systematically in regions you'd never think to look.

This guide is about how to find those bugs without having to imagine (or run into) them first.

## Examples in place of fixtures

If your existing unit tests use hand-written fixtures (mock instances of your domain types, sample users, example orders) the cheapest way to start getting value from Exhaust is to replace those fixtures with `#example`:

```swift
// Before
let user = User(id: UUID(), name: "Alice", age: 32, subscription: .premium)
#expect(process(user).isValid)

// After
let user = #example(userGenerator)
#expect(process(user).isValid)
```

Your test now runs against a generated user each time rather than a hand-crafted fixture. Strictly speaking that makes it a property test, just one with a sample size of 1. After all, your assertion is being checked against a generated input instead of a hand-picked one. If you would like determinism you can also specify a `seed` to ensure the generated value is always the same, or a `count` to generate more than one. `#example` generates values at size 50 on Exhaust's 0-to-100 complexity scale — deliberately middle-of-the-road.

You're not yet getting everything Exhaust offers this way: just one input per run instead of hundreds, and if the test fails you'll see the whole random value that triggered it rather than a minimal counterexample. Those benefits come with the next step up, when you move the assertion inside an `#exhaust` call.

The immediate win is time. Mock instances of rich domain types are tedious to write and tedious to maintain as those types evolve. `#example(userGenerator)` replaces all of that with a single line. A side benefit is that every run exercises your function on data the fixture-writing habit would probably never have picked — the cases you didn't think to write down.

## The smallest useful test you can write

If you'd rather add a new test than modify an existing one, here's the cheapest new test you can write. Pick a function that takes some structured input, and pick the most pessimistic property you can imagine: that it doesn't crash and it doesn't throw an unexpected error.

```swift
@Test func parserDoesntCrashOrThrowUnexpectedly() {
    let generator = #gen(.string())

    #exhaust(generator) { input in
        do {
            _ = try parse(input)
        } catch is ParseError {
            // expected: malformed input is allowed to throw a ParseError
        } catch {
            throw error  // anything else fails the test
        }
    }
}
```

This is a real, useful test, and it's about twelve lines of code. It'll catch overflows, regex catastrophic backtracking, infinite loops, out-of-memory errors on degenerate input, encoding bugs on emoji and combining characters, surrogate-pair mishandling, and unexpected exception types leaking out of the parser. 

`.string()` produces values across the breadth of Unicode, so the test exercises far more of the input space than any hand-picked set of strings you'd come up with on your own. You don't need a fancy property, you don't need a custom generator, and you don't need to understand the theory — any of that can come later if you decide you want more out of PBT than this.

This is the entry point. Everything from here on is about getting more value from the same basic shape: a generator, a property, and `#exhaust` to run them together.

## Look at your existing tests first

Before reaching for new conceptual machinery, have a look at the unit tests you've already written, because each one is a property in disguise. A unit test asserts that *one* input produces *one* output, but you didn't pick that input at random — it's an instance of a more general claim you were really making, and the claim is usually more interesting than the instance.

Take a test like this:

```swift
@Test func myClampWithinRange() {
    #expect(myClamp(5, in: 0...10) == 5)
}
```

Ask yourself what the actual claim was. You picked `5` as an example, but the claim wasn't really about `5`. It was about what `myClamp` does to any value with respect to the range `0...10`. The function should leave values that are already inside the range alone, and pull values outside the range back to the nearest bound. 

There are a few claims bundled up in that description, and we'll sharpen them later. For now, the simplest piece to lift out is that across the whole input space, the output always lands inside the range. That's a property you can check directly:

```swift
@Test func myClampStaysInRange() {
    let generator = #gen(.int(in: -100...100))

    #exhaust(generator) { value in
        let result = myClamp(value, in: 0...10)
        #expect(result >= 0 && result <= 10)
    }
}
```

You haven't invented anything here. You've just written down what the original test was implicitly claiming, in a form Exhaust can check across the whole input space rather than at one hand-picked point. The unit test asserted the claim held at `5`. The property asserts it holds for any value `#exhaust` draws from the generator, which is a much stronger statement for roughly the same amount of effort.

This is the cheapest source of property tests you have. Every existing unit test is a question of the form *what general claim is this specific assertion an instance of?* The answer is almost always a property worth testing, and you're usually within sight of an `#exhaust` call once you've named it.

## Look at your specs and docs next

The second-cheapest source of properties is the prose you've already written about the system. Code review comments, design documents, PR descriptions, ticket acceptance criteria, sentences from a domain expert — anywhere someone has written down a constraint of the form *for all X, Y must hold*, or one of its many disguised forms: *every order with discounted line items has a total above zero*, *the cache never returns stale data after invalidation*, *withdrawing more than the balance is rejected*.

Each such sentence is a property in disguise, and the work is to notice the universal quantifier (*every*, *all*, *never*, *always*) and turn the constraint into an assertion Exhaust can check against generated input. You're not coming up with the property. The spec already defined it. You're just translating it from English into Swift.

The two on-ramps complement each other: unit tests are specific assertions you can generalise, prose contains general claims you can make concrete. Either route gets you to the same destination, and most real codebases have more of both than you'd expect. If you can't find properties from either source, the next section is about recognising them from scratch.

## Stop describing outputs and start describing properties

Instead of writing assertions about *specific* outputs, you start writing assertions about *every possible* output.

The previous two sections gave you the easy cases: properties that were already written down somewhere, either implicit in a unit test or explicit in a spec, and just needed translating into Swift. This section is about the harder case, which is recognising properties from scratch when no test or document contains them in half-finished form. 

Examples come naturally when you think about a function: *I called it with `this` and I got `that` back.* Properties ask you to step back from the example and articulate the shape of what's true regardless of input — another way of thinking about the same code. 

If this feels harder than writing a unit test, that's because it is: identifying properties is a skill that takes practice, and struggling with it the first few times doesn't mean you're missing something obvious. The patterns below are scaffolding for that practice — a handful of shapes that come up often enough that pattern-matching against them will usually reveal a property worth writing.

For sort, you might say:

> Whatever I sort, the result has the same elements as the input.
> 
> Whatever I sort, the result is in ascending order.
>
> Whatever I sort, the result has the same length as the input.

These are *properties*. None of them mentions a specific input. Each describes what must be true for *all* inputs. They're the same kind of statement you'd already write in a docstring or a code review comment ("this function preserves length"), except now they're checked against a huge range of inputs by the library, instead of sitting in prose as a claim that nobody verifies.

The skill, then, is recognising properties in the things you'd otherwise put in comments. A few patterns to look for:

**Roundtrips.** "If I encode a value and then decode the result, I get the value back." For any serialiser, parser, encrypter, compressor, or encoder. Almost always present, almost always worth checking.

**Doing the same thing twice changes nothing** (sometimes called *idempotence*). "If I do this operation twice, the second time changes nothing." Validation, normalisation, sanitisation, deduplication, sorting, formatting.

**Invariants on the output.** "The output of `sort` is always sorted." "The output of `myDedupe` has no duplicates." "The output of `myClamp` is in range." Things the function exists to guarantee.

**Something is preserved**. "The sum is preserved." "The element count is preserved." "The set of keys is preserved." Whatever the operation rearranges, something usually doesn't change.

**Relationships between operations.** "`length(reverse(xs))` equals `length(xs)`." "`first(sort(xs))` equals `min(xs)`." Cross-checks where two operations agree about something.

These are already in your code as comments, README claims, and "the function should…" sentences in PR descriptions. The work is to write them down as assertions.

### A trap to avoid: don't replicate the implementation

Before naming the trap, it helps to name the principle the trap ignores: 

> Checking an answer is almost always cheaper than computing it. 

Verifying that an array is sorted is a single linear scan, whereas sorting it is the whole problem. Verifying that a number is prime takes one division loop, but finding all primes up to N takes a sieve. Verifying that a parser produced valid JSON takes a schema check, but writing the parser is the work itself. 

The function you're testing already computes the answer. Your property's job is to *check* it, to state a constraint the answer satisfies, and checking is a different (and usually simpler) activity than computing.

The trap is what happens when you reach for computing instead of checking. Faced with a function and asked to write a property, the natural instinct is to write a second version of the function and assert the two versions agree:

```swift
// Don't do this.
@Test func fibonacciIsCorrect() {
    func referenceFibonacci(_ n: Int) -> Int {
        if n < 2 { return n }
        var (a, b) = (0, 1)
        for _ in 2...n { (a, b) = (b, a + b) }
        return b
    }

    let generator = #gen(.int(in: 1...30))

    #exhaust(generator) { n in
        #expect(fibonacci(n) == referenceFibonacci(n))
    }
}
```

On the surface this looks rigorous — you're checking that your code agrees with another hand-written source of truth. Underneath, though, **the code and the test will change together**. When you fix a bug in `fibonacci` you'll almost certainly update `referenceFibonacci` at the same time, because you'll notice they disagree and your instinct will be to make them agree. 

When you misunderstand the function's contract, you'll misunderstand it the same way in both implementations: if you think Fibonacci starts at `F(0) = 1` when it actually starts at `F(0) = 0`, both functions will reflect that mistake and the test will happily pass. 

The two sides of the equality are coupled through a shared mental model, and a test that's coupled to the thing it's testing can't reveal bugs in that thing — it can only tell you when your two copies of the thing have drifted apart, which is only rarely the bug you were looking for.

The fix is to apply the following principle: *check, don't compute*. 

What constraint does the output of `fibonacci` have to satisfy that you can verify without recomputing it? For Fibonacci, the defining recurrence is right there — each value equals the sum of the two before it.

```swift
@Test func fibonacciSatisfiesRecurrence() {
    let generator = #gen(.int(in: 2...30))

    #exhaust(generator) { n in
        #expect(fibonacci(n) == fibonacci(n - 1) + fibonacci(n - 2))
    }
}
```

The property doesn't know how `fibonacci` is implemented, and it doesn't have to. A bug in `fibonacci` can't hide in the property, because the property describes a constraint the output has to satisfy independently of the code that produced it. 

Whenever you catch yourself writing a second version of the function inside the property, stop and ask what claim about the *output* you could check more cheaply than recomputing the answer.

### A related trap: properties that are too weak

Here's the opposite failure mode: you write a property the function actually satisfies, and it holds up against hundreds of generated inputs. It feels like a solid test… but a buggy implementation would *also* pass it.

Think back to the `myClamp` property from earlier: *the output is always inside the range*. That's true of `myClamp`, certainly, but it's also true of an implementation that ignores the input entirely and returns `lowerBound` every time. Or one that returns `upperBound` every time. Or the midpoint. 

The property isn't wrong. `myClamp` genuinely produces outputs in the range, but it doesn't fully describe `myClamp`'s behaviour. It checks only *that* the output is somewhere in the range, leaving *which* value in the range the output is for a given input entirely unconstrained. "Which value" is the whole job of `myClamp`.

The sharpening test is to ask: *can I imagine a broken implementation that would satisfy this property?* If you can, the property is too weak, and the bug lives in the gap between what the property says and what the function actually promises. A stronger property pins `myClamp` down by branch:

```swift
@Test func myClampBehavesCorrectlyOnEachBranch() {
    let generator = #gen(.int(in: -100...100))

    #exhaust(generator) { value in
        let result = myClamp(value, in: 0...10)

        if value < 0 {
            #expect(result == 0)
        } else if value > 10 {
            #expect(result == 10)
        } else {
            #expect(result == value)
        }
    }
}
```

Three claims now, one per branch of the function's behaviour. An implementation that always returns `0` fails the branch for values above the range. An implementation that returns the input unchanged (forgetting to clamp entirely) fails both outer branches. An off-by-one at the boundary fails one branch or the other depending on direction. 

The property still doesn't mention an implementation, but it says enough about the output to constrain correct implementations uniquely.

That question — *can I imagine a broken implementation that would satisfy this?* — is worth keeping in mind whenever you write a property. A yes means there's a stronger property waiting to be written.

## A generator and a property: the smallest useful PBT

Once you have a property, you need a *generator* — something that produces the inputs to test the property against. Generators describe the shape of input you want. Exhaust draws many examples from them and runs your property on each. At its simplest:

```swift
@Test func sortPreservesLength() {
    let generator = #gen(.int(in: -1000...1000).array(length: 0...100))

    #exhaust(generator) { xs in
        #expect(sort(xs).count == xs.count)
    }
}
```

That's the entire shift. You've gone from one example to many: Exhaust now generates hundreds of arrays, runs `sort` on each, and asserts that length is preserved every time. If any input violates the property, you get a counterexample for free.

**The smallest useful PBT skill is just this.** Pick a property you'd be willing to write in a code comment, pick a generator that produces inputs of the right type, and run them together with `#exhaust`. That's it — you're now testing your function against a much wider set of inputs than you could ever hand-pick.

It's worth running this against code you already trust, just to see what happens. You'll find yourself surprised how often a "this can't fail" function fails on an empty array, on an array of all-equal elements, on negative integers, or on an array of length one. These are real bugs, found by a property you would have written in a comment anyway.

## How `#exhaust` searches the input space

`#exhaust` does more than random sampling. Every run moves through phases, and each one does a different job.

**Coverage sampling.** Before random sampling starts, Exhaust systematically exercises the boundary values most likely to cause bugs. What counts as a boundary depends on the type: min and max (plus one off each) for signed and unsigned integers; NaN, infinities, and `ulpOfOne` for floating-point types; DST transitions and timezone edges for dates; the set of lengths 0, 1, 2, and the range's lower bound (filtered to whichever fit the permitted range) for collections. 

The catalogue encodes the kinds of bugs each type is known for — the sort of thing a seasoned developer has learned to check for by hand over a career of finding them the hard way. These boundary values are drawn in combinations at pairwise coverage by default, so any bug that surfaces when two parameters hit their boundaries simultaneously gets caught without your having to remember to test the combination yourself. 

Generators with very small domains get enumerated exhaustively as a special case.

**Random sampling.** Once coverage is done, the sampler turns to the generator's natural distribution, testing the property against varied, ordinary inputs. Coverage and sampling have separate budgets. At the default `.expedient` budget you get 200 of each, so a property runs 400 times per invocation in total. Larger budgets (`.expensive`, `.exorbitant`) scale both numbers in lockstep.

**Reduction.** The moment any phase produces a failing input, `#exhaust` switches from searching for failures to making the failure it found useful to you. Reduction works across every dimension of the input at once: it deletes elements from sequences, collapses recursive structure, swaps between branches, drives numeric values toward their simplest form, redistributes magnitude between coupled parameters, and reorders siblings into a natural reading order. 

Big structural simplifications tend to happen first, because they shrink the counterexample fastest. Value minimisation happens late, once the structure has settled. The result is the smallest, simplest input the reducer can find that still triggers the failure — the counterexample format you've seen already in the `myDedupe` example, with a `Reduction diff` showing the path from the first failing input to the minimum.

The first two phases search for bugs. The third makes the bugs actionable. A property that passes all three means *no failures in the coverage budget, no failures in random sampling, and nothing for reduction to simplify*. A failure in either of the first two triggers the third automatically.

## Reading a failure report

When reduction finishes, Exhaust reports the minimal counterexample it arrived at. Here's what one looks like — say you've written a `myDedupe` function that should remove consecutive duplicate elements from an array, leaving one of each, and a property to go with it:

```swift
@Test func myDedupePreservesDistinctElements() {
    let generator = #gen(.int(in: 0...10).array(length: 0...20))

    #exhaust(generator) { xs in
        #expect(Set(myDedupe(xs)) == Set(xs))
    }
}
```

The property might fail on an eight-element input like `[3, 7, 7, 0, 7, 1, 1, 4]`, but that's not what gets reported. The reducer shrinks it first, and you see this instead:

```
   Counterexample:
     [
       [0]: 0,
       [1]: 0
     ]
   
   Reduction diff:
       [
     -   [0]: 3,
     -   [1]: 7,
     -   [2]: 7,
         [0]: 0,
     -   [4]: 7,
     +   [1]: 0,
     -   [5]: 1,
     -   [6]: 1,
     -   [7]: 4
       ]
Expectation failed: (Set(myDedupe(xs)) → []) == (Set(xs) → [0])
```

Now you can see it. `myDedupe` is incorrectly clearing the array when every element is a duplicate, instead of leaving one of each. The `Counterexample` block shows the reduced input — two zeros — and the `Reduction diff` shows how Exhaust got there, stripping elements away until only the two needed to trigger the bug remain. You can paste the counterexample straight into a unit test as a regression: it's the minimal input that demonstrates the bug, and the failure message tells you exactly what went wrong.

A habit worth forming: when a property test fails, don't reach for the debugger immediately. Read the reduced counterexample first, because it may just give you a direct route to the answer.

When you want to lock in a specific failing case as a permanent regression, Exhaust exposes a Swift Testing trait that attaches seeds to a test:

```swift
@Test(.exhaust(regressions: "1A", "2A"))
func myDedupePreservesDistinctElements() {
    // ...
}
```

Each string replays a specific reduced counterexample. The random distribution still runs, but these particular cases run before it every time.

By default, `#exhaust` and `#explore` record failures as Swift Testing issues via `Issue.record`, so they surface in the test runner alongside any `#expect` failures. If you need to assert on the result of the run yourself — checking that a property fails in a particular way, say — there's a way to suppress that reporting and inspect the return value directly.

Exhaust is single-threaded within a test. This is because test suites will usually run tests in parallel. Property closures are required to be `@Sendable` so there is less risk of confounding results or bugs caused by shared state.

Property closures can be async, throwing or return a simple boolean.

## Writing your own generators

Built-in generators (`.int()`, `.array()`, `.string()`, and their siblings) are simple enough. Generators compose together in ways that let you express almost any generator you could care to think of.

```swift
struct Order {
    let id: UUID
    let items: [LineItem]
    let total: Double
}

let generator = #gen(
    .uuid(),
    lineItemGenerator.array(),
    .double()
) { id, items, total in
    Order(id: id, items: items, total: total)
}
```

The shaping question for a generator is *what values does my code accept?* The production distribution of values is a separate question, and the two often have very different answers. A sort function accepts any `[Int]`. Whether the arrays it happens to see in production are short and positive is beside the point, because the contract says any `[Int]` and the bugs you're trying to find live somewhere in the full domain the function claims to handle. 

A generator narrowed to "typical production inputs" is really a generator that only tests inputs a bug would already have had to survive to reach production.

What counts as "the contract" is usually right there in the signature — specifically in the *input type*, which is a separate question from whatever validation the function does to the values once it has them. `parse()` takes any `String`, and one of your generators should produce any `String`, including malformed ones, because the parser's rejection behaviour is as much under test as its happy path. A validator on `addUser(name:age:)` should see ages well outside `0...150`, so the property can assert the out-of-range cases are handled the way the function claims to handle them.

The generator only narrows when the input type itself rules out the invalid values. `myClamp` can't be called with a malformed range because `ClosedRange` won't let you construct one — the type has done the validation already, and the generator has to match what it permits. The bound comes from what the function can structurally *be called with*. Informal notions of "valid" or "sensible" input don't apply — if the signature permits it, the generator should produce it.

Exhaust will ramp from simple to complex inputs within the bounds you declare. The bounds themselves just have to match what the function has agreed to handle.

### Valid by construction

Whatever structure the acceptance set has, the generator should encode it so every value it produces is well-formed by construction. The alternative is filtering inside the property body with `guard` or a precondition, and that path has two problems: it wastes time generating inputs you immediately throw away, and it tends to silently over-constrain what you do test.

The myClamp property from earlier is a good example. If you wanted to vary the range rather than fixing it at `0...10`, you'd need bounds where `lowerBound ≤ upperBound`. The tempting shape is to generate two independent integers and add a `guard lo <= hi else { return }` inside the property body, but that's wasting half your test budget on inputs you discard. A better approach is to generate a length-2 array of integers and sort it inside the `#gen` closure:

```swift
let generator = #gen(
    .int().array(length: 2),
    .int()
) { bounds, value in
    let sorted = bounds.sorted()
    return (range: sorted[0]...sorted[1], value: value)
}
```

Now every value drawn from this generator is well-formed by construction. The `lowerBound ≤ upperBound` constraint is a fact about the generator's output rather than a filter in the property body. Notice what the generator deliberately *doesn't* do: it keeps `value` independent of the range. The principle is to encode the structure that's really there in the input domain, and to leave alone whatever isn't.

Exhaust's character and string generators accept a `CharacterSet`, so you can specify exactly which characters will be generated. `.asciiString()` gives you ASCII-only out of the box, and a specific `CharacterSet` gives you any discontiguous alphabet you need, like alphanumerics plus `@` and `.` for email-shaped strings, say.

When a property body reaches for `guard` to skip inputs, that's almost always a signal that the generator should be producing better-shaped inputs. The constraint has to live somewhere — the question is whether it lives in the generator (where it shapes what gets tested) or in the property body (where it silently discards inputs after the fact).

## When the generator can't reliably reach what you need: `#explore`

Eventually you'll have a property and a generator and a niggling suspicion: *I think there might be a bug when the order has both a refund and a partial fulfilment.* 

You write the property and run `#exhaust`. It tries the property against hundreds of generated orders, and they all pass. You're not reassured, though, because you don't actually know whether the bug isn't there or whether the generator just never produced an order with both conditions.

This is the moment for `#explore`. It lets you declare *the questions you want the test to answer* as named predicates, and Exhaust guarantees that each question is actually asked:

```swift
@Test func ordersBalanceCorrectly() {
    let generator = #gen(
        .uuid(),
        lineItemGenerator.array(),
        .double()
    ) { id, items, total in
        Order(id: id, items: items, total: total)
    }

    #explore(generator,
        directions: [
            ("has refund",          { $0.hasRefund }),
            ("partial fulfilment",  { $0.fulfilment == .partial }),
            ("refund + partial",    { $0.hasRefund && $0.fulfilment == .partial }),
            ("over $1000",          { $0.total > 1000 }),
            ("single line item",    { $0.items.count == 1 }),
        ]
    ) { order in
        #expect(order.balance.isValid)
    }
}
```

Each direction is a question, and Exhaust's job is to answer all of them. It doesn't do this by brute-force filtering — generating thousands of inputs and keeping only the ones that match a direction would hang the test on rare conditions. 

Instead, it uses *choice gradient sampling*: the generator is really a sequence of decisions (which enum case, which integer from a range, which length for an array), and Exhaust runs a short sampling pass to learn which decisions lead toward a direction and which lead away. That pass produces a reweighted generator, biased toward the direction, and the actual test run then uses that biased generator normally. 

Each direction gets its own tuning pass and its own biased generator.

At the default `.expedient` budget, the property runs on 30 examples per direction, and the report tells you which directions got exercised and whether any of them failed. If "refund + partial" turns out to be infeasible under your generator — because some constraint in the generator rules it out — the sampler exhausts its tuning budget without getting close, and `#explore` tells you the direction was unreachable. You find the bug in your generator instead of getting a false silence.

The `#explore` skill is recognising the moment when your worry shifts from "does the property hold?" to "is the property even being tested in the cases I care about?" The first question is `#exhaust`'s job; the second is `#explore`'s.

A few signs you've crossed into `#explore` territory:

- You're tempted to write `if order.hasRefund && order.fulfilment == .partial { ... }` as a precondition inside the property. (Don't — declare it as a direction instead.)
- `#exhaust` tried hundreds of inputs and nothing failed, but you're still not sure why.
- You're writing a comment in the test that says "this also covers the X case" without any way to verify
- You can articulate the regions of the input space where bugs might live, even if you can't enumerate the bugs themselves

## When the bug is in a sequence of operations: `@Contract`

Everything above this point has been about pure functions — feed in an input, check the output. A lot of real code isn't shaped like that, though. Some bugs only show up after a particular sequence of operations on a stateful object: you can insert fine, delete fine, lookup fine, but do `insert(x); delete(x); lookup(x)` in order and the object is left in a state it shouldn't be reachable to. No single operation is buggy in isolation. The bug lives in the interaction.

Exhaust has a separate facility for this kind of testing, built around a `@Contract` macro. You declare a struct that describes the system under test (`@SUT`), an inventory of operations Exhaust is allowed to invoke (`@Command`), and a set of invariants that must hold after every operation (`@Invariant`). Optionally, you can also declare a reference model (`@Model`) that commands update alongside the real system. Invariants can then check the real system against the model as an oracle. Either way, Exhaust generates sequences of operations and runs them against the system, reporting when an invariant breaks (or when the model and SUT disagree, if you've provided a model). The shape looks like this:

```swift
@Test func specHolds() {
    #exhaust(Spec.self, commandLimit: 8)
}

@Contract
struct Spec {
    @SUT var sut = MyType()
    @Command mutating func op() { /* mutate sut */ }
    @Invariant func holds() -> Bool { /* check sut */ }
}
```

It's an advanced capability with its own document. The point here is just to know it exists. If you find yourself trying to bend `#exhaust` into testing a collection of operations over time, or generating an array of actions and applying them one by one in a loop, reach for `@Contract` instead — that's what it's there for.

## The tools, in summary

Here's when each tool is the right answer:

**`#example(generator, count: n)`**. *Create instance(s) of the generator's output*. Use this to avoid having to manually construct test data, or even to inspect the output of your generator.

**`#examine(generator)`**. *Validate that values from this generator round-trip correctly.* Run it once on each custom generator you write to confirm reduction will behave as expected.

**`#exhaust(generator) { value in ... }`**. *Run the property against a wide distribution of inputs*, with deterministic coverage of structural choice points and reduction on failure. This is the workhorse. Use it for properties that should hold across the generator's natural distribution.

**`#explore(generator, directions: [...]) { value in ... }`**. *Guarantee that each declared region of the input space gets exercised.* Use it when you can name the regions you care about and want assurance they were tested, and reach for it when `#exhaust` passes too easily for comfort.

**`@Contract`**. *Test stateful systems across sequences of operations.* Reach for it when the bug you're worried about lives in the ordering or combination of several calls rather than in any single call. Its own document covers the mechanics.