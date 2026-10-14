import AppKit

public final class AppDelegate: NSObject, NSApplicationDelegate, ShortcutManagerDelegate, MenuBarControllerDelegate {
    private var isProcessing = false
    private let processingQueue = DispatchQueue(label: "com.local.Batterysettinginfo.pipeline", qos: .userInitiated)

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Configure menu bar
        MenuBarController.shared.setup()
        MenuBarController.shared.delegate = self

        // Configure shortcut manager
        ShortcutManager.shared.delegate = self
        _ = ShortcutManager.shared.start()

        // Background check for model
        processingQueue.async {
            _ = LocalInferenceEngine.shared.loadModelIfNeeded()
            DispatchQueue.main.async {
                MenuBarController.shared.updateMenuState()
            }
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        ShortcutManager.shared.stop()
        LocalInferenceEngine.shared.unloadModel()
    }

    // MARK: - ShortcutManagerDelegate

    public func didTriggerAnalysisShortcut() {
        runPipeline()
    }

    // MARK: - MenuBarControllerDelegate

    public func menuBarDidRequestTrigger() {
        runPipeline()
    }

    public func menuBarDidRequestPermissionCheck() {
        MenuBarController.shared.updateMenuState()
    }

    // MARK: - Core Processing Pipeline
    // Shortcut -> Screen Capture -> Apple Vision OCR -> MCQ Validation -> Embedded llama.cpp -> Result -> Cleanup

    public func runPipeline() {
        guard !isProcessing else {
            return
        }
        isProcessing = true
        FeedbackManager.shared.deliverStatus("Analyzing...")

        Task {
            defer {
                self.isProcessing = false
            }

            do {
                // 1. In-memory Screen Capture
                var capturedImage: CGImage? = try await ScreenCaptureService.shared.captureMainScreen()
                guard let image = capturedImage else {
                    FeedbackManager.shared.deliverStatus("Capture Failed")
                    return
                }

                // 2. Apple Vision OCR
                let recognizedLines = try await OCRService.shared.recognizeText(from: image)

                // 3. Immediate release of image buffer from memory
                capturedImage = nil

                guard !recognizedLines.isEmpty else {
                    FeedbackManager.shared.deliverStatus("No Text Found")
                    return
                }

                // 4. MCQ Validation & Parsing
                guard let parsedMCQ = QuestionParser.shared.parse(lines: recognizedLines) else {
                    FeedbackManager.shared.deliverStatus("No MCQ Detected")
                    return
                }

                // 5. Embedded llama.cpp Inference
                let (answer, rawOutput) = try await LocalInferenceEngine.shared.solve(mcq: parsedMCQ)

                // 6. Deliver Result (Caps Lock modifier + Menu Bar UI)
                FeedbackManager.shared.deliverResult(answer: answer, summary: rawOutput)

                // 7. Temporary data cleanup occurs naturally via ARC exit of Task scope

            } catch let captureError as ScreenCaptureError {
                FeedbackManager.shared.deliverStatus("Capture: \(captureError.localizedDescription)")
            } catch let inferenceError as InferenceError {
                FeedbackManager.shared.deliverStatus("Model: \(inferenceError.localizedDescription)")
            } catch {
                FeedbackManager.shared.deliverStatus("Error: \(error.localizedDescription)")
            }
        }
    }
}
