# 200

# Reflecting on Random Generation

## HARRISON GOLDSTEIN,University of Pennsylvania, USA

## SAMANTHA FROHLICH,University of Bristol, UK

## MENG WANG,University of Bristol, UK

## BENJAMIN C. PIERCE,University of Pennsylvania, USA

```
Expert users of property-based testing often labor to craft random generators that encode detailed knowledge
about what it means for a test input to be valid and interesting. Fortunately, the fruits of this labor can also
be put to other good uses. In the bidirectional programming literature, for example, generators have been
repurposed as validity checkers, while Python’s Hypothesis library uses them to shrink and mutate test inputs.
To unify and generalize these uses (and more), we proposereflective generators, a new foundation for
random data generators that can “reflect” on an input value to calculate the random choices that could have
been made to produce it. Reflective generators combine ideas from two existing abstractions:free generators
andpartial monadic profunctors. They can be used to implement and enhance the aforementioned shrinking
and mutation algorithms, generalizing them to work for any values that could have been produced by the
generator, not just ones for which a trace of the generator’s execution is available. Beyond shrinking and
mutation, reflective generators simplify and generalize a published algorithm for example-based generation;
they can also be used as checkers and partial value completers, and test data producers like enumerators and
fuzzers.
CCS Concepts:•Software and its engineering→General programming languages.
Additional Key Words and Phrases: bidirectional programming, property-based testing, random generation
```
ACM Reference Format:
Harrison Goldstein, Samantha Frohlich, Meng Wang, and Benjamin C. Pierce. 2023. Reflecting on Random
Generation.Proc. ACM Program. Lang.7, ICFP, Article 200 (August 2023), 41 pages. https://doi.org/10.1145/
3607842

```
1 INTRODUCTION
Property-based testing, popularized by Haskell’s QuickCheck library [Claessen and Hughes 2000],
draws much of its bug-finding power fromgeneratorsfor random data. These programs are carefully
crafted and encode important information about the system under test. In particular, QuickCheck
generators like the one in Figure 1a capture what it means for a test input to bevalid—here, ensuring
that a tree satisfies the binary search tree (BST) invariant by keeping track of the minimum and
maximum allowable values in each sub-tree. This generator is not just a program for generating
BSTs, itdefinesBSTs in the sense that its range is precisely the set of BSTs.
Developers of tools like Hypothesis [MacIver et al.2019]—arguably the most popular PBT
framework, with 6,500 stars on GitHub and an estimated 500,000 users [Dodds 2022]—capitalize
on this observation and repurpose generators for other tasks, including test-caseshrinkingand
mutation. These algorithms do not operate directly on data values; rather, shrinking or mutating
a value is accomplished by shrinking or mutating therandom choicesthat produced that value,
and then re-running the generator on the modified choices [MacIver and Donaldson 2020]. This
amounts to treating generators asparsers, taking unstructured randomness and parsing it into
Authors’ addresses: Harrison Goldstein, hgo@seas.upenn.edu, University of Pennsylvania, Philadelphia, Pennsylvania, USA;
Samantha Frohlich, samantha.frohlich@bristol.ac.uk, University of Bristol, Bristol, UK; Meng Wang, meng.wang@bristol.ac.
uk, University of Bristol, Bristol, UK; Benjamin C. Pierce, bcpierce@cis.upenn.edu, University of Pennsylvania, Philadelphia,
Pennsylvania, USA.
```
2023. 2475-1421/2023/8-ART
https://doi.org/10.1145/

```
Proc. ACM Program. Lang., Vol. 7, No. ICFP, Article 200. Publication date: August 2023.
```

```
200:2 Goldstein and Frohlich et al.
```
```
bst :: (Int, Int) -> Gen Tree
bst (lo, hi) | lo > hi = return Leaf
bst (lo, hi) =
frequency
[ ( 1, return Leaf ),
( 5, do
x <- choose (lo, hi)
l <- bst (lo, x - 1)
r <- bst (x + 1, hi)
return (Node l x r) ) ]
```
```
(a) QuickCheck generator.
```
```
bst :: (Int, Int) -> Reflective Tree Tree
bst (lo, hi) | lo > hi = exact Leaf
bst (lo, hi) =
frequency
[ ( 1, exact Leaf),
( 5, do
x <- focus (_Node._2) (choose (lo, hi))
l <- focus (_Node._1) (bst (lo, x - 1))
r <- focus (_Node._3) (bst (x + 1, hi))
return (Node l x r) ) ]
```
```
(b) Reflective generator.
```
```
Fig. 1. Generators for binary search trees.
```
structured values—a perspective formalized in terms offree generators[Goldstein and Pierce 2022].
Viewing generators as parsers has two advantages: (1) shrinking and mutation can be implemented
generically, rather than once per generator, and (2) the modified data values will automatically
satisfy any preconditions that the generator was designed to enforce (e.g., the BST invariant), since
they are ultimately produced by pushing modified choices through the generator.
Ideally, Hypothesis’s type-agnostic, validity-preserving algorithms should completely subsume
more manual ones. Unfortunately, the current Hypothesis approach assumes that the shrinker, for
example, is given access to the original random choices that the generator made when producing
the value it is shrinking; this doesn’t work when shrinking is separated (in time or space) from
generation. In particular, Hypothesis can’t shrink values that it did not generate in the first place—
e.g., because they were provided as pathological examples or from crash reports. More subtly,
Hypothesis’s shrinking also breaks if the value was modified between generation and shrinking, or
saved without also saving a record of the choices.
To use Hypothesis-style shrinking on an arbitrary value, the shrinker needs some way of
reconstituting a set of random choices that produce that value. Luckily, inspiration for how to do this
can be drawn from the grammar-based testing literature, specificallyInputs from Hell[Soremekun
et al.2020], which describes a way to produce test inputs that are similar to an existing one. Starting
with a grammar-based generator [Godefroid et al.2008], they first use the grammar to parse a
value, determining whichproductionsmust be expanded to produce that value. Then, they bias the
generator to expand those productions more often, thus resulting in more values that are similar to
the example. In essence, this approach determines which generator choices lead to a desired value
bygoing backward, parsing the value with the same grammar that (could have) generated it.
TheInputs from Hellapproach works well for grammar-based generators, but does not apply to
generators that enforce validity. For this, we need a more general solution—one that works with the
kinds ofmonadicgenerators used in QuickCheck, which can enforce arbitrary validity conditions.
Such a solution can be found in the bidirectional programming literature. Xia et al.[2019] describe
partial monadic profunctors, which enrich standard monads with extra operations for describing
bidirectional computations. This infrastructure, along with the parsing-as-generation perspective
of free generators, enables exactly the kind of bidirectional generation needed to extract random
choices from a monadically produced value.
Our main contribution,reflective generators, is a language for writing bidirectional generators that
can “reflect” on a value to analyze which choices produce that value (see Figure 1b). They subsume
the grammar-based generators ofInputs from Hell, and, critically, they enable Hypothesis-style
shrinking and mutation for arbitrary values in the range of a monadic generator. Furthermore, since


```
Reflecting on Random Generation 200:
```
```
reflective generators are built onfreer monads, they can be interpreted numerous ways besides
generation and reflection. We discuss three more use cases that demonstrate the versatility of
reflective generators as testing utilities.
Following a brief tour through some background (§2), we offer the following contributions:
```
- We presentreflective generators, a framework that fusesfree generatorsandpartial monadic
    profunctorsinto a flexible domain-specific language for PBT generators that can reflect on a
    value to obtain choices that produce it. (§3)
- We develop the theory of reflective generators, defining what it means for reflective generators
    to be correct along a number of axes and comparing their expressive power to other generation
    abstractions. (§4)
- We demonstrate the core behavior of reflective generators by generalizing prior work on
    example-based generation. Our implementation subsumes theInputs from Hellalgorithm and
    extends it to work with monadic generators. (§5)
- We apply reflective generators to manipulate user-provided values. Reflective generators
    enable generator-based shrinking and mutation algorithms to work even when the random-
    ness used to generate test inputs is not available. We show that our shrinkers are at least as
    effective as other automated shrinking techniques. (§6)
- We leverage the reflective generator abstraction to implement other testing tools: checkers
    for test input validity, “completers” that can randomly complete a partially defined value,
    and test input producers like enumerators and fuzzers. (§7)

We conclude by discussing related work (§8) and future directions (§9).

2 BACKGROUND
The abstractions we present in this paper rely on a significant amount of prior work. In this section,
we review the structures that make reflective generators possible: monadic random generators
(§2.1), free generators (§2.2), and partial monadic profunctors (§2.3).

```
class Monad m where
return :: a -> m a
(>>=) :: m a -> (a -> m b) -> m b
```
```
do { x <- m; f x } = m >>= f
```
```
type Gen a = Int -> a
(a) Definitions for monadic generators.
```
```
data Freer f a where
Return :: a -> Freer f a
Bind :: f a
-> (a -> Freer f b)
-> Freer f b
```
```
data Pick a where
Pick :: [(Weight, Choice, Freer Pick a)]
-> Pick a
(b) Definitions for free generators.
```
```
class Profunctor p where
lmap :: (d -> c) -> p c a -> p d a
rmap :: (a -> b) -> p c a -> p c b
```
```
class Profunctor p => PartialProf p where
prune :: p b a -> p (Maybe b) a
```
```
class (forall b. Monad (p b), PartialProf p)
=> PMP p
(c) Definitions for partial monadic profunctors.
```
```
Fig. 2. Background definitions.
```

200:4 Goldstein and Frohlich et al.

2.1 Monadic Random Generators

The idea of testing executable properties using monadic generators was popularized by QuickCheck
and has endured for more than two decades. The core structures used by QuickCheck are shown in
Figure 2a, whereGenrepresents the type of random generators. It treats the inputIntas a random
seed and uses it to produce a value of the appropriate type. Generators like the one in Figure 1a are
easy to write because they aremonads[Moggi 1991]; this structure provides a neat interface for
chaining effectful computations.

2.2 Free Generators

Interfaces like theMonadtype class can be reified into “free” structures that represent each operation
as a data constructor, allowing it to be interpreted in multiple ways. There are several such free
structures for the monad interface; [BCP: cite the others?] [HG: Yeah, we should... I don’t have the
exhaustive list in my head though. Sam? If you don’t I can spend 20 minutes reading] we focus on
thefreer monad[Kiselyov and Ishii 2015] structure shown in Figure 2b, which reifies thereturn
operation as the constructorReturnand(>>=)asBind. The extra type constructorfranges over
the operations that are specific to each given monad, for example, theGet :: State s sand
Put :: s -> State s ()operations forState.
Free generators[Goldstein and Pierce 2022] are an instance of this scheme, instantiatingfas
the type constructorPick(Figure 2b), which represents a choice between sub-generators.Pickis
used to implement familiar QuickCheck-style combinators likechoose, which generates an integer
in a given range, andoneof, which randomly selects between a list of generators. Goldstein and
Pierce use free generators to draw a formal connection between random generation and parsing,
interpreting the same free generator as both a generator and a parser.

2.3 Partial Monadic Profunctors

Profunctorsare a standard construction from category theory, generalizing ordinary functors—
structure-preserving maps—to allow for both covariant and contravariant mapping operations.
They are realized as theProfunctorclass (Figure 2c), popularized in Haskell by Pickering et al.
[2017], where the mapping operations are calledrmapandlmaprespectively. The quintessential
example of a profunctor is the function type constructor(->). This makes sense, sinceb -> ais
contravariant inband covariant ina. In that case,rmapimplements post-composition (of some
functiona -> a') andlmapimplements pre-composition (of a functionb'-> b). Indeed, it is
often useful to think of profunctors as function-like: a value of typep b a“examines a value of
typebto produce a value of typea” (potentially doing some other effects).
Amonadic profunctoris a profunctor that is also a monad (i.e., a profunctorpsuch that for anyb,
p bis a monad). Xia et al.[2019] use this extra structure to implement composable bidirectional
computations. For example, consider the classic bidirectional programming example of a parser
and a pretty printer, which invert one-another. These dual functions can be implemented using the
same monadic profunctor:

```
data Biparser b a = { parse :: String -> (a, String); print :: b -> (a, String) }
```
ThisBiparseris a single program that gets “interpreted” in two different ways. As a parser, it
ignores thebparameter entirely, and simply acts as a parser in the style of Parsec [Leijen and
Meijer 2001] to produce a value of typea. As a pretty printer, it still needs to produce a value of
typea—after all, the two interpretations share the same code—but now there is no inputString
to parse. Instead, the pretty printer interpretation has a value of typebit uses as instructions to
produce both theaand aString. This scheme makes much more sense when the profunctor is


```
Reflecting on Random Generation 200:
```
aligned, that is of typeBiparser a a; in that case, a properly written pretty printer acts as an
identity function, taking a value and reproducing it while also recording itsStringrepresentation.
Xia et al.call the first type of interpretation, which ignores its contravariant parameter and just
produces an output, a “forward” interpretation, and the second, which acts as an identity function
and follows the structure of its contravariant parameter, a “backward” interpretation. We sayparse
goes forward andprintgoes backward. This is an arbitrary choice, but it is helpful as an analogy
for the way that certain monadic profunctors are duals of one other.
Writing aBiparser, or any other monadic profunctor, is a game of type alignment. In general,
aligned programs are desirable, but aligning the types gets tricky around monadic binds. Suppose
we have an alignedp a aand we want to get anaout and continue with a function of type
a -> p b b(whose codomain is also aligned). Wecannotsimply use(>>=)whose type is:
(>>=) :: p b a -> (a -> p b b) -> p b b
The problem is the first argument: we have a value of typep a abut we need one of typep b a
sincep bis the type of the monad. Luckily, thelmapoperation (§2c) makes it possible to take
an aligned profunctor,p a aand turn it into ap b aby providing anannotationof typeb -> a
that says how to focus on some part of a value of typebthat has typea. We can thus build up a
Biparserby writing a program that looks essentially like a standard monadic parser, but with
monadic binds annotated with calls tolmapthat fix the alignment.
This story is almost complete, but it leaves out cases where annotations need to be partial.
Consider aBiparserlike this one, which parses either a letter or a number:
letter :: Biparser Char Char
number :: Biparser Int Int
data LorN = Letter Char | Number Int

