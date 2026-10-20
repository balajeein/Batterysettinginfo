import AppKit
import CoreGraphics
import Foundation

@main
struct TestAnswerValidationMain {
    static func assertTrue(_ condition: Bool, _ message: String) {
        if !condition {
            print("❌ FAILED: \(message)")
            exit(1)
        } else {
            print("✓ PASSED: \(message)")
        }
    }

    static func main() async {
        print("=======================================================")
        print(" Running 6 Core Answer-Validation & Pipeline Test Cases")
        print("=======================================================\n")

        let optionsAD = [
            MCQOption(label: "A", text: "To increase the dataset size"),
            MCQOption(label: "B", text: "To retain the most important input features that help solve the real problem"),
            MCQOption(label: "C", text: "To create new features from existing data"),
            MCQOption(label: "D", text: "To align stakeholders with project goals")
        ]

        let mcq = ParsedMCQ(
            question: "What is the main goal of feature selection in ML?",
            options: optionsAD,
            rawText: "What is the main goal of feature selection in ML?\nA) ... B) ..."
        )

        let engine = LocalInferenceEngine.shared

        // -------------------------------------------------------------
        // Case 1: Question with options A–D where model returns B (with explanation)
        // -------------------------------------------------------------
        print("--- Case 1: Model returns 'B' with explanation ---")
        let rawResponse1 = "B — To retain the most important input features that help solve the real problem"
        do {
            let (label, explanation, formatted, validation) = try engine.parseAndValidate(
                raw: rawResponse1,
                availableOptions: mcq.options
            )
            assertTrue(label == "B", "Case 1: Label must be 'B'")
            assertTrue(explanation.contains("retain the most important input features"), "Case 1: Explanation must be preserved")
            assertTrue(formatted.hasPrefix("B — "), "Case 1: Formatted answer must start with 'B — '")
            assertTrue(validation.contains("Valid"), "Case 1: Validation status must be Valid")
            print("  Result: label=\(label), formatted=\(formatted)")
            print("  Explanation: \(explanation)")
        } catch {
            assertTrue(false, "Case 1 should not throw error: \(error)")
        }

        // -------------------------------------------------------------
        // Case 2: Raw response such as 'Answer: B'
        // -------------------------------------------------------------
        print("\n--- Case 2: Raw response 'Answer: B' ---")
        let rawResponse2 = "Answer: B"
        do {
            let (label, explanation, formatted, _) = try engine.parseAndValidate(
                raw: rawResponse2,
                availableOptions: mcq.options
            )
            assertTrue(label == "B", "Case 2: Label must be 'B'")
            assertTrue(formatted.hasPrefix("B — "), "Case 2: Formatted answer should look up option text")
            assertTrue(!explanation.isEmpty, "Case 2: Explanation populated from option B")
            print("  Result: label=\(label), formatted=\(formatted)")
        } catch {
            assertTrue(false, "Case 2 should not throw error: \(error)")
        }

        // Also test "Option B", "**B**", and single "B"
        let variations = ["Option B", "**B**", "B", "B.", "Select: B"]
        for v in variations {
            do {
                let (l, _, _, _) = try engine.parseAndValidate(raw: v, availableOptions: mcq.options)
                assertTrue(l == "B", "Variation '\(v)' must resolve to 'B'")
            } catch {
                assertTrue(false, "Variation '\(v)' failed: \(error)")
            }
        }

        // Vision responses must use the same option-set validation as text responses.
        print("\n--- Vision answer validation uses detected options ---")
        do {
            let (visionLabel, _, _, _) = try engine.parseAndValidateVisionOutput(
                raw: "ANSWER: B\nEXPLANATION: The retained features are the useful subset.",
                availableOptions: mcq.options
            )
            assertTrue(visionLabel == "B", "Vision response must resolve to detected Option B")
        } catch {
            assertTrue(false, "Valid vision response should not throw: \(error)")
        }

        do {
            _ = try engine.parseAndValidateVisionOutput(raw: "ANSWER: E", availableOptions: mcq.options)
            assertTrue(false, "Vision response must reject Option E when only A-D exist")
        } catch let InferenceError.invalidOptionLabel(label, available, _) {
            assertTrue(label == "E" && available == ["A", "B", "C", "D"], "Vision response rejected invalid label E")
        } catch {
            assertTrue(false, "Expected invalidOptionLabel for vision Option E, got: \(error)")
        }

        // -------------------------------------------------------------
        // Case 3: Invalid response such as 'Option E' when only A–D are available
        // -------------------------------------------------------------
        print("\n--- Case 3: Invalid response 'Option E' when only A-D available ---")
        let invalidResponses = ["Option E", "E", "Answer: E", "E) Extraneous option"]
        for inv in invalidResponses {
            do {
                let _ = try engine.parseAndValidate(raw: inv, availableOptions: mcq.options)
                assertTrue(false, "Case 3: '\(inv)' must NOT be accepted when only A-D exist!")
            } catch let InferenceError.invalidOptionLabel(label, available, _) {
                assertTrue(label == "E", "Case 3: Detected invalid label 'E'")
                assertTrue(available == ["A", "B", "C", "D"], "Case 3: Available options list correct")
                print("  Correctly rejected '\(inv)': Option 'E' not in [\(available.joined(separator: ", "))]")
            } catch {
                assertTrue(false, "Case 3: Expected invalidOptionLabel error, got: \(error)")
            }
        }

        // Test non-matching arbitrary text (e.g. starts with A but is not option A)
        let arbitraryProse = "According to statistical learning theory, variance is reduced by regularization."
        do {
            let _ = try engine.parseAndValidate(raw: arbitraryProse, availableOptions: mcq.options)
            assertTrue(false, "Arbitrary prose starting with 'According' must NOT match Option A!")
        } catch let InferenceError.unparseableAnswer(_, reason) {
            assertTrue(true, "Case 3: Arbitrary prose correctly rejected: \(reason)")
            print("  Correctly rejected arbitrary text: \(reason)")
        } catch {
            assertTrue(false, "Expected unparseableAnswer, got: \(error)")
        }

        // -------------------------------------------------------------
        // Case 4: Empty response
        // -------------------------------------------------------------
        print("\n--- Case 4: Empty response ---")
        let emptyResponses = ["", "   ", "\n\t  \n"]
        for empty in emptyResponses {
            do {
                let _ = try engine.parseAndValidate(raw: empty, availableOptions: mcq.options)
                assertTrue(false, "Case 4: Empty response must throw emptyOutput")
            } catch InferenceError.emptyOutput {
                assertTrue(true, "Case 4: Correctly identified emptyOutput")
                print("  Correctly rejected empty response")
            } catch {
                assertTrue(false, "Expected emptyOutput, got: \(error)")
            }
        }

        // -------------------------------------------------------------
        // Case 5: Model-loading or inference failure
        // -------------------------------------------------------------
        print("\n--- Case 5: Model-loading / inference failure ---")
        // Verify invalid path handling
        let nonExistentPath = "/tmp/non_existent_model_12345.gguf"
        let isGGUF = c_llama_engine_is_valid_gguf(nonExistentPath)
        assertTrue(!isGGUF, "Case 5: Non-existent file must not be valid GGUF")

        let invalidEngine = c_llama_engine_create(nonExistentPath, 512, 1, 0)
        assertTrue(invalidEngine == nil, "Case 5: Engine initialization on non-existent file must fail with nil")
        print("  Correctly failed engine initialization on invalid path")

        // -------------------------------------------------------------
        // Case 6: Screenshot with no recognizable MCQ
        // -------------------------------------------------------------
        print("\n--- Case 6: Screenshot with no recognizable MCQ ---")
        let nonMCQLines = [
            "System Settings",
            "General",
            "Appearance: Dark",
            "Language & Region: English (US)",
            "Date & Time: Set automatically",
            "Storage: 450 GB available of 1 TB"
        ]
        let nonMCQResult = QuestionParser.shared.parseWithDiagnostics(lines: nonMCQLines)
        switch nonMCQResult {
        case .success:
            assertTrue(false, "Case 6: Non-MCQ text must NOT be parsed as MCQ")
        case .failure(let reason):
            assertTrue(true, "Case 6: Correctly rejected non-MCQ screenshot: \(reason.description)")
            print("  Rejection reason: \(reason.description)")
        }

        // -------------------------------------------------------------
        // LIVE MODEL INFERENCE TEST (if GGUF model is present)
        // -------------------------------------------------------------
        if engine.hasModelFileAvailable() {
            print("\n--- Bonus: Live GGUF Model Inference with Newton School Question ---")
            do {
                let result = try await engine.solve(mcq: mcq)
                print("  Live Inference Answer: \(result.optionLabel)")
                print("  Live Formatted: \(result.formattedAnswer)")
                print("  Live Explanation: \(result.explanation)")
                print("  Live Duration: \(result.durationMs) ms")
                print("  Validation: \(result.validationResult)")
                assertTrue(result.optionLabel == "B", "Live model MUST answer B for feature selection question!")
            } catch {
                assertTrue(false, "Live model inference failed: \(error)")
            }

            print("\n--- Regression: UART transmitter shift-register question ---")
            let uartMCQ = ParsedMCQ(
                question: "Which shift register mode is used in a UART transmitter to send data one bit at a time over a single wire?",
                options: [
                    MCQOption(label: "A", text: "SISO"),
                    MCQOption(label: "B", text: "SIPO"),
                    MCQOption(label: "C", text: "PISO"),
                    MCQOption(label: "D", text: "PIPO")
                ],
                rawText: "UART shift register regression"
            )
            do {
                let result = try await engine.solve(mcq: uartMCQ)
                print("  UART Inference Answer: \(result.optionLabel)")
                assertTrue(result.optionLabel == "C", "UART transmitter must answer C (PISO), not B (SIPO)")
            } catch {
                assertTrue(false, "UART live inference failed: \(error)")
            }

            print("\n--- Regression: ANSI terminal key-sequence question ---")
            let terminalMCQ = ParsedMCQ(
                question: "Which key press will cause \"DOWN\" to be displayed? process.stdin.on('data', (key) => { if (key[0] === 27 && key[1] === 91) { if (key[2] === 65) { console.log('DOWN'); } } });",
                options: [
                    MCQOption(label: "A", text: "Enter key"),
                    MCQOption(label: "B", text: "Left Arrow key"),
                    MCQOption(label: "C", text: "Up Arrow key"),
                    MCQOption(label: "D", text: "Down Arrow key")
                ],
                rawText: "ANSI terminal key-sequence regression"
            )
            do {
                let result = try await engine.solve(mcq: terminalMCQ)
                print("  Terminal Inference Answer: \(result.optionLabel)")
                assertTrue(result.optionLabel == "C", "ANSI byte 65 must map to Option C (Up Arrow key), not the printed DOWN text")
            } catch {
                assertTrue(false, "Terminal key-sequence inference failed: \(error)")
            }
        } else {
            print("\n  [Note: No live GGUF model in models directory; skipped live inference]")
        }

        engine.unloadModel()
        print("\n=======================================================")
        print(" All 6 Required Test Cases PASSED Successfully! ✓")
        print("=======================================================")
    }
}
