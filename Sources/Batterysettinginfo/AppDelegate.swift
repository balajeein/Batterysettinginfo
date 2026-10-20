import AppKit

public final class AppDelegate: NSObject, NSApplicationDelegate, ShortcutManagerDelegate, MenuBarControllerDelegate {
    private var isProcessing = false
    private let processingQueue = DispatchQueue(label: "com.local.Batterysettinginfo.pipeline", qos: .userInitiated)

    public func applicationDidFinishLaunching(_ notification: Notification) {
        batteryDiagnosticLog("[AppDelegate] Batterysettinginfo application launched. Process PID: \(ProcessInfo.processInfo.processIdentifier)")

        // Inspect and log initial permission diagnostics
        ScreenCaptureService.shared.logCurrentPermissionDiagnostics()

        // Configure menu bar
        MenuBarController.shared.setup()
        MenuBarController.shared.delegate = self

        // Configure shortcut manager
        ShortcutManager.shared.delegate = self
        let shortcutStarted = ShortcutManager.shared.start()
        batteryDiagnosticLog("[AppDelegate] ShortcutManager.start() result: \(shortcutStarted) [\(ShortcutManager.shared.registrationDiagnostic)]")

        // Background check for model
        processingQueue.async {
            if !OnlineSettings.shared.isOnlineMode {
                _ = LocalInferenceEngine.shared.loadModelIfNeeded()
            }
            DispatchQueue.main.async {
                MenuBarController.shared.updateMenuState()
            }
        }
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        // Refresh permissions and state on return to application
        batteryDiagnosticLog("[AppDelegate] applicationDidBecomeActive: refreshing permissions and menu state")
        ScreenCaptureService.shared.logCurrentPermissionDiagnostics()
        if ShortcutManager.shared.registrationStatus != .active {
            _ = ShortcutManager.shared.start()
        }
        MenuBarController.shared.updateMenuState()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        ShortcutManager.shared.stop()
        LocalInferenceEngine.shared.unloadModel()
    }

    // MARK: - ShortcutManagerDelegate

    public func didTriggerAnalysisShortcut() {
        batteryDiagnosticLog("[AppDelegate] ShortcutManager delegate invoked didTriggerAnalysisShortcut")
        runPipeline()
    }

    // MARK: - MenuBarControllerDelegate

    public func menuBarDidRequestTrigger() {
        batteryDiagnosticLog("[AppDelegate] MenuBarController delegate invoked menuBarDidRequestTrigger")
        runPipeline()
    }

    public func menuBarDidRequestPermissionCheck() {
        ScreenCaptureService.shared.logCurrentPermissionDiagnostics()
        MenuBarController.shared.updateMenuState()
    }

    // MARK: - Core Processing Pipeline
    // Shortcut -> Screen Capture -> Apple Vision OCR -> MCQ validation -> llama.cpp -> Result -> Cleanup

