# 128

# Parsing Randomness

## HARRISON GOLDSTEIN,University of Pennsylvania, USA

## BENJAMIN C. PIERCE,University of Pennsylvania, USA

```
Random data generators can be thought of as parsers of streams of randomness. This perspective on generators
for random data structures is established folklore in the programming languages community, but it has never
been formalized, nor have its consequences been deeply explored.
We build on the idea offreer monadsto developfree generators, which unify parsing and generation using
a common structure that makes the relationship between the two concepts precise. Free generators lead
naturally to a proof that a monadic generator can be factored into a parser plus a distribution over choice
sequences. Free generators also support a notion ofderivative, analogous to the familiar Brzozowski derivatives
of formal languages, allowing analysis tools to “preview” the effect of a particular generator choice. This gives
rise to a novel algorithm for generating data structures satisfying user-speci"ed preconditions.
```
```
CCS Concepts:•Software and its engineering→General programming languages.
```
```
Additional Key Words and Phrases: Random generation, Parsing, Property-based testing, Formal languages
```
ACM Reference Format:
Harrison Goldstein and Benjamin C. Pierce. 2022. Parsing Randomness.Proc. ACM Program. Lang.6, OOPSLA2,
Article 128 (October 2022), 25 pages.https://doi.org/10.1145/

### 1 INTRODUCTION

“A generator is a parser of randomness...” It’s one of those observations that’s totally puzzling
right up to the moment it becomes totally obvious: a random generator—such as might be found in
a property-based testing tool like!"#$C%&#$[Claessen and Hughes 2000]—is a transformer from
a series of random choices into a data structure, just as a parser is a transformer from a series of
characters into a data structure.
While this connection may be obvious once it is pointed out, few actually think of generators
this way. Indeed, to our knowledge the framing of random generators as parsers has never been
explored formally. The relationship between these fundamental concepts deserves a deeper look!
We focus on generators written in themonadicstyle popularized by the!"#$C%&#$library,
which that build random data structures by making a sequence of random choices; those choices
are the key. Traditionally, a generator makes decisions using a stored source of randomness (e.g., a
seed) that it consults and updates whenever it must make a choice. Equivalently, if we like, we can
pre-compute a list of choices and pass it in to the generator, which gradually walks down the list
whenever it needs to make random decisions. In this mode of operation, the generator is effectively
parsing the sequence of choices into a data structure!

```
Authors’ addresses:Harrison Goldstein, University of Pennsylvania, Philadelphia, PA, USA, hgo@seas.upenn.edu;Benjamin
C. Pierce, University of Pennsylvania, Philadelphia, PA, USA, bcpierce@cis.upenn.edu.
```
Permission to make digital or hard copies of part or all of this work for personal or classroom use is granted without fee
provided that copies are not made or distributed for pro"t or commercial advantage and that copies bear this notice and
the full citation on the "rst page. Copyrights for third-party components of this work must be honored. For all other uses,
contact the owner/author(s).
©2022 Copyright held by the owner/author(s).
2475-1421/2022/10-ART
https://doi.org/10.1145/

```
Proc. ACM Program. Lang., Vol. 6, No. OOPSLA2, Article 128. Publication date: October 2022.
```
```
This work is licensed under a Creative Commons Attribution 4.0 International License.
```

```
128:2 Harrison Goldstein and Benjamin C. Pierce
```
```
FreeGenerators
```
```
Parser + Randomness = Generator
```
```
1."Ageneratorisaparser
ofrandomness."
```
```
2.FreeGeneratorDerivatives
```
```
3.ChoiceGradientSampling
```
```
Fig. 1. Our contributions.
```
To connect generators and parsers, we intro-
ducefree generators, syntactic data structures that
can be interpreted aseithergenerators or parsers.
Free generators have a rich theory; in particular,
we can use them to prove that a large class of
random generators can be factored into a parser
and a distribution over sequences of choices.
Besides clarifying folklore, free generators ad-
mit transformations that do not exist for standard
generators and parsers. A particularly exciting
one is a notion ofderivativewhich modi"es a
generator by asking the question: “what does this
generator look like after it makes choice𝑐?” The
derivative previews a particular choice to deter-
mine how likely it is to lead to useful values.
We use derivatives of free generators to tackle
a well-known problem—we call it thevalid gen-
eration problem. The challenge is to generate a
large number of random values that satisfy some
validity condition. This problem comes up often
in property-based testing, where the validity con-
dition is the precondition of some functional spec-
i"cation. Since generator derivatives give a way
of previewing the effects of a particular choice,
we can usegradients(derivatives with respect to a
vector of choices) to preview all possible choices
and pick a promising one. This leads us to an ele-
gant algorithm that takes a free generator and replaces its distribution with one that produces only
valid values. Replacing the distribution in this way trades the bene"ts of the programmer’s tuning
effort for a higher chance of "nding valid inputs to test with.
In § 2 below, we introduce the ideas behind free generators and the operations that can be de"ned
on them. We then present our main contributions:

- We formalize the folklore analogy between parsers and generators usingfree generators,a
    novel class of structures that make choices explicit and support syntactic transformations (§ 3 ).
    We use free generators to prove that any "nitely supportedmonadic generatorcan factored
    into a parser and a distribution over strings.
- We exploit free generators to transport an idea from formal languages—theBrzozowski
    derivative—to the context of generators (§ 4 ).
- To illustrate the potential applications of these formal results, we present an algorithm that
    uses derivatives to turn a naïve generator into one with a different distribution, assigning
    nonzero probability only to values satisfying a Boolean precondition (§ 5 ). Our algorithm
    performs well on a set of simple benchmarks, in most cases producing more than twice as
    many valid values as a naïve “rejection sampling” generator in the same amount of time (§ 6 ).

We conclude with related and future work (§ 8 and § 9 ).


```
Parsing Randomness 128:
```
### 2 HIGH-LEVEL STORY