```
lOrN :: Biparser LorN LorN
lOrN = Letter <$> lmap ??? letter <|> Number <$> lmap ??? number
The first annotation should be of typeLorN -> Char, but there is no total function of that
type: what happens if theLorNis aNumber? The more appropriate annotation type would be
LorN -> Maybe Char. Xia et al.make this possible withpartial monadic profunctors(PMPs), which
add one more operation,prune, to capture failure. (We have renamed itpruneinstead of the
original “internaliseMaybe”.) Unlike monadic profunctors, which can only be annotated with
total functions usinglmap, PMPs can be annotated with partial functions. The combinatorcomap
demonstrates this generalized annotation:
comap :: PMP p => (c -> Maybe b) -> p b a -> p c a
comap f = lmap f. prune
```
When a PMP likeprintbranches (e.g., inlOrN) the execution follows both sides (e.g., trying to
pretty print both aLetterand aNumber). The partial annotations tell the computation when to
prunea branch, keeping the search space small and ensuring that PMPs likeprintare efficient.
A concrete example of a partial profunctor is the partial arrow constructor:
newtype PartialArr a b = PartialArr {unPA :: a -> Maybe b}
This follows on naturally from the intuition that(->)is a profunctor. In fact, these are also PMPs,
you can find the relevant instances in Appendix A.
PMPs are complex, and they can be used in a wide variety of ways. We recommendComposing
Bidirectional Programs Monadically[Xia et al. 2019] for a more thorough explanation.


```
200:6 Goldstein and Frohlich et al.
```
### 3 THE REFLECTIVE GENERATOR LANGUAGE

```
Reflective generators combine free generators with PMPs, enabling a host of enhanced testing
algorithms. In this section, we explain the intuition behind reflective generators (§3.1), describe
their implementation (§3.2), and discuss their various interpretations (§3.3).
The basic structure of a reflective generator comes from adding the partial monadic profunctor
operations,lmapandprune, to thePickdatatype. We call this extended typeR(for Reflective) and
implement it like this:
type Weight = Int
type Choice = Maybe String
```
```
data R b a where
Pick :: [(Weight, Choice, Freer (R b) a)] -> R b a
Lmap :: (c -> d) -> R d a -> R c a
Prune :: R b a -> R (Maybe b) a
ThePickconstructor here has two small changes from the free generator presentation: we add
an extra contravariant type variableb, and we modify thechoicetype to optionally elide choice
labels.^1 ThenLmapcaptures contravariant annotations (there is no need to explicitly represent
rmap, as we will be able to encode it using the monad structure), andPrunerepresents its PMP
counterpart with an analogous type. A reflective generator is then a freer monad overR b:
type Reflective b a = Freer (R b) a
```
```
3.1 Intuition
The typeReflective b aof reflective generators should be understood to mean a program that
can “reflect on a valueb, recording choices, while generating ana.”
Like PMPs, reflective generators use annotations to fix the types around monadic binds. More
intuition of how these should be defined follows from the intuitive interpretation of the types:
the goal is to take a generator that reflects on choices in anaand turn it into one that reflects on
choices in ab. Here’s the key: it suffices to show how tofocus on a part of thebthat contains an
a, because that focusing turnsachoices intobchoices. Put another way, the annotation should
embed a mapping of typeb -> aorb -> Maybe athat focuses on theapart of theb. To see this
in action, consider the example in Figure 1b, paying attention to the first bind in theNodebranch,
do
x <- focus (_Node._2) (choose (lo, hi))
...
```
where...continues on to produce the rest of the tree. The call tochooseresults in aReflective
Int Int, but the type of the enclosing monad isReflective Tree; as discussed in §2.3 we need to
add an annotation on the bind that focuses on anIntin aTreeto get aReflective Tree Int. In
the example, we annotate withfocus (_Node._2)(this syntax is introduced in the next section)
but the following is equivalent:
comap (\ t -> case t of { Leaf -> Nothing; Node _ x _ -> Just x })
As with PMPs likeBiparser, the process of reflecting on choices is all about the interaction
between binds andcomaps. A value flows through the program, and, at each bind, thecomapfocuses
on the part of the value that the left side of the bind should reflect on. If the focusing fails, that

(^1) As inParsing Randomness, we represent weights inPickas integers for simplicity. Formally they are required to be strictly
positive; this will be necessary to prove Theorem 4.4.


```
Reflecting on Random Generation 200:
```
```
branch gets pruned—there is no way to produce the desired value—but if it succeeds, then the left
side can reflect on that part of the value, extracting some choices, and reflection can continue on
the right side.
With this intuition in mind, we can move onto the technical details of reflective generators.
```
```
3.2 Implementation
```
We next describe how reflective generators are implemented and what we’ve done to make them
feel familiar and easy to work with. (In §9, we discuss plans to validate this belief with a proper
user study.)

```
The Full Story.The actual typeRdefined in the Haskell artifact is a bit more complicated than
the one explained above. The actual implementation looks like:
```
```
data R b a where
Pick :: [(Weight, Choice, Freer (R b) a)] -> R b a −−as before
Lmap :: (c -> d) -> R d a -> R c a −−as before
Prune :: R b a -> R (Maybe b) a −−as before
ChooseInteger :: (Integer, Integer) -> R Integer Integer
GetSize :: R b Int
Resize :: Int -> R b a -> R b a
```
```
First, we add a constructorChooseIntegerfor picking integers from an arbitrary range. Techni-
cally, this is implementable viaPickby simply enumerating all of the integers in the desired range,
but doing so is inefficient if the range is large. Adding a separate function for choosing within a
range of integers allows us to bootstrap other generators over large ranges, and it it makes it easy
to implement much more efficient interpretation functions later on.
Second, we add two constructors,GetSizeandResize, that are analogous to similar opera-
tions implemented by QuickCheck. Maintaining size control is critical for ensuring generator
termination, and, although it is possible to implement sized generators by passing size parameters
around manually, internalizing size control cleans up the API of the combinator library and makes
generators more readable.
In future sections, we often elide parts of definitions pertaining to these operations, to streamline
the presentation, but they do present a couple of theoretical complications that we note in §4.
```
```
Building a Domain-Specific Language.We implement a variety of combinators that make reflective
generators easier to read and write, aiming for an interface that captures the full power of reflective
generation without straying too far from familiar QuickCheck syntax.
The most important reflective generator operation isPick, so we provide a number of choice
combinators that are built on top of it:
```
```
pick :: [(Int, String, Reflective b a)] -> Reflective b a
labeled :: [(String , Reflective b a)] -> Reflective b a
frequency :: [(Int , Reflective b a)] -> Reflective b a
oneof :: [Reflective b a] -> Reflective b a
choose :: (Int, Int) -> Reflective Int Int
```
```
The most flexible,pick, just passes through to thePickconstructor, wielding its full power. The
rest are simplifications of this operation that represent common use cases. A bit simpler,labeled
takes only choice labels and no weights—it sets all weights to 1. Finally,frequency,oneof, and
choosehave the same API as their counterparts in QuickCheck, forgoing choice labels.
```

```
200:8 Goldstein and Frohlich et al.
```
A brief aside on choice labels: whether or not a user decides to label the choices in a generator
depends on two factors. First, it depends on how the generators will be used. In §5.1, we discuss a
use case that relies heavily on choice labels, and in §6 we discuss one that ignores them. Second,
whether or not a particular sub-generator is labeled can impact the behavior of use cases that pay
attention to labels; in §5.1 we discuss intentionally eliding labels as a way of marking parts of
the generator whose distributions should not be tuned. As a general rule, we recommend labeling
choices in generators, and all generators provided by the reflective generators library are labeled by
default, but it is convenient to be able to elide labels when upgrading from a QuickCheck generator.
Choice operators alone are not enough to build a reflective generators, we need infrastructure to
glue them together. The bulk of these glue operations follow from the fact that reflective generators
are, as expected, PMPs:^2
instance Profunctor Reflective where
lmap _ (Return a) = Return a
lmap f (Bind x h) = Bind (Lmap f x) (lmap f. h)
rmap = fmap

```
instance PartialProfunctor Reflective where
prune (Return a) = Return a
prune (Bind x f) = Bind (Prune x) (prune. f)
Bothlmapandprunecommute overBindand do nothing to aReturn(see the laws in §4), so these
implementations are straightforward. Behind the scenes, theFunctor,Applicative, andMonad
operations are implemented for free from the freer monad.
Usinglmapandpruneon their own is a bit tedious, so we give two combinators that make
common use cases much simpler. Thefocuscombinator makes it possible to replace pattern
matches inlmapannotations withlenses[Foster 2009].
focus :: Getting (First b) c b -> Reflective b a -> Reflective c a
focus p = lmap (preview p). prune
The curious reader can dig into the gory details of the types^3 involved, but it suffices to understand
focusas a notational convenience that gives a terse syntax for pattern matches:
focus (_Node._2) g = (lmap (\ case { Node _ x _ -> Just x; _ -> Nothing }). prune) g
This call tofocusidentifies the part of the value thatgproduces: the second argument to theNode
constructor. The neat thing about this setup is that_Node, a lens that “pattern matches” on a node,
can be automatically generated from theTreedatatype, and_2, which extracts the second element
of ak-tuple, is included in the lens library. Together they can match on and extract the part of the
value that the reflective generator needs to focus on.
Another convenient helper built fromlmapandpruneisexact, which operates likereturnbut
ensures that the returned value is exactly the expected one:
exact :: Eq a => a -> Reflective a a
exact a = (lmap (\ a'-> if a == a'then Just a else Nothing)
```
. prune) (Pick [(1, Nothing, return a)])

(^2) Technically, these definitions are not legal Haskell, since both partially apply theReflectivetype constructor, which is
not supported by GHC. In the Haskell artifact we implement the operations as normal functions (rather than type-class
methods).
(^3) https://hackage.haskell.org/package/lens-5.2/docs/Control-Lens-Getter.html


```
Reflecting on Random Generation 200:
```
```
bst :: (Int, Int) -> Reflective Void Tree
bst (lo, hi) | lo > hi = return Leaf
bst (lo, hi) =
frequency
[ ( 1, return Leaf),
( 5, do
x <- voidAnn (choose (lo, hi))
l <- voidAnn (bst (lo, x - 1))
r <- voidAnn (bst (x + 1, hi))
return (Node l x r) ) ]
```
```
Fig. 3. An intermediate generator withVoidas its contravariant type, usingvoidAnn.
```
```
Using this function (or manuallypruneing) at the leaves of a reflective generator is critical: without
it, the generator may incorrectly claim to be able to produce an invalid value.
We saw above that combinators likeoneof,frequency, andchoosealign closely with the
QuickCheck API to make upgrading easier. We provide one more combinator to simplify the
upgrade process,voidAnn, which can be used in place of an annotation:
voidAnn :: Reflective b a -> Reflective Void a
voidAnn = lmap (\ x -> case x of)
TheVoidtype in Haskell is uninhabited, and thus a reflective generator of typeReflective Void a
can only be used in limited cases, butvoidAnnmakes it possible to perform the upgrade from
Figure 1 in stages. First, go from Figure 1a to Figure 3, then go from Figure 3 to Figure 1b by
replacingVoidwith the correct output type, replacingvoidAnnannotations with ones that do
appropriate focusing, and replacingreturnwithexactwhere appropriate. All three generators
are shown together in Appendix B. Experienced reflective generator writers do the upgrade in a
single step, but when starting out it may be easier to take a detour through a simpler intermediate
generator.
There are a number of other combinators implemented in the artifact, includinggetSize,resize,
standard generators for base types, and higher-order combinators for lists and tuples.
```
3.3 Interpretation
Like free generators, reflective generators do not do anything interesting until they areinterpreted.
An interpretation describes how the inert syntax of the generator program should be executed. As
with PMPs, most reflective generator interpretations can be thought of as working either “forward,”
simply producing an output of their covariant type, or “backward,” reflecting on a value (and
reproduce iten passant) while tracking choices. Unlike PMPs, reflective generators do not explicitly
pair a forward and a backward interpretation together—in fact, the interpretation in §7.2 actually
uses both directions at once. Still, directionality of interpretations is often a useful intuition.
The simplest “forward” interpretation turns a reflective generator into a standard QuickCheck
generator, shown in Figure 4 The free monad part of the syntax is implemented as expected, with
Returnimplemented asreturnin theGenmonad, andBindas the monad’s bind. The rest of the
syntax is similarly straightforward, withLmapandPrunedoing nothing andPickinterpreted as a
weighted random choice.
Of course, the value of reflective generators lies in their ability to run “backward,” focusing on
sub-parts of a value and reflecting on how they are constructed. This process can be seen using