    public func runPipeline() {
        guard !isProcessing else {
            batteryDiagnosticLog("[AppDelegate] Pipeline trigger ignored: already processing")
            return
        }
        isProcessing = true

        var debugInfo = PipelineDebugInfo()
        debugInfo.status = "Processing"
        if OnlineSettings.shared.isOnlineMode {
            debugInfo.modelFilename = OnlineInferenceEngine.modelName
            debugInfo.modelType = "NVIDIA hosted multimodal vision"
            debugInfo.sentToVisionModel = "Yes (direct screenshot)"
        } else {
            if let path = LocalInferenceEngine.shared.currentModelPath ?? AppConfiguration.shared.resolveModelPath() {
                debugInfo.modelFilename = (path as NSString).lastPathComponent
            } else {
                debugInfo.modelFilename = "None (No GGUF in models directory)"
            }
            debugInfo.modelType = LocalInferenceEngine.shared.modelTypeDescription
            debugInfo.sentToVisionModel = LocalInferenceEngine.shared.visionModelStatus
        }
        debugInfo.screenshotCaptured = "Capturing..."
        MenuBarController.shared.updateDebugInfo(debugInfo)
        MenuBarController.shared.setPipelineState(.analyzing)

        Task {
            defer {
                self.isProcessing = false
            }

            do {
                // 1. In-memory Screen Capture
                batteryDiagnosticLog("[AppDelegate] Pipeline Step 1: Requesting in-memory screen capture...")
                var capturedImage: CGImage? = try await ScreenCaptureService.shared.captureMainScreen()
                guard let image = capturedImage else {
                    batteryDiagnosticLog("[AppDelegate] Pipeline Step 1 FAILED: Nil CGImage returned", type: .error)
                    debugInfo.status = "Error"
                    debugInfo.screenshotCaptured = "Failed: Nil image returned"
                    debugInfo.errorMessage = "Screen capture returned nil CGImage"
                    MenuBarController.shared.updateDebugInfo(debugInfo)
                    MenuBarController.shared.setPipelineState(.captureFailed("Nil image returned"))
                    FeedbackManager.shared.deliverStatus("Capture Failed")
                    return
                }

                debugInfo.screenshotCaptured = "Yes (\(image.width)x\(image.height))"
                MenuBarController.shared.updateDebugInfo(debugInfo)
                batteryDiagnosticLog("[AppDelegate] Pipeline Step 2: Screen capture succeeded (\(image.width)x\(image.height)).")

                if OnlineSettings.shared.isOnlineMode {
                    debugInfo.modelFilename = OnlineInferenceEngine.modelName
                    debugInfo.modelType = "NVIDIA hosted multimodal vision"
                    debugInfo.sentToVisionModel = "Yes (direct screenshot sent to NVIDIA)"
                    MenuBarController.shared.updateDebugInfo(debugInfo)

                    do {
                        let result = try await OnlineInferenceEngine.shared.solve(cgImage: image)
                        debugInfo.status = "Success"
                        debugInfo.finalAnswer = "Option \(result.optionLabel)"
                        debugInfo.explanation = result.explanation
                        debugInfo.extractedQuestion = "Question and options analyzed directly from screenshot"
                        debugInfo.availableOptions = "Extracted by NVIDIA vision model"
                        debugInfo.rawModelResponse = result.rawOutput
                        debugInfo.validationResult = result.validationResult
                        debugInfo.inferenceDurationMs = "\(result.durationMs) ms"
                        debugInfo.errorMessage = "None"
                        MenuBarController.shared.updateDebugInfo(debugInfo)

                        MenuBarController.shared.setPipelineState(
                            .inferenceSuccess(answer: result.optionLabel, summary: result.formattedAnswer)
                        )
                        FeedbackManager.shared.deliverResult(
                            answer: result.optionLabel,
                            summary: result.formattedAnswer
                        )
                    } catch let onlineError as OnlineInferenceError {
                        debugInfo.status = "Online Error"
                        debugInfo.validationResult = "Failed"
                        debugInfo.errorMessage = onlineError.localizedDescription
                        MenuBarController.shared.updateDebugInfo(debugInfo)
                        MenuBarController.shared.setPipelineState(.inferenceFailed(onlineError.localizedDescription))
                        FeedbackManager.shared.deliverStatus("Online Error")
                    } catch {
                        let message = error.localizedDescription
                        debugInfo.status = "Online Error"
                        debugInfo.validationResult = "Failed"
                        debugInfo.errorMessage = message
                        MenuBarController.shared.updateDebugInfo(debugInfo)
                        MenuBarController.shared.setPipelineState(.inferenceFailed(message))
                        FeedbackManager.shared.deliverStatus("Online Error")
                    }
                    return
                }

                // Pre-load the model before OCR so the menu can report its actual state.
                _ = LocalInferenceEngine.shared.loadModelIfNeeded()
                debugInfo.modelType = LocalInferenceEngine.shared.modelTypeDescription
                if let path = LocalInferenceEngine.shared.currentModelPath {
                    debugInfo.modelFilename = (path as NSString).lastPathComponent
                }

                // OCR is intentionally the primary path even when an mmproj is installed.
                // It gives the text model a validated question/options set and prevents a
                // vision response from inventing an option based on unrelated screen UI.
                batteryDiagnosticLog("[AppDelegate] Running Apple Vision OCR -> validated MCQ -> text inference...")
                debugInfo.sentToVisionModel = "No (OCR text is supplied to the model; vision projector is not used for answer selection)"
                MenuBarController.shared.updateDebugInfo(debugInfo)

                // Recognition is intentionally retried with a different Vision
                // configuration and, as a final attempt, a fresh screenshot.
                // This avoids treating one transient OCR miss as "No MCQ".
                var ocrImage = image
                var recognizedLines: [String] = []
                var parseResult: Result<ParsedMCQ, ParserRejectionReason> = .failure(.insufficientLines)
                var recognitionPass = "none"
                var recognitionErrors: [String] = []

                for attempt in 1...3 {
                    if attempt == 3 {
                        do {
                            try await Task.sleep(nanoseconds: 120_000_000)
                            ocrImage = try await ScreenCaptureService.shared.captureMainScreen()
                            batteryDiagnosticLog("[AppDelegate] Recognition retry 3 captured a fresh screenshot (\(ocrImage.width)x\(ocrImage.height))")
                        } catch {
                            recognitionErrors.append("fresh screenshot: \(error.localizedDescription)")
                            batteryDiagnosticLog("[AppDelegate] Fresh screenshot retry failed: \(error.localizedDescription)", type: .error)
                        }
                    }

                    do {
                        let useFastPass = attempt == 2
                        let lines = try await OCRService.shared.recognizeText(
                            from: ocrImage,
                            recognitionLevel: useFastPass ? .fast : .accurate,
                            usesLanguageCorrection: !useFastPass
                        )
                        recognizedLines = lines
                        parseResult = QuestionParser.shared.parseWithDiagnostics(lines: lines)

                        if case .success = parseResult {
                            recognitionPass = useFastPass ? "fast OCR retry" : (attempt == 3 ? "fresh screenshot OCR retry" : "accurate OCR")
                            batteryDiagnosticLog("[AppDelegate] MCQ recognized via \(recognitionPass)")
                            break
                        }

                        if case .failure(let reason) = parseResult {
                            recognitionErrors.append("pass \(attempt): \(reason.description)")
                            batteryDiagnosticLog("[AppDelegate] OCR pass \(attempt) did not produce a coherent MCQ: \(reason.description)")
                        }
                    } catch {
                        recognitionErrors.append("pass \(attempt): \(error.localizedDescription)")
                        batteryDiagnosticLog("[AppDelegate] OCR pass \(attempt) failed: \(error.localizedDescription)", type: .error)
                    }

                    if attempt < 3 {
                        try? await Task.sleep(nanoseconds: 80_000_000)
                    }
                }

                capturedImage = nil // Immediate memory release

                guard !recognizedLines.isEmpty else {
                    debugInfo.status = "Error"
                    debugInfo.errorMessage = "Apple Vision OCR recognized 0 text lines after 3 passes: \(recognitionErrors.joined(separator: "; "))"
                    MenuBarController.shared.updateDebugInfo(debugInfo)
                    MenuBarController.shared.setPipelineState(.ocrFailed("No text recognized on screen"))
                    FeedbackManager.shared.deliverStatus("No Text Found")
                    return
                }

                switch parseResult {
                case .failure(let reason):
                    debugInfo.status = "Error"
                    debugInfo.errorMessage = "No MCQ detected after 3 recognition passes: \(reason.description) [\(recognitionErrors.joined(separator: "; "))]"
                    MenuBarController.shared.updateDebugInfo(debugInfo)
                    MenuBarController.shared.setPipelineState(.noMCQFound(reason.description))
                    FeedbackManager.shared.deliverStatus("No MCQ: \(reason.description)")
                    return

                case .success(let mcq):
                    debugInfo.extractedQuestion = mcq.question
                    debugInfo.availableOptions = mcq.options.map { "\($0.label)) \($0.text)" }.joined(separator: " | ")
                    MenuBarController.shared.updateDebugInfo(debugInfo)

                    guard LocalInferenceEngine.shared.hasModelFileAvailable() else {
                        debugInfo.status = "Error"
                        debugInfo.errorMessage = "No GGUF model found in ~/Library/Application Support/Batterysettinginfo/models/"
                        MenuBarController.shared.updateDebugInfo(debugInfo)
                        MenuBarController.shared.setPipelineState(.mcqFoundNoModel(mcq))
                        FeedbackManager.shared.deliverStatus("MCQ Found (No Model)")
                        return
                    }

                    do {
                        let result = try await LocalInferenceEngine.shared.solve(mcq: mcq)
                        debugInfo.status = "Success"
                        debugInfo.finalAnswer = "Option \(result.optionLabel)"
                        debugInfo.explanation = result.explanation
                        debugInfo.rawModelResponse = result.rawOutput
                        debugInfo.validationResult = result.validationResult
                        debugInfo.inferenceDurationMs = "\(result.durationMs) ms"
                        debugInfo.errorMessage = "None"
                        MenuBarController.shared.updateDebugInfo(debugInfo)

                        MenuBarController.shared.setPipelineState(.inferenceSuccess(answer: result.optionLabel, summary: result.formattedAnswer))
                        FeedbackManager.shared.deliverResult(answer: result.optionLabel, summary: result.formattedAnswer)
                    } catch let inferErr as InferenceError {
                        switch inferErr {
                        case .invalidOptionLabel, .unparseableAnswer, .emptyOutput:
                            debugInfo.status = "Invalid response"
                        default:
                            debugInfo.status = "Error"
                        }

                        debugInfo.validationResult = "Failed: \(inferErr.localizedDescription)"
                        debugInfo.errorMessage = inferErr.localizedDescription
                        if case .invalidOptionLabel(_, _, let raw) = inferErr {
                            debugInfo.rawModelResponse = raw
                        } else if case .unparseableAnswer(let raw, _) = inferErr {
                            debugInfo.rawModelResponse = raw
                        } else if case .answerDisagreement(_, _, let firstRaw, let secondRaw) = inferErr {
                            debugInfo.rawModelResponse = "Primary check: \(firstRaw)\nIndependent verification: \(secondRaw)"
                        }
                        MenuBarController.shared.updateDebugInfo(debugInfo)
                        MenuBarController.shared.setPipelineState(.inferenceFailed(inferErr.localizedDescription))
                        FeedbackManager.shared.deliverStatus("No answer: \(inferErr.localizedDescription)")
                    }
                }
            } catch let captureError as ScreenCaptureError {
                batteryDiagnosticLog("[AppDelegate] Screen capture error: \(captureError.localizedDescription)", type: .error)
                debugInfo.status = "Error"
                debugInfo.screenshotCaptured = "Failed: \(captureError.localizedDescription)"
                debugInfo.errorMessage = captureError.localizedDescription
                MenuBarController.shared.updateDebugInfo(debugInfo)
                MenuBarController.shared.setPipelineState(.captureFailed(captureError.localizedDescription))
                FeedbackManager.shared.deliverStatus("Capture: \(captureError.localizedDescription)")
                DispatchQueue.main.async {
                    MenuBarController.shared.updateMenuState()
                }
            } catch {
                let nsError = error as NSError
                let msg = "Pipeline error [\(nsError.domain):\(nsError.code)]: \(error.localizedDescription)"
                batteryDiagnosticLog("[AppDelegate] Unexpected error: \(msg)", type: .error)
                debugInfo.status = "Error"
                debugInfo.errorMessage = msg
                MenuBarController.shared.updateDebugInfo(debugInfo)
                MenuBarController.shared.setPipelineState(.captureFailed(msg))
                FeedbackManager.shared.deliverStatus("Error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    MenuBarController.shared.updateMenuState()
                }
            }
        }
    }
}
