Notes on Test-Case Reduction
============================

Attention Conservation Notice: Niche, somewhat poorly organised.

Epistemic Status: Reasonably confident that following this advice is better than trying to figure things out on your own, as it’s the distillation of about four years of work in the subject, but much of it is unvalidated and individual bits may be suboptimal.

* * *

There’s a lot of knowledge in my head about test-case reduction that doesn’t as far as I know exist anywhere else, as well as plenty that exists in maybe two or three other people’s heads but isn’t written down anywhere. I thought I would write some of it down.

What is test-case reduction?
----------------------------

Test-case reduction is the process of taking some value (a test case, usually represented as a sequence of bytes, though in property-based testing land it can be an arbitrary value) that demonstrates some property of interest (usually that it triggers a bug in some program) and turning it into a smaller and simpler test case with the same property.

This is boring to do by hand, so we generally want to have tools that do this for us – test-case reducers. When I say test-case reduction in this post I will generally mean this form of automated test-case reduction done by such a reducer.

Test-case reduction is sometimes called test-case minimization, or shrinking. I prefer the test-case reduction terminology and will use that in this post, but they’re all the same thing.

Generally speaking test-case reduction is _black box_. You have some oracle function that e.g. runs the software and sees if it crashes and returns yes or no. You may understand the format of the test cases (e.g. [C-Reduce](https://embed.cs.utah.edu/creduce/) and [Conjecture’s shrinker](https://github.com/HypothesisWorks/hypothesis/blob/master/hypothesis-python/src/hypothesis/internal/conjecture/shrinker.py) are the two most sophisticated test-case reducers I know of and they both make _extensive_ use of the fact that they can understand the format), and you may have a _little_ visibility of what the oracle is doing (Conjecture tracks the API the oracle uses to access the data and uses that to guide the reduction), but you definitely don’t have anything like a detailed understanding of the grammar that leads to the property of interest.

Why do we want to do test-case reduction? Roughly three reasons:

1.  Smaller examples are nicer for everyone concerned, computer and human alike. They run faster, are easier to read, and if you need to report them as upstream bugs probably don’t have any incriminating data about your internal software and IP.
2.  Test-case reduction helps to _[normalize](https://www.cefns.nau.edu/~adg326/issta17.pdf)_ bugs – if you have a thousand bug reports then you don’t really want to triage that. Many of those bugs will become the same after reduction, reducing your workload
3.  The knowledge that a test-case is reduced tells you what is essential about it. Although it may not be the smallest value that demonstrates the bug, every feature of it is in some way essential – you can’t just delete a bit and expect it to work. This significantly aids the developer in localizing the fault.

A fourth reason that I think is underexplored is that test-case reduction is [really good at finding bugs](https://blog.regehr.org/archives/1284). I’d like to do some more work on this, and have found at least one probably-security bug in a widely deployed piece of software through this (I reported it upstream years ago and it’s fixed in the latest version, but I won’t say what). I’ll ignore this use case for now, as it’s a bit non-central – generally reducers work well for this when they’re failing to achieve the actual desired goal of test-case reduction.

Importantly, none of these reasons require the reducer to do a perfect job – for the third one it has to do a _comprehensible_ job (i.e. you only know what details are essential if you know what details the reducer can remove), but beyond that every little bit helps – a reducer that is not very good is still better than nothing, and incremental improvements to the reducer will result in incrementally better results.

This is good, because doing test-case reduction perfectly is basically impossible. Because of the black-box nature of the problem, almost all test-case reduction problems can only be solved perfectly with an exponential search.

Instead essentially every test-case reducer is based on a form of _local search_ – rather than trying to construct a minimal example from scratch, we make simplifying transformations to the known initial example that try to make it smaller and simpler. We stop either when the user gets bored or when no further transformations work.

This approach dates back to Delta Debugging from Hildebrant and Zeller’s classic paper on delta debugging, [Simplifying and Isolating Failure-Inducing Input](https://www.cs.purdue.edu/homes/xyzhang/fall07/Papers/delta-debugging.pdf). Delta-debugging takes test cases that are a sequence of some form and tries to find a test case that is _one-minimal_ – i.e. such that removing any single element of the sequence loses you the property of interest. It has a bunch of optimisations on top of the naive greedy algorithm, but I think these are mostly the wrong optimisations. The sequence reducer we use in Hypothesis that I’ll talk a little bit about later shares almost nothing in common with delta debugging other than the basic greedy algorithm.

Due to this lineage, Regehr et al. in the C-Reduce paper “[Test-Case Reduction for C Compiler Bugs](http://faculty.pucit.edu.pk/faisal/cs545/papers/4.pdf)” refer to these local search based approaches as _generalised delta debugging_. I’m just going to refer to them as local search.

All of the best reducers are highly specialised to a particular category of test case, with a lot of elaborate local search procedures designed to work around particular difficulties. Writing such a reducer is inevitably a lot of work, but even simple reducers can be worthwhile. In this post I hope to give you some general lessons that will help you either work on an existing reducer or write your own simple ones (I don’t especially encourage you to write your own complicated one, though I’d love to hear about it if you do).

Good Oracles are Hard to Find
-----------------------------

The oracle for a test-case reduction problem is the predicate that takes a test case and determines if it is interesting or not. Writing an effective oracle is surprisingly tricky due to two basic problems: _Test-case validity_ and _slippage_.

The test-case validity problem is when you have some oracle whose domain doesn’t contain all of the values that the reducer might want to try, and its behaviour is incorrect outside of that domain. For example, suppose you had a test that compiles a program with multiple different optimisation levels and asserts the outputs of running the compiled programs are all the same. This is a perfectly good oracle function, but a C program that it accepts only corresponds to a compiler bug if it does not execute any undefined behaviour. Thus when doing reduction you might start with a legimate bug but turn it into a C program that executes undefined behaviour and thus still satisfies the oracle but is no longer a bug. You could mitigate this by using a semantics checking interpreter that first checks if the program executes any undefined behaviour, but that’s expensive.

The problem of _slippage_ is when your oracle function is too broad and thus captures bugs that are not the ones you intended. Suppose your oracle just checked if the program crashes. In the course of reduction you might find an entirely different (possibly easier to trigger) crash and move to that one instead.

There are a number of mitigation strategies I use for this in Hypothesis. The main ones are the following:

1.  The oracle functions we use are always “An exception of this type is thrown from this line”. This is reasonably robust to slippage.
2.  Because of how we apply test-case reduction, any reduced example is one that could have been generated, so we can only reduce to invalid examples if we could have generated invalid examples in the first place. This makes it much easier for users to fix their tests by adding preconditions when this happens.
3.  We record all successful reductions and when we rerun the test we replay those reductions first. This means that if we slipped to a different bug or an invalid test at some point and that has been fixed (either by fixing the bug or the test), we don’t lose our previous work – we just resume from the point at which the slippage occurred.

Because of this I’m going to ignore these problems for the rest of this post and just assume that the oracle function is fixed and known good.

Reduction Orders
----------------

An approach that is slightly idiosyncratic to me is that I like to make sure I have a _reduction order_ – some total order over the test cases such that given any two distinct test cases we consider the smaller value in this order to be better than the other.

It’s more normal for this to be a preorder, where two distinct values can be either unrelated or equally good. The most common choice for this preorder is just that you measure the size of the test case in some way and always prefer smaller test cases.

Some reducers (e.g. QuickCheck) do not have any defined order at all. I think this makes it hard to reason about the reducer and easy to introduce bugs when writing it, so I dislike this.

The reason I prefer to have a total order is that it makes it much easier to determine when a test-case reducer is making progress, and it is helpful for the purposes of test-case normalization because it means that any oracle has a canonical best solution (the minimal test case satisfying the oracle) so perfect normalization is possible at least in principle even if we can’t necessarily find it.

The order I almost always use for test cases represented as sequences of bytes is the _[shortlex order](https://en.wikipedia.org/wiki/Shortlex_order)_. There are specific reasons that this is a good choice for Hypothesis, but I think it works pretty reasonably in general – certainly you want to always prefer shorter test cases, and among test cases of the same size having a reasonably local and easy to reason about order matters more than what that order actually is.

As Alex Groce points out in the comments, [TSTL](https://github.com/agroce/tstl) also effectively uses the shortlex order for its normalization, and the proof of termination in “[One Test to Rule Them All](https://www.cefns.nau.edu/~adg326/issta17.pdf)” relies on this. In the papers terminology the two concepts are split, with reduction referring to reducing the length and normalization referring to canonicalization operations that decrease the test-case lexicographically while keeping the length fixed. I tend not to separate the two and refer to the whole process as test-case reduction, as they tend to be very intertwined (especially with Hypothesis’s autopruning, which I will explain below, which means that even operations that look like “pure normalization” can have dramatic effects on the size of the test case).

Caching and Canonicalization
----------------------------

Oracle functions are often expensive, and natural ways of writing test-case reducers will often try invoking it with the same value over and over again. It can be very useful to cache the oracle function to reduce the cost of re-execution. Almost all test-case reducers do this except for ones based on QuickCheck’s approach which sadly can’t due to limitations of the API and its generality (essentially the problem is that you can generate and reduce values which you can’t compare for equality).

As well as all the usual difficulties around caching and invalidation (Hypothesis currently ignores these by just not invalidating the cache during reduction, but I need to fix this), there are a number of things that are peculiar to test-case reduction that are worth noting here.

The first is that if you can assume that your reducer is greedy in that it only ever considers values which are smaller than the best test case you’ve seen so far, you don’t actually need to cache things, you just need to record whether you’ve seen them at all – you can assume that if you’ve seen a value before and it’s not your current best value then it must not be interesting. This allows you to use a more efficient data structure like a [bloom filter](https://en.wikipedia.org/wiki/Bloom_filter). This can be very helpful if your test cases are large or you try a lot of them during reduction. [theft](https://github.com/silentbicycle/theft) is the only implementation I’m aware of that does this. You could adapt this to non-greedy reducers by having two levels of caching: One that contains all known good examples, and a bloom filter for all known bad examples. I’ve never seen this done but it would probably work well.

The second thing you can do is canonicalization. You may have access to e.g. a formatter that will transform your test case into a canonical form (of course, the formatting might itself break the property. This implicitly turns your oracle into the oracle “the formatted version of this satsisfies the original oracle”, but that’s probably fine). You can now do the calculation in two stages: First look up your test case in the cache. If you get a cache miss, canonicalize it and look that up in the cache. If that’s still a cache miss, run the oracle. Either way, update the cache entry for both the original and canonicalized form. I’m not sure if anyone does this – I’ve done it in some experimental reducers, and Hypothesis does something like it but a bit more complicated (canonicalization happens as a side effect of test execution, so it can’t run it without executing the test, but does update the cache with the canonical version as well as the non-canonical one) – but it works pretty well.

Keeping Track of the Best Example
---------------------------------

The way I design reducers is that there is a single object that manages the state of reduction. It exposes a function, say test\_oracle, which handles the caching as above.

What it _also_ does is that whenever it runs the actual oracle and the result is interesting, if the test case in question is better than the best it’s seen so far, it updates its best known example. This is part of why having a defined reduction order is helpful.

The reason this is useful is because it is often helpful to make decisions based on the result of the oracle function (e.g. for adaptive searches). It can be an annoying amount of book-keeping to make sure you keep everything updated correctly, and this nicely automates that.

This is also useful because (especially if you save it externally somewhere – Hypothesis has an example database, file-based reducers might have a testfile.best copy on disk or something) it means that your reducer is automatically an [anytime algorithm](https://en.wikipedia.org/wiki/Anytime_algorithm) – that is, you can interrupt it at any point and get its current best answer rather than losing all your work.

Cost of Reduction
-----------------

The cost measure I tend to design around is the number of oracle invocations. This is an _extremely_ crude measure and I ignore it where useful to do so.

The only actual cost that matters is of course wall clock runtime. The problem with this is that it tends to be almost entirely dependent on the vagaries of the oracle function – it could have essentially arbitrary complexity (exactly the same reducer will have very different timing profiles if the oracle is quadratic vs linear), or you could be regularly hitting a timeout bug that you aren’t interested in, or just about anything else. It’s a black box, it can do whatever it wants.

The most common thing that you see in practice is that the oracle gets _much_ faster when the reducer has been running for a while, because it tends to be very fast to run small examples and very slow to run large examples, even if smaller changes don’t necessarily have as predictable effects. As a result, I tend to design reducers to actually prioritise _progress_ over performance. e.g. the sequence reducer that we use in Hypothesis can technically make up to twice as many oracle calls as an alternative design in some circumstances, but has a huge benefit of avoiding stalls – long periods where many oracle invocations are made and none of them return true so the reducer fails to make any progress.

An additional benefit of making progress is that it tends to make future attempts to reduce cheaper – e.g. if you’ve successfully deleted some data, the test case is now smaller, so there are fewer transformations you need to make.

A minor side benefit of prioritising progress is that it makes the reducer’s progress much more fun to watch.

Reduction Passes
----------------

Most non-trivial reducers are organised into _reduction passes_. A reduction pass is basically just a specialized reducer that does one sort of operation – e.g. you might have a reduction pass that deletes values, and a separate reduction pass that moves them around.

There’s nothing logically special about reduction passes – they’re just functions – but they do seem to be a common and useful way of organising test-case reducers.

The big question when you organise your reducer this way then becomes: What order do you run the reduction passes in?

Generally the goal is that by the end of the reduction process you want your best test case to be a fixed point of every reduction pass – none of them can make progress – but that gives you a lot of freedom about which to run when, and that seems to make a huge difference for a couple of reasons:

1.  Some reduction passes are much more expensive than others (e.g. constant time vs linear vs quadratic), so it makes sense to run them once the example is already small.
2.  Often one pass will _unlock_ another, allowing a previously stuck pass to make progress.
3.  Some passes will substantially increase the cache hit rate on later runs, which can have a large performance impact.

Current pass ordering schemes are a bit ad hoc and not very well justified. I’m not sure anyone really knows how to do this well, including me. This is a good area for research (which I’m doing some of).

That being said I’m reasonably sure the following things are true:

1.  You should run at least some other passes before you rerun a pass – a pass that has just run is much less likely to make good progress the second time you run it.
2.  It’s worth having a pass that is primarily designed to promote cache hits run fairly early on (e.g. Hypothesis has an alphabet\_minimize reduction pass, which tries to bulk replace all bytes of the same value with smaller ones, for this purpose).
3.  It can be worth deprioritising passes that don’t seem to do anything useful.
4.  You should try to put off running quadratic or worse passes for as long as you possibly can (Ideally don’t have them at all or, if you do, do whatever you can to get the constant factors way down). They are often best treated as “emergency passes” that only run when all of the fast passes get stuck.
5.  In general it is worth running passes which will reduce the size of the test case before passes that won’t, and among those passes you should generally prefer to run cheaper ones earlier.

Reduction Pass Design
---------------------

The way I write them, a reduction pass is basically just a function that takes a starting test case and calls the oracle function with a number of other test cases (reductions). After that the best one will have been updated, or it won’t and thus the pass is currently at a fixed point.

The questions worth asking about a reduction pass are then basically:

1.  What reductions does it try when…
    *   The pass fails to reduce the current best test case?
    *   The pass successfully reduces the current best test case?
2.  What order does it try them in?

The answer to these questions matters a lot – the reductions you try have a big impact on the cost of reduction and the quality of the final result, and the order can have a big impact on progress (and thus implicitly on the cost of reduction. Where it affects the quality of the result it’s usually by accident).

The question of what reductions to try depends a lot on what you’re trying to do, but generally speaking I find it’s best to make reduction passes that try at most an \\(O(1)\\) number of big changes (e.g. replacing a number with \\(0\\)) and at most \\(O(n)\\) small changes (e.g. trying subtracting one from every number, deleting every element).

The reason the questions of which operations to run differs based on whether the pass successfully reduces if you’ve successfully reduced then you know the pass will be run again before the reducer stops, so you can rely on that next run for ensuring any properties you wanted the pass to ensure. Thus you have a fair bit of freedom to do whatever you want, and can skip things that seem unlikely to work. The book-keeping doesn’t have to be too precise.

One useful rule of thumb is that when you have successfully reduced something you should try other similar reductions before moving on to the next thing. In particular it is useful to run _adaptive algorithms_ – ones which try to turn small reductions into much larger ones. e.g. when you successfully delete something, try deleting progressively larger regions around it using an exponential probe and binary search. This can often replace \\(O(n)\\) oracle invocations with only \\(O(\\log(n))\\).

One big advantage of this approach of avoiding big operations but using adaptive versions of small operations is that you get most of the benefits of large operations but don’t have to pay their cost. In the case where no or few reductions are possible, delta debugging will make up to twice as many calls as a more naive greedy algorithm, while the adaptive algorithm will make exactly the same number.

It should be noted that the opposite is also true when delta debugging makes progress – the adaptive algorithm may make twice as many calls for some easy to reduce examples. The difference is that both it and delta debugging are only making \\(O(\\log(n)\\) calls in this case, so the slow down is less noticeable. It’s also not hard to create examples that are pathological for either algorithm, but the common case is the more interesting one, and in general it seems to be common that delta debugging quickly slows down compared to the adaptive or greedy algorithms.

The question of what order to run operations in is tricky and probably deserves its own entire article, but a short version:

*   It’s often a good idea to run the reductions in a random order. The reason for this is that it gets a good trade off between progress and cost – larger reductions are great for reducing cost but they often don’t work. Smaller reductions are more likely to work but if you only make small reductions you’ll take forever to progress.
*   When you do make progress you should try to avoid doing things that look too much like things you’ve already tried this pass. e.g. a common mistake is that when trying to delete elements from a sequence you start again at the beginning when you’ve deleted one. This is a great way to turn a linear time pass into a quadratic time one.
*   In general it is better to run dissimilar operations next to eachother. For example in a quadratic pass that tries each pair of indices it is better to run in order (0, 1), (1, 2), …, (0, 2), (1, 3), … than it is to run as (0, 1), (0, 2), …, (1, 2), (1, 3), …. The latter order is much more likely to make progress early on because it spreads out each index across the whole iteration so you don’t get long stalls where one index just doesn’t work at all.

A nicely illustrative (and well commented) example of all of these principles is [Hypothesis’s sequence deletion algorithm](https://github.com/HypothesisWorks/hypothesis/blob/master/hypothesis-python/src/hypothesis/internal/conjecture/shrinking/length.py).

Salient features are:

*   Indices are deleted in a random order.
*   When an index is deleted we try to binary search to expand this into an entire surrounding interval that can be deleted.
*   We never try to delete the same index more than once in a given run, even when we’ve made changes that would in principle allow it to be possible.

Another common pattern that is useful when doing this sort of thing is to loop over a varying list with an index into it. For example a simpler deletion algorithm would try deleting the element at index i and if that fails, increment i. In this loop either the index can increase or the length can decrease. If we never succeed, we’ve attempted to delete every element of the list. If we do succeed, we didn’t retry the elements earlier in the list but that’s OK because the pass will run again.

Stopping Conditions
-------------------

Because a reducer’s task is essentially unbounded (strictly it is finite, but in practice the number of shorter smaller strings than a typical test case exceeds the number of atoms in the universe), one important design consideration is when to stop reducing – you can’t hope to stop reducing when you’ve got the optimal answer, because even when you have it you can’t verify that it’s optimal.

The natural stopping point for local search based approaches is that you stop when all of the reduction passes fail to make progress and you’re at a local minimum.

Other common stopping criteria are:

*   When the user tells you to stop (which is part of why the anytime nature of reduction is useful).
*   After you have performed N oracle invocations.
*   After some time limit has passed.
*   After you have successfully reduced the test case N times.

The latter condition is the one Hypothesis uses – after it has successfully reduced the test case 500 times it stops reduction. I think this approach originally comes from QuickCheck. It’s a slightly non-obvious condition but generally works pretty well. The reasoning is basically that if you’re making a lot of successful shrinks then the shrinks you’re making must be relatively small, which means you’re probably stuck in a zig zagging pattern (I’ll expand on these below) and could be here a while if you actually waited for the reducer to finish. Because in Hypothesis you will often have a user sitting there waiting on the end result, it’s better to terminate early.

It’s generally rare for Hypothesis to hit this limit in practice these days – the current pass selection is very good at adapting to the shape of the test case so tends to turn small shrinks into large shrinks unless it’s working on a very large test case. Generally when we find cases where it hits the limit we’ll fix the shrinker by adding or improving a reduction pass.

Having these early stopping conditions slightly ruins the utility of reduction for highlighting necessary features of the reduced test cases, because you no longer have the guarantee that the final test case is fully reduced, but is something of a necessary evil – it’s much better to return a suboptimal but still good result in a reasonable amount of time than it is to wait on getting a perfect result.  

Better Reduction through (Bad) Parsing
--------------------------------------

A big obstacle to test-case reduction is that often the transformations you want to make don’t work not because of something related to the property of interest but because there’s some more basic validity constraint on the test cases you need. For example, suppose we were trying to delete a byte at a time using delta debugging or a sequence reducer like Hypothesis’s. This would work fine for some formats, but what if we were trying to reduce C or some other language where braces and brackets have to balance? We would never be able to remove those braces because you have to remove the balanced pair simultaneously.

Misherghi and Su pointed out in “[HDD: Hierarchical Delta Debugging](http://www.gmw6.com/docs/hdd-icse06.pdf)” that you can solve this problem if you have a formal grammar for the language of valid test cases, by using the grammar to suggest reductions. This observation is very sensible and reasonable and went on to have approximately zero users ever because it’s really annoying to get a good formal grammar for test cases and nobody ever bothered to do the work to make it usable. This may be changing as there is now [picireny](https://github.com/renatahodovan/picireny), which I haven’t tried but looks pretty good.

However there’s a much simpler variant of this, which starts from the observation that this works even if you don’t have a fully blown grammar for the format but just have some bad guesses about what it might look like.

For example, a classic observation is that delta debugging makes much more sense if you run it line oriented rather than byte oriented. You “parse” the file into a series of lines and then run the reducer on that sequence. You can do this just as well with any other separator you liked – spaces, arbitrary bytes, repeated tokens, etc. – and it works pretty well as a set of reduction passes.

You can also e.g. guess that it might be a brace oriented language and try balancing braces and see if it works. If it does, try doing what you would have done with a proper grammar (e.g. remove the contents of the braces, remove the entire region, just remove the braces and leave their contents intact).

I’ve yet to turn many of these observations into anything I’d consider a production ready test-case reducer, but I’ve done enough experimentation with them to know that they work pretty well. They’re not _perfect_ – some formats are hard to reduce without knowing a fair bit about them – but they’re surprisingly good, particularly if you take a lot of different bad parses and use each of them as a separate pass.

More generally, a philosophy of taking a guess and see if it works seems to play out pretty well in test-case reduction, because the worst case scenario is that it doesn’t work and you wasted a bit of time, and often it’s possible to make quite good guesses.

Another advantage of the “bad parsing” approach is that you can often make changes that just happen to work but don’t necessarily correspond to grammatically sensible transformations.

This works particularly well if you have multiple different ways of parsing the data – e.g. Hypothesis has some reduction passes that work using the underlying token structure of its representation, and some that work on the higher level hierarchical structure. Many of the lexical reductions are boundary violating (e.g. Hypothesis can reduce the nested list \\(\[\[0, 1\], \[2, 3\]\]\\) to \\(\[\[0, 1, 2, 3\]\]\\) by deleting data in a region that cuts across a hierarchical boundary. Similarly you can imagine doing this on the text form by deleting the two innermost brackets which don’t correspond to a balanced pair). Switching between different viewpoints on how to parse the data gives you the ability to define fairly orthogonal reduction passes, each of which can perform transformations that the other would miss.

Misc Details
------------

Here are some additional useful details that didn’t fit anywhere else.

### Autopruning  

A thing that has proven _phenomenally_ useful in Hypothesis is autopruning. By the nature of the problem in Hypothesis, you can determine how much of the test case is used. This lets you replace any successful test case with a potentially much shorter prefix by pruning out the unused bits. This happens automatically whenever you call the test function.

I don’t know how broadly applicable this is. Certainly it’s easy to implement without that tracking – every time you successfully reduce the test case, try replacing it with a prefix – first delete the last byte and if that works try binary searching down to some shorter prefix. I suspect this is more useful in Hypothesis’s application than anywhere else though.

### Pessimistic Concurrency

An approach I haven’t personally used yet but is found in Google Project Zero’s [halfempty](https://github.com/googleprojectzero/halfempty) is _pessimistic concurrency_. C-Reduce uses [a similar strategy](https://blog.regehr.org/archives/749).

Essentially the idea is to adopt a parallelisation strategy that assumes that the result of the oracle is almost always false. When you invoke the test oracle and miss the cache, rather than running the oracle then and there you just return false (i.e. pessimistically assume that the reduction didn’t work) and carry on. You then schedule the real oracle to run in parallel and if it happens to return true you either rerun the pass or restart the reduction process from that successful reduction.

I suspect this approach interacts badly with some of my opinions on reducer design – in particular what I actually observe when watching reduction run is not that success is unlikely but that there are long periods of mostly failure and modest periods of mostly success. I imagine one can adapt this to choose between sequential and parallel modes appropriately though.

I need to look into this area more. I haven’t so far because Python is terrible at concurrency so it hasn’t really been worth my while in Hypothesis, but I’m doing some experiments with a new file-based test case reducer where I’ll probably implement something like this.

### Zig Zagging

This is an interesting thing I have observed happening. It’s reasonably well [explained in this Hypothesis pull request](https://github.com/HypothesisWorks/hypothesis/pull/1082).

The problem of zig zagging occurs when a small change unlocks a small change unlocks another small change etc. This is particularly pernicious when the small change is not one that changes the size of the example, because it can put you into exponential time failure modes.

The example in the issue is when you have a test that fails if and only if \\(|m – n| \\leq 1\\). Each iteration of reduction will either reduce \\(m\\) or \\(n\\) by \\(2\\), and so you end up running a total of \\(m + n\\) reductions.

Hypothesis solves this by noticing when the example size isn’t changing and looking for the byte values that are changing and trying to lower them all simultaneously. It handles this case very well, but it’s not a fully general solution.

### Backtracking

One of the big questions in test-case reduction is whether you want to backtrack – that is, rather than constantly be trying to reduce the current best example, is it sometimes worth restarting reduction from a larger starting point.

The reason this might be worth doing is that often larger examples are easier to reduce and will get you to a nicer local minimum. One example of backtracking might be running a formatter. For example, suppose you had a pass that could delete single lines, and you had the code ‘while(true){print(“hello”);}’ and wanted to reduce with respect to there being an infinite loop. Your line based reducer can’t do anything about this because it’s all on a single line and you have to retain the loop, but if a formatter ran and put the print in its own line then you’d have increased the size of the test case, but once you’ve run the line based pass you’ll have decreased it.

A classic approach here is related to the earlier observation about bad parsing and languages with braces, which is the use of [topformflat](https://manpages.debian.org/jessie/delta/topformflat.1.en.html) to make files more amenable to delta debugging. topformflat doesn’t _usually_ increase the size of the file, but it’s at best a lateral move.

C-Reduce currently uses these sorts of backtracking moves fairly extensively – it applies topformflat, but it also e.g. inlines function calls which may be a significant size increase.

At the moment Hypothesis does not do any sort of backtracking. I keep toying with the idea, but inevitably end up coming up with purely greedy approaches that solve the problem that I have at the time better than backtracking would. One of the big differences here though is that Hypothesis has to run in much shorter time periods than C-Reduce does, so frequently even if it would be worth adding in backtracking it may not be worth the extra wait for the user

Conclusion
----------

This was mostly a grab bag of stuff, so I don’t know that I really have a conclusion, except that I think test-case reduction is really interesting and I wish more people worked on it, and I hope this post gave you some sense of why.

If you’d like to learn more, I’d recommend starting with [the Conjectureshrinker](https://github.com/HypothesisWorks/hypothesis/blob/master/hypothesis-python/src/hypothesis/internal/conjecture/shrinker.py) from Hypothesis. You might also find it useful to look [through the relevant issues and pull requests](https://github.com/HypothesisWorks/hypothesis/issues?utf8=%E2%9C%93&q=label%3Ashrink-quality+), which I try to make sure are well explained and often have good discussion and commentary.

This suggestion isn’t just personal bias – along with C-Reduce, Conjecture is easily in the top two most sophisticated examples of test-case reducers you’re likely to find (I genuinely can’t think of any other examples that come even close to being comparable). The two are quite different, and studying C-Reduce is also a worthwhile activity, but the advantages of starting with Hypothesis is that it’s much smaller, much better commented, not written in Perl, and that you will make me happy by doing so.