```
200:10 Goldstein and Frohlich et al.
```
```
generate :: Reflective b a -> Gen a
generate = interp
where
interpR :: R b a -> Gen a
interpR (Pick gs) = QC.frequency [(w, interp g) | (w, _, g) <- gs]
interpR (Lmap _ r) = interpR r
interpR (Prune r) = interpR r
```
```
interp :: Reflective b a -> Gen a
interp (Return a) = return a
interp (Bind r f) = interpR r >>= interp. f
```
```
Fig. 4. The “generate” interpretation.
```
```
thereflectfunction in Figure 5, which interprets a generator to determine which choices could
lead to a given value. For example, it would behave as follows when run onbst(adapted to record
choices):
```
```
ghci> reflect bst Leaf
[["leaf"]]
ghci> reflect bst (Node Leaf 4 Leaf)
[["node","4","leaf","leaf"]]
```
Here, the constructor choice is indicated with"leaf"or"node", and the number choice by printing
the number. A list of lists is produced so that all possible choice traces are covered. (In these examples,
there just happens to be only one trace of choices that could have led to the provided values.)
When interpretingPickthe computation splits, each branch representing making one particular
choice. In each branch,Lmapnodes focus on parts of the value being reflected on; if the focusing
fails, a followingPrunenode will filter that branch out of the computation. The monad structure,
ReturnandBind, threads the list of recorded choices through the computation, so the final result
is a list of the different branches of the computation that were not pruned, along with the choices
made in each of those branches.
These two interpretations demonstrate the essence of reflective generators, but they are far from
the only ones—in total we discuss seven use cases of our different interpretations, all of which can
be found in our artifact, and we expect there are use cases for many more. As a user, this gives an
amazing amount of flexibility, since a single reflective generator can be interpreted in all of these
ways.

### 4 THEORY OF REFLECTIVE GENERATORS

```
In this section, we describe more of the theory underlying reflective generators. We discuss various
formulations of correctness, including defining what it means to correctly interpret a reflective
generator and what it means to correctly write an individual reflective generator (§4.1). Next, we
explore an interesting property of reflective generators—overlap—which has implications for gener-
ator efficiency (§4.2). Finally, we discuss the expressive power of reflective generators, comparing
it to grammar-based generators and to standard monadic ones (§4.3).
```

Reflecting on Random Generation 200:

```
reflect :: Reflective a a -> a -> [[String]]
reflect g = map snd. interp g
where
interpR :: R b a -> (b -> [(a, [String])])
interpR (Pick gs) = \ b -> −−Record choices made.
concatMap
( \ (_, ms, g') ->
case ms of
Nothing -> interp g'b
Just lbl -> map (\ (a, lbls) -> (a, lbl : lbls)) (interp g'b)
) gs
interpR (Lmap f r) = \ b -> interpR r (f b)−−Adjust b according to f.
interpR (Prune r) = \ b -> case b of −−Filter invalid branches.
Nothing -> []
Just a -> interpR r a
```
```
interp :: Reflective b a -> (b -> [(a, [String])])
interp (Return a) = \ _ -> return (a, [])
interp (Bind r f) = \ b -> do −−Thread choices around.
(a, cs ) <- interpR r b
(a', cs') <- interp (f a) b
return (a', cs ++ cs')
```
```
Fig. 5. The “reflect” interpretation.
```
4.1 Correctness

Both interpretations and individual reflective generators can be written incorrectly—the types
involved are not strong enough. Here, we describe algebraic properties that the programmer should
prove (or test) to ensure good behavior.

Correctness of Interpretations.Reflective generators should obey the laws of monads [Moggi
1991], profunctors, and PMPs:

