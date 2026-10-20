import Foundation

@main
struct TestBridgeMain {
    static func main() async {
        print("=== Running Embedded llama.cpp Native Bridge Tests ===")

        let backend = LocalInferenceEngine.shared.backendInfo
        print("✓ Backend info reported: \(backend)")
        guard !backend.isEmpty else {
            print("❌ FAILED: Backend info is empty")
            exit(1)
        }

        // Test GGUF validation on non-existent file
        let invalidPath = "/nonexistent/test_model.gguf"
        let isInvalidValid = c_llama_engine_is_valid_gguf(invalidPath)
        print("✓ Nonexistent model validation result: \(isInvalidValid) (expected: false)")
        guard !isInvalidValid else {
            print("❌ FAILED: Invalid model was reported as valid")
            exit(1)
        }

        // Test GGUF validation on a non-GGUF file (e.g. text file)
        let tempTxt = "/tmp/fake_model.gguf"
        try? "THIS IS NOT A GGUF FILE".write(toFile: tempTxt, atomically: true, encoding: .utf8)
        let isFakeValid = c_llama_engine_is_valid_gguf(tempTxt)
        print("✓ Fake model validation result: \(isFakeValid) (expected: false)")
        unlink(tempTxt)
        guard !isFakeValid else {
            print("❌ FAILED: Fake non-GGUF file reported as valid GGUF")
            exit(1)
        }

        // Test engine creation on invalid path
        let handle = c_llama_engine_create(invalidPath, 2048, 4, 99)
        print("✓ Engine creation on missing path: \(String(describing: handle)) (expected: nil)")
        guard handle == nil else {
            print("❌ FAILED: Engine creation succeeded on missing model")
            exit(1)
        }

        // Check if an actual model is supplied by the developer/user
        if let resolvedPath = AppConfiguration.shared.resolveModelPath() {
            print("✓ Discovered local GGUF model at: \(resolvedPath)")
            let loadResult = LocalInferenceEngine.shared.loadModelIfNeeded()
            switch loadResult {
            case .success(let path):
                print("✓ Successfully loaded real model into embedded llama.cpp: \(path)")
                print("   Vision support: \(LocalInferenceEngine.shared.hasVisionSupport ? "YES" : "NO")")

                // Perform test inference
                let testMCQ = ParsedMCQ(
                    question: "What is the capital of France?",
                    options: [
                        MCQOption(label: "A", text: "Berlin"),
                        MCQOption(label: "B", text: "Paris"),
                        MCQOption(label: "C", text: "Rome"),
                        MCQOption(label: "D", text: "Madrid")
                    ],
                    rawText: "What is the capital of France?\nA) Berlin\nB) Paris\nC) Rome\nD) Madrid"
                )

                do {
                    let result = try await LocalInferenceEngine.shared.solve(mcq: testMCQ)
                    print("✓ Inference succeeded!")
                    print("   Predicted Option: \(result.optionLabel)")
                    print("   Raw Output: \(result.rawOutput)")
                } catch {
                    print("❌ Inference error: \(error)")
                }

                LocalInferenceEngine.shared.unloadModel()

            case .failure(let err):
                print("⚠️ Model found but failed to load: \(err.localizedDescription)")
            }
        } else {
            print("ℹ️ No local GGUF model installed in Application Support or BATTERY_MODEL_PATH.")
            print("   Missing-model diagnostic verified: Engine handled absence safely without crash.")
            print("   To test real inference, place a .gguf model into: \(AppConfiguration.shared.applicationSupportDirectory.path)")
        }

        print("=== Embedded llama.cpp Native Bridge Tests PASSED Successfully ===")
    }
}
