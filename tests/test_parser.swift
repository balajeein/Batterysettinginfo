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

        print("=== All QuestionParser Unit Tests PASSED Successfully ===")
    }
}
