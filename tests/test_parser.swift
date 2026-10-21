import Foundation

@main
struct TestParserMain {
    static func assertTrue(_ condition: Bool, _ message: String) {
        if !condition {
            print("❌ FAILED: \(message)")
            exit(1)
        } else {
            print("✓ PASSED: \(message)")
        }
    }

    static func main() {
        print("=== Running QuestionParser Unit Tests ===")

        let parser = QuestionParser()

        // Test 1: Standard A, B, C, D Multiple Choice Question
        let standardMCQ = """
Which celestial body is at the center of the Solar System?
A) Mars
B) The Sun
C) Jupiter
D) The Moon
"""
        let res1 = parser.parse(rawText: standardMCQ)
        assertTrue(res1 != nil, "Standard A-D MCQ should be parsed")
        assertTrue(res1?.options.count == 4, "Should extract exactly 4 options")
        assertTrue(res1?.options[0].label == "A" && res1?.options[0].text == "Mars", "Option A should match")
        assertTrue(res1?.options[1].label == "B" && res1?.options[1].text == "The Sun", "Option B should match")

        // Test 2: Numeric options 1, 2, 3, 4 with periods
        let numericMCQ = """
What is the boiling point of pure water at standard atmospheric pressure?
1. 50 degrees Celsius
2. 75 degrees Celsius
3. 100 degrees Celsius
4. 120 degrees Celsius
"""
        let res2 = parser.parse(rawText: numericMCQ)
        assertTrue(res2 != nil, "Numeric 1-4 MCQ should be parsed")
        assertTrue(res2?.options.count == 4, "Should extract 4 numeric options")
        assertTrue(res2?.options[2].label == "3" && res2?.options[2].text == "100 degrees Celsius", "Option 3 should match")

        // Test 3: Bracketed options [A], [B], [C]
        let bracketMCQ = """
Which sorting algorithm has an average time complexity of O(n log n)?
[A] Quick Sort
[B] Bubble Sort
[C] Selection Sort
"""
        let res3 = parser.parse(rawText: bracketMCQ)
        assertTrue(res3 != nil, "Bracketed options [A].. should be parsed")
        assertTrue(res3?.options.count == 3, "Should extract 3 options")

        // Test 4: Multi-line option text wrapping
        let wrappedMCQ = """
Which of the following describes the principle of least privilege?
A) Users should be granted only the minimum permissions necessary
to perform their authorized job duties.
B) All users should have administrative privileges by default.
C) Privileges should be assigned randomly.
"""
        let res4 = parser.parse(rawText: wrappedMCQ)
        assertTrue(res4 != nil, "Wrapped multi-line option text should be parsed")
        assertTrue(res4?.options[0].text.contains("minimum permissions necessary") == true, "Continuation line merged into Option A")

        // Test 5: Reject non-MCQ text (e.g. article / prose)
        let prose = """
The quick brown fox jumps over the lazy dog.
This is a standard paragraph with no choices.
It should not be recognized as a multiple choice question.
"""
        let res5 = parser.parse(rawText: prose)
        assertTrue(res5 == nil, "Prose paragraph should be rejected as non-MCQ")

        // Test 6: Reject single-option or incomplete text
        let incomplete = """
What is the capital of France?
A) Paris
"""
        let res6 = parser.parse(rawText: incomplete)
        assertTrue(res6 == nil, "Single option question should be rejected")

        // Test 7: Reject source code snippet
        let codeSnippet = """
func calculateTotal(items: [Double]) -> Double {
    let a = 10.0
    let b = 20.0
    return a + b
}
"""
        let res7 = parser.parse(rawText: codeSnippet)
        assertTrue(res7 == nil, "Code snippet should be rejected as non-MCQ")

        // Test 8: Revision-page answer cards must keep option boundaries and
        // stop before the page's "INCORRECT ANSWER" feedback.
        let revisionPageMCQ = """
        QUESTION 1/3
        What is the VLC command-line flag that tells VLC to exit automatically when a song finishes playing?
        A) --auto-quit
        B) --exit-on-finish
        C) --play-and-exit
        D) --single-instance
        INCORRECT ANSWER
        """
        let res8 = parser.parse(rawText: revisionPageMCQ)
        assertTrue(res8 != nil, "Revision-page MCQ should be parsed")
        assertTrue(res8?.options.count == 4, "Revision-page MCQ should keep all four options")
        assertTrue(res8?.options[2].text == "--play-and-exit", "Option C must not be shifted into option B")

        // Never accept positional fallback when OCR still exposes conflicting
        // labels; a false negative is safer than an incorrect answer.
        let shiftedRevision = """
        What is the VLC command-line flag that tells VLC to exit automatically when a song finishes playing?
        --auto-quit
        B) --exit-on-finish --play-and-exit
        D) --single-instance
        INCORRECT ANSWER
        """
        let res9 = parser.parse(rawText: shiftedRevision)
        assertTrue(res9 == nil, "Shifted option extraction must be rejected")

        // Newton School layout: OCR can omit the small A-D badges and the
        // question's terminal code sample must not become Option A.
        let unlabeledCodeQuestion = [
            "Newton School",
            "QUESTION 3/3",
            "Which statement best describes the relationship between tput cup command and:",
            "process.stdout.write('\\x1B[row;colH');",
            "One controls audio playback while the other controls video playback",
            "Both perform terminal cursor positioning",
            "One clears the screen while the other saves cursor position",
            "They are unrelated terminal operations"
        ]
        let res10 = parser.parse(lines: unlabeledCodeQuestion)
        assertTrue(res10 != nil, "Unlabeled Newton School code-question layout should be parsed")
        assertTrue(res10?.question.contains("process.stdout.write") == true, "Code sample should remain part of the question")
        assertTrue(res10?.options.count == 4, "Unlabeled layout should produce four positional options")
        assertTrue(res10?.options[1].text == "Both perform terminal cursor positioning", "Option B must remain aligned after skipping code sample")

        // Browser/header text must never be accepted as an answer-card cluster.
        let browserNoiseCluster = [
            "Newton School",
            "A) School",
            "B) QUESTION 3/3",
            "C) Which statement best describes the relationship between tput cup command and:",
            "D) One controls audio playback while the other controls video playback"
        ]
        let res11 = parser.parse(lines: browserNoiseCluster)
        assertTrue(res11 == nil, "Browser/header option-like noise must be rejected")

        // Compact lowercase command options must remain separate. A previous
        // fallback rule merged every lowercase line into the preceding option,
        // turning `stty raw`, `reset tty`, `stty sane`, and `tty reset` into one
        // malformed answer choice.
        let terminalResetLines = [
            "QUESTION 2/3",
            "Which command resets a terminal to reasonable default settings after it has accidentally been left in raw mode?",
            "stty raw",
            "reset tty",
            "stty sane",
            "tty reset",
            "INCORRECT ANSWER"
        ]
        let res12 = parser.parse(lines: terminalResetLines)
        assertTrue(res12 != nil, "Compact terminal command options should be parsed")
        assertTrue(res12?.options.count == 4, "Terminal command question should keep four options")
        assertTrue(res12?.options[0].text == "stty raw", "Option A should remain stty raw")
        assertTrue(res12?.options[1].text == "reset tty", "Option B should remain reset tty")
        assertTrue(res12?.options[2].text == "stty sane", "Option C should remain stty sane")
        assertTrue(res12?.options[3].text == "tty reset", "Option D should remain tty reset")

        print("=== All QuestionParser Unit Tests PASSED Successfully ===")
    }
}