```
To set the stage, let’s clarify the speci"c formulations of generators and parsers that we plan to
discuss. Consider the following programs:
genTreeℎ=
ifℎ= 0 then
returnLeaf
else
𝑐←frequency[( 1 ,False),( 3 ,True)]
if𝑐==Falsethen returnLeaf
if𝑐==Truethen
𝑥←genInt()
𝑙←genTree(ℎ− 1 )
𝑟←genTree(ℎ− 1 )
returnNode𝑙𝑥𝑟
```
```
parseTreeℎ=
ifℎ= 0 then
returnLeaf
else
𝑐←consume()
if𝑐==lthen returnLeaf
if𝑐==nthen
𝑥←parseInt()
𝑙←parseTree(ℎ− 1 )
𝑟←parseTree(ℎ− 1 )
returnNode𝑙𝑥𝑟
else fail
```
```
The program on the left,genTree, generates random binary trees of integers like
```
```
Node Leaf 5 Leaf and Node Leaf 5 (Node Leaf 8 Leaf),
```
```
up to a given heightℎ, guided by a series of weighted random Boolean choices made usingfrequency.
Each time the program runs, it produces a random tree—i.e., the program denotes a distribution
over trees. Generators like these can describe arbitrary "nitely supported distributions of values.
The program on the right,parseTree, parses a string into a tree, turning
```
```
n5llintoNode Leaf 5 Leaf and n5ln8llintoNode Leaf 5 (Node Leaf 8 Leaf).
```
It consumes the input string character by character withconsumeand uses the characters to decide
what to do next. This program is deterministic, but its execution (and thus the "nal tree it produces)
is guided by a string of characters it is passed as input. Parsers like these can parse arbitrary
computable languages.
These two programs are nearly identical in structure, and both produce the same set of values.
The main difference lies in how they make choices: ingenTreebranches are taken at random,
whereas inparseTreethey are controlled by the input string.
This is the key observation that links generators and parsers. To make it more concrete, let us
imagine how to recover the distribution ofgenTreeℎfromparseTreeℎ. We can do this by choosing
a string at random and then parsing it—if we choose strings with the correct distribution, then the
result of parsing those strings into values will be the same as if we had rungenTreein the "rst
place.
Here, we want the distribution over strings given toparseTreeto satisfy the weighting of the
Boolean choices ingenTree. That is,nshould appear three times more often thanl, sinceTrueis
chosen three times more often thanFalse.

```
Free Generators.With these intuitions in hand, let’s connect parsing and generation formally.
First, we unify random generation with parsing by abstracting both into a single data structure;
then we show that a structure of this form can be viewed equivalently as a generator or as a parser
and a source of randomness.
```

```
128:4 Harrison Goldstein and Benjamin C. Pierce
```
```
Our unifying data structure is called afree generator.^1 Free generators are syntactic structures
that can be interpreted as programs that either generate or parse. For example:
```
```
fgenTreeℎ=
ifℎ= 0 then
returnLeaf
else
𝑐←pick[( 1 ,l,returnFalse),( 3 ,n,returnTrue)]
if𝑐==Falsethen returnLeaf
if𝑐==Truethen
𝑥←fgenInt()
𝑙←fgenTree(ℎ− 1 )
𝑟←fgenTree(ℎ− 1 )
returnNode𝑙𝑥𝑟
```
The structure of this program is again very similar to that ofgenTreeandparseTree. The call to
pickon line 5 combines ideas from both the generator (capturing the relative weights ofFalseand
True) and the parser (capturing the labelslandncorresponding to different paths in the parser
code). However, the meaning offgenTreeis very different from that of eithergenTreeorparseTree.
The operators infgenTreeare entirely syntactic, and the result of runningfgenTreeℎis simply an
abstract syntax tree (AST).
The syntactic nature of free generators means that they can simultaneously represent generators,
parsers, and more. In § 3 we give several ways to interpret free generators. We writeG$·%for the
random generator interpretationof a free generator andP$·%for theparser interpretation. In other
words,

```
G$fgenTreeℎ%≈genTreeℎ and P$fgenTreeℎ%≈parseTreeℎ.
The interpretation functions walk the AST produced byfgenTreeto recover the behavior of the
generator and parser programs.
These two interpretations can be related, formally, with the help of one "nal interpretation
function,R$·%, therandomness interpretationof the free generator. The randomness interpretation
produces the distribution of sequences of choices that the random generator interpretation makes.
Now, for any free generator𝑔, we have
P$𝑔%〈$〉R$𝑔%≈G$𝑔%
```
where〈$〉is a “mapping” operation that applies a function to samples from a distribution (see
Theorem3.1below). Since a large class of generators (monadic generators with a "nitely supported
distribution) can also be written as free generators, another way to read this theorem is that such
generators can be factored into two pieces: a distribution over choice sequences (given byR$·%),
and a parser of those sequences (given byP$·%).
This precisely formalizes the intuition that “A generator is a parser of randomness.” But wait,
there’s more to come!

```
Derivatives of Free Generators.Since a free generator de"nes a parser, it also de"nes a formal
language: we writeL$·%for thislanguage interpretationof a free generator. The language of a
free generator is the set of choice sequences that it can parse.
```
(^1) This document uses theknowledgepackage in LATEX to make de"nitions interactive. Readers viewing the PDF electronically
can click on technical terms and symbols to see where they are de"ned in the document.


```
Parsing Randomness 128:
```
```
Viewing free generators this way suggests some interesting ways that free generators might
be manipulated. In particular, formal languages come with a notion ofderivative, due to Brzo-
zowski [Brzozowski 1964]. Given a language𝐿, the Brzozowski derivative of𝐿with respect to a
character𝑐is
𝛿𝑐L𝐿={𝑠|𝑐·𝑠∈𝐿},
```
```
that is, the set of all strings in𝐿that start with𝑐, with the "rst𝑐removed.
We can apply the same intuition to parsers by considering the derivative of a parser with respect
to𝑐to be whatever parser remains after𝑐has been parsed. Each consecutive derivative "xes certain
choices within the parser, simplifying the program:
parseTree10 =
𝑐←consume()
if𝑐==lthen
returnLeaf
if𝑐==nthen
𝑥←parseInt()
𝑙←parseTree 9
𝑟←parseTree 9
returnNode𝑙𝑥𝑟
else fail
```
```
𝛿nL(parseTree10)≈
```
```
𝑥←parseInt()
𝑙←parseTree 9
𝑟←parseTree 9
returnNode𝑙𝑥𝑟
```
```
𝛿 5 L𝛿nL(parseTree10)≈
```
```
𝑙←parseTree 9
𝑟←parseTree 9
returnNode𝑙 5 𝑟
```
```
The "rst derivative "xes the charactern, ensuring that the parser will produce aNode. The next
"xes the character 5 , which determines the value 5 in the "nalNode.
Free generators have a closely related notion ofderivative, illustrated by an almost identical set
of transformations:
fgenTree10 =
𝑐←pick[...]
if𝑐==Falsethen
returnLeaf
if𝑐==Truethen
𝑥←fgenInt()
𝑙←fgenTree 9
𝑟←fgenTree 9
returnNode𝑙𝑥𝑟
else fail
```
```
𝛿nL(fgenTree10)≈
```
```
𝑥←fgenInt()
𝑙←fgenTree 9
𝑟←fgenTree 9
returnNode𝑙𝑥𝑟
```
```
𝛿 5 L𝛿nL(fgenTree10)≈
```
```
𝑙←fgenTree 9
𝑟←fgenTree 9
returnNode𝑙 5 𝑟
```
But there is a critical difference between this series of derivatives and the ones forparseTree.
Whereas the parser derivatives we saw could be thought ofintuitivelyas a program transformation
on parsers, the analogous transformation on free generators is readily computable! Just as we can
compute the derivative of a regular expression or a context-free grammar, we can compute the
derivative of a free generator via a simple and e#cient syntactic transformation.
In § 4 we de"ne a procedure,𝛿𝑐L, for computing the derivative of a free generator and prove it
correct, in the sense that, for all free generators𝑔,

```
𝛿𝑐LL$𝑔%=L$𝛿𝑐𝑔%.
```
```
In other words, the derivative of the language of𝑔is equal to the language of the derivative of𝑔.
(See Theorem4.2.)
```

```
128:6 Harrison Goldstein and Benjamin C. Pierce
```
```
Putting Free Generators to Work.The derivative of a free generator isthe generator that remains
after a particular choice. This gives us a way of “previewing” the effect of making a choice by
looking at the generator after "xing that choice.
In § 5 and § 6 we present and evaluate an algorithm calledChoice Gradient Samplingthat uses free
generators to address thevalid generation problem. Given a validity predicate on a data structure,
the goal is to generate as many unique, valid structures as possible in a given amount of time.
Starting from a simple free generator, our algorithm uses derivatives to evaluate choices and search
for ones that produce valid values.
We evaluate the choice gradient sampling algorithm on four small benchmarks, all standard in
the property-based testing literature. For each, we compare our algorithm to rejection sampling—
sampling from a naïve generator and discarding invalid results—as a simple but useful baseline for
understanding how well or algorithm performs. Our algorithm does remarkably well on three out
of four benchmarks, generating more than double the valid values per minute of rejection sampling.
```
```
3 FREE GENERATORS
```
We now turn to developing the theory of free generators, beginning with some background on
monadic abstractions for parsing and random generation.

```
Background: Monadic Parsers and Generators.In § 2 we represented generators and parsers
as pseudo-code. Here we $esh out the details, presenting all de"nitions asH'($&))programs, both
for the sake of concreteness and also becauseH'($&))’s abstraction features (e.g., type-classes)
allow us to focus on the key concepts.H'($&))is a lazy functional language, but, as we focus our
attention on "nite programs, our results should apply directly to eager functional languages. It
may also be possible, with appropriate domain knowledge, to translate these ideas to idiomatic
constructs in popular imperative languages [Petříček 2009].
We represent both generators and parsers usingmonads[Moggi 1991]. A monad is a type
constructor (e.g.,List,Maybe, etc.)Mequipped with two operations,
return :: a→Ma
(»=) :: M a→(a→M b)→Mb
(with»=pronounced “bind”). Conceptually,returnis the simplest way to put some value into the
monad, while bind gives a way to sequence operations that produce monadic values.
We can use these operations to de"negenTreelike we would in!"#$C%&#$[Claessen and
Hughes 2000] andparseTreelike we would using libraries likeP'*(&#[Leijen and Meijer 2001]:
```
```
genTree :: Int→Gen Tree
genTree 0 =returnLeaf
genTreeℎ=do
c←frequency [(1, False ), (3, True)]
casecof
False→returnLeaf
True→do
x←genInt
l←genTree (ℎ−1)
r←genTree (ℎ−1)
return (Node l x r)
```
```
parseTree :: Int→Parser Tree
parseTree 0 =returnLeaf
parseTreeℎ=do
c←consume
casecof
l→returnLeaf
n→do
x←parseInt
l←parseTree (ℎ−1)
r←parseTree (ℎ−1)
return(Node l x r)
_→ fail
```

```
Parsing Randomness 128:
```
```
In the "rst program,genTree, we use the monadic operations (along withfrequency) to generate a
random tree of integers. The expressionreturnLeafis a degenerate generator that always produces
the valueLeaf—this is what we mean by the “simplest way to put a value into theGenmonad.”
Rather than use(»=)explicitly, we usedo-notation, where
do
a←x
fa
```
is syntactic sugar forx»= f. In the context of theGentype, this operation samples from a gen-
eratorxto get a valueaand then passes it toffor further processing—this is what we mean by
“sequencing operations.” Formally,genTreedenotes a distribution over binary trees (e.g., an arrow
in an appropriate category [Giry 1982]), and running the program samples from that distribution.
We can see these same combinators (used with a different monad) inparseTree. There,returna
means “parse nothing and producea”, andx»= fmeans “run the parserxto get a valueaand then
run the parserfa.” Under the hood, we have:

```
typeParser a = String→Maybe (a, String )
```
AParsercan be applied to a string to obtain eitherNothingorJust (a, s), whereais the parse
result andscontains any extra characters. Theconsumefunction pulls the "rst character offof the
string for inspection.

```
Expressiveness Relative to Other Abstractions.Monadic parsers and generators are maximally
expressive in their respective domains. Monadic parsers can parse arbitrary computable languages,
subsuming more restricted parser descriptions like context-free grammars and regular expressions.
Likewise, monadic generators can generate values satisfying arbitrary computable constraints (e.g.,
it is possible to write a monadic generator for well-typed System F terms), subsuming less powerful
representations like probabilistic context-free grammars.
For example, the following monadic generator generates (only) valid binary search trees:
```
```
genBST :: ( Int , Int )→Gen Tree
genBST (lo, hi) | lo > hi =returnLeaf
genBST (lo, hi) =do
c←frequency [(1, False ), (3, True)]
casecof
False→returnLeaf
True→do
x←genRange (lo, hi)
l←genBST (lo, x−1)
r←genBST (x + 1, hi)
return (Node l x r)
The generator maintains the BST invariant by keeping track of the minimum and maximum values
available for a given sub-tree and ensuring that all values to the left of a value are less and that
all values to the right of a value are greater. This kind of generator is impossible to express as
a stochastic CFG, since there is dependence between the choice of valuexand the choices of
sub-trees. Our examples are mostly focused on simple (non-dependent) generators to streamline
the exposition, but our theory applies to the full class of monadic generators with "nitely supported
distributions.
```

```
128:8 Harrison Goldstein and Benjamin C. Pierce
```
```
Representing Free Generators.With the monad interface in mind, we can now give the formal
de"nition of a free generator.^2
```
```
Type De!nition.The actual type of free generators is based on a structure called afreer monad[Kise-
lyov and Ishii 2015]:
dataFreer f awhere
Return :: a→Freer f a
Bind :: f a→(a→Freer f b)→Freer f b
This type looks complicated, but it is essentially just a representation of a monadic syntax tree. The
constructors ofFreeralign almost exactly with the monadic operationsreturnand(»=), providing
syntactic forms that can represent the building blocks of monadic programs.
An eagle-eyed reader might notice that the type ofBindhere is not quite an instance of the type
of(»=)above—one would have expected to see
Bind :: Freer f a→(a→Freer f b)→Freer f b
```
withFreer f aas the "rst argument. The version we use is equally powerful, but more convenient.
We will see in a moment that syntax trees in a freer monad are normalized by construction.
But what is going on with thisfthat appears throughoutFreer? The type constructorfis a type
ofspecialized operationsthat are speci"c to a particular monadic program. For example, programs in
theGenmonad do not just usereturnand(»=), they also use aGen-speci"c operation,frequency.
Similarly, representing aParseras a syntax tree requires a way to represent a call toconsume. In
general,fashould be a syntactic representation of an operation returninga. Thus, we might have
a type representing a parser operation that returns a character:
dataConsume awhere
Consume :: Consume Char
SinceFreeris polymorphic overf, it can capture any specialized operation necessary to represent
the syntax tree of a monad.
For free generators speci"cally, the specialized operation we need is calledpick—we saw it in
§ 2. Intuitively,picksubsumes bothfrequencyandconsume. We de"ne thePickoperation with a
data type (since free generators are syntactic objects) simultaneously with our de"nition ofFGen,
the type offree generators:
dataPick awhere
Pick :: [(Weight, Choice, Freer Pick a)] →Pick a
typeFGen a = Freer Pick a
By de"ningFGenasFreer Pick, we are really saying that “FGenis a monad with operationPick.”
ThePickoperation takes a list of triples. The "rst element of typeWeightrepresents the weight
given to a particular choice; weights are represented by signed integers for e#ciency, but for
theoretical purposes we treat them as strictly positive. The typeChoicecan theoretically be any
type that admits equality, but for the purposes of this paper we take choices to be single characters.
This makes the analogy with parsing clearer. Finally,Freer Pick ais actually just the typeFGen a!
Thus we should view the third element in the triple as anestedfree generator that is run iffa
speci"c choice is made.

(^2) For algebraists: Free generators are “free” in the sense that they admit unique structure-preserving maps to other “generator-
like” structures. In particular, theG$·%andP$·%maps are canonical. For the sake of space, we do not explore these ideas
further here.


```
Parsing Randomness 128:
```
```
Together the elements of these triples represent both kinds of choices that we have seen so
far, subsuming both the weighted random choices of generators and the input-directed choices of
parsers. Depending on our needs, we can interpretPickas either kind of choice. In the rest of the
paper, we sometimes speak of free generators “making” or “parsing” a choice, but remember that
this is really just an analogy—a free generator is simply syntax, and the interpretation comes later.
```
```
Our First Free Generator.TheFGenstructure achieves our goal of unifying monadic generation
and parsing, so let’s try writing a free generator. Following the basic structure ofgenTreeand
parseTree, we can start to de"nefgenTree:
fgenTree :: Int →FGen Tree
fgenTree 0 = Return Leaf
fgenTreeℎ= Bind
(Pick [(1, l, Return False ), (3, n, Return True )])
(𝜆c→casecof
False→Return Leaf
True→ ... )
The "rst few lines are relatively easy to translate. The height checks are all the same as before, but
now in theℎ= 0 case we produce the syntactic objectReturn Leafrather thanreturnLeaf, whose
behavior depends on a particular implementation ofreturn. Whenℎ> 0 , we useBindandPickto
specify that the generator has two choices:False(with weight 1, marked by characterl) andTrue
(with weight 3, marked byn).
But things get a bit more complicated when we get into the anonymous function passed as the
second argument toBind. In theFalsecase weReturn Leafagain, but in theTruecase the next step
should be a call tofgenInt.Wecouldlook at the de"nitions ofgenIntandparseIntto determine
the next choice, and then wecouldcreate aBindnode to make that choice, but that would be fairly
tedious to do for every choice that the generator might eventually make. In general, whileFGen
is the right type to capture free generators, its constructors are a bit cumbersome to write down
directly.
```
```
Recovering Monadic Syntax.Luckily, we can use the same monadic machinery used bygenTree
andparseTreeto make free generators much easier to write. We can de"nereturnand(»=)for
FGenas follows, allowing us to usedo-notation to write free generators:
return :: a→FGen a
return= Return
```
(»=) :: FGen a→(a→FGen b)→FGen b
Return a»= f=fa
Bind p g»= f = Bind p (𝜆a→ga»= f)
Thereturnoperator maps directly to aReturnsyntax node, but there is a bit more going on in
the de"nition of(»=). Speci"cally,(»=)normalizes the structure of the computation, ensuring that
there is always an operation at the “front.” The advantage of this is that it is always𝑂( 1 )to check if
a free generator has a choice to make. There is no need to dig through the syntax tree to determine
the next step.
Another convenient way to manipulate free generators is via an operation called called “fmap,”
writtenf 〈$〉x. Likereturnand(»=),(〈$〉)is a syntactic transformation, but intuitivelyf 〈$〉x
means “apply the functionfto the result of generating/parsing withx”. We de"ne it as:


```
128:10 Harrison Goldstein and Benjamin C. Pierce
```
```
(〈$〉) :: (a→b)→FGen a→FGen b
f 〈$〉Return a = Return ( f a)
g〈$〉(Bind p f ) = Bind p (( g〈$〉).f)
(Note that all monads have an analogous operation; this will come in handy later.)
```
```
Representing Failure. For reasons that will become clear in § 4 , it is useful to be able to represent a
free generator that can “fail.” We call the always-failing free generatorvoid, and de"ne it like this:
void :: FGen a
void= Bind (Pick []) Return
```
Any reasonable interpretation of this free generator must fail (by either diverging or returning a
signal value); with no choices in thePicklist, there is no way to get a value of typeato pass to
the second argument ofBind. Additionally, the use ofReturnas the second argument toBindis
irrelevant, since any free generator with no choices available will fail. This suggests that we can
check if a free generator is certainlyvoidby matching on an empty list of choices! InH'($&))this
is easy to do with a pattern synonym:
pa!ernVoid :: FGen a
pa!ernVoid←Bind (Pick []) _
This declaration means that pattern-matching onVoidis equivalent to matching aBindwith no
choices to make and ignoring the second argument. It is simple to de"ne a function that uses this
new pattern to check if a particular free generator isvoid:
isVoid :: FGen a→Bool
isVoid Void = True
isVoid _ = False
Whilevoidis useful as an error case for algorithms that build free generators, it would be
incorrect for a user to usevoidin a hand-written free generator. To enforce this constraint, we
de"ne a wrapper aroundPick(calledpick) that does a few coherence checks to make sure that the
generator is constructed properly:
pick :: [(Weight, Choice, FGen a)]→FGen a
pickxs =
case filter (𝜆(_, _, x)→not ( isVoid x )) xsof
ys | hasDuplicates (map snd ys)→undefined
[]→undefined
ys→Bind (Pick ys) Return
This function is partial: it yieldsundefinedif the list passed topickis invalid. (This is analogous
to raising an exception in a conventional imperative language.) The "rst line "lters out any choices
that are equivalent tovoid, since making those choices would lead to failure. The second line checks
that the user has not duplicated any of the choice labels; this would introduce a nondeterministic
choice that would complicate the interpretation considerably (see § 7 ). Finally, the third line ensures
that the generator we construct is not itselfvoid. In practice, these checks ensure that the various
interpretations of free generators presented in the remainder of this section work as intended.

```
Examples.Now that we have seen the building blocks of free generators, let’s look at a couple of
concrete examples. First, we can "nally write down an ergonomic version offgenTree:
```

```
Parsing Randomness 128:
```
```
fgenTree :: Int →FGen Tree
fgenTree 0 =returnLeaf
fgenTreeℎ=do
c←pick [(1, l,returnFalse ), (3, n,returnTrue)]
casecof
False→returnLeaf
True→do
x←fgenInt
l←fgenTree (ℎ−1)
r←fgenTree (ℎ−1)
return (Node l x r)
```
Remember, thedo-notation here is no longer sequencing generators or parsers. Instead, each line
of ado-block builds a newBindnode in a syntax tree. Similarly,returnhas no semantics, it only
wraps a value in the inertReturnconstructor. In this wayfgenTreelooks like bothgenTreeand
parseTree, but it does not behave like either (yet).
Trees are nice as a running example, but they are by no means the most complicated thing that
free generators can represent. Here is a free generator that produces random (possibly ill-typed)
terms of a simply-typed lambda-calculus:
fgenExpr :: Int →FGen Expr
fgenExpr 0 =pick[ (1, i, Lit 〈$〉 fgenInt ), (1, v, Var〈$〉fgenVar) ]
fgenExprℎ=
pick [ (1, i, Lit 〈$〉 fgenInt ),
(1, p,do{e 1 ←fgenExpr (ℎ−1); e 2 ←fgenExpr (ℎ−1);return (Plus e 1 e 2 ) }),
(1, l,do{t←fgenType; e←fgenExpr (ℎ−1); return(Lam t e) }),
(1, a,do{e 1 ←fgenExpr (ℎ−1); e 2 ←fgenExpr (ℎ−1);return (App e 1 e 2 ) }),
(1, v, Var〈$〉fgenVar) ]
StructurallyfgenExpris similar tofgenTree; it just has more cases and more choices. One stylistic
difference betweenfgenExprandfgenTreeis thatfgenExprdoes notpicka coin and use it to decide
what should be generated next; instead, it picks among a list of free generators directly. These
styles of writing free generators are equivalent.
This version of the lambda calculus uses de Bruijn indices for variables and has integers and
functions as values. This is a useful example because, while syntactically valid terms in this language
are easy to generate (as we just did), it is more di#cult to generate only well-typed terms. We will
return to this problem in § 6.

```
Interpreting Free Generators.A free generator does not do anything on its own—it is just a
data structure. To actually use these structures, we next de"ne the interpretation functions that we
mentioned in § 2 and prove a theorem linking those interpretations together.
```
```
Free Generators as Generators of Values.The "rst and most natural way to interpret a free generator
is as a!"#$C%&#$generator—that is, as a distribution over data structures. Plain!"#$C%&#$
generators ignore failure cases likevoid(they throw an error if there are no valid choices to make),
but to make things a bit more explicit for our theory we use a modi"ed generator monad:Gen⊥.
We de"ne therandom generator interpretationof a free generator to be:
```

```
128:12 Harrison Goldstein and Benjamin C. Pierce
```
```
G$·%:: FGen a→Gen⊥a
G$Void% =⊥
G$Return v% =returnv
G$Bind (Pick xs) f%=do
x←frequency (map (𝜆(w, _, x)→(w,returnx )) xs)
a←G$x%
G$fa%
```
Note that the operations on the right-hand side of this de"nition donotbuild a free generator; they
areGen⊥operations. This translation turns the syntactic formReturn vinto the semantic action
“always generate the valuev” and the syntactic formBindinto an operation that chooses a random
sub-generator (with appropriate weight), samples from it, and then continues withf.
Note thatG$fgenTreeℎ%has the same distribution asgenTreeℎ.

```
Free Generators as Parsers of Random Sequences. Theparser interpretationof a free generator views
it as a parser of sequences of choices. The translation looks like this:
```
```
P$·%:: FGen a→Parser a
P$Void% =𝜆s→Nothing
P$Return a% =returna
P$Bind (Pick xs) f%=do
c←consume
x←casefind ((== c). snd) xsof
Just (_, _, x)→returnx
Nothing→fail
a←P$x%
P$fa%
```
```
This time thedo-notation on the right hand side is interpreted using theParsermonad (as before,
de"ned asString→Maybe (a, String )). In the case forBind, the parser consumes a character
and attempts to make the corresponding choice from the list provided byPick. If it succeeds, it
runs the corresponding sub-parser and continues withf. If it fails, the whole parser fails.
Note thatP$fgenTreeℎ%has the same parsing behavior asparseTreeℎ.
```
```
Free Generators as Generators of Random Sequences. Our "nal interpretation of free generators
represents the distribution with which the generator makes choices, ignoring how those choices
are used to produce values. In other words, it captures exactly the parts of the structure that the
parser interpretation discards. We de"ne therandomness interpretationof a free generator to be:
```
```
R$·%:: FGen a→Gen⊥String
R$Void% =⊥
R$Return a% =return𝜀
R$Bind (Pick xs) f%=do
(c, x)←frequency (map (𝜆(w, c, x)→(w,return (c, x ))) xs)
s←R$x»=f%
return (c : s)
```
Again, we useGen⊥andfrequencyto capture randomness and potential failure.


```
Parsing Randomness 128:
```
```
Factoring Generators.These different interpretations of free generators are closely related to one
another; in particular, we can reconstructG$·%fromP$·%andR$·%. That is, a free generator’s
random generator interpretation can be factored into a distribution over choice sequences plus a
parser of those sequences.
To make this more precise, we need a notion of equality for generators like the ones produced
viaG$·%. We say two!"#$C%&#$generators areequivalent, written𝑔 1 ≡𝑔 2 , iffthe generators
represent the same distribution over values. This is coarser notion than program equality, since
two generators might produce the same distribution of values in different ways.
With this in mind, we can state and prove the relationship between different interpretations of
free generators:
```
```
T%&+*&, 3.1 (F'#-+*"./).Everyfree generatorcan be factored into a parser and a distribution
over choice sequences that are, together, equivalent to its interpretation as a generator. In other words,
for all free generators𝑔,
P$𝑔%〈$〉R$𝑔%≡(𝜆𝑥→(𝑥,𝜀))〈$〉G$𝑔%.
```
```
P*++0 ($&-#%.By induction on the structure of𝑔; see the Appendix for the full proof.!
```
```
C+*+))'*1 3.2.Any monadic generator,𝛾, written usingreturn,(»=), andfrequency, can be
factored into a parser plus a distribution over choice sequences.
```
```
P*++0.Translate𝛾into a free generator,𝑔, by replacingreturnand(»=)with the equivalent free
generator constructs, andfrequencywithpick. (This will require choosing labels for each choice,
but the speci"c choice of labels is irrelevant.)
By construction,𝛾=G$𝑔%.
Additionally,𝑔can be factored into a parser and a source of randomness via Theorem3.1. Thus,
(𝜆𝑥→(𝑥,𝜀))〈$〉𝛾=(𝜆𝑥→(𝑥,𝜀))〈$〉G$𝑔%≡P$𝑔%〈$〉R$𝑔%,
and𝛾can be factored as desired.!
```
```
This corollary is what we wanted to show all along. Monadic generators are parsers of random-
ness.
```
Free Generators as Formal Language Syntax. One "nal interpretation will prove useful. Thelanguage
of a free generatoris the set of choice sequences that it can make or parse. It is de"ned recursively,
by cases:
L$·%:: FGen a→Set String
L$Void% =,
L$Return a% =𝜀
L$Bind (Pick xs) f%= [ c : s | (w, c, x) ←xs , s←L$x»=f%]
This de"nition usesH'($&))’s list comprehension syntax to iterate through the large space of
choices sequences in the language of a free generator. To determine the language of aBindnode,
we look at each possible choice and then at each possible string in the languageL$x»=f%obtained
by continuing with that choice. (This recursion is well-founded as long as the language of the free
generator is "nite; by monad identitiesBind (Pick xs) f = Bind (Pick xs) Return»= f, andxis
strictly smaller thanBind (Pick xs) Return.) For each of these strings, we attach the appropriate
choice label to the front. The end result is a list of all of the sequences of choices that, if made in
order, would result in a valid output.


```
128:14 Harrison Goldstein and Benjamin C. Pierce
```
```
We can think of the result of this interpretation as the support of the distribution given byR$𝑔%.
The language of a free generator is exactly those choice sequences that the random generator
interpretation can make and the parser interpretation can parse.
```
```
4 DERIVATIVES OF FREE GENERATORS
Next, we review the notion of Brzozowski derivative from formal language theory and show that a
similar operation exists forfree generators. The way these derivatives fall out from the structure of
free generators justi"es taking the correspondence between generators and parsers seriously.
```
```
Background: Derivatives of Languages. TheBrzozowski derivative[Brzozowski 1964] of a
formal language𝐿with respect to some choice𝑐is de"ned as
𝛿𝑐L𝐿={𝑠|𝑐·𝑠∈𝐿}.^3
In other words, it is the set of strings in𝐿that begin with𝑐, with the initial𝑐removed. For example,
𝛿aL{abc,aaa,bba}={bc,aa}.
Many formalisms for de"ning languages support syntactic transformations that correspond to
Brzozowski derivatives. For example, we can take the derivative of a regular expression like this:
```
### 𝛿𝑐L,=,

### 𝛿𝑐L𝜀=,

```
𝛿𝑐Lc=𝜀 (𝑐=c)
𝛿𝑐Ld=,(𝑐≠d)
𝛿𝑐L(𝑟 1 +𝑟 2 )=𝛿𝑐L𝑟 1 +𝛿𝑐L𝑟 2
𝛿𝑐L(𝑟 1 ·𝑟 2 )=𝛿𝑐L𝑟 1 ·𝑟 2 +𝜈L𝑟 1 ·𝛿𝑐L𝑟 2
𝛿𝑐L(𝑟∗)=𝛿𝑐L𝑟·𝑟∗
```
### 𝜈L,=,

### 𝜈L𝜀=𝜀

```
𝜈Lc=,
𝜈L(𝑟 1 +𝑟 2 )=𝜈L𝑟 1 +𝜈L𝑟 2
𝜈L(𝑟 1 ·𝑟 2 )=𝜈L𝑟 1 ·𝜈L𝑟 2
𝜈L(𝑟∗)=𝜀
```
```
The𝜈Loperator, used in the “·” rule and de"ned on the right, determines thenullabilityof an
expression—whether or not it accepts𝜀. If𝑟accepts𝜀then𝜈L𝑟=𝜀, otherwise𝜈L𝑟=,.
As one would hope, if𝑟has language𝐿, it is always the case that𝛿𝑐L𝑟has language𝛿𝑐L𝐿.
```
The Free Generator Derivative. To de"ne derivatives of free generators, we "rst need a de"nition
ofnullabilityfor free generators:
𝜈:: FGen a→Set a
𝜈(Return v) = {v}
𝜈g=, (g≠Return v)
Note that this behaves a bit differently than the𝜈Loperation on regular expressions. For a regular
expression𝑟, the expression𝜈L𝑟is either,or𝜀. Here, the null check returns either,or the
singleton set containing the value in theReturnnode. That is,𝜈for free generators extracts a value
that can be obtained by making no further choices. Another difference is that, for free generators,
“can accept the empty string” and “accepts only the empty string” are equivalent statements; this
greatly simpli"es the de"nition of𝜈.

(^3) The superscriptLhighlights that is thelanguagederivative, distinguishing it from the generator derivative to be de"ned
momentarily.


Parsing Randomness 128:

To see what the derivative operation might look like, we can write down some equations that it
should satisfy, based on the equations satis"ed by regular expressions:

```
𝛿𝑐void≡void (1)
𝛿𝑐(return𝑣)≡void (2)
𝛿𝑐(pick𝑥𝑠)≡𝑥 if(𝑐,𝑥)∈𝑥𝑠 (3)
𝛿𝑐(pick𝑥𝑠)≡void if(𝑐,𝑥)∉𝑥𝑠
𝛿𝑐(𝑥»= 𝑓)≡𝛿𝑐(𝑓𝑎) if𝜈𝑥={𝑎} (4)
𝛿𝑐(𝑥»= 𝑓)≡𝛿𝑐𝑥»= 𝑓 if𝜈𝑥=,
```
The derivative of an empty generator, or of one that immediately returns a value without looking
at any input, should bevoid. The derivative ofpickdepends on whether or not𝑐is present in the
list of possible choices—if it is, we simply make the choice; if not, the result isvoid. Finally, the
equations for(»=)are based on the equation for concatenation of regular expressions, using𝜈to
check to see if the left hand side of the expression is out of choices to make.
Of course, these equations are not de"nitions. In fact, the actual de"nition of thederivativefor a
free generator𝑔is much simpler:

```
𝛿:: Char→FGen a→FGen a
𝛿𝑐(Return v) =void
𝛿𝑐(Bind (Pick xs) f ) =
casefind ((== c). snd) xsof
Just (_, _, x)→x»= f
Nothing→void
```
Since freer monads are pre-normalized, there is no need to check nullability explicitly in this
de"nition. It is always apparent from the top-level constructor (ReturnorBind) whether or not
there is a choice available to be made. The de"nition is not even recursive!
We can use the earlier equations to give us con"dence that this de"nition is correct.

L&,,' 4.1.𝛿𝑐satis!es equations ( 1 ), ( 2 ), ( 3 ), and ( 4 ). In other words, the free generator derivative
behaves similarly to the regular expression derivative.

```
P*++0 ($&-#%.See the Appendix for the proofs. Most are immediate.!
```
Another way to ensure that the derivative operation acts as expected is to see how it behaves in
relation to the free generator’slanguage interpretation. The following theorem makes this concrete:

T%&+*&, 4.2.The derivative of a free generator’s language is the same as the language of its
derivative. That is, for allfree generators𝑔and choices𝑐,

```
𝛿𝑐LL$𝑔%=L$𝛿𝑐𝑔%.
```
```
P*++0 ($&-#%.Straightforward induction (see the Appendix).!
```
Since derivatives behave as expected, we can use them to simulate the behavior of a free generator.
Just as we can check if a regular expression matches a string by taking derivatives with respect
to each character in the string, we can simulate a free generator’s parser interpretation by taking
repeated derivatives. Each derivative "xes a particular choice, so a sequence of derivatives "xes a
choice sequence.


```
128:16 Harrison Goldstein and Benjamin C. Pierce
```
### 5 GENERATING VALID RESULTS WITH GRADIENTS

We now put the theory offree generatorsand theirderivativesinto practice. We introduce Choice
Gradient Sampling (CGS), a novel algorithm for generating data that satis"es some given validity
condition, given a simple free generator for data of the appropriate type.
TheChoice Gradient Samplingalgorithm starts with a free generator for data of some type
and uses derivatives to step the generator through choices one at a time. This process guides the
generator towards values that are valid with respect to a given validity condition. At each step, the
algorithm looks at all available choices and takes the free generator’s derivative with respect to
each one. Since this is, in a sense, a vector of all possible derivatives, we call this thegradientof the
free generator, by analogy with calculus. We write
∇𝑔=〈𝛿a𝑔,𝛿b𝑔,𝛿c𝑔〉
for the gradient of𝑔with respect to the available choices{a,b,c}.
Since each derivative in the gradient is itself a free generator, the derivatives can be interpreted
as value generators and sampled. If the derivative with respect tocproduces lots of valid samples,
thencis a good choice. If it produces mostly invalid samples, maybe other choices would be better.
As we discuss below, this process is not faithful to the distribution of the original generator, but
it provides a metric that guides the algorithm toward a series of “good” choices, leading to more
valid inputs in many cases.

### 1:𝑔←𝐺

### 2:V←,

```
3:while true do
4: if𝜈𝑔≠,then return𝜈𝑔∪V
5: ifisVoid gthen𝑔←𝐺
6: 𝐶←choices𝑔
7: ∇𝑔←〈𝛿𝑐𝑔|𝑐∈𝐶〉 ⊲∇𝑔is the gradient of𝑔
8: for𝛿𝑐𝑔∈∇𝑔do
9: ifisVoid𝛿𝑐𝑔then
10: 𝑣←,
11: else
12: 𝑥 1 ,...,𝑥𝑁!G$𝛿𝑐𝑔% ⊲SampleG$𝛿𝑐𝑔%
13: 𝑣←{𝑥𝑗|𝜑(𝑥𝑗)}
14: 𝑓𝑐←|𝑣| ⊲𝑓𝑐is the!tnessof c
15: V←V∪𝑣
16: ifmax𝑐∈𝐶𝑓𝑐= 0 then
17: for𝑐∈𝐶do𝑓𝑐←weightOf𝑐𝐺
18: 𝑔!frequency[(𝑓𝑐,𝛿𝑐𝑔)|𝑐∈𝐶]
```
```
Fig. 3. Choice Gradient Sampling: Given a free generator𝐺, a sample rate constant𝑁, and a validity predicate
𝜑, this algorithm produces a set of outputs that all satisfy𝜑(𝑥).
```
```
We present the CGS algorithm in detail in Figure 3. Lines 7–14 are the core of the algorithm; their
execution is shown pictorially in Figure 4. We take the gradient of𝑔by taking the derivative with
respect to each possible choice, in this casea,b, andc. Then we evaluate each of the derivatives by
interpreting the free generator withG$·%, sampling values from the resulting value generator, and
counting how many of those results are valid with respect to𝜑. The precise number of samples is
```

```
Parsing Randomness 128:
```
controlled by𝑁, the sample rate constant; this is up to the user, but in general higher values for𝑁
will give better information about each derivative at the expense of time spent sampling. At the
end of sampling, we have values𝑓a,𝑓b, and𝑓c, which we can think of as the “"tness” of each choice.
We then pick a choice randomly, weighted based on "tness, and continue until our choices produce
a valid output.

```
Fig. 4. The main loop of Choice Gradient Sampling.
```
```
Critically, we avoid wasting effort by saving
the samples (V) that we use to evaluate the
gradients. Many of those samples will be valid
results that we can use, so there is no reason
to throw them away. Still, note that the perfor-
mance of this sampling does depend on|𝐶|, the
number of choices available at this point. If the
generator has many valid choices at a given
point, it will need to do a lot of sampling to
decide which choice to make.
This sampling procedure would not be pos-
sible with a traditional monadic generator: free
generators are key. Trying to take a deriva-
tive of a traditional monadic generator would
be like taking the derivative of a black-box
function—there would be no generic way to
incrementalize evaluation. Free generators ex-
pose more structure, making derivatives (and
thus CGS) possible.
```
```
Impact on Distribution.As noted above, this algorithm is not faithful to the original distribution
of𝐺. In particular, the observable behavior of the algorithm isnotto sample from the original
generator’s distribution, conditioned on validity. While this property would arguably be ideal, it
seems quite di#cult to obtain. Moreover, its absence need not signi"cantly detract from the value
that CGS provides, for two reasons.
First, while the distribution produced by CGS is not faithful to the original distribution, it is
certainly informed by it. At any given point in the algorithm, the weight given to a choice is
based on how often making future choices, weighted by the original distribution, results in valid
values. This means that valid values that are unlikely results from𝐺will be unlikely results from
CGS, and likely results from𝐺will also be likely from CGS. Doing better than this would be
quite di#cult, since the preconditions we care about are black-box functions. This means that
the only information they can provide is whether or not a particular value is valid, forcing us
into rejection-based approaches. Standard rejection sampling does, in fact, sample from the ideal
conditional distribution but it does so very slowly. Rather than sample from that distribution, CGS
allows the predicate to guide its generation, reaching valid inputs more quickly.
Second, and more importantly, the primary use case for CGS is to improve the performance of
free generators that are either automatically derived or else hand written but not carefully tuned.
That is, the algorithm is most effective as a low-effort way to get from a useless generator to a
usable one. If a tester has strict requirements for the distribution they are after, CGS will likely not
be su#cient; but as a quick way of getting up and running it can be quite helpful.
```

128:18 Harrison Goldstein and Benjamin C. Pierce

We have implemented our Choice Gradient Sampling algorithm inH'($&)), along with all of
the de"nitions presented throughout the paper^4 [Goldstein 2022].

6 EXPLORATORY EVALUATION

TheChoice Gradient Samplingalgorithm is not a tightly optimized production algorithm: it is a
proof of concept. Primarily, CGS exists to illustrate the theory offree generatorsand theirderivatives.
Still, there is much to learn by exploring how well CGS is able to guide realistic generators to valid
outputs.
We set out to answer two basic research questions:
RQ1Does CGS produce more useful test inputs than standard sampling procedures, in the same
period of time?
RQ2Are the test inputs obtained from CGS well distributed in shape and size?

Our experimental results suggest that, with a few (interesting) caveats, these questions can both
be answered in the a#rmative. We "nd that CGS generally produces at least twice as many valid
values asrejection sampling(explained in the next section) in the same period of time, and we also
"nd that CGS’s values are at least as diverse as the ones from rejection sampling. This indicates
that guiding generation with derivatives is a promising approach to the valid generation problem.

Experimental Setup.Our experiments explore how well CGS improves on a canonical generation
strategy. We compare our algorithm to the standard rejection sampling approach used by default
in frameworks like!"#$C%&#$, which takes a naïve generator, samples from it, and discards
any results that are not valid. Rejection sampling is a useful point of comparison because, like our
approach, it requires no extra effort from the user.
We use four simple free generators to test four different benchmarks:BST,SORTED,AVL, and
STLC. Details about each of these benchmarks are given in Table 1.

```
Table 1. Overview of benchmarks.
```
```
Free Generator Validity Condition 𝑁 Depth
BST Binary trees with values 0–9 Is a valid BST 50 5
SORTED Lists with values 0–9 Is sorted 50 20
AVL AVL trees with values 0–9 Is a balanced AVL tree 500 5
STLC Arbitrary ASTs for𝜆-terms Is well-typed 400 5
```
Each of our benchmarks requires a simple free generator to act as a baseline and as a starting
point for CGS. For consistency, and to avoid potential biases, our generators follow their respective
inductive data types as closely as possible. For example,fgenTree, shown in § 3 and used in the
BSTbenchmark, follows the structure of the de"nition of theTreetype exactly. All generators use
uniform choice weights, to avoid potential biases introduced by manual tuning.
The parameter𝑁, used by CGS to decide how many samples to use for each iteration, was chosen
via trial and error in order to balance "tness accuracy with sampling time. It is possible that some
of our best-case results might improve with a more careful choice of𝑁.

Results.We ran CGS and Rejection on each benchmark for one minute (on a MacBook Pro with an
M1 processor and 16GB RAM) and recorded the unique valid values produced. We counted unique
values because duplicate tests are generally less useful than fresh ones (if the system under test is
pure, duplicate tests add no value). The totals, averaged over 10 trials, are presented in Table 2.

(^4) https://github.com/hgoldstein95/free-generators


```
Parsing Randomness 128:
```
```
Table 2. Unique valid values generated in 60 seconds (𝑛= 10 trials). Standard deviation in parentheses.
```
```
BST SORTED AVL STLC
Rejection 7 , 354 ( 109 ) 5 , 768 ( 88 ) 129 ( 6 ) 70 , 127 ( 711 )
CGS 22 , 107 ( 338 ) 59 , 677 ( 1 , 634 ) 219 ( 2 ) 280 , 091 ( 7 , 265 )
```
```
These measurements show that CGS is always able to generate more unique values than Rejection
in the same amount of time, often signi"cantly more. The exception is theAVLbenchmark; we
discuss this below.
Besides unique values, we measured some other metrics; the charts in Figure 5 show the results
for theSTLCbenchmark. The "rst plot (“Unique Terms over Time”) shows how CGS behaves over
time. Not only does CGS "nd more unique terms than Rejection overall, but its lead continues to
grow over time. Additionally, the “Normalized Size Distribution” chart shows the size distributions
terms generated by both algorithms. The CGS distribution is skewed farther to the right, showing
that it generates larger terms on average; this is good from the perspective of property-based
testing, where test size is often positively correlated with bug-"nding power, since larger test inputs
tend to exercise more of the implementation code. Analogous charts for the remaining benchmarks
can be found in the Appendix.
```
```
Measuring Diversity.Nothing in the CGS algorithm guarantees that the values we generate are
diverse. Test input diversity is critical for for effective testing, since a more diverse test suite will
"nd more bugs more quickly, so we present experimental evidence that the values produced by
CGS are indeed no less diverse than the valid values produced by rejection sampling.
Our diversity metric relies on the fact that each value is roughly isomorphic to the choice
sequence that generated it. For example, in the case ofBST, the sequencen5l6llcan be parsed
to produceNode 5 Leaf (Node 6 Leaf Leaf)and a simple in-order traversal can recovern5l6ll
again. Thus, choice sequence diversity is a reasonable proxy for value diversity.
We estimated the average Levenshtein distance [Levenshtein et al. 1966 ] (the number of edits
needed to turn one string into another) between pairs of choice sequences in the values generated
by each of our algorithms. We chose this metric for sequence distance because it is fairly standard
and implementations were readily available. Computing an exact mean distance between all pairs
in such a large set would be very expensive, so we settled for the mean of a random sample of 3000
pairs from each set of valid values. Figure 6 shows the results of these distance calculations, broken
down by value size.
Each pair of lines in the chart represents an experiment. For all butAVL(the small pair of
dash-dotted lines in the lower left), the lines exhibit a clear trend: the per-size diversity of CGS is at
least as good as that of rejection sampling. (In fact, the diversity actually gets signi"cantly better at
large sizes, but much of this effect can be explained by the fact that CGS simply produces more
large values.)
One might hope for even better results than this—why shouldn’t CGS produce much more diverse
values at all sizes? A potential explanation lies in the way CGS retains intermediate samples. While
the "rst few samples will be mostly uncorrelated, the samples drawn later on in the generation
process (once a number of choices have been "xed) will tend to be similar to one another. This
likely results in clusters of inputs that are all valid but that only explore one shape of input.
```
The Problem with AVL: Very Sparse Validity Conditions.TheAVLbenchmark is an outlier in
most of our measurements: CGS only manages to "nd a modest number of extra valid AVL trees, and
their pairwise diversity is actually slightly worse than that of rejection sampling. Understanding


128:20 Harrison Goldstein and Benjamin C. Pierce

```
Fig. 5. Unique values and term sizes for theSTLCbenchmark, averaged over values in a single trial.
```
this phenomenon provides insight into a critical assumption underlying the CGS algorithm—namely
that it is not too di#cult to "nd valid values randomly.
It is clear that AVL treesarequite di#cult to "nd randomly: balanced binary search trees are
hard to generate on their own, and AVL trees are even more di#cult because the generator must
guess the correct height to cache at each node. This is why rejection sampling only "nds 156 AVL
trees in the time it takes to "nd 9 , 762 binary search trees.
In domains like this, CGS is unlikely to "ndanyvalid trees while sampling. In particular, the
check in line 15 of Figure 4 will often be true, meaning that choices will be made at random rather
than guided by the "tness of the appropriate derivatives. We could reduce this effect by signi"cantly
increasing the sample rate constant𝑁, but then sampling time would likely dominate generation
time, resulting in worse performance overall.


```
Parsing Randomness 128:21
```
```
Fig. 6. Levenshtein diversity of generated values, plo!ed against the size of those values.
```
```
The lesson here seems to be that the CGS algorithm does not work well with especially hard-to-
satisfy validity conditions. In § 9 , we present an idea that would do some of the hard work ahead of
time and help with this issue.
```
7 LIMITATIONS
Our free generator abstraction is extremely general and demonstrably useful, but a few technical
weaknesses are worth discussing.
The biggest limitation has to do with the kinds of distributions our free generators can represent.
Our exposition uses weighted choices (frequency) as the randomness primitive, but!"#$C%&#$
is technically built using a primitive like:
choose :: Random r⇒(r, r)→Gen r
Intuitively,choose (x, y)uniformly picks a value in therangefromxtoy, and this range can
technically be in"nite (e.g., ifr = Rational). This cannot be replicated withfrequencyorpick.
Thus, our results only apply to generators whose distributions are "nitely supported.
Another small issue is that we have intentionally neglected one common element of monadic
generators in the style of!"#$C%&#$: size. Generators in standard!"#$C%&#$track size bounds
dynamically, allowing the testing framework to externally control the size distribution of the inputs
that it generates. This does not impact our theoretical results (sizes can always be passed around
manually, as we do in the examples in this paper), and sizes would be relatively easy to add to the
free generator language in practice.
Finally, a note on the class of languages that free generators can parse (when interpreted with
P$·%). Free generators are limited in their nondeterminism (by the de"nition ofpick, and by
assumptions made in the de"nition ofP$·%); choices in a free generator are always unambiguous.
This means that the parser interpretation of a free generator cannot parse arbitrary languages of
choices, even though monadic parsers in general can parse arbitrary languages. Ultimately this
is not a practical concern, as free generators parse sequences of choices, not realistic languages,
but it is aesthetically disappointing. We believe it would be straightforward to add an operator for
explicit nondeterminism and extend the interpretations accordingly.


```
128:22 Harrison Goldstein and Benjamin C. Pierce
```
### 8 RELATED WORK

We discuss a variety of publications that relate to the present work via connections either to free
generators or to our Choice Gradient Sampling algorithm.

Parsing and Generation.The connection between parsers and generators has been employed
implicitly in some generator implementations. Two popular property-based testing libraries,H 12
3+-%&("([MacIver et al. 2019 ] andC*+45'*[Dolan and Preston 2017], implement generators by
parsing a stream of random choices. In fact,H13+-%&("(even takes advantage of parsing concepts
whenshrinkingtest inputs to make failing test-cases more readable for uses. However, neither of
these frameworks has formalized the relationship between parsing and generation.

Free Generators.Garnock-Jones et al.present a formalism based on parsing expression grammars
(PEGs) with some of the same goals as ours. They give a derivative-based algorithm that somewhat
resembles CGS, which constructs sentences that match a particular PEG. Their work does not
attempt to solve the valid generation problem for complex validity conditions like the ones we
tackle, but it does provide further evidence that connecting parsing and generation is advantageous.
Claessen et al.[ 2015 ] present a generator representation that is related to our free generator
structure, but used in a very different way. They primarily use the syntactic structure of their
generators (they call them “spaces”) to control the size distribution of generated outputs; in par-
ticular, spaces do not make choice information explicit in the way free generators do.Claessen
et al.’s generation approach usesH'($&))’s laziness, rather than derivatives and sampling, to prune
unhelpful paths in the generation process. This pruning procedure performs well when validity
conditions take advantage of laziness, but it is highly dependent on evaluation order and limited in
its analysis of what makes a choice invalid. In contrast, CGS does not require that predicates be
written in a speci"c way and has a much more nuanced notion of “unhelpful” choices.

The Valid Generation Problem.The valid generation problem is well studied. The most obvious
solution existing solution is to write a bespoke generator. For example, theCS,"-%project famously
developed a generator for valid C programs that was very successful at "nding bugs in C compil-
ers [Yang et al. 2011 ]. More generally, the domain-speci"c language for generators provided by the
!"#$C%&#$library [Hughes 2007] provides a whole framework for writing manual generators
that produce valid inputs by construction. The primary issue with these manual approaches is
effort: writing a bespoke generator is labor intensive and di#cult. The CGS algorithm aims to
avoid manual techniques like this in the hopes of making property-based testing more accessible
to programmers that do not have the time or expertise to write their own custom generators.
The constraint logic programming (CLP) generators proposed byDewey[ 2017 ] represent a
different approach to valid generation, more automated than!"#$C%&#$. Users of CLP generators
have a constraint solver to help them, making it easier to express certain kinds of validity conditions
in the generator. Even so, the CLP approach is not truly automatic: testers still need to express
validity condition as annotated logic programs. Depending on the testers’ background, this may
be ideal or it may be a deal-breaker. In contrast, CGS only requires that the validity condition be
encoded as a Boolean predicate in the host programming language, which the tester may very well
already have written for other reasons.
TheL6#$language [Lampropoulos et al.2017a] provides a similar semi-automatic solution; users
are still required to put in some effort, but they are able to de"ne generators and validity predicates
at the same time. Again, this solution might be satisfying if users are starting from scratch and
willing to learn a domain-speci"c language, but if validity predicates have already been written or
users do not want to learn a new language, a more automated solution may be preferable.


```
Parsing Randomness 128:23
```
```
When validity predicates are expressed as inductive relations, approaches like the one inGener-
ating Good Generators for Inductive Relations[Lampropoulos et al.2017b] are extremely powerful.
In the!"#$C%"#$framework, users can extract generators from the inductive relations that they
likely already have for their proofs. This is incredibly convenient for testing lemmas that will
eventually be proved, to establish con"dence before attempting the proof. Unfortunately, the kinds
of inductive relations that!"#$C%"#$depends on generally require dependent types to express,
so this approach does not work in most mainstream programming languages.
T'*/&-[Löscher and Sagonas 2017] uses search strategies like hill climbing and simulated
annealing to supplement random generation and signi"cantly streamline property-based testing.
Löscher and Sagonas’s approach works well when inputs have a sensible notion of “utility,” but in
the case of valid generation the utility is often degenerate—0 if the input is invalid, and 1 if it is
valid—with no good way to say if an input is “better” or “worse.” In these cases, derivative-based
searches may make more sense.
Some approaches use machine learning to automatically generate valid inputs.L&'*.7F 688 [Gode-
froid et al. 2017 ] generates valid data using a recurrent neural network. This solution seems to work
best when a large corpus of inputs is already available and the validity condition is more structural
than semantic. In the same vein,RLC%&#$[Reddy et al. 2020 ] uses reinforcement learning to guide
a generator to valid inputs. This approach served as early inspiration for our work, and we think
that the theoretical advance of generator derivatives may lead improved learning algorithms in the
future (see § 9 ).
```
```
9 CONCLUSION
Free generators and their derivatives are powerful structures that give a $exible perspective on
random generation. This formalism yields a useful algorithm for addressing the valid generation
problem, and it clari"es the folklore that a generator is a parser of randomness. Moving forward,
there are a number of paths to explore, some continuing our theoretical exploration and others
looking towards algorithmic improvements.
```
Bidirectional Free Generators. We have only scratched the surface of what seems possible
withfree generators. One concrete next step is to merge the theory of free generators with the
emerging theory ofungenerators[Goldstein 2021]. This work describes generators that can be run
both forward (to generate values as usual) andbackward. In the backward direction, the program
takes a value that the generator might have generated and “un-generates” it to give a sequence of
choices that the generator might have made when generating that value.
Free generators are quite compatible with these ideas, and turning a free generator into a
bidirectional generator that can both generate and ungenerate should be fairly straightforward.
From there, we can build on the ideas in the ungenerators work and use the backward direction of
the generator to learn a distribution of choices that approximates some user-provided samples of
“desirable” values.

Algorithmic Optimizations.In § 6 , we saw some problems with theChoice Gradient Sampling
algorithm: because CGS evaluates derivatives via sampling, it does poorly when validity conditions
are very di#cult to satisfy. This begs the question: might it be possible to evaluate the "tness of a
derivative without naïvely sampling?
One potential approach involves staging the sampling process. Given a free generator with a
depth parameter, we can "rst evaluate choices on generators for size 1, then evaluate choices for
size 2, etc. These intermediate stages would make gradient sampling more successful at larger sizes,
and might signi"cantly improve the results on benchmarks likeAVL. Unfortunately, this approach


```
128:24 Harrison Goldstein and Benjamin C. Pierce
```
```
might perform poorly on benchmarks likeSTLCwhere the validity condition is not uniform: size-1
generators would avoid generating variables, leading larger generators to avoid variables as well.
Nevertheless, this design space seems well worth exploring.
```
Making Choices with Neural Networks.Another algorithmic optimization is a bit farther a"eld:
using recurrent neural networks (RNNs) to improve our generation procedure.
As Choice Gradient Sampling makes choices, it generates useful data about the frequencies with
which choices should be made. Speci"cally, every iteration of the algorithm produces a pair of a
history and a distribution over next choices that looks something like this:
abcca1→{a:0. 3 ,b:0. 7 ,c:0. 0 }

In the course of CGS, this information is used once (to make the next choice) and then forgotten—but
what if there was a way to learn from it? Pairs like this could be used to train an RNN to make
choices that are similar to the ones made by CGS.
There are details to work out, including network architecture, hyper-parameters, etc., but in
theory we could run CGS for a while, train an RNN, and after that point only use the RNN to
generate valid data. Setting things up this way would recover some of the time that is currently
spent sampling of derivative generators.
One could imagine a user writing a de"nition of a type and a predicate for that type, and then
setting the model to train while they work on their algorithm. By the time the algorithm is "nished
and ready to test, the RNN model would be trained and ready to produce valid test inputs. A
work$ow like this might help increase adoption of property-based testing in industry.

```
ACKNOWLEDGMENTS
Thank you to John Hughes for his invaluable comments on an early draft of this work, and to
Penn’s PLClub for their continued support.
This work was "nancially supported by NSF awards #1421243,Random Testing for Language
Designand #1521523,Expeditions in Computing: The Science of Deep Speci!cation.
```
```
REFERENCES
Janusz A Brzozowski. 1964. Derivatives of regular expressions.Journal of the ACM (JACM)11, 4 (1964), 481–494.
Koen Claessen, Jonas Duregård, and Michal H. Palka. 2015. Generating constrained random data with uniform distribution.
J. Funct. Program.25 (2015).https://doi.org/10.1017/S0956796815000143
Koen Claessen and John Hughes. 2000. QuickCheck: a lightweight tool for random testing of Haskell programs. InProceedings
of the Fifth ACM SIGPLAN International Conference on Functional Programming (ICFP ’00), Montreal, Canada, September
18-21, 2000, Martin Odersky and Philip Wadler (Eds.). ACM, Montreal, Canada, 268–279.https://doi.org/10.1145/351240.
351266
Kyle Thomas Dewey. 2017.Automated Black Box Generation of Structured Inputs for Use in Software Testing. University of
California, Santa Barbara.
Stephen Dolan and Mindy Preston. 2017. Testing with crowbar. InOCaml Workshop.
Tony Garnock-Jones, Mahdi Eslamimehr, and Alessandro Warth. 2018. Recognising and generating terms using derivatives
of parsing expression grammars.arXiv preprint arXiv:1801.10490(2018).
Michele Giry. 1982. A categorical approach to probability theory. InCategorical aspects of topology and analysis. Springer,
68–85.
Patrice Godefroid, Hila Peleg, and Rishabh Singh. 2017. Learn&fuzz: Machine learning for input fuzzing. In2017 32nd
IEEE/ACM International Conference on Automated Software Engineering (ASE). IEEE, 50–59.https://dl.acm.org/doi/10.
5555/3155562.3155573
Harrison Goldstein. 2021. Ungenerators. InICFP Student Research Competition.https://harrisongoldste.in/papers/icfpsrc21.
pdf
Harrison Goldstein. 2022. Parsing Randomness: Free Generators Development. (Oct 2022).https://doi.org/10.5281/zenodo.
7086231
```

Parsing Randomness 128:25

John Hughes. 2007. QuickCheck testing for fun and pro"t. InInternational Symposium on Practical Aspects of Declarative
Languages. Springer, 1–32.https://dl.acm.org/doi/10.1007/978-3-540-69611-7_1
Oleg Kiselyov and Hiromi Ishii. 2015. Freer monads, more extensible effects.ACM SIGPLAN Notices50, 12 (2015), 94–105.
https://dl.acm.org/doi/10.1145/2804302.2804319
Leonidas Lampropoulos, Diane Gallois-Wong, Catalin Hritcu, John Hughes, Benjamin C. Pierce, and Li-yao Xia. 2017a.
Beginner’s Luck: a language for property-based generators. InProceedings of the 44th ACM SIGPLAN Symposium on
Principles of Programming Languages, POPL 2017, Paris, France, January 18-20, 2017. 114–129.http://dl.acm.org/citation.
cfm?id=3009868
Leonidas Lampropoulos, Zoe Paraskevopoulou, and Benjamin C Pierce. 2017b. Generating good generators for inductive
relations.Proceedings of the ACM on Programming Languages2, POPL (2017), 1–30.https://dl.acm.org/doi/10.1145/3158133
Daan Leijen and Erik Meijer. 2001. Parsec: Direct style monadic parser combinators for the real world. (2001).
Vladimir I Levenshtein et al.1966. Binary codes capable of correcting deletions, insertions, and reversals. InSoviet physics
doklady, Vol. 10. Soviet Union, 707–710.
Andreas Löscher and Konstantinos Sagonas. 2017. Targeted Property-Based Testing. InProceedings of the 26th ACM
SIGSOFT International Symposium on Software Testing and Analysis(Santa Barbara, CA, USA)(ISSTA 2017). Association
for Computing Machinery, New York, NY, USA, 46–56. https://doi.org/10.1145/3092703.3092711
David R MacIver, Zac Hat"eld-Dodds, et al.2019. Hypothesis: A new approach to property-based testing.Journal of Open
Source Software4, 43 (2019), 1891.
Eugenio Moggi. 1991. Notions of computation and monads.Information and computation93, 1 (1991), 55–92.
TomášPetříček. 2009. Encoding monadic computations in C# using iterators.Proceedings of ITAT(2009).
Sameer Reddy, Caroline Lemieux, Rohan Padhye, and Koushik Sen. 2020. Quickly generating diverse valid test inputs with
reinforcement learning. InICSE ’20: 42nd International Conference on Software Engineering, Seoul, South Korea, 27 June -
19 July, 2020, Gregg Rothermel and Doo-Hwan Bae (Eds.). ACM, 1410–1421.https://doi.org/10.1145/3377811.3380399
Xuejun Yang, Yang Chen, Eric Eide, and John Regehr. 2011. Finding and understanding bugs in C compilers. InProceedings
of the 32nd ACM SIGPLAN Conference on Programming Language Design and Implementation, PLDI 2011, San Jose, CA,
USA, June 4-8, 2011. 283–294.https://doi.org/10.1145/1993498.1993532


```
128:26 Harrison Goldstein and Benjamin C. Pierce
```
# Appendix

### A PROOF OF THEOREM3.1

### L￿￿￿￿A.1.

```
P»G»= 5 ...h$iR»G»= 5 ...⌘(P»G...h$iR»G...)»= _( 0 ,[])!(P» 50 ...h$iR» 50 ...)
```
```
P￿￿￿￿.By induction on the structure ofG.
```
- Casex = Return a
    P»Return a»= f...h$iR»Return a»= f...
       −−By de￿nition (»=).
          ⌘P»fa...h$iR»fa...
       −−By[−expansionand de￿nitions ofP»·...andR»·....
          ⌘P»Return a...h$iR»Return a...»=_(a, [])!P»fa...h$iR»fa...
- Casex = Bind (Pick xs) k
    P»Bind (Pick xs) k»= f...h$iR»Bind (Pick xs) k»= f...
       −−By de￿nition (»=).
          ⌘P»Bind (Pick xs) (_a!ka»= f)...h$iR»Bind (Pick xs) (_a!k»= f ))...
       −−By de￿nition (P»·...andR»·...).
          ⌘(do
             c consume
             x casefind ((== c). snd) xsof
                Just (_, _, x)!returnx
Nothing!fail
             P»x»=_a!ka»= f...) h$i(do
                (c, x) frequency (map (_(w, c, y)!(w,return (c, y ))) xs)
s R»x»= (_a!ka»= f)...
pure (c : s ))
       −−By simpli￿cation.
          ⌘do
             (_, x) frequency (map (_(w, c, y)!(w,return(c, y ))) xs)
             P»x»=_a!ka»= f...h$iR»x»=_a!ka»= f...
       −−Bymonadlaws.
          ⌘do
             (_, x) frequency (map (_(w, c, y)!(w,return(c, y ))) xs)
             P»(x»= k)»= f...h$iR»(x»= k)»= f...
       −−ByIH.
          ⌘do
             (_, x) frequency (map (_(w, c, y)!(w,return(c, y ))) xs)
             (P»x»=k...h$iR»x»=k...)»= (_a!P»fa...h$iR»fa...)
       −−Byexpansionand de￿nitions (P»·...andR»·...).
          ⌘(P»Bind (Pick xs) k...h$iR»Bind (Pick xs) k...)»= (_a!P»fa...h$iR»fa...)

```
⇤
```

Parsing Randomness 128:27

T￿￿￿￿￿￿3.1 (F￿￿￿￿￿￿￿￿).Everyfree generatorcan be factored into a parser and a distribution
over choice sequences that are, together, equivalent to its interpretation as a generator. In other words,
for all free generators 6 ,

```
P» 6 ...h$iR» 6 ...⌘(_G!(G,Y))h$iG» 6 ....
P￿￿￿￿.By induction on the structure ofG.
```
- Casex = Return a
    P»Return a...h$iR»Return a... ⌘return(a, []) ⌘(_a!(a, [])) h$iG»Return a...
    (By de￿nition.)
- Casex = Bind (Pick xs) k
    P»Bind (Pick xs) k...h$iR»Bind (Pick xs) k...
       −−By de￿nition (P»·...andR»·...).
          ⌘(doc consume
             x casefind ((== c). snd) xsof
                Just (_, _, x)!returnx
Nothing! fail
             P»x»=k...)h$i (do
                (c, x) frequency (map (_(w, c, x)!(w,return (c, x ))) xs)
s R»x»=k...
pure (c : s ))
       −−By simpli￿cation.
          ⌘dox frequency (map (_(w, _, x)!(w,returnx )) xs)
             s R»x»=k...
             returnP»x»=k...s
       −−Bymonadlaws.
          ⌘dox frequency (map (_(w, _, x)!(w,returnx )) xs)
             P»x»=k...h$iR»x»=k...
       −−ByLemmaA.1.
          ⌘dox frequency (map (_(w, _, x)!(w,returnx )) xs)
             (P»x...h$iR»x...)»=_(a, []) !P»ka...h$iR»ka...
       −−ByIH.
          ⌘dox frequency (map (_(w, _, x)!(w,returnx )) xs)
             ((_a!(a, [])) h$iG»x...)»=_(a, []) !(_a!(a, [])) h$iG»ka...
       −−By simpli￿cation.
          ⌘(_a!(a, [])) h$idox frequency (map (_(w, _, x)!(w,returnx )) xs)
             a G»x...
             G»ka...
       −−By de￿nition (G»·...)
          ⌘(_a!(a, [])) h$i G»Bind (Pick xs) k...

Thus the decomposition of a free generator into a parser and a source of randomness is equivalent
to interpreting it as a generator. ⇤


128:28 Harrison Goldstein and Benjamin C. Pierce

### B PROOF OF LEMMA4.1

L￿￿￿￿4.1.X 2 satis￿es equations ( 1 ), ( 2 ), ( 3 ), and ( 4 ). In other words, the free generator derivative
behaves similarly to the regular expression derivative.

```
P￿￿￿￿.We prove each equation individually.
```
- Equation 1 :X 2 void⌘void
    By evaluation.
- Equation 2 :X 2 (returnE)⌘void
    By de￿nition.
- Equation 3 :
    X 2 (pickGB)⌘G if( 2 ,G) 2 GB
    X 2 (pickGB)⌘void if( 2 ,G) 8 GB
    Unfold the de￿nition ofpick, by evaluation.
- Equation 4 :
    X 2 (G»= 5 )⌘X 2 ( 50 ) ifaG={ 0 }
    X 2 (G»= 5 )⌘X 2 G»= 5 ifaG=ú
- CaseG=Return 0. By de￿nition,aG={ 0 }.
X 2 (x»=f) ⌘X 2 (Return a»=f)−−Byassumption.
⌘X 2 (f a) −−By de￿nition (»=).
- CaseG=Bind(PickGB) 6. By de￿nition,aG=ú.
X 2 (x»=f) ⌘X 2 (Bind (Pick xs) g»=f) −−Byassumption.
⌘X 2 (Bind (Pick xs) (_a!ga»= f )) −−By de￿nition (»=).
⌘ casefind ((== c). snd) xsof −−By de￿nition (X).
Just (_, _, x)!x»= (_a!ga»= f)
Nothing!void
⌘ casefind ((== c). snd) xsof −−Bymonadlaws.
Just (_, _, x)!(x»= g)»= f
Nothing!void
⌘X 2 x»=f −−By de￿nition (X).

Thus all four equations hold. ⇤


Parsing Randomness 128:29

### C PROOF OF THEOREM4.2

T￿￿￿￿￿￿4.2.The derivative of a free generator’s language is the same as the language of its
derivative. That is, for allfree generators 6 and choices 2 ,

```
X 2 LL» 6 ...=L»X 26 ....
```
P￿￿￿￿. L»X 2 x...=L»casexof −−By de￿nition (X).
Return _!void
Bind (Pick xs) k!casefind ((== c). snd) xsof
Just (_, _, y)!L»y»=k...
Nothing![] ...
= casexof −−By de￿nition (L).
Return _![]
Bind (Pick xs) k!o
(_, d, y) xs
cs L»y»=k...
guard (c == d)
pure cs
= do −−ByHaskell identities.
(d : cs) casexof
Return _![ [] ]
Bind (Pick xs) k!do
(_, d, y) xs
s L»y»=k...
pure (d : s)
guard (c == d)
pure cs
=do −−By de￿nition (L).
(d : cs) L»x...
guard (c == d)
pure cs
=X 2 L(L»x...) −−By de￿nition (XL)
⇤
There is another proof of this theorem, suggested by Alexandra Silva, which uses the fact that
2 ⌃
⇤
is the ￿nal coalgebra, along with the observation thatFGenhas a 2 ⇥()⌃coalgebraic structure.
This approach is certainly more elegant, but it abstracts away some helpful operational intuition.


128:30 Harrison Goldstein and Benjamin C. Pierce

### D FULL EXPERIMENTAL RESULTS

```
BSTCharts
```
```
SORTEDCharts
```
```
AVLCharts
```

