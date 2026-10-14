import AppKit

public final class AppDelegate: NSObject, NSApplicationDelegate, ShortcutManagerDelegate, MenuBarControllerDelegate {
    private var isProcessing = false
    private let processingQueue = DispatchQueue(label: "com.local.Batterysettinginfo.pipeline", qos: .userInitiated)

    public func applicationDidFinishLaunching(_ notification: Notification) {
        if AppConfiguration.shared.isDiagnosticModeEnabled {
            fputs("[AppDelegate] Batterysettinginfo application launched. Initializing components...\n", stderr)
        }

        // Configure menu bar
        MenuBarController.shared.setup()
        MenuBarController.shared.delegate = self

        // Configure shortcut manager
        ShortcutManager.shared.delegate = self
        let shortcutStarted = ShortcutManager.shared.start()
        if AppConfiguration.shared.isDiagnosticModeEnabled {
            fputs("[AppDelegate] ShortcutManager.start() result: \(shortcutStarted)\n", stderr)
        }

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
            if AppConfiguration.shared.isDiagnosticModeEnabled {
                fputs("[AppDelegate] Pipeline trigger ignored: already processing\n", stderr)
            }
            return
        }
        isProcessing = true
        MenuBarController.shared.setPipelineState(.analyzing)

        Task {
            defer {
                self.isProcessing = false
            }

            do {
                // 1. In-memory Screen Capture
                var capturedImage: CGImage? = try await ScreenCaptureService.shared.captureMainScreen()
                guard let image = capturedImage else {
                    MenuBarController.shared.setPipelineState(.captureFailed("Nil image returned"))
                    FeedbackManager.shared.deliverStatus("Capture Failed")
                    return
                }

                // 2. Apple Vision OCR
                let recognizedLines = try await OCRService.shared.recognizeText(from: image)

                // 3. Immediate release of image buffer from memory
                capturedImage = nil

                guard !recognizedLines.isEmpty else {
                    MenuBarController.shared.setPipelineState(.ocrFailed("No text recognized on screen"))
                    FeedbackManager.shared.deliverStatus("No Text Found")
                    return
                }

                // 4. MCQ Validation & Parsing with Diagnostics
                let parseResult = QuestionParser.shared.parseWithDiagnostics(lines: recognizedLines)
                switch parseResult {
                case .failure(let reason):
                    if AppConfiguration.shared.isDiagnosticModeEnabled {
                        fputs("[Diagnostic 7] Parser rejection reason: \(reason.description)\n", stderr)
                        fputs("[Diagnostic 8] Final result: No valid MCQ detected\n", stderr)
                    }
                    MenuBarController.shared.setPipelineState(.noMCQFound(reason.description))
                    FeedbackManager.shared.deliverStatus("No MCQ: \(reason.description)")
                    return

                case .success(let mcq):
                    if AppConfiguration.shared.isDiagnosticModeEnabled {
                        fputs("[Diagnostic 7] Parser evaluation: SUCCESS\n", stderr)
                        fputs("[Diagnostic 8] Final result: Valid MCQ parsed with \(mcq.options.count) options [\(mcq.options.map { $0.label }.joined(separator: ", "))]\n", stderr)
                        fputs("    Question: \"\(mcq.question)\"\n", stderr)
                        for opt in mcq.options {
                            fputs("    Option \(opt.label): \(opt.text)\n", stderr)
                        }
                    }

                    // 5. Check model availability before attempting inference
                    guard LocalInferenceEngine.shared.hasModelFileAvailable() else {
                        if AppConfiguration.shared.isDiagnosticModeEnabled {
                            fputs("[AppDelegate] MCQ detected, but no local GGUF model is installed.\n", stderr)
                        }
                        MenuBarController.shared.setPipelineState(.mcqFoundNoModel(mcq))
                        FeedbackManager.shared.deliverStatus("MCQ Found (No Model)")
                        return
                    }

                    // 6. Run embedded llama.cpp inference
                    do {
                        let (answer, rawOutput) = try await LocalInferenceEngine.shared.solve(mcq: mcq)
                        if AppConfiguration.shared.isDiagnosticModeEnabled {
                            fputs("[AppDelegate] Inference succeeded! Answer: \(answer), Output: \(rawOutput)\n", stderr)
                        }
                        MenuBarController.shared.setPipelineState(.inferenceSuccess(answer: answer, summary: rawOutput))
                        FeedbackManager.shared.deliverResult(answer: answer, summary: rawOutput)
                    } catch let inferErr as InferenceError {
                        switch inferErr {
                        case .modelNotFound:
                            MenuBarController.shared.setPipelineState(.mcqFoundNoModel(mcq))
                        case .invalidModelFormat, .engineInitializationFailed:
                            MenuBarController.shared.setPipelineState(.modelLoadFailed(inferErr.localizedDescription))
                        case .inferenceFailed, .emptyOutput:
                            MenuBarController.shared.setPipelineState(.inferenceFailed(inferErr.localizedDescription))
                        }
                        FeedbackManager.shared.deliverStatus("Error: \(inferErr.localizedDescription)")
                    }
                }

                // 7. Temporary data cleanup occurs naturally via ARC exit of Task scope

            } catch let captureError as ScreenCaptureError {
                MenuBarController.shared.setPipelineState(.captureFailed(captureError.localizedDescription))
                FeedbackManager.shared.deliverStatus("Capture: \(captureError.localizedDescription)")
            } catch {
                MenuBarController.shared.setPipelineState(.captureFailed(error.localizedDescription))
                FeedbackManager.shared.deliverStatus("Error: \(error.localizedDescription)")
            }
        }
    }
}