```
(M 1 ) return a >>= f = f a
(M 2 ) x >>= return = x
(M 3 ) (x >>= f) >>= g = x >>= (\ a -> f a >>= g)
```
(P 1 ) lmap id = id
(P 2 ) lmap (f'. f) = lmap f. lmap f'
(P MP 1 ) lmap Just. prune = id
(P MP 2 ) lmap (f >=> g). prune = lmap f. prune. lmap g. prune
(P MP 3 ) (lmap f. prune) (return y) = return y
(P MP 4 ) (lmap f. prune) (x >>= g) = (lmap f. prune) x >>= (lmap f. prune). g
Some of these are definitionally true for all reflective generators, thanks to the structure of freer
monads:

```
Lemma 4.1.Reflective generators always obey(M 1 ),(M 3 ),(P MP 3 ), and(P MP 4 ).
```

```
200:12 Goldstein and Frohlich et al.
```
```
Proof.By induction on the structure of the generator, using the definitions ofreturnand(>>=)
from Kiselyov and Ishii [2015] and the definitions oflmapandprunefrom §3.2. See Appendix C. □
The other equations do not hold in general: they must be established for each interpretation.
We say an interpretation of a reflective generator islawfulif it implements a PMP homomorphism
to some lawful partial monadic profunctor. Concretely:
Definition 1.An interpretation
J·K:: Reflective b a -> p b a
islawfuliffpobeys the laws of monads, profunctors, and partial monadic profunctors and there
exists anR-interpretation
J·KR:: R b a -> p b a
such that the following equations hold:
JReturn aK = return a
JBind r fK =JrKR>>= \ x ->Jf xK
JLmap f rKR= lmap fJrKR
JPrune rKR= pruneJrKR
```
An alternative approach would be to simply define an interpretation of a reflective generator as a
PMP homomorphism along with an interpretation forPick, rather than giving the programmer
the freedom to implement lawless interpretations. From a programming perspective, this would
behave like a tagless-final embedding [Kiselyov 2012]. We found this tagless-final approach more
tedious to program with, but it is available to users if desired (see Appendix D).
Thegenerateinstance is indeed lawful, modulo one technical caveat. The classicGen“monad”
itself is not actually a lawful monad, but itislawful up to distributional equivalence [Claessen
and Hughes 2000]—i.e., generators that produce equivalent probability distributions of values are
equivalent, even if they are not equal as Haskell terms. The same caveat applies to the other laws.
Theorem 4.2.Thegenerateinterpretation is lawful up to distributional equivalence.
Proof.SinceLmapandPruneare both ignored, the other laws are trivial. □
Thereflectinterpretation is also lawful, ignoring themap sndprojection that discards the accu-
mulator values.
Theorem 4.3.Thereflectinterpretation is lawful.
Proof.We choose
p b a = b -> [(a, [String])] = ReaderT b (WriterT [String] []) a

which is simply a stack of three monads (reader, writer, and list). Lawfulness follows straight-
forwardly, by aligning the definition ofreflectwith the lawful implementations of the monad,
profunctor, and partial profunctor operations for this combined monad. □
Correctness of a Reflective Generator.The proofs of lawfulness for each of the interpretations we
want to use can be carried out once and for all, but there is also some work to do for each individual
reflective generator, to ensure that its various interpretations will behave the way we expect. We
next characterize what it is for a reflective generator to becorrectand comment on testing for
correctness using QuickCheck.
Our correctness criteria is based on similar notions to those of Xia et al.[2019]. We formulate
correctness using two interpretations. Thegenerateinterpretation is the canonical “forward”


```
Reflecting on Random Generation 200:
```
interpretation, characterizing the set of values that can be produced by a reflective generator when
it ignores its contravariant parameter. The canonical “backward” interpretation should characterize
the generator’s operation as a generalized identity function, taking a value and reproducing it—
reflectis almost the right interpretation, but it does extra work to keep track of choices. Thus,
we define:

```
reflect':: Reflective b a -> b -> [a]
Thereflect'interpretation has the same behavior asreflect, but it skips the code that tracks
choices. It also has a more general, unaligned type. (Alignment is an artificial restriction anyway;
reflectcould also be given an unaligned type, but the alignment better-communicates the intended
use.) The full code for this and all other interpretation functions can be found in our artifact.
We define soundness and completeness of a reflective generator as follows:
Definition 2.A reflective generatorgissoundiff
a∼generate g ==> (not. null) (reflect'g a).^4
```
Wherea∼γmeans “acan be sampled from QuickCheck generatorγ.”

In other words, if thegenerateinterpretation can produce a value, then thereflect'interpretation
can reflect on that value without failing.
Definition 3.A reflective generatorgiscompleteiff
(not. null) (reflect'g a) ==> a∼generate g.
In other words, if thereflect'interpretation successfully reflects on a value, then that value
should be able to be sampled from thegenerateinterpretation.
As there is no way to checka∼generate gdirectly, completeness is impossible to test. Luckily,
Xia et al. give an alternative. First they defineweak completeness:

```
Definition 4.A reflective generatorgisweak completeiff
a∈reflect'g b ==> a∼generate g.
```
Weak completeness is still impossible to test, but it iscompositional, meaning it is true of a generator
if it is true of its sub-generators. Since the only kind of sub-generator reflective generators can be
built from isPick, we can prove this once and for all:
Lemma 4.4.All reflective generators are weak complete.
Proof.By induction on the structure of the generator; see Appendix E. (Note that this relies on
the weights in everyPickbeing strictly positive.) □
Xia et al.also gives a so-calledpure projection property, which is testable (albeit sometimes
intractably^5 ):
Definition 5.A reflective generator satisfiespure projectioniff

(^4) The definition we give for soundness is morally correct, but it will occasionally fail (spuriously) if tested using QuickCheck.
The problem issize: QuickCheck varies the generator’s size parameter while testing, but it does not know to vary the size of
thereflect'interpretation to match. Concretely, this means that QuickCheck may test
a∼resize 100 (generate g) ==> (not. null) (reflect'g a).
which is effectively evaluating two different generators. To get around this, we should instead test
a∼generate (resize n g) ==> (not. null) (reflect'(resize n g) a).
for allnin a reasonable range.
(^5) The precondition of this property is often difficult to satisfy, leading to discards, but since needs only be tested once for
given generator, the user can likely afford a while trying to falsify it.


200:14 Goldstein and Frohlich et al.

a'∈reflect'g a ==> a = a'.
To complete the picture, we prove the following:
Theorem 4.5.Any weak-complete reflective generator satisfying pure projection is complete.
Proof.Assume(not. null) (reflect'g a), so there is somea'inreflect'g a. By pure
projection,a = a'soais inreflect'g a. then by weak completeness we havea∼generate g
as desired. □

The take-away is that testing completeness of a reflective generator directly is impossible, but
testing pure projection suffices, where tractable. When determining the correctness of a reflective
generator, one should definitely test soundness and, where tractable, test pure projection.

External Correctness of a Reflective Generator.The notions of soundness and completeness above
are internal, focused on only the reflective generator itself, but we can also defineexternalsoundness
and completeness with respect to some predicate on the generator’s outputs.
We define the following properties:

Definition 6.A reflective generatorgisexternally soundwith respect topiff

```
x∈gen g ==> p x.
```
Definition 7.A reflective generatorgisexternally completewith respect topiff

p x ==> (not. null) (reflect x g).
Unlike internal soundness and completeness, external soundness and completeness may not
be reasonable to check for every reflective generator. Sometimes there is no external predicate
to check against; other times there may be a predicate, but the generator may intentionally be
incomplete. But it is interesting and useful that both of these aretestable; normal QuickCheck
generators cannot test their own completeness.

4.2 Overlap

One last theoretical property of a reflective generator worth noting is itsoverlap.

Definition 8.A reflective generator’soverlapfor a given value is the number of different ways
that the value could be produced.

Many reflective generators naturally have an overlap of 1, meaning that there is only one way to
generate any given value, but some generators benefit from higher overlap. For example, a generator
might pick between two high-level strategies for generating values for the sake of distribution
control.
But overlap can cause problems for backward interpretations that care about examining all ways
of producing a particular value (e.g.,probabilityOfwhich we will define in §7). In these cases,
overlap may lead to exponential blowup or even non-termination. For example, consider the three
generators in Figure 6. The first,g1, generates natural numbers, each in exactly one way:

```
ghci> reflect g1 (S (S (S (S (S Z)))))−− 5
[["S","S","S","S","S","Z"]]
```
The second,gE, can generate numbers in exponentially many ways; specifically, it can generate a
number by generating any sum of 1 s and 2 s that add to the desired total:

```
ghci> length (reflect gE (S (S (S (S (S Z))))))−− 5
8
ghci> length (reflect gE (S (S (S (S (S (S ...)))))))−− 10
89
```

```
Reflecting on Random Generation 200:
```
```
g1 = labelled [ ("Z", exact Z), ("S", fmap S (focus _S g1)) ]
```
```
gE =
labelled
[ ("Z", exact Z),
("S", fmap S (focus _S gE)),k
("2", fmap (S.S) (focus (_S._S) gE))
]
```
```
gI =
labelled
[ ("Z", exact Z),
("S", fmap S (focus _S gI)),
("inf", gI)
]
```
```
Fig. 6. Reflective generators with unit, exponential, and infinite overlap.
```
Computingreflect gEof a large number could take a very long time, which may be a problem
for some use cases. Finally, we havegIwhich includes the option to make a no-op choice,"inf":
ghci> length (reflect gI (S (S (S (S (S Z))))))−− 5
...
Callingreflect gIdoes not terminate—there are infinitely many ways to generate 5. However,
we conjecture that any generator with infinite overlap can be made into one that does not, by
ensuring that any loop is guarded by some change to the generated structure.

```
4.3 Expressiveness
Reflective generators fall on a spectrum between simple grammar-based generators and complex
monadic ones. Here, we show off the different kinds of data constraints that reflective generators
can express and discuss a few idioms that they cannot express.
Grammar-Based and Monadic Generators.Grammar-based generators [Godefroid et al.2008]
use a context-free grammar describing the program’s input format as the basis for generating test
inputs. For example, the following grammar fragment defines a generator of expression parse trees:
term -> factor | term "*" factor | term "/" factor
Read as a generator, this says “to generate aterm, choose either afactor, a"*"node, or a"/"
node.” Grammar-based generators are useful for generating inputs to a program with a context-free
input structure, like expression evaluators, JSON minifiers, or even some compilers. They are often
used in fuzzing, which we will discuss more in §6.3, for this reason. But grammar-based generators
cannot ensure that the values they generate satisfy context-sensitive constraints. One might, for
example, want to ensure that the left-hand side of a division does not evaluate to zero:
term -> factor | term "*" factor | term "/" nonzero(factor)
```
A complete generator of these expressions would require evaluation to take place during generation,
which is not possible as part of a context-free grammar. And this is just the tip of the iceberg: there
are a host of context-sensitive constraints that a generator might need to satisfy.
Enter monadic generators. As described in §2.1, monadic generators were introduced with
QuickCheck and are a domain-specific language for writing generators that produce values satisfy-
ing arbitrary computable constraints. Monadic generators can generate binary search trees [Hughes
2019], well-typed terms in a simply-typed lambda calculus, and more. Monadic generators subsume
context-free generators, for example, the following generator subsumes the term generator above:
term = oneof [fmap Factor factor, liftM2 Mul term factor, liftM2 Div term factor]

And with a bit more effort, we can exclude the parse trees with a divide-by-zero error:


```
200:16 Goldstein and Frohlich et al.
```
```
term = oneof [ fmap Factor factor, liftM2 Mul term factor,
do f <- factor
if eval f == 0 then liftM2 Mul term (return f) else liftM2 Div term (return f) ]
```
```
There is technically one more rung on this ladder: Hypothesis generators. While they are not
computationally more powerful than monadic ones, they are implemented in Python and can thus
perform arbitrary side-effects while generating. See Appendix F for an example of a Hypothesis
generator. As we move on to analyzing reflective generators’ expressiveness, we continue to focus
on pure generators, but incorporating an extra monad argument (and thus, arbitrary effects) to
reflective generators is compelling future work.
```
```
What Reflective Generators Can Do.As a start, reflective generators are certainly at least as
powerful as grammar-based generators.
```
```
Claim 1.Every grammar-based generator can be turned into a reflective generator via an analogous
procedure to the one for monadic generators.
```
```
Justification.A grammar can be made into a monadic generator in the following way. For
every ruleS→α 1 | ··· |αn, we can write a generator
```
```
s = oneof [liftMi C 1 T(α 1 ), ..., liftMj Cn T(αn)]
```
whereC 1 throughCnare fresh data constructors, andTtranslates each production by turning
non-terminals into the appropriate sub-generator and turning terminals into terminals into Haskell
strings. To turn that monadic generator into a reflective generator, simply addfocusannotations
that extract each argument from each constructor (C). □

```
For example, this is thetermgenerator that results from translating the grammar-based generator
to a reflective generator:
```
```
term = oneof [
fmap Factor (focus _Factor factor),
liftM2 Mul (focus (_Mul._1) term) (focus (_Mul._2) factor),
liftM2 Div (focus (_Div._1) term) (focus (_Div._2) factor) ]
```
```
In fact, reflective generators can implement all of the examples we previously listed as the
motivation for monadic generators (see the binary search tree generator in Figure 1b and the STLC
generator fragment below). There are also a variety of examples in §5.1 and §6 that are expressible
by monadic generators and not context-free ones.
To see how reflective generators fare in a complex case, consider a reflective generator for terms
in a simply-typed lambda calculus (STLC). The STLC generator is built from two sub-generators:
```
```
type_ :: Reflective Type Type
expr :: Type -> Reflective Expr Expr
```
(The underscore preventstype_from being interpreted as a keyword.) The STLC generator works
by picking a type, then generating a value of that type. The monadic version of the generator
would simply writetype_ >>= expr. But this does not work for a reflective generator; it needs an
annotation. Specifically, what’s needed is a mapping fromExprtoTypethat can focus on the type
in the expression. Pleasingly, this focusing is precisely type inference! The type-correct reflective
generator is:comap typeOf type_ >>= expr.


```
Reflecting on Random Generation 200:
```
What Reflective Generators Can’t Do.Given that reflective generators seem to be able to ex-
press so much, it may be easier to characterize what theycan’texpress. The biggest limita-
tion of reflective generators is that they cannot represent any approach to generation that fun-
damentally loses information about previously generated data. For example, in the generator
lmap ??? g >>= \ _ -> g', the annotation is missing because there is no valid annotation to
write: the value generated bygcannot be “focused” on as part of the final structure. Why might this
come up? One case is when the generator generates a value and then computes some un-invertible
function on it; there would be no way to recover the original value to analyze the choices made
when producing that value.
We have run across very few generators that fundamentally require an un-invertible function,
but one interesting examples is some formulations of System F [Girard 1986; Reynolds 1974]. It
is possible (though challenging) to write a monadic generator for System F [Pałka et al.2011],
but impossible to do so for reflective generators. The problem can be seen when referring back
to the reflective generator for STLC terms, which uses type inference to recover a type from an
expression. If we tried to translate this generator to one for System F, we would have a problem:
type inference for System F is undecidable! Thus, the generator may fail to run backward, even if it
works correctly when run forward. Of course, in practice one could write a reflective generator
for System F terms which would work modulo some time-outs, but this is a neat example of the
dividing line between monadic and reflective generators.
System F is a rare example of a fundamental limitation of reflective generators, but there are a
few common generation idioms that reflective generators need to work around. First, reflective
generators cannot use the QuickCheck combinator “suchThat”, which samples a value and then,
if it does not satisfy a some predicate, throws it away,increases the size parameter, and samples
another. The size manipulation is the problem here: to correctly reflect on a value, the backward
direction would need to keep trying generators, recording and throwing away choices, until one
succeeds; as far as we know this is not possible with the current structure. The solution is simply
to avoidsuchThatin favor of generators that satisfy predicates constructively—this would be
our recommendation anyway, sincesuchThatcan be extremely slow in complex cases. Second,
reflective generators do not support a relatively common idiom where generators pick an integer
and then use that integer to bias the generation distribution in some way. This is problematic
because there is no way to recover that integer in the backward direction. One could theoretically
encode this pattern viapick: instead ofdo { i <- choose (0, n); k i }, write apickwithn
equally-weighted branches that each callkon a different value ofi. But this is inefficient, so, in
practice, a larger rewrite might be required to get the desired distribution of values.
Bottom line: reflective generators have some ergonomic limitations, but they are almost as
powerful as monadic generators in practice.

```
5 EXAMPLE-BASED GENERATION
In this section, we demonstrate the power of reflective generators in the context of a clever
generation technique that was an early inspiration for their design: example-based generation
(§5.1). We replicate and generalize the prior work using reflective generators (§5.2).
```
5.1 Inputs from Hell
Inputs from Hell[Soremekun et al.2020] (IFH) describes an approach to random testing that starts
with a set of user-provided example test inputs and randomly produces values that are either quite
similar to or quite different from those examples—the idea being that similar values represent
“common” inputs and that different ones represent interestingly “uncommon” inputs. By drawing
test cases from both of these classes, IFH is able to find bugs in realistic programs.


```
200:18 Goldstein and Frohlich et al.
```
```
The IFH approach is based on grammar-based generation. Examples provided by the user are
parsed by the grammar, and the resulting parse trees are used to derive weights for a probabilistic
context-free grammar (pCFG) that generates the actual test inputs. For example, given a simple
grammar for numbers
num -> "" | digit num digit -> "1" | "2" | "3"
and the example 12 , the IFH technique might derive the following pCFGs:
num -> 33% "" | 66% digit num digit -> 50% "1" | 50% "2" | 0% "3" −−common
num -> 66% "" | 33% digit num digit -> 0% "1" | 0% "2" | 100% "3" −−uncommon
Each production is given a weight based on the number of times it appears in the parse tree for the
provided example (more or less weight, depending on whether the goal is to generate common
or uncommon inputs). The first grammar puts more weight on the 1 and 2 , since it is trying to
generate more inputs like the initial example, whereas the second puts more weight on 3 because
it is trying to generate inputsunlike 12.
```
```
5.2 Reflecting on Examples
This process—parse the input, analyze the parse tree, and re-weight the grammar—is fairly straight-
forward to implement in the setting of grammar-based generation, but the IFH work does not
extend to monadic generators. As we discuss in §4.3, this is a significant limitation. Reflective
generators can bridge this gap by recapitulating the ideas in IFH but using a reflective generator
for IFH’s parsing and generation steps.
```
Implementation.We define three functions, corresponding to the parsing, analysis, and re-
weighting operations for grammars in the IFH paper:

```
reflect :: Reflective a a -> a -> [[String]]
analyzeWeights :: [[String]] -> Weights
genWithWeights :: Reflective b a -> Weights -> Gen a
```
We have already seenreflect: it reflects on a generated value and produces lists of choices that
were made to produce that value. With the choice sequences in hand,analyzeWeightsaggregates
the choices together to produce a set of weights that say how often to expand one rule versus
another. This allows a new interpretation,genWithWeights, to generate new values by making
choices with the weights calculated from the user-provided examples.
When a reflective generator looks like a grammar (as withtermin §4.3), this process replicates
the IFH algorithm exactly. But we have seen that reflective generators are far more powerful than
grammar-based generators, so the new algorithm both replicatesand generalizesIFH, enabling
example-based generation for a much larger class of generators.
These interpretations rely heavily on choice labels, which we discuss briefly in §3.2. These labels
are used byreflectandgenWithWeightsto track the choices that should be weighted higher or
lower based on the examples. This means that, rather than building reflective generators withoneof
orfrequency, the programmer should uselabeledorpick. Recall that the reflective generators
library provides base generators that are labeled as well. However, there is some flexibility here: if
the programmer would prefer some choicesnotbe re-weighted based on examples, they can simply
elide the labels. This is another way that the reflective generators approach generalizes IFH.

```
Example-Based Generation in Action.Soremekun et al.[2020] use the IFH tuning algorithm as
part of a comprehensive testing regime; by contrast, we have found them to be most useful as a
quick way to tune a generator to yield a reasonable distribution of sizes and shapes.
```

```
Reflecting on Random Generation 200:
```
To see this in action, consider a generator for JSON documents (the payload) along with a short
hash of the document that can be used as a checksum:
withHashcode :: Reflective String String
The full generator can be found in Appendix G. This is inspired by a generator for JSON documents
from the IFH paper, the reflective version of which is shown in full in Appendix H. Note that, while
the JSON part of the generator is equivalent to a context-free one,withHashcodeis not (since it
has to compute the hash during generation).
To demonstrate how these also achieve the goal of IFH-style generators (that the weighted
generator is preferable to its unweighted counterpart), we sampled 10 JSON documents that
were used in the IFH experiments, ranging from∼200-1,200 bytes long, and used them to weight
withHashcodein the style of IFH. We generated 1,000 documents from that weighted generator, as
well as from the unweighted generator, and compare the results in Figure 7.

```
100 101 102 103 104
Length
```
```
0
```
```
100
```
```
200
```
```
300
```
```
400
```
```
500
```
```
Count
```
```
Weighted
Unweighted
```
```
(a) Length distributions of unweighted and
weighted.
```
```
Unweighted Weighted
```
```
0.
```
```
0.
```
```
0.
```
```
0.
```
```
0.
```
```
0.
```
```
0.
```
```
0.
```
```
JS-Divergence
```
```
(b) Jensen-Shannon divergence of character distri-
butions. Unweighted vs. Examples and Weighted
vs. Examples.
```
```
Fig. 7. Analysis ofwithChecksumtuned by example in the style ofInputs from Hell.
```
```
Figure 7a demonstrates that the weighted generator is far preferable to the unweighted version
in terms of its length distribution. The unweighted distribution, shown in orange, is skewed to the
left (smaller values) and has a huge spike. Inspecting the data revealed that the payloads of these
values are all either{}or[], both relatively uninteresting and certainly not worth generating
hundreds of times! In contrast, the weighted generator has a varied length distribution. It generates
very few trivial values, instead producing a wide distribution that covers more of the input space.
Figure 7b focuses on the samples’character distributions. We counted the occurrences of each
character across all 10 of the example documents, resulting in a probability distribution over char-
acters. Then, for each sample, we computed the Jensen-Shannon divergence^6 [Lin 1991], between
```
(^6) Jensen-Shannon divergence is closely related to the more common Kullback-Leiber (KL) divergence [Kullback and Leibler
1951], but it works better for distributions with differing support because its value is never infinite.


```
200:20 Goldstein and Frohlich et al.
```
```
unlabeled = oneof
[ exact Leaf,
Branch
<$> focus (_Branch._1) unlabeled
<*> focus (_Branch._2) unlabeled ] (10(1(100)0))
```
```
Fig. 8. A Hypothesis-inspired reflective generator and a tree that the generator might produce.
```
the example distribution and the character distribution of the sample and plotted those divergences
in a violin plot. JS divergence measures the difference between two probability distributions, so it
is a simple way of getting a sense of how similar or different the characters in the samples are from
the ones in the examples. The plots show that the unweighted samples are farther from the the
example distribution than the weighted samples.
Without this example-based tuning, the developer ofwithHashcodewould need to think carefully
about the distribution that they want and even harder about how to alter the generator weights to
get there. With example-based tuning, they simply need to assemble 10 or so examples, compute
weights from those, and then use those weights for generation instead.

6 VALIDITY-PRESERVING SHRINKING AND MUTATION
The example-based generation in the previous section illustrates some of the benefits of reflecting
on choices. In this section, we explore those benefits further, using them to implement test input
manipulation algorithms like shrinking and mutation. In this section, we discuss the “internal
test-case reduction” algorithms implemented in the Hypothesis framework for PBT (§6.1), show
that reflective generators make these algorithms much more flexible (§6.2), and finally sketch the
ways that these ideas also apply to test-case mutation (§6.3).

6.1 Test-Case Reduction in Hypothesis
Shrinkingis the process of turning a large counterexample into a smaller one that still triggers a
bug. Shrinking is critical in PBT because bugs are often tickled by very large inputs that are nearly
impossible to use for debugging—shrinking makes it much easier to understand which specific bits
of the value are actually necessary to trigger the bug.
In QuickCheck, users can either useGHC’s Generics [Magalhães et al.2010] to derive a shrinker
automatically for a given type, or they can write a shrinker by hand. The former is effective in
simple cases, as we will see below, but it is not very general—these automatic shrinkers only
know about the type structure, so they cannot ensure that the shrunken values satisfy important
preconditions nor adequately shrink less structured data like strings. The latter is totally general,
but many users find writing shrinkers by hand confusing and error-prone.
This unsatisfying situation led MacIver and Donaldson [2020] to design Hypothesis’s “internal
test-case reduction,” which gives the best of both worlds. It solves the generality issue without
requiring user effort or understanding. The key insight is that the generator itself already has all of
the information needed to produce precondition-satisfying inputs, so the generator should be used
as part of the shrinking process. The accompanying clever trick is toshrink the random choices
used to generate a value, rather than shrinking the value itself.
Concretely, Hypothesis represents its input randomness as a bracketed string of bits. For example
(10(1(100)0))produces the tree in Figure 8. The first bit says to expand the top-level node, the
second says that the left-hand subtree is a leaf, and so on. Each level of bracketing delineates some


Reflecting on Random Generation 200:21

choices that are logically nested together (in this case, on a particular level of the tree). Hypothesis
aims to shrink these bitstrings by finding theshortlex minimumstring of choices that results in a
valid counterexample; shortlex order considers shorter strings to be less than longer strings, and
follows lexicographic ordering otherwise (brackets are ignored for the purpose of ordering). In
practice, shortlex order turns out to be an effective proxy for complexity of generated test cases:
smaller bitstrings tend to produce smaller test cases.
The actual shrinking procedure uses a number of different passes, each of which attempts to
shorten the choice string, swap 1 s with 0 s, or both, resulting in a shortlex-smaller choice string.
The passes are described in the Hypothesis paper and available in the open source codebase^7.

6.2 Reflective Shrinking

The downside of the Hypothesis approach is that this style of shrinking only works if the random
bitstring that produced the target value is still available—without it, there is nothing to shrink.
But there are many reasons one might want to shrink a value for which one doesnothave a
corresponding bitstring. In particular, shrinking can be useful for understanding externally provided
values that were not produced by the generator at all; for example, if a user submits a bug report
containing a printout of some large input that caused a crash, it might be much easier to debug
the problem with the help of a shrinker. Similarly, internal shrinking does not work if the value
has been modified at all between generation and shrinking, as might be desirable when doing
fuzzing-style (see §6.3) testing where test inputs are mutated to explore values in a particular region.
Luckily, reflective generators can help.

Extracting Bracketed Choices Sequences.We implementreflective shrinkingvia yet another inter-
pretation of reflective generators, with the following type:

```
data Choices = Choice Bool | Draw [Choices]
choices :: Reflective a a -> a -> [Choices]
```
TheChoicestype describes rose trees with two types of nodes:Choice, which represents a single-
bit choice, andDrawwhich represents some nested sequence of choices;^8 this type is isomorphic
to the bracketed choice sequences that Hypothesis uses. Thechoicesfunction takes a reflective
generator and a value and produces the choice sequences that result in generating that value.
The implementation ofchoicesis similar to that ofreflect. It performs a “backward” inter-
pretation of the generator, keeping track of choices as it disassembles a value. This interpretation
ignores choice labels, since Hypothesis shrinks at a lower level of abstraction. Instead, the inter-
pretation of aPicknode determines how many bits would be required to choose a branch (by
taking the log of the length of the list of sub generators) and then assigns the appropriate choice
sequences to each branch. For example:

```
choices (oneof [exact 1, exact 2, exact 3]) 2 = [Draw [Choice False, Choice True]]
```
```
(10(1(100)0)) => (1(100)0)
(100)
```
```
(a) Shrinks fromsubTrees.
```
```
(10(1(100)0)) => (10(00000))
(10(0000))
(10(000))
(10(00))
(10(0))
(10)
```
```
(b) Shrinks fromzeroDraws.
```
```
(10(1(100)0)) => (0111000)
(1010100)
```
```
(c) Shrinks fromswapBits.
```
```
Fig. 9. Shrinking strategies.
```
```
Shrinking Strategies.With an appropriate bracketed choice
sequence in hand, shrinking can begin. We implemented a rep-
resentative subset of the shrinking passes described in the Hy-
pothesis paper: one pass tries shrinking to every available child
sequence of the original, a second replacesDrawnodes with
zeroes, and a third swaps ones and zeroes to produce lexically
```
(^7) https://github.com/HypothesisWorks/hypothesis
(^8) In the Haskell artifact, we use a slightly more complicated type, caching size information to make shortlex comparisons
faster.
Proc. ACM Program. Lang., Vol. 7, No. ICFP, Article 200. Publication date: August 2023.


```
200:22 Goldstein and Frohlich et al.
```
```
Table 1. Average size of shrunk outputs after reflective shrinking, compared with Hypothesis shrinking,
QuickCheck’sgenericShrink, and un-shrunk inputs. (Mean and two standard-deviation range.)
∗Hypothesis experiments not re-run, data taken from [MacIver and Donaldson 2020].
```
```
Reflective Hypothesis∗ QuickCheck Baseline
binheap 9.15 (8.00–10.30) 9.02 (9.01–9.03) 9.14 (8.12–10.16) 14.89 (7.01–22.77)
bound5 3.06 (0.60–5.52) 2.08 (2.07–2.10) 17.75 (0.00–62.32) 131.48 (0.38–262.59)
calculator 5.03 (4.54–5.52) 5.00 (5.00–5.00) 5.07 (4.21–5.92) 13.75 (1.60–25.90)
parser 3.70 (2.21–5.20) 3.31 (3.28–3.34) 3.67 (2.69–4.64) 40.04 (0.00–127.51)
reverse 2.00 (2.00–2.00) 2.00 (2.00–2.00) 2.00 (2.00–2.00) 2.67 (0.76–4.57)
```
smaller choices strings. The results ofsubTrees,zeroDraws,
andswapBitsare shown in Figures 9a, 9b, and 9c accordingly.
Replicating Hypothesis Evaluation.To check that we repli-
cated Hypothesis shrinking correctly, we replicated one of the
experiments from the Hypothesis paper. MacIver and Donaldson
borrowed five examples from the SmartCheck repository [Pike
2014] that represent a varied range of shrinking scenarios. Each
example comes with a property, a buggy implementation, and
a QuickCheck generator; the goal was to run the property to
find a counterexample and shrink that counterexample to the
smallest possible value.
We upgraded the existing QuickCheck generators to reflective
ones, making minor modifications where necessary: we replaced
uses ofsuchThatwith generators that satisfied invariants con-
structively, modified some of the approaches to distribution man-
agement, and added appropriate reflective annotations. These
modifications are based on the observations from §4.3. Then, we ran each experiment 1,000 times
and reported the average size of the resulting counterexamples in Table 1. Note that the QuickCheck
and baseline numbers come from thegenerateinterpretation of the upgraded reflective generator,
rather than the original generator.
We find that reflective shrinkers perform just as well as QuickCheck’sgenericShrinkin all
cases, and significantly better inbound5. With a few caveats, reflective shrinkers also match
Hypothesis. They exhibit a higher variance in the size of counterexamples that they produce, likely
because they only implement a subset of Hypothesis’s shrinking strategies, but nevertheless their
counterexamples are on average within 1 unit of Hypothesis (and usually much closer). The worst
experiment relative to Hypothesis isbound5; in that example, we suspect the difference is due to
differing strategies for generating integers, rather than anything to do with shrinking directly.
A Realistic Example.As a final demonstration that reflective shrinkers are useful, we return to a
modified version of the JSON example used in §5. We define a generator for “package.json” files,
which are used as a configuration format in Node.js. Programs that process these files may be used
by millions of users, so a user may indeed find a bug in the program that a PBT regime did not.
Imagine a scenario where a user finds a bug where a program behaves incorrectly only when
the file specifies a specific version of a specific package. In this case, shrinking would be extremely
helpful: it would help the developers of the program isolate the exact lines in the JSON file that
cause a problem. But shrinking a JSON file like this is impossible for bothgenericShrinkand
Hypothesis. The former does not work because the format is too unstructured: the generator


```
Reflecting on Random Generation 200:23
```
```
produces JSON strings, rather than a Haskell datatype, so the best the shrinker could do is shorten
the string (which would result in invalid JSON). The latter does not even start to shrink, since the
JSON file came from a user, and therefore there is no random bitstring to shrink.
A reflective shrinker, however, works perfectly. Appendix I shows two JSON documents, the
first a full “buggy” version and the second a shrunk version. The shrunk JSON document could
point a developer to the precise issue with their program.
```
6.3 Reflective Mutation
HypoFuzz, a tool for coverage-guided fuzzing [Fioraldi et al.2020] of PBT properties, is a newer and
lesser-known part of the Hypothesis ecosystem. Like Crowbar [Dolan and Preston 2017], HypoFuzz
uses a PBT generator to aid the fuzzer. Fuzzers try to maximize code coverage by keeping track of
a set of interesting inputs andmutatingthem, attempting to explore similar values and hopefully
continue to cover new branches of the program. “Mutating well” can be challenging, since naïve
mutations will rarely produce valid values; HypoFuzz gets around this concern with the same trick
Hypothesis uses for fuzzing: mutate the randomness, not the value.
Internal mutation has all of the same benefits and drawbacks as internal shrinking. On the
positive side, it is type agnostic, easy to use, and guarantees validity of the mutated values. On the
other side, it assumes that the randomness used to produce a given value is available. It may seem
like this drawback is less of an issue for mutation than it is for shrinking, since the fuzzer can just
keep track of the random choices associated with each value it wants to mutate, but this is not
true of the initial set ofseed inputs. For optimal fuzzing, the seeds are provided by the user and
represent some set of initially interesting values that the fuzzer can play with. but this does not
work with Hypothesis-style mutation: the seeds needed for this style are not user-comprehensible
values but choice sequences! Once again, reflective generators provide a compelling solution. We
can simply extract a choice sequence from each seed using thechoicesinterpretation.

```
7 IMPROVING THE TESTING WORKFLOW
So far we have seen reflective generators in the context of example-based generation, shrinking, and
mutation. In this section, we explore several more useful interpretations, demonstrating reflective
generators’ power and flexibility.
```
```
7.1 Reflective Checkers
The “bigenerators” in the original work on PMPs [Xia et al.2019] can be viewed as a special case of
reflective generators. Rather than rather than reflect on a value and produce choices, a bigenerator
simply checks whether a value is in the range of the generator, effectively checking if the value
satisfies the invariant that the generator enforces. Reflective generators can do this too, by reflecting
on the generator’s choices and asking whether or not there exists a set of choices that results in
the desired value.
Going further, a reflective generator can calculate theprobabilityof generating a particular
value with thegenerateinterpretation. We implement this in our artifact as an interpretation,
probabilityOf, which tracks the different ways of generating a particular value and the likelihood
of choosing those different ways. Obviously this works best when the generator’s overlap is low
(see §4.2)—in cases where overlap is exponential or infinite this may be slow or fail to terminate.
```
```
7.2 Reflective Completers
```
A rather different use case for reflective generators is generation based on apartial value. For
example, imagine a binary search tree with holes:


```
200:24 Goldstein and Frohlich et al.
```
```
Node (Node _ 1 _) 5 _
Reflective generators provide a way torandomly completea value like this, filling the holes with
appropriate randomly generated values:
```
```
Node (Node Leaf 1 Leaf) 5 Leaf
Node (Node Leaf 1 (Node Leaf 3 Leaf)) 5 (Node (Node Leaf 6 Leaf) 7 Leaf)
```
This technique lets the user pick out a sub-space of a generator, defined by some value prefix,
and explore that sub-space while maintaining any preconditions that generator enforces. We
accomplish this with some carefully targeted hacks, representing a partial value as a value containing
undefined: [HG: TODO: Cite Natasha][Sam: is an acknowledgement at the end the best way to do
this as we have nothing to point at][HG: I chatted with her on Slack—the plan was to put nothing
for now, and cite the IFL paper if it gets accepted. If it doesn’t, we could always cite an arXiv
version? Or just ack]Node (Node undefined 1 undefined) 5 undefined.
Suppose, now, that this value were passed into a backward interpretation ofbstfrom §1—where
would things fail? The key insight is that theonlyplace a reflective generator manipulates its
focused value is when re-focusing. In other words, the only place a backward interpretation can
crash on a partial value is while interpretingLmap. Capitalizing on this insight, we wrap the standard
Lmapinterpretation in a call tocatch, Haskell’s exception handling mechanism:

```
complete :: Reflective a a -> a -> IO (Maybe a)
...
interpR (Lmap f x) b =
catch
(evaluate (f b) >>= interpR x)
(\(_ :: SomeException) -> fmap (: []) (QC.generate (generate (Bind x Return))))
```
As long as no exception occurs, the code works as before. If there is ever an exception, the current
value is abandoned and the rest is generated via thegenerateinterpretation. In other words,
completemixes both backward and forward styles of interpretation to achieve its goals.
This trick works best for “structural” generators that only do shallow pattern matching inLmaps,
things fall apart if the backward direction needs to evaluate the whole term. The clearest example
of this iscomap typeOf type_ >>= expr(recall, it generates a type and then a program of that
type); in the backward direction, this generator immediately evaluates the whole term to compute
its type. For this generator,completewould just generate a totally fresh program.
Users may be able to work around this by making their predicates lazier. For example, one
could imagining writing an optimistic type checking algorithmoptimisticTypeOfthat maxi-
mizes laziness by blindly trusting user-provided type annotations. The user could then use the
reflective generatorcomap optimisticTypeOf type_ >>= exprto complete an incomplete term
likeApp (Ann (Int :-> Int) undefined) (Ann Int undefined). The completer would suc-
cessfully determine that the type of the whole expression isInt, and then it would have enough
information to complete theundefineds with well-typed expressions.

```
7.3 Reflective Producers
```
Weighted random generation in the style of QuickCheck is not the only way to get test inputs:
both enumeration [Braquehais 2017; Runciman et al.2008] and guided generation [Fioraldi et al.
2020; Zalewski 2022] have been explored as alternatives. Indeed, much of the PBT literature has
moved from talking aboutgeneratorsto talking aboutproducersof test data, where the specific
strategy does not matter [Paraskevopoulou et al.2022; Soremekun et al.2020]. We use the language


```
Reflecting on Random Generation 200:25
```
of “generators” here because it is familiar and concrete, but reflective generators might better be
considered asreflective producersbecause they can also be used in these other styles.
A reflective generator can be made into an enumerator by interpretingPickas an exhaustive
choice rather than a random one. We implement an interpretation
enumerate :: Reflective b a -> [[a]]
for “roughly size-based” enumeration, leaning heavily on the combinators and techniques found
in LeanCheck [Braquehais 2017]. We say “roughly” because, whereas LeanCheck enumerators
allow the user to define their own notion of size for each enumerator, reflective generators are
limited to a single notion of size based on the number and order of choices needed to produce
a given value. A thorough evaluation of this discrepancy would require its own study, but early
experiments are promising. For example,enumerate (bst (1, 10))reaches size-4 BSTs before
its 10th enumerated value and matches the size order of an idiomatic LeanCheck enumerator given
in Appendix J.
While fuzzing is sometimes treated as a separate topic from PBT—focused on finding crash failures
by generating inputs external to a system rather than finding more subtle errors in individual
functions—a number of recent projects have attempted to bridge the gap, and reflective generators
may offer a useful unifying framework for such efforts. We already saw that reflective mutators are
helpful in the context of HypoFuzz-style mutation; reflective generators can also be used to interface
with an external fuzzer in the style of Crowbar [Dolan and Preston 2017], which is designed to
get its inputs from popular fuzzers like AFL or AFL++ [Fioraldi et al.2020; Zalewski 2022]. Since
Crowbar already uses a free-monad-like structure to represent its generators, we can imagine
writing an equivalent reflective generator interpretation that works the same way. More generally,
reflective generators can be used in any producer algorithm that uses a generator as a parser.

```
8 RELATED WORK
This work builds on the ideas of free generators [Goldstein and Pierce 2022] and partial monadic
profunctors [Xia et al.2019]. Free generators are, in turn, built on top of freer monads [Kiselyov
and Ishii 2015], which were initially invented as a better way to represent effectful code in pure
languages. While our implementation remains faithful to the basic conception of freer monads,
there are many insights from Kiselyov and Ishii that we have not yet explored. Likewise, PMPs are
part of the long tradition of bidirectional programming [Foster 2009], and it remains to be seen if
there are stronger ways to tie reflective generators to work on other bidirectional abstractions.
The concrete realization of reflective generators is also related to the implementation of Crow-
bar [Dolan and Preston 2017]. Both libraries use a syntactic, uninterpreted representation for
generators, although the Crowbar version does not incorporate any ideas from monadic profunc-
tors and uses a different type for bind that does not normalize as aggressively.
The idea of reflective generators was originally sparked by the tools developed inInputs from
Hell[Soremekun et al.2020], and these tools in turn tie into the broader world of grammar-based
generation [Aschermann et al.2019; Godefroid et al.2008, 2017; Holler et al.2012; Srivastava and
Payer 2021; Veggalam et al.2016; Wang et al.2019]. Grammar-based approaches are less expressive
than monadic ones, since they can only generate strings from a context-free grammar, and therefore
cannot generate complex data structures with internal dependencies.
Replicating example distributions is a classic problem inprobabilistic programming[Gordon
et al.2014]. While the goals of probabilistic programs are usually quite different from those of PBT
generators, there is some overlap in the formalisms used to express these ideas. In particular, one
representation of probabilistic programs in the functional programming literature [Ścibior et al.
2018] uses a free monad that is similar to free and reflective generators.
```

```
200:26 Goldstein and Frohlich et al.
```
Reflective shrinking and mutation build heavily on ideas in the Hypothesis framework [MacIver
and Donaldson 2020; MacIver et al.2019], but there are other approaches to automated shrinking.
As mentioned in §6, QuickCheck providesgenericShrink, which provides a competent shrinker
for any Haskell type that implementsGeneric. WhilegenericShrinkis a decent starting point, it
fails to shrink unstructured data (like strings) and values with complex preconditions. Another
alternative is provided by Hedgehog [Stanley [n. d.]], another Haskell PBT library. Hedgehog
shrinking is similar to Hypothesis shrinking, using the structure of the generator to enable autoamtic
validity-preserving shirnking. It has the same limitation: externally provided values cannot be
shrunk.

```
9 CONCLUSION AND FUTURE DIRECTIONS
Reflective generators are a powerful abstraction for producing and manipulating test inputs. We
have developed their theory and demonstrated their utility in a variety of testing scenarios, in-
cluding example-based generation, shrinking, mutation, precondition checking, value completion,
enumeration, fuzzing, and more. We plan to build on reflective generators, automating their creation
and improving their usability.
```
```
Automation and Synthesis of Annotations.TheLmapannotations in reflective generators can be
arbitrarily complex, but in practice they are usually simple, predictable functions that operate on
the input’s structure. We hope that, in a large variety of cases, the annotations can besynthesized.
We plan to work with Hoogle+ [James et al.2020], using its type-based synthesis algorithm to
obtain candidate programs for the annotations with no user intervention. This is an especially
compelling opportunity because it is easy to tell whether annotations are correct: they must be
sound and complete, as described in §4. When synthesizing multiple annotations at the same time,
the system can even use the number of examples that pass or fail the soundness and completeness
properties as a way to infer which annotations are correct and which need to be re-synthesized—if
changing an annotation increases the number of passing tests, it is more likely to be correct; if the
change causes more tests to fail, it is likely wrong. If this idea works, it could make transitioning
from QuickCheck generators to reflective generators almost entirely automatic.
```
```
Usability.We have taken care to design an API for reflective generators that aligns with existing
QuickCheck functions and minimizes programmer effort. Our own experience writing reflective
generators studies has been positive, and, except for the aforementioned limitations (§4.3), we ran
into no issues upgrading existing generators. The automation techniques hypothesized above could
make reflective generators even more usable. Still, we certainly do not constitute a representative
sample of PBT users: the usability of reflective generators should be studied empirically.
There is a growing push in the PL community to incorporate ideas and techniques from human-
computer interaction (HCI) [Chasins et al.2021], and this is a perfect opportunity to join that
movement. We plan to collaborate with HCI researchers on a thorough usability analysis of reflective
generators. Inspired by prior work [Coblenz et al.2021], we hope our analysis will be useful for
both assessing and refining our design.
```
```
ACKNOWLEDGMENTS
```
We would like to thank Natasha England-Elbro for help with the implementation and ideas around
value completion; Zac Hatfield Dodds for guidance around Hypothesis and its implementation;
John Hughes and others at Chalmers University for their enthusiastic feedback; and Joseph W.
Cutler, Jessica Shi, Ernest Ng, and the rest of the University of Pennsylvania’s PLClub for constant
support and encouragement.


Reflecting on Random Generation 200:27

This work was financially supported by NSF awards #1421243,Random Testing for Language
Designand #1521523,Expeditions in Computing: The Science of Deep Specification.


200:28 Goldstein and Frohlich et al.

### APPENDIX

### A PARTIAL ARROWS ARE PMPS

```
instance Profunctor PartialArr where
dimap f g (PartialArr p) = PartialArr (fmap g. p. f)
```
```
instance Monad (PartialArr a) where
return b = PartialArr (Just. const b)
(PartialArr p) >>= k = PartialArr (\a -> join (fmap (\x -> unPA (k x) a) (p a)))
−−Same as the one for (−>), but dealing with the maybe
−−bind for (−>): f >>= k = \ r−> k ( f r) r
```
```
prune :: PartialArr b a -> PartialArr (Maybe b) a
prune (PartialArr p) = PartialArr (join. fmap p)
```
### B GENERATOR UPGRADE PROGRESSION

Original:

```
bst :: (Int, Int) -> Gen Tree
bst (lo, hi) | lo > hi = return Leaf
bst (lo, hi) = frequency
[ ( 1, return Leaf ),
( 5, do
x <- choose (lo, hi)
l <- bst (lo, x - 1)
r <- bst (x + 1, hi)
return (Node l x r) ) ]
```
Midpoint:

```
bst :: (Int, Int) -> Reflective Void Tree
bst (lo, hi) | lo > hi = return Leaf
bst (lo, hi) = frequency
[ ( 1, return Leaf),
( 5, do
x <- voidAnn (choose (lo, hi))
l <- voidAnn (bst (lo, x - 1))
r <- voidAnn (bst (x + 1, hi))
return (Node l x r) ) ]
```
Final:

```
bst :: (Int, Int) -> Reflective Tree Tree
bst (lo, hi) | lo > hi = exact Leaf
bst (lo, hi) = frequency
[ ( 1, exact Leaf),
( 5, do
x <- focus (_Node._2) (choose (lo, hi))
l <- focus (_Node._1) (bst (lo, x - 1))
r <- focus (_Node._3) (bst (x + 1, hi))
return (Node l x r) ) ]
```

Reflecting on Random Generation 200:29

### C PROOFS OF LEMMA 4.1 (LAWS)

This appendix proves the equations from Lemma 4.1.

```
(M 1 ) return a >>= f = f a
(M 3 ) (x >>= f) >>= g = x >>= (\ a -> f a >>= g)
(P MP 3 ) (lmap f. prune) (return y) = return y
(P MP 4 ) (lmap f. prune) (x >>= g) = (lmap f. prune) x >>= lmap f. prune. g
Using the following relevant definitions:
```
```
data Freer f a where
Return :: a -> Freer f a
Bind :: f a -> (a -> Freer f c) -> Freer f c
```
```
data R b a where
Pick :: [(Weight, Choice, Reflective b a)] -> R b a
Lmap :: (c -> d) -> R d a -> R c a
Prune :: R b a -> R (Maybe b) a
ChooseInteger :: (Integer, Integer) -> R Integer Integer
GetSize :: R b Int
Resize :: Int -> R b a -> R b a
```
```
type Reflective b = Freer (R b)
```
```
instance Monad (Reflective b) where
return = Return
Return x >>= f = f x
Bind u g >>= f = Bind u (g >=> f)
```
```
prune :: Reflective b a -> Reflective (Maybe b) a
prune (Return a) = Return a
prune (Bind x f) = Bind (Prune x) (prune. f)
```
```
lmap :: (c -> d) -> Reflective d a -> Reflective c a
lmap f = dimap f id
```
```
dimap :: (c -> d) -> (a -> b) -> Reflective d a -> Reflective c b
dimap _ g (Return a) = Return (g a)
dimap f g (Bind x h) = Bind (Lmap f x) (dimap f g. h)
```
```
Proofs of(M 1 )and(M 3 ).Immediate, by definition. □
```
```
Proof of(P MP 3 ).By rewriting.
(lmap f. prune) (return y)
={−def. return−}
(lmap f. prune) (Return y)
={−def. prune (Return case )−}
lmap f (Return y)
={−def. lmap−}
```

```
200:30 Goldstein and Frohlich et al.
```
```
dimap f id (Return y)
={−def. dimap (Return case )−}
Return y
={−def. return−}
return y
Thus(P MP 3 )holds. □
Proof of(P MP 4 ).By induction over the structure of x.
```
Casex = Return a:

```
(lmap f. prune) (Return a >>= g)
={−def. >>= (Return case )−}
(lmap f. prune) (g a)
={−re−bracket−}
(lmap f. prune. g) a
={−def. >>= (Return case )−}
Return a >>= (lmap f. prune. g)
={−def. return−}
return a >>= (lmap f. prune. g)
={−PMP3−}
(lmap f. prune) (return a) >>= (lmap f. prune. g)
={−def. return−}
(lmap f. prune) (Return a) >>= lmap f. prune. g
```
Casex = Bind r h:

```
(lmap f. prune) (Bind r h >>= g)
={−def. >>=−}
(lmap f. prune) (Bind r (h >=> g))
={−def. prune + lmap−}
Bind (Lmap f (Prune r)) (lmap f. prune. (h >=> g))
={−IH−}
Bind (Lmap f (Prune r)) (lmap f. prune. h >=> lmap f. prune. g)
={−def. >>=−}
(Bind (Lmap f (Prune r)) (lmap f. prune. h)) >>= (lmap f. prune. g)
={−def. prune + lmap−}
(lmap f. prune) (Bind r h) >>= lmap f. prune. g
Thus(P MP 4 )holds. □
```

```
Reflecting on Random Generation 200:31
```
### D POLYMORPHIC INTERPRETATION FUNCTION

```
interpret ::
forall p d c.
(PartialProf p, forall b. Monad (p b)) =>
(forall b a. [(Weight, Choice, Reflective b a)] -> p b a) ->
Reflective d c ->
p d c
interpret p = interp
where
interp :: forall b a. Reflective b a -> p b a
interp (Return a) = return a
interp (Bind r f) = do
a <- interpR r
interpret p (f a)
```
```
interpR :: forall b a. R b a -> p b a
interpR (Pick xs) = p xs
interpR (Lmap f r) = lmap f (interpR r)
interpR (Prune r) = prune (interpR r)
```
### E PROOF OF LEMMA 4.4 (WEAK COMPLETENESS)

```
Recall that a reflective generatorgis weak complete iff
a∈reflect'g b ==> a∼generate g.
```
We claim that every reflective generator is weak complete, where the definition ofreflect'is as
follows:

```
reflect':: Reflective b a -> b -> [a]
reflect'= interp
where
interp :: Reflective b a -> b -> [a]
interp (Return x) _ = return x
interp (Bind r f) b = interpR r b >>= \x -> interp (f x) b
```
```
interpR :: R b a -> b -> [a]
interpR (Lmap f r') b = interpR r'(f b)
interpR (Prune r') b = maybeToList b >>= \b'-> interpR r'b'
interpR (Pick gs) b = gs >>= (\ (_, _, g) -> interp g b)
```
```
Proof.By mutual induction over the structure ofFreerandR.
Given a reflective generatorgand a valuea:
```
Caseg = Return a':
Assumea∈reflect'(Return a') b
reflect'(Return a') b = [a'], thusa = a'.
By definition,a'∼return a', soa∼return a'= reflect'(Return a').
Caseg = Bind r f:
Assumea∈reflect'(Bind r f) b.


```
200:32 Goldstein and Frohlich et al.
```
```
Thus,a∈ (interpRreflect′ r b >>= \ x -> reflect'(f x) b).
Thus,∃a'such thata' ∈interpRreflect′ r banda∈ reflect'(f a') b.
By IHR,a'∼interpRgenerater.
By IH,a∼generate (f a').
Thus,a∈ (interpRgenerater >>= \ x -> generate (f x)).
Thus,a∈ generate (Bind r f).
Simultaneously, given anR rand a valuea:
```
Caser = Lmap f r':
Assumea∈interpRreflect′ (Lmap f r') b.
Thus,a∈ interpRreflect′ r'(f b).
By IHR,a∼interpRgenerater'.
Thus,a∼interpRgenerate (Lmap f r').
Caser = Prune r':
Assumea∈interpRreflect′ (Prune r') b.
Thus,a∈ maybeToList b >>= \ b'-> interpRreflect′r'b'.
Thus,∃b'such thata ∈interpRreflect′ r'b'
By IHR,a∼interpRgenerater'b'.
Thus,a∼interpRgenerate (Prune r').
Caser = Pick gs:
Assumea∈interpRreflect′ (Pick gs) b.
Thus,a∈ (gs >>= \ (_, _, g) -> reflect'g b).
Thus,∃g'such that(_, _, g')∈ gsanda∈ reflect'g'b.
By IH,a∼generate g'.
Thus,a∼QC.frequency [(w, interp g) | (w, _, g) <- gs].
(Recall, we assume weights are positive.)
Thus,a∼interpRgenerate (Pick gs).
This completes the proof. □

```
F HYPOTHESIS GENERATOR EXAMPLE
This Hypothesis generator produces valid binary search trees, and can be used for integrated
shrinking in the style of MacIver and Donaldson [2020]. Since this is just a normal Python function,
the generator can use side-effects if desired.
@st.composite
def bsts(draw, lo=-10, hi=10):
if lo > hi:
return Leaf()
else:
if not draw(st.integers(min_value=0, max_value=3)):
return Leaf()
x = draw(st.integers(min_value=lo, max_value=hi))
return Node(x, draw(bsts(lo, x - 1)), draw(bsts(x + 1, hi)))
```

Reflecting on Random Generation 200:33

### G JSON WITH HASH CODE GENERATOR

```
withHashcode :: Reflective String String
withHashcode = do
let a = "{\"payload\":"
let b = ",\"hashcode\":"
let c = "}"
consume a >>- \_ ->
start >>- \payload -> do
let hashcode = take 8 (show (abs (hash payload)))
consume b >>- \_ ->
consume hashcode >>- \_ ->
consume c >>- \_ ->
return (a ++ payload ++ b ++ hashcode ++ c)
where
hash = foldl'(\h c -> 33 * h`xor`fromEnum c) 5381
consume s = lmap (take (length s)) (exact s)
```
A reflective generator for JSON objects with a hashcode, not expressible with a grammar-based
generator. The generator produces a payload, then computes its hash, and then assembles the larger
JSON object containing both.

H GENERATOR FOR JSON DOCUMENTS

This reflective generator encodes the full grammar of JSON documents. While it is complex and
unweildy, we would not necessarily expect a programmer to write this themselves. It follows
the structure of the grammar exactly, so it could be produced automatically from a more concise
representation of the grammar.
Note: We slightly simplified the grammar from the IFH repository, skipping a few rules for
unicode support that were not used by any of the provided examples.

```
token :: Char -> Reflective b ()
token s = labeled [(['\'', s,'\''], pure ())]
```
```
label :: String -> Reflective b ()
label s = labeled [(s, pure ())]
```
```
(>>-) :: Reflective String String
-> (String -> Reflective String String)
-> Reflective String String
p >>- f = do
x <- p
lmap (drop (length x)) (f x)
```
```
−−start = array | object ;
start :: Reflective String String
start =
labeled
[ ("array", array),
("object", object)
```

200:34 Goldstein and Frohlich et al.

```
]
```
```
−−object = "{" "}" | "{" members "}" ;
object :: Reflective String String
object =
labeled
[ ("'{''}'", lmap (take 2) (exact "{}")),
( "'{'members'}'",
lmap (take 1) (exact "{") >>- \b1 ->
members >>- \ms ->
lmap (take 1) (exact "}") >>- \b2 ->
pure (b1 ++ ms ++ b2)
)
]
```
```
−−members = pair | pair ',' members ;
members :: Reflective String String
members =
labeled
[ ("pair", pair),
( "pair','members",
pair >>- \p ->
lmap (take 1) (exact ",") >>- \c ->
members >>- \ps ->
pure (p ++ c ++ ps)
)
]
```
```
−−pair = string ':' value ;
pair :: Reflective String String
pair =
string >>- \s ->
lmap (take 1) (exact ":") >>- \c ->
value >>- \v ->
pure (s ++ c ++ v)
```
```
−−array = "[" elements "]" | "[" "]" ;
array :: Reflective String String
array =
labeled
[ ("'['']'", lmap (take 2) (exact "[]")),
( "'['elements']'",
lmap (take 1) (exact "[") >>- \b1 ->
elements >>- \ms ->
lmap (take 1) (exact "]") >>- \b2 ->
pure (b1 ++ ms ++ b2)
)
]
```

Reflecting on Random Generation 200:35

```
−−elements = value ',' elements | value ;
elements :: Reflective String String
elements =
labeled
[ ("value", value),
( "value','elements",
value >>- \el ->
lmap (take 1) (exact ",") >>- \c ->
elements >>- \es ->
pure (el ++ c ++ es)
)
]
```
```
−−value = "f" "a" " l " "s" "e" | string | array | "t" "r" "u" "e" | number
−− | object | "n" "u" " l " " l " ;
value :: Reflective String String
value =
labeled
[ ("false", lmap (take 5) (exact "false")),
("string", string),
("array", array),
("number", number),
("true", lmap (take 4) (exact "true")),
("object", object),
("null", lmap (take 4) (exact "null"))
]
```
```
−−string = "\"" "\"" | "\"" chars "\"" ;
string :: Reflective String String
string =
labeled
[ ("'\"''\"'", lmap (take 2) (exact "\"\"")),
( "'\"'chars'\"'",
lmap (take 1) (exact ['"']) >>- \q1 ->
chars >>- \cs ->
lmap (take 1) (exact ['"']) >>- \q2 ->
pure (q1 ++ cs ++ q2)
)
]
```
```
−−chars = char_ chars | char_ ;
chars :: Reflective String String
chars =
labeled
[ ("char_", (: []) <$> focus _head char_),
("char_ chars", (:) <$> focus _head char_ <*> focus _tail chars)
]
```

200:36 Goldstein and Frohlich et al.

```
−−char_ = digit | unescapedspecial | letter | escapedspecial ;
char_ :: Reflective Char Char
char_ =
labeled
[ ("letter", letter),
("digit", digit),
("unescapedspecial", unescapedspecial),
("escapedspecial", escapedspecial)
]
```
```
letters :: [Char]
letters = ['a'..'z'] ++ ['A'..'Z']
```
```
−−letter = "a" | .. | "z" | "A" | .. | "Z"
letter :: Reflective Char Char
letter = labeled (map (\c -> ([c], exact c)) letters)
```
```
unescapedspecials :: [Char]
unescapedspecials = ['/','+',':','@','$','!','\''
,'(',',','.',')','-','#','_']
```
```
−−unescapedspecial = "/" | "+" | ":" | "@" | "$" | "!" | "\"
−− | "(" | "'" | "," | "." | ")" | "−" | "#" | "_"
unescapedspecial :: Reflective Char Char
unescapedspecial = labeled (map (\c -> ([c], exact c)) unescapedspecials)
```
```
escapedspecials :: [Char]
escapedspecials = ['\b','\n','\r','\\','\t','\f']
```
```
−−escapedspecial = "\\ b" | "\\ n" | "\\ r" | "\\/" | "\\\\" | "\\ t" | "\\\"" | "\\ f" ;
escapedspecial :: Reflective Char Char
escapedspecial = labeled (map (\c -> ([c], exact c)) escapedspecials)
```
```
−−number = int_ frac exp | int_ frac | int_ exp | int_ ;
number :: Reflective String String
number =
labeled
[ ("int_", int_),
("int_ exp", int_ >>- \i -> expo >>- \ex -> pure (i ++ ex)),
("int_ frac", int_ >>- \i -> frac >>- \f -> pure (i ++ f)),
("int_ frac exp"
, int_ >>- \i -> frac >>- \f -> expo>>- \ex -> pure (i ++ f ++ ex))
]
```
```
−−int_ = nonzerodigit digits | "−" digit digits | digit | "−" digit ;
int_ :: Reflective String String
int_ =
```

Reflecting on Random Generation 200:37

```
labeled
[ ("nonzero digits", (:) <$> focus _head nonzerodigit <*> focus _tail digits),
("digit", (: []) <$> focus _head digit),
( "'-'digit",
(\x y -> x : [y])
<$> focus _head (exact'-')
<*> focus (_tail. _head) digit
),
("'-'digit digits", (:) <$> focus _head (exact'-')
<*> focus _tail ((:) <$> focus _head digit <*> focus _tail digits))
]
```
```
−−frac = "." digits ;
frac :: Reflective String String
frac = label "'.'digits" >> (:) <$> focus _head (exact'.') <*> focus _tail digits
```
```
−−exp = e digits ;
expo :: Reflective String String
expo =
label "e digits"
>> ( e >>- \e'->
digits >>- \d ->
pure (e'++ d)
)
```
```
−−digits = digit digits | digit ;
digits :: Reflective String String
digits =
labeled
[ ("digit", (: []) <$> focus _head digit),
("digit digits", (:) <$> focus _head digit <*> focus _tail digits)
]
```
```
−−digit = nonzerodigit | "0" ;
digit :: Reflective Char Char
digit =
labeled [("nonzerodigit", nonzerodigit), ("' 0 '", exact' 0 ')]
```
```
−−nonzerodigit = "3" | "4" | "7" | "8" | "1" | "9" | "5" | "6" | "2" ;
nonzerodigit :: Reflective Char Char
nonzerodigit =
labeled (map (\c -> ([c], exact c)) [' 1 ',' 2 ',' 3 ',' 4 ',' 5 ',' 6 ',' 7 ',' 8 ',' 9 '])
```
```
−−e = "e" | "E" | "e" "−" | "E" "−" | "E" "+" | "e" "+" ;
e :: Reflective String String
e =
labeled
[ ("'e'", lmap (take 1) (exact "e")),
```

200:38 Goldstein and Frohlich et al.

```
("'E'", lmap (take 1) (exact "E")),
("'e-'", lmap (take 2) (exact "e-")),
("'E-'", lmap (take 2) (exact "E-")),
("'e+'", lmap (take 2) (exact "e+")),
("'E+'", lmap (take 2) (exact "E+"))
]
```
### I EXAMPLE OF REDUCED PACKAGE.JSON

```
{
"name": "reflective-generators",
"description": "What a great project",
"scripts": {
"start": "node ./src/server.js",
"build": "babel ./src -out-dir ./dist",
"test": "mocha ./test"
},
"repository": {
"type": "git",
"url": "https://example.com"
},
"keywords": [
"reflective",
"generators"
],
"author": "test",
"license": "mit",
"devDependencies": {
"babel-cli": "^6.24.1",
"babel-core": "^6.24.1",
"babel-preset-es2015": "^6.24.1"
},
"dependencies": {
"express": "^4.15.3",
"reflective": "^0.0.1"
}
}
```
```
{
"name": "a",
"description": "a",
"scripts": {
"start": "a",
"build": "a",
"test": "a"
},
"repository": {
"type": "a",
"url": "a"
},
"keywords": [],
"author": "a",
"license": "a",
"devDependencies": {},
"dependencies": {
"express": "^4.15.3"
}
}
```
### J LEANCHECK BST ENUMERATOR

```
leanBST :: (Int, Int) -> [[Tree]]
leanBST (lo, hi) | lo > hi = [[Leaf]]
leanBST (lo, hi) =
cons0 Leaf
\/ ( choose (lo, hi) >>- \ x ->
leanBST (lo, x - 1) >>- \ l ->
leanBST (x + 1, hi) >>- \ r ->
delay [[Node l x r]]
```

Reflecting on Random Generation 200:39

```
)
where
(>>-) = flip concatMapT
choose = concatT [zipWith (\i x -> [[x]]`ofWeight`i) [0 ..] [lo .. hi]]
```

200:40 Goldstein and Frohlich et al.

### REFERENCES

Cornelius Aschermann, Tommaso Frassetto, Thorsten Holz, Patrick Jauernig, Ahmad-Reza Sadeghi, and Daniel Teuchert.

2019. NAUTILUS: Fishing for Deep Bugs with Grammars. InProceedings 2019 Network and Distributed System Security
Symposium. Internet Society, San Diego, CA. https://doi.org/10.14722/ndss.2019.23412
Rudy Matela Braquehais. 2017. Tools for Discovery, Refinement and Generalization of Functional Properties by Enumerative
Testing. (Oct. 2017). [http://etheses.whiterose.ac.uk/19178/](http://etheses.whiterose.ac.uk/19178/) Publisher: University of York.
Sarah E. Chasins, Elena L. Glassman, and Joshua Sunshine. 2021. PL and HCI: better together.Commun. ACM64, 8 (Aug.
2021), 98–106. https://doi.org/10.1145/3469279
Koen Claessen and John Hughes. 2000. QuickCheck: a lightweight tool for random testing of Haskell programs. InProceedings
of the Fifth ACM SIGPLAN International Conference on Functional Programming (ICFP ’00), Montreal, Canada, September
18-21, 2000, Martin Odersky and Philip Wadler (Eds.). ACM, Montreal, Canada, 268–279. https://doi.org/10.1145/351240.
351266
Michael Coblenz, Gauri Kambhatla, Paulette Koronkevich, Jenna L. Wise, Celeste Barnaby, Joshua Sunshine, Jonathan
Aldrich, and Brad A. Myers. 2021. PLIERS: A Process that Integrates User-Centered Methods into Programming Language
Design.ACM Transactions on Computer-Human Interaction28, 4 (July 2021), 28:1–28:53. https://doi.org/10.1145/3452379
Zac Hatfield Dodds. 2022. current maintainer of Hypothesis (https://github.com/HypothesisWorks/hypothesis). Personal
communication.
Stephen Dolan and Mindy Preston. 2017. Testing with crowbar. InOCaml Workshop. https://github.com/ocaml/
ocaml.org-media/blob/master/meetings/ocaml/2017/extended-abstract__2017__stephen-dolan_mindy-preston_
_testing-with-crowbar.pdf
Andrea Fioraldi, Dominik Maier, Heiko Eißfeldt, and Marc Heuse. 2020. {AFL++} : Combining Incremental Steps of Fuzzing
Research. https://www.usenix.org/conference/woot20/presentation/fioraldi
John Nathan Foster. 2009. Bidirectional programming languages. Ph.D. University of Pennsylvania, United States –
Pennsylvania. https://www.proquest.com/docview/304986072/abstract/11884B3FBDDB4DCFPQ/1 ISBN: 9781109710137.
Jean-Yves Girard. 1986. The system F of variable types, fifteen years later.Theoretical Computer Science45 (Jan. 1986),
159–192. https://doi.org/10.1016/0304-3975(86)90044-7
Patrice Godefroid, Adam Kiezun, and Michael Y. Levin. 2008. Grammar-based whitebox fuzzing. InProceedings of the 29th
ACM SIGPLAN Conference on Programming Language Design and Implementation (PLDI ’08). Association for Computing
Machinery, New York, NY, USA, 206–215. https://doi.org/10.1145/1375581.1375607
Patrice Godefroid, Hila Peleg, and Rishabh Singh. 2017. Learn&fuzz: Machine learning for input fuzzing. In2017 32nd
IEEE/ACM International Conference on Automated Software Engineering (ASE). IEEE, 50–59. https://dl.acm.org/doi/10.
5555/3155562.3155573
Harrison Goldstein and Benjamin C. Pierce. 2022. Parsing Randomness.Proceedings of the ACM on Programming Languages
6, OOPSLA2 (Oct. 2022), 128:89–128:113. https://doi.org/10.1145/3563291
Andrew D. Gordon, Thomas A. Henzinger, Aditya V. Nori, and Sriram K. Rajamani. 2014. Probabilistic programming. In
Future of Software Engineering Proceedings (FOSE 2014). Association for Computing Machinery, New York, NY, USA,
167–181. https://doi.org/10.1145/2593882.2593900
Christian Holler, Kim Herzig, and Andreas Zeller. 2012. Fuzzing with code fragments. InProceedings of the 21st USENIX
conference on Security symposium (Security’12). USENIX Association, USA, 38.
John Hughes. 2019. How to Specify It!. In20th International Symposium on Trends in Functional Programming. https:
//doi.org/10.1007/978-3-030-47147-7_4
Michael B. James, Zheng Guo, Ziteng Wang, Shivani Doshi, Hila Peleg, Ranjit Jhala, and Nadia Polikarpova. 2020. Digging
for fold: synthesis-aided API discovery for Haskell.Proceedings of the ACM on Programming Languages4, OOPSLA (Nov.
2020), 205:1–205:27. https://doi.org/10.1145/3428273
Oleg Kiselyov. 2012. Typed Tagless Final Interpreters. InGeneric and Indexed Programming: International Spring School,
SSGIP 2010, Oxford, UK, March 22-26, 2010, Revised Lectures, Jeremy Gibbons (Ed.). Springer, Berlin, Heidelberg, 130–174.
https://doi.org/10.1007/978-3-642-32202-0_3
Oleg Kiselyov and Hiromi Ishii. 2015. Freer monads, more extensible effects.ACM SIGPLAN Notices50, 12 (2015), 94–105.
https://dl.acm.org/doi/10.1145/2804302.2804319 Publisher: ACM New York, NY, USA.
S. Kullback and R. A. Leibler. 1951. On Information and Sufficiency.The Annals of Mathematical Statistics22, 1 (1951), 79–86.
https://www.jstor.org/stable/2236703 Publisher: Institute of Mathematical Statistics.
Daan Leijen and Erik Meijer. 2001. Parsec: Direct Style Monadic Parser Combinators For The Real World. (2001), 22.
[http://www.cs.uu.nl/research/techreps/repo/CS-2001/2001-35.pdf](http://www.cs.uu.nl/research/techreps/repo/CS-2001/2001-35.pdf)
J. Lin. 1991. Divergence measures based on the Shannon entropy.IEEE Transactions on Information Theory37, 1 (Jan. 1991),
145–151. https://doi.org/10.1109/18.61115 Conference Name: IEEE Transactions on Information Theory.
David R. MacIver and Alastair F. Donaldson. 2020. Test-Case Reduction via Test-Case Generation: Insights from the
Hypothesis Reducer (Tool Insights Paper). In34th European Conference on Object-Oriented Programming (ECOOP 2020)


Reflecting on Random Generation 200:41

(Leibniz International Proceedings in Informatics (LIPIcs), Vol. 166), Robert Hirschfeld and Tobias Pape (Eds.). Schloss
Dagstuhl–Leibniz-Zentrum für Informatik, Dagstuhl, Germany, 13:1–13:27. https://doi.org/10.4230/LIPIcs.ECOOP.2020.
13 ISSN: 1868-8969.
David R MacIver, Zac Hatfield-Dodds, and others. 2019. Hypothesis: A new approach to property-based testing.Journal of
Open Source Software4, 43 (2019), 1891. https://joss.theoj.org/papers/10.21105/joss.01891.pdf
José Pedro Magalhães, Atze Dijkstra, Johan Jeuring, and Andres Löh. 2010. A generic deriving mechanism for Haskell.ACM
SIGPLAN Notices45, 11 (Sept. 2010), 37–48. https://doi.org/10.1145/2088456.1863529
Eugenio Moggi. 1991. Notions of computation and monads. Information and Computation93, 1 (July 1991), 55–92.
https://doi.org/10.1016/0890-5401(91)90052-4
Michał H. Pałka, Koen Claessen, Alejandro Russo, and John Hughes. 2011. Testing an Optimising Compiler by Generating
Random Lambda Terms. InProceedings of the 6th International Workshop on Automation of Software Test (AST ’11). ACM,
New York, NY, USA, 91–97. https://doi.org/10.1145/1982595.1982615 event-place: Waikiki, Honolulu, HI, USA.
Zoe Paraskevopoulou, Aaron Eline, and Leonidas Lampropoulos. 2022. Computing correctly with inductive relations. In
Proceedings of the 43rd ACM SIGPLAN International Conference on Programming Language Design and Implementation (PLDI
2022). Association for Computing Machinery, New York, NY, USA, 966–980. https://doi.org/10.1145/3519939.3523707
M. Pickering, J. Gibbons, and N. Wu. 2017. Profunctor optics: Modular data accessors.Art, Science, and Engineering of
Programming1, 2 (2017). https://ora.ox.ac.uk/objects/uuid:9989be57-a045-4504-b9d7-dc93fd508365 Publisher: Aspect-
Oriented Software Association.
Lee Pike. 2014. SmartCheck: automatic and efficient counterexample reduction and generalization. InProceedings of the
2014 ACM SIGPLAN symposium on Haskell (Haskell ’14). Association for Computing Machinery, New York, NY, USA,
53–64. https://doi.org/10.1145/2633357.2633365
John C. Reynolds. 1974. Towards a theory of type structure. InProgramming Symposium, Proceedings Colloque sur la
Programmation, Paris, France, April 9-11, 1974 (Lecture Notes in Computer Science, Vol. 19), Bernard Robinet (Ed.). Springer,
408–423. https://doi.org/10.1007/3-540-06859-7_148
Colin Runciman, Matthew Naylor, and Fredrik Lindblad. 2008. Smallcheck and lazy smallcheck: automatic exhaustive
testing for small values.ACM SIGPLAN Notices44, 2 (Sept. 2008), 37–48. https://doi.org/10.1145/1543134.1411292
Ezekiel Soremekun, Esteban Pavese, Nikolas Havrikov, Lars Grunske, and Andreas Zeller. 2020. Inputs from Hell: Learning
Input Distributions for Grammar-Based Test Generation.IEEE Transactions on Software Engineering(2020). https:
//doi.org/10.1109/TSE.2020.3013716 Publisher: IEEE.
Prashast Srivastava and Mathias Payer. 2021. Gramatron: effective grammar-aware fuzzing. InProceedings of the 30th ACM
SIGSOFT International Symposium on Software Testing and Analysis (ISSTA 2021). Association for Computing Machinery,
New York, NY, USA, 244–256. https://doi.org/10.1145/3460319.3464814
Jacob Stanley. [n. d.]. Hedgehog will eat all your bugs. https://hedgehog.qa/
Spandan Veggalam, Sanjay Rawat, Istvan Haller, and Herbert Bos. 2016. IFuzzer: An Evolutionary Interpreter Fuzzer Using
Genetic Programming. InComputer Security – ESORICS 2016 (Lecture Notes in Computer Science), Ioannis Askoxylakis,
Sotiris Ioannidis, Sokratis Katsikas, and Catherine Meadows (Eds.). Springer International Publishing, Cham, 581–601.
https://doi.org/10.1007/978-3-319-45744-4_29
Junjie Wang, Bihuan Chen, Lei Wei, and Yang Liu. 2019. Superion: Grammar-Aware Greybox Fuzzing. In2019 IEEE/ACM
41st International Conference on Software Engineering (ICSE). 724–735. https://doi.org/10.1109/ICSE.2019.00081 ISSN:
1558-1225.
Li-yao Xia, Dominic Orchard, and Meng Wang. 2019. Composing bidirectional programs monadically. InEuropean Symposium
on Programming. Springer, 147–175. https://doi.org/10.1007/978-3-030-17184-1_6
Michał Zalewski. 2022. American Fuzzy Lop (AFL). https://github.com/google/AFL original-date: 2019-07-25T16:50:06Z.
Adam Ścibior, Ohad Kammar, and Zoubin Ghahramani. 2018. Functional programming for modular Bayesian inference.
Proceedings of the ACM on Programming Languages2, ICFP (July 2018), 83:1–83:29. https://doi.org/10.1145/3236778

Received 2023-03-01; accepted 2023-06-27


