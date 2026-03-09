// MARK: - Exam Grader Contract Test
//
// Ported from Hillel Wayne's blog post "Property Testing Complex Inputs" (https://www.hillelwayne.com/post/contract-examples/).
//
// The original post demonstrates a core challenge in property-based testing: generating *dependent* test data, where one value's shape constrains another. An `ExamInstance` must produce an `answers` array whose length matches the `Exam.answerKey` it references, and each answer is optionally blank (nil) to represent a skipped question.
//
// Rather than a standalone property test with a custom generator, this port reframes the problem as a `@Contract` (stateful) test. The system under test is a `BuggyExamGrader` that manages exams and submitted answer sheets. Two deliberate bugs are embedded:
//
//   1. Length validation bug — `submitAnswers` accepts answer arrays of any length without checking that they match the exam's answer key length. A correct implementation would reject or truncate mismatched lengths.
//
//   2. Grading bug — `grade()` divides the number of correct answers by the total number of questions (`answerKey.count`) instead of by the number of *attempted* (non-blank) questions. This means blank answers deflate the score even though the student did not attempt them.
//
// The contract exposes these bugs through two complementary mechanisms:
//
//   - An `@Invariant` (`answersMatchKeyLength`) asserts that every stored submission has `answers.count == exam.answerKey.count`. Because the `submitAnswers` command generates answer counts from an independent range (0...6), mismatches are inevitable, and the invariant catches bug 1.
//
//   - A postcondition in `gradeLatest` checks that when every non-blank answer is correct, the computed score should be 1.0 (perfect). The grading bug makes this fail whenever at least one answer is blank, because blanks inflate the denominator. This catches bug 2.
//
// The dependent-data challenge from the original blog post surfaces naturally here: the `submitAnswers` command intentionally *does not* constrain its answer count to the current exam's key length, which is what allows the invariant to detect the missing validation. A correct system would enforce the constraint internally.

import Testing
import Exhaust
import ExhaustCore

// MARK: - Tests

@Suite("Exam grader contract tests")
struct ExamGraderTests {
    /// Runs the contract and verifies that Exhaust detects at least one of the two embedded bugs. With sequence lengths of 3 to 8 commands, the contract reliably triggers either the invariant failure (mismatched answer length) or the postcondition failure (grading penalizes blanks). The test passes when the trace contains a failure — meaning the contract successfully caught the bug.
    @Test("Detects answer length mismatch or grading bug")
    func examGraderBugs() throws {
        let result = try #require(
            #exhaust(
                ExamGraderContract.self,
                commandLimit: 8,
                .suppressIssueReporting
            )
        )
        #expect(result.trace.contains { step in
            switch step.outcome {
            case .invariantFailed, .checkFailed: return true
            default: return false
            }
        })
    }

    /// Uses a dependent generator (the Exhaust equivalent of Hypothesis's `@composite`) to isolate the grading bug. The generator binds the answer key length into the answers generator, so lengths always match — bug 1 is structurally impossible. The property then checks that when every non-blank answer is correct, the grade is 1.0. The buggy grader counts blanks in the denominator, deflating the score, so this property fails.
    ///
    /// This is written as a standalone property test rather than a `@Contract` because dependent generation requires `bind` — monadic chaining where one generated value determines the shape of the next generator. `@Command` attribute arguments are resolved at macro expansion time, so they cannot express inter-parameter dependencies. Hypothesis solves this with `@composite`, which provides an imperative `draw()` function that executes generators within the current choice-recording context. Without equivalent syntax sugar, the `bind`-based generator cannot be embedded in a `@Command` declaration, so a standalone `#exhaust` property test is the natural home for it.
    @Test("Dependent generator isolates grading bug via @composite pattern")
    func gradingBugWithDependentGenerator() throws {
        let grader = BuggyExamGrader()
        let gen = examWithMatchingAnswers()

        let counterExample = #exhaust(gen, .suppressIssueReporting) { exam, answers in
            let instance = ExamInstance(student: "student", exam: exam, answers: answers)
            let score = grader.grade(instance)

            // If every non-blank answer is correct, the score must be 1.0.
            let nonBlankCorrect = zip(answers, exam.answerKey)
                .allSatisfy { answer, key in answer == nil || answer == key }
            let hasAttempted = answers.contains(where: { $0 != nil })
            let hasBlanks = answers.contains(where: { $0 == nil })

            // Only check the interesting case: some correct answers + some blanks
            guard nonBlankCorrect && hasAttempted && hasBlanks else { return true }
            return score == 1.0
        }

        #expect(counterExample != nil, "should find a case where blanks deflate the grade")
    }
}

// MARK: - Contract

// Three commands model the lifecycle of the exam system:
//
// 1. `createExam(keyLength:)` — generates an answer key of 1 to 5 questions, all with a fixed exam name so that later commands always reference the most recent exam.
//
// 2. `submitAnswers(answerCount:)` — generates an answer sheet with 0 to 6 answers. The range deliberately exceeds the maximum key length (5) so that mismatches are possible. Each answer is either a random choice (1...5) or nil (blank). Skips if no exam exists yet.
//
// 3. `gradeLatest()` — grades the most recent submission and checks a postcondition: if every non-blank answer is correct, the score must be 1.0. This postcondition fails when blanks are counted in the denominator (bug 2).
//
// The `answersMatchKeyLength` invariant runs after every command and catches bug 1 as soon as a mismatched submission is stored.

