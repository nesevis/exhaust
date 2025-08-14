Of course. Here is a summary of the video and a concise, actionable list of ways to write property tests.

### Summary of the Video

In this keynote from Lambda Days 2020, John Hughes provides a practical guide to writing effective properties for property-based testing of pure functions. He begins by contrasting simple unit tests with property-based tests, using a `reverse` function as an example. He cautions against the common pitfall of simply re-implementing the function's logic within the test, which is expensive and often misses bugs.

Hughes then introduces a more complex example—a binary search tree—to demonstrate five systematic approaches for formulating powerful properties:

1.  **Invariant Properties:** Check that a fundamental rule of the data structure (e.g., the sorted nature of a binary search tree) holds true after every operation.
2.  **Postcondition Properties:** Verify that the output of a function relates to its input in a predictable way. For instance, after inserting a key into a map, a lookup for that key should successfully return the inserted value.
3.  **Metamorphic Properties:** Relate two different calls to the functions under test. For example, inserting key A then key B should produce the same result as inserting key B then key A (if the keys are different). This technique is powerful because it doesn't require knowing the exact correct output.
4.  **Inductive Properties:** Define the specification of a function based on the data structure's constructors (e.g., a tree is either a `Leaf` or a `Branch`). This allows you to create a complete specification through a series of simpler properties.
5.  **Model-based Properties:** The most powerful method discussed. It involves comparing the complex implementation against a much simpler, obviously correct "model" (e.g., using a simple list as a model for a binary search tree). You run the same sequence of operations on both your implementation and the model and check that their abstract states remain equivalent.

Hughes concludes by showing that model-based and metamorphic properties are the most effective at finding bugs quickly and completely. He encourages developers not to overthink properties but to simply write them and let the testing tool do the work of finding counterexamples.

### Actionable List: 5 Ways to Write Property Tests

Here are five systematic ways to formulate property tests for your pure functions, as presented in the talk:

1.  **Check for an Invariant:** Identify a property of your data that must **always** be true. Write a property to confirm that every function in your API maintains this invariant.
    *   **Example:** For a binary search tree, create a `isValid()` function that checks if the keys are correctly ordered. Then, write a property that asserts `isValid(insert(key, value, tree))` is always true.

2.  **Test the Postcondition:** For a given function, define what should be true after it has been executed. This relates the function's output directly back to its inputs.
    *   **Example:** After inserting a key-value pair into a tree, `find(key, insert(key, value, tree))` should return `Just value`.

3.  **Relate Two Operations (Metamorphic Testing):** Don't predict the exact result. Instead, run two different sequences of operations and check if their results are related in a specific way.
    *   **Example:** Inserting key `k1` then `k2` into a tree should be equivalent to inserting `k2` then `k1` (assuming `k1` and `k2` are different). `insert k1 v1 (insert k2 v2 t) == insert k2 v2 (insert k1 v1 t)`.

4.  **Specify Inductively:** Define the behavior of a function by writing a property for each way your data can be constructed (e.g., base cases and recursive cases). Together, these properties form a complete specification.
    *   **Example:** For a `union` function on trees, specify two properties:
        1.  Base case: `union(emptyTree, t)` should equal `t`.
        2.  Inductive step: `union(insert(k, v, t1), t2)` should be equivalent to `insert(k, v, union(t1, t2))`.

5.  **Compare to a Simple Model:** Implement the same operations on a simple, obviously correct data structure (like a list). Write a property that runs random operations on both your complex implementation and the simple model, ensuring they produce equivalent results.
    *   **Example:** Check that converting a tree to a list after an `insert` operation produces the same result as performing a corresponding insert operation on the list version of that tree. `toList(insert(k, v, t)) == listInsert(k, v, toList(t))`.