@Contract
struct ExamGraderContract {
    @SUT var grader = BuggyExamGrader()

    @Invariant
    func answersMatchKeyLength() -> Bool {
        grader.submissions.allSatisfy { $0.answers.count == $0.exam.answerKey.count }
    }

    @Command(weight: 2, Gen.int(in: 1...5))
    mutating func createExam(keyLength: Int) throws {
        grader.createExam(name: "exam", answerKey: Array(repeating: keyLength, count: keyLength))
    }

    @Command(weight: 3, Gen.int(in: 0...6))
    mutating func submitAnswers(answerCount: Int) throws {
        guard grader.exams["exam"] != nil else { throw skip() }
        grader.submitAnswers(student: "student", examName: "exam", answers: Array(repeating: answerCount, count: answerCount))
    }

    @Command(weight: 1)
    mutating func gradeLatest() throws {
        guard let latest = grader.submissions.last else { throw skip() }
        let score = grader.grade(latest)
        // Postcondition: if every non-blank answer matches the key, the score must be perfect. A correct grader excludes blanks from the denominator, so skipping questions never penalizes a student who answered every attempted question correctly.
        let nonBlankCorrect = zip(latest.answers, latest.exam.answerKey)
            .allSatisfy { answer, key in answer == nil || answer == key }
        if nonBlankCorrect {
            let nonBlankCount = latest.answers.compactMap({ $0 }).count
            if nonBlankCount > 0 {
                try check(score == 1.0, "blanks should not penalize a perfect score")
            }
        }
    }
}

// MARK: - Dependent generator (Exhaust equivalent of @composite)
//
// Hillel Wayne's blog post uses Hypothesis's `@composite` decorator to build a generator where the answers array length depends on the previously generated answer key length. This is the core challenge the post addresses: generating *structurally dependent* test data.
//
// In Exhaust, `bind` serves the same role — it chains two generators so that the second can use the first's output to determine its shape. Here we generate the answer key length first, then bind into a generator that produces exactly that many optional answers (nil = blank). The answer key itself uses correct values (1...5), and each student answer is either a correct match, a wrong answer, or blank.
//
// Because lengths always match by construction, bug 1 (missing length validation) is structurally impossible. This isolates the grading bug: the property asserts that blanks should not deflate the score of a student who answered every attempted question correctly.
//
// `bind` breaks reflection (the backward pass for decomposing a value back into generator choices), but `#exhaust` uses the forward VACTI interpreter, which records the choice tree alongside generation. Shrinking operates on the choice sequence directly and is completely unaffected by normally opaque `bind` boundaries.

/// Generates an ``Exam`` and matching `[Int?]` answers array where the answers length always matches the answer key length, and each answer is either correct, wrong, or blank (nil).
private func examWithMatchingAnswers() -> ReflectiveGenerator<(Exam, [Int?])> {
    #gen(.int(in: 1...5))
        .bind { keyLength in
            let keyGen = #gen(.int(in: 1...5)).array(length: UInt64(keyLength))
            let answersGen: ReflectiveGenerator<[Int?]> = ReflectiveGenerator.oneOf(
                weighted: (1, .just(nil)),
                (2, #gen(.int(in: 1...5)).map { Optional($0) })
            ).array(length: UInt64(keyLength))
            return Gen.zip(keyGen, answersGen).map { answerKey, answers in
                (Exam(name: "exam", answerKey: answerKey), answers)
            }
        }
}

// MARK: - Types

// Minimal exam domain: an `Exam` defines the answer key (correct answers numbered 1 through 5), and an `ExamInstance` pairs a student's response sheet with the exam it belongs to. Answers are optional — nil represents a blank or skipped question.

struct Exam {
    let name: String
    let answerKey: [Int]  // correct answers, values 1...5
}

struct ExamInstance {
    let student: String
    let exam: Exam
    let answers: [Int?]  // nil = blank/skipped
}

// A stateful exam management system with two deliberate bugs.
//
// Bug 1 (length validation): `submitAnswers` blindly stores whatever answer array it receives without checking that its length matches the exam's answer key. In a correct implementation, this would be a precondition failure or a silent truncation/padding.
//
// Bug 2 (grading denominator): `grade()` uses the total number of questions as the denominator. A correct grader would exclude blanks from the denominator so that skipping a question does not penalize the score.

struct BuggyExamGrader {
    private(set) var exams: [String: Exam] = [:]
    private(set) var submissions: [ExamInstance] = []

    mutating func createExam(name: String, answerKey: [Int]) {
        exams[name] = Exam(name: name, answerKey: answerKey)
    }

    mutating func submitAnswers(student: String, examName: String, answers: [Int?]) {
        guard let exam = exams[examName] else { return }
        // Bug 1: no length validation — accepts any answer count
        submissions.append(ExamInstance(student: student, exam: exam, answers: answers))
    }

    func grade(_ instance: ExamInstance) -> Double {
        // Bug 2: denominator is answerKey.count (all questions), not the count of non-nil answers. Blanks inflate the denominator, making partial attempts score lower than they should.
        let total = instance.exam.answerKey.count
        guard total > 0 else { return 1.0 }
        let correct = zip(instance.answers, instance.exam.answerKey)
            .filter { $0.0 == $0.1 }
            .count
        return Double(correct) / Double(total)
    }
}
