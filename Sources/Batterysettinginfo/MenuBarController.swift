import AppKit

private final class PasteableSecureTextField: NSSecureTextField {
    @objc func paste(_ sender: Any?) {
        guard let clipboardText = NSPasteboard.general.string(forType: .string),
              !clipboardText.isEmpty else {
            NSSound.beep()
            return
        }

        if let editor = currentEditor() as? NSTextView {
            editor.replaceCharacters(in: editor.selectedRange(), with: clipboardText)
        } else {
            stringValue += clipboardText
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            paste(self)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

public protocol MenuBarControllerDelegate: AnyObject {
    func menuBarDidRequestTrigger()
    func menuBarDidRequestPermissionCheck()
}

public enum PipelineState {
    case idle
    case analyzing
    case captureFailed(String)
    case ocrFailed(String)
    case noMCQFound(String)
    case mcqFoundNoModel(ParsedMCQ)
    case modelLoadFailed(String)
    case inferenceFailed(String)
    case inferenceSuccess(answer: String, summary: String)
}

public struct PipelineDebugInfo: Sendable {
    public var status: String = "Idle"
    public var finalAnswer: String = "Not available"
    public var explanation: String = "Not available"

    public var modelFilename: String = "Not available"
    public var modelType: String = "Not available"
    public var screenshotCaptured: String = "Not available"
    public var sentToVisionModel: String = "Not available"
    public var extractedQuestion: String = "Not available"
    public var availableOptions: String = "Not available"
    public var rawModelResponse: String = "Not available"
    public var validationResult: String = "Not available"
    public var inferenceDurationMs: String = "Not available"
    public var errorMessage: String = "None"

    public init() {}

    public func formattedDiagnosticReport() -> String {
        return """
        ================ BATTERYSETTINGINFO DEBUG REPORT ================
        Status: \(status)
        Timestamp: \(Date())

        [RESULT]
        Final Answer: \(finalAnswer)
        Explanation: \(explanation)

        [DIAGNOSTICS & DEBUG]
        Active Model: \(modelFilename)
        Model Architecture: \(modelType)
        Screenshot Captured: \(screenshotCaptured)
        Vision Model Input: \(sentToVisionModel)
        Extracted Question: \(extractedQuestion)
        Available Options: \(availableOptions)
        Raw Model Response: \(rawModelResponse)
        Validation Result: \(validationResult)
        Inference Duration: \(inferenceDurationMs)
        Error Message: \(errorMessage)
        =================================================================
        """
    }
}

/// Controls the background menu bar status item and status menu
public final class MenuBarController: NSObject, FeedbackDelegate, NSMenuDelegate {
    public static let shared = MenuBarController()

    public weak var delegate: MenuBarControllerDelegate?

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!

    private var statusMenuItem: NSMenuItem!
    private var triggerItem: NSMenuItem!
    private var blinkDebugItem: NSMenuItem!
    private var analysisModeItem: NSMenuItem!
    private var offlineModeItem: NSMenuItem!
    private var onlineModeItem: NSMenuItem!
    private var setNVIDIAKeyItem: NSMenuItem!
    private var clearNVIDIAKeyItem: NSMenuItem!
    private var nvidiaKeyStatusItem: NSMenuItem!

    // Result Section
    private var resultSectionHeader: NSMenuItem!
    private var resultAnswerItem: NSMenuItem!
    private var resultExplanationItem: NSMenuItem!
    private var resultStatusItem: NSMenuItem!

    // Debug Section
    private var debugSectionHeader: NSMenuItem!
    private var debugModelItem: NSMenuItem!
    private var debugModelTypeItem: NSMenuItem!
    private var debugScreenshotItem: NSMenuItem!
    private var debugVisionInputItem: NSMenuItem!
    private var debugQuestionItem: NSMenuItem!
    private var debugOptionsItem: NSMenuItem!
    private var debugRawResponseItem: NSMenuItem!
    private var debugValidationItem: NSMenuItem!
    private var debugDurationItem: NSMenuItem!
    private var debugErrorItem: NSMenuItem!
    private var copyDebugItem: NSMenuItem!

    // Existing System & Permission Items
    private var screenPermMenuItem: NSMenuItem!
    private var accessPermMenuItem: NSMenuItem!

    private var currentDebugInfo = PipelineDebugInfo()
    private var revertTimer: Timer?

    private override init() {
        super.init()
    }

    public func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.title = "🔋"
            button.toolTip = "Batterysettinginfo (Offline/Online MCQ Agent - ⌘⇧')"
        }

        buildMenu()
        FeedbackManager.shared.delegate = self
        updateMenuState()
    }

    private func buildMenu() {
        menu = NSMenu(title: "Batterysettinginfo")
        menu.delegate = self

        statusMenuItem = NSMenuItem(title: "Batterysettinginfo: Ready", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        triggerItem = NSMenuItem(
            title: "Trigger Analysis (⌘⇧')",
            action: #selector(triggerClicked),
            keyEquivalent: "'"
        )
        triggerItem.keyEquivalentModifierMask = [.command, .shift]
        triggerItem.target = self
        menu.addItem(triggerItem)

        let analysisModeMenu = NSMenu(title: "Analysis Mode")
        analysisModeItem = NSMenuItem(title: "Analysis Mode: Offline", action: nil, keyEquivalent: "")
        analysisModeItem.submenu = analysisModeMenu
        menu.addItem(analysisModeItem)

        offlineModeItem = NSMenuItem(
            title: "Offline — Local Qwen3-VL",
            action: #selector(offlineModeClicked),
            keyEquivalent: ""
        )
        offlineModeItem.target = self
        analysisModeMenu.addItem(offlineModeItem)

        onlineModeItem = NSMenuItem(
            title: "Online — NVIDIA Vision",
            action: #selector(onlineModeClicked),
            keyEquivalent: ""
        )
        onlineModeItem.target = self
        analysisModeMenu.addItem(onlineModeItem)

        analysisModeMenu.addItem(NSMenuItem.separator())

        setNVIDIAKeyItem = NSMenuItem(
            title: "Set NVIDIA API Key…",
            action: #selector(setNVIDIAKeyClicked),
            keyEquivalent: ""
        )
        setNVIDIAKeyItem.target = self
        analysisModeMenu.addItem(setNVIDIAKeyItem)

        clearNVIDIAKeyItem = NSMenuItem(
            title: "Clear NVIDIA API Key",
            action: #selector(clearNVIDIAKeyClicked),
            keyEquivalent: ""
        )
        clearNVIDIAKeyItem.target = self
        analysisModeMenu.addItem(clearNVIDIAKeyItem)

        nvidiaKeyStatusItem = NSMenuItem(
            title: "NVIDIA API Key: Not configured",
            action: nil,
            keyEquivalent: ""
        )
        nvidiaKeyStatusItem.isEnabled = false
        analysisModeMenu.addItem(nvidiaKeyStatusItem)

        let blinkDebugMenu = NSMenu(title: "Blink Debug")
        blinkDebugItem = NSMenuItem(title: "Blink Debug", action: nil, keyEquivalent: "")
        blinkDebugItem.submenu = blinkDebugMenu
        menu.addItem(blinkDebugItem)

        let debugBlinkOptions: [(String, Int)] = [
            ("A — 1 blink", 1),
            ("B — 2 blinks", 2),
            ("C — 3 blinks", 3),
            ("D — 4 blinks", 4)
        ]
        for (title, count) in debugBlinkOptions {
            let item = NSMenuItem(
                title: title,
                action: #selector(debugBlinkClicked),
                keyEquivalent: ""
            )
            item.tag = count
            item.target = self
            blinkDebugMenu.addItem(item)
        }

        blinkDebugMenu.addItem(NSMenuItem.separator())

        let heartbeatItem = NSMenuItem(
            title: "Heartbeat — No MCQ pattern",
            action: #selector(debugHeartbeatClicked),
            keyEquivalent: ""
        )
        heartbeatItem.target = self
        blinkDebugMenu.addItem(heartbeatItem)

        // MARK: - RESULT SECTION
        menu.addItem(NSMenuItem.separator())

        resultSectionHeader = NSMenuItem(title: "─── RESULT ───", action: nil, keyEquivalent: "")
        resultSectionHeader.isEnabled = false
        menu.addItem(resultSectionHeader)

        resultAnswerItem = NSMenuItem(title: "Answer: Not available", action: nil, keyEquivalent: "")
        resultAnswerItem.isEnabled = false
        menu.addItem(resultAnswerItem)

        resultExplanationItem = NSMenuItem(title: "Explanation: Not available", action: nil, keyEquivalent: "")
        resultExplanationItem.isEnabled = false
        menu.addItem(resultExplanationItem)

        resultStatusItem = NSMenuItem(title: "Status: Idle", action: nil, keyEquivalent: "")
        resultStatusItem.isEnabled = false
        menu.addItem(resultStatusItem)

        // MARK: - DEBUG SECTION
        menu.addItem(NSMenuItem.separator())

        debugSectionHeader = NSMenuItem(title: "─── DIAGNOSTICS & DEBUG ───", action: nil, keyEquivalent: "")
        debugSectionHeader.isEnabled = false
        menu.addItem(debugSectionHeader)

        debugModelItem = NSMenuItem(title: "Model: Not available", action: nil, keyEquivalent: "")
        debugModelItem.isEnabled = false
        menu.addItem(debugModelItem)

        debugModelTypeItem = NSMenuItem(title: "Model Type: Not available", action: nil, keyEquivalent: "")
        debugModelTypeItem.isEnabled = false
        menu.addItem(debugModelTypeItem)

        debugScreenshotItem = NSMenuItem(title: "Screenshot Captured: Not available", action: nil, keyEquivalent: "")
        debugScreenshotItem.isEnabled = false
        menu.addItem(debugScreenshotItem)

        debugVisionInputItem = NSMenuItem(title: "Vision Model Input: Not available", action: nil, keyEquivalent: "")
        debugVisionInputItem.isEnabled = false
        menu.addItem(debugVisionInputItem)

        debugQuestionItem = NSMenuItem(title: "Question: Not available", action: nil, keyEquivalent: "")
        debugQuestionItem.isEnabled = false
        menu.addItem(debugQuestionItem)

        debugOptionsItem = NSMenuItem(title: "Available Options: Not available", action: nil, keyEquivalent: "")
        debugOptionsItem.isEnabled = false
        menu.addItem(debugOptionsItem)

        debugRawResponseItem = NSMenuItem(title: "Raw Response: Not available", action: nil, keyEquivalent: "")
        debugRawResponseItem.isEnabled = false
        menu.addItem(debugRawResponseItem)

        debugValidationItem = NSMenuItem(title: "Validation Result: Not available", action: nil, keyEquivalent: "")
        debugValidationItem.isEnabled = false
        menu.addItem(debugValidationItem)

        debugDurationItem = NSMenuItem(title: "Inference Duration: Not available", action: nil, keyEquivalent: "")
        debugDurationItem.isEnabled = false
        menu.addItem(debugDurationItem)

        debugErrorItem = NSMenuItem(title: "Error: None", action: nil, keyEquivalent: "")
        debugErrorItem.isEnabled = false
        menu.addItem(debugErrorItem)

        copyDebugItem = NSMenuItem(
            title: "📋 Copy Debug Info",
            action: #selector(copyDebugInfoClicked),
            keyEquivalent: "c"
        )
        copyDebugItem.keyEquivalentModifierMask = [.command, .option]
        copyDebugItem.target = self
        menu.addItem(copyDebugItem)

        // MARK: - SYSTEM & PERMISSIONS
        menu.addItem(NSMenuItem.separator())

        let openFolderItem = NSMenuItem(
            title: "Open Models Directory...",
            action: #selector(openModelsFolderClicked),
            keyEquivalent: "m"
        )
        openFolderItem.target = self
        menu.addItem(openFolderItem)

        screenPermMenuItem = NSMenuItem(
            title: "Screen Recording: Checking...",
            action: #selector(openScreenRecordingSettingsClicked),
            keyEquivalent: ""
        )
        screenPermMenuItem.target = self
        menu.addItem(screenPermMenuItem)

        accessPermMenuItem = NSMenuItem(
            title: "Accessibility (⌘⇧'): Checking...",
            action: #selector(requestAccessPermClicked),
            keyEquivalent: ""
        )
        accessPermMenuItem.target = self
        menu.addItem(accessPermMenuItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Batterysettinginfo", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    /// Truncates text safely for compact menu item labels
    private func truncateLabel(_ text: String, max: Int = 42) -> String {
        let clean = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if clean.count <= max {
            return clean
        }
        return String(clean.prefix(max - 3)) + "..."
    }

    /// Updates the compact Result and Debug sections in the menu bar popover
    public func updateDebugInfo(_ info: PipelineDebugInfo) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateDebugInfo(info)
            }
            return
        }

        self.currentDebugInfo = info

        // Result Section
        resultAnswerItem.title = "Answer: \(truncateLabel(info.finalAnswer, max: 48))"
        resultExplanationItem.title = "Explanation: \(truncateLabel(info.explanation, max: 48))"
        resultStatusItem.title = "Status: \(info.status)"

        // Debug Section
        debugModelItem.title = "Model: \(truncateLabel(info.modelFilename, max: 42))"
        debugModelTypeItem.title = "Model Type: \(truncateLabel(info.modelType, max: 42))"
        debugScreenshotItem.title = "Screenshot: \(truncateLabel(info.screenshotCaptured, max: 42))"
        debugVisionInputItem.title = "Vision Input: \(truncateLabel(info.sentToVisionModel, max: 42))"
        debugQuestionItem.title = "Question: \(truncateLabel(info.extractedQuestion, max: 42))"
        debugOptionsItem.title = "Available Options: \(truncateLabel(info.availableOptions, max: 42))"
        debugRawResponseItem.title = "Raw Response: \(truncateLabel(info.rawModelResponse, max: 42))"
        debugValidationItem.title = "Validation: \(truncateLabel(info.validationResult, max: 42))"
        debugDurationItem.title = "Inference: \(info.inferenceDurationMs)"
        debugErrorItem.title = "Error: \(truncateLabel(info.errorMessage, max: 42))"
    }

    public func updateMenuState() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateMenuState()
            }
            return
        }

        let isOnline = OnlineSettings.shared.isOnlineMode
        analysisModeItem.title = "Analysis Mode: \(isOnline ? "Online" : "Offline")"
        offlineModeItem.state = isOnline ? .off : .on
        onlineModeItem.state = isOnline ? .on : .off
        nvidiaKeyStatusItem.title = "NVIDIA API Key: \(OnlineInferenceEngine.shared.statusDescription)"
        clearNVIDIAKeyItem.isEnabled = OnlineSettings.shared.apiKey != nil

        if isOnline {
            currentDebugInfo.modelFilename = OnlineInferenceEngine.modelName
            currentDebugInfo.modelType = "NVIDIA hosted multimodal vision"
            currentDebugInfo.sentToVisionModel = "Yes (direct screenshot)"
            debugModelItem.title = "Model: \(OnlineInferenceEngine.modelName)"
            debugModelTypeItem.title = "Model Type: NVIDIA hosted vision"
            debugVisionInputItem.title = "Vision Input: Direct screenshot"
        } else {
            // Model state
            let modelLoaded = LocalInferenceEngine.shared.isModelLoaded
            let modelPath = LocalInferenceEngine.shared.currentModelPath ?? AppConfiguration.shared.resolveModelPath()

            if let path = modelPath {
                let filename = (path as NSString).lastPathComponent
                currentDebugInfo.modelFilename = filename
                currentDebugInfo.modelType = LocalInferenceEngine.shared.modelTypeDescription
                currentDebugInfo.sentToVisionModel = LocalInferenceEngine.shared.visionModelStatus
                debugModelItem.title = "Model: \(filename) (\(modelLoaded ? "Active" : "Ready"))"
                debugModelTypeItem.title = "Model Type: \(LocalInferenceEngine.shared.modelTypeDescription)"
                debugVisionInputItem.title = "Vision Input: \(truncateLabel(LocalInferenceEngine.shared.visionModelStatus, max: 42))"
            } else {
                currentDebugInfo.modelFilename = "None (No GGUF in models directory)"
                currentDebugInfo.modelType = "Not available"
                currentDebugInfo.sentToVisionModel = "No"
                debugModelItem.title = "Model: None Found (Click Open Folder)"
                debugModelTypeItem.title = "Model Type: Not available"
                debugVisionInputItem.title = "Vision Input: Not available"
            }
        }

        // Screen recording permission
        let hasScreen = ScreenCaptureService.shared.hasScreenCapturePermission()
        if hasScreen {
            screenPermMenuItem.title = "Screen Recording: Granted ✓"
            screenPermMenuItem.action = nil
            screenPermMenuItem.isEnabled = false
        } else {
            screenPermMenuItem.title = "Screen Recording: Not Granted (Open Settings...)"
            screenPermMenuItem.action = #selector(openScreenRecordingSettingsClicked)
            screenPermMenuItem.target = self
            screenPermMenuItem.isEnabled = true
        }

        // Global shortcut registration. Carbon RegisterEventHotKey does not
        // require Accessibility permission, so report the actual registration
        // state instead of showing a misleading permission requirement.
        if ShortcutManager.shared.registrationStatus == .active {
            accessPermMenuItem.title = "Global Shortcut (⌘⇧'): Active ✓"
            accessPermMenuItem.action = nil
            accessPermMenuItem.isEnabled = false
        } else {
            accessPermMenuItem.title = "Global Shortcut (⌘⇧'): Not Active (Click to Retry)"
            accessPermMenuItem.action = #selector(requestAccessPermClicked)
            accessPermMenuItem.target = self
            accessPermMenuItem.isEnabled = true
        }
    }

    public func setPipelineState(_ state: PipelineState) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.setPipelineState(state)
            }
            return
        }

        revertTimer?.invalidate()

        switch state {
        case .idle:
            resetToIdle()

        case .analyzing:
            statusMenuItem.title = "Status: Processing Screen…"

        case .captureFailed(let err):
            statusMenuItem.title = "Capture Failed: \(truncateLabel(err, max: 35))"
            scheduleRevert()

        case .ocrFailed(let err):
            statusMenuItem.title = "OCR: \(truncateLabel(err, max: 35))"
            scheduleRevert()

        case .noMCQFound(let reason):
            statusMenuItem.title = "No MCQ: \(truncateLabel(reason, max: 35))"
            scheduleRevert()

        case .mcqFoundNoModel(let mcq):
            statusMenuItem.title = "MCQ Detected (\(mcq.options.count) opts) — Missing Model"
            scheduleRevert(after: 6.0)

        case .modelLoadFailed(let err):
            statusMenuItem.title = "Model Error: \(truncateLabel(err, max: 35))"
            scheduleRevert()

        case .inferenceFailed(let err):
            statusMenuItem.title = "Failed: \(truncateLabel(err, max: 35))"
            scheduleRevert()

        case .inferenceSuccess(let answer, _):
            statusMenuItem.title = "Result: Option \(answer)"
            scheduleRevert(after: 5.0)
        }
    }

    private func scheduleRevert(after seconds: TimeInterval = 4.0) {
        revertTimer?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            self?.resetToIdle()
        }
        RunLoop.main.add(timer, forMode: .common)
        revertTimer = timer
    }

    private func resetToIdle() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.resetToIdle()
            }
            return
        }
        if let button = statusItem.button {
            button.title = "🔋"
        }
        statusMenuItem.title = "Batterysettinginfo: Ready"
        updateMenuState()
    }

    @objc private func copyDebugInfoClicked() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let report = currentDebugInfo.formattedDiagnosticReport()
        pasteboard.setString(report, forType: .string)

        batteryDiagnosticLog("[MenuBarController] Copied debug report to clipboard (\(report.count) chars)")
        copyDebugItem.title = "✓ Debug Info Copied to Clipboard"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.copyDebugItem.title = "📋 Copy Debug Info"
        }
    }

    @objc private func triggerClicked() {
        delegate?.menuBarDidRequestTrigger()
    }

    @objc private func offlineModeClicked() {
        OnlineSettings.shared.isOnlineMode = false
        LocalInferenceEngine.shared.unloadModel()
        batteryDiagnosticLog("[MenuBarController] Analysis mode set to Offline")
        updateMenuState()
    }

    @objc private func onlineModeClicked() {
        if OnlineSettings.shared.apiKey == nil {
            setNVIDIAKeyClicked()
        }
        guard OnlineSettings.shared.apiKey != nil else {
            updateMenuState()
            return
        }
        OnlineSettings.shared.isOnlineMode = true
        LocalInferenceEngine.shared.unloadModel()
        batteryDiagnosticLog("[MenuBarController] Analysis mode set to Online (NVIDIA Vision)")
        updateMenuState()
    }

    @objc private func setNVIDIAKeyClicked() {
        let alert = NSAlert()
        alert.messageText = "Set NVIDIA API Key"
        alert.informativeText = "Your key is stored locally in this app and is used only in Online mode. Do not share your key."

        let field = PasteableSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "nvapi-…"
        field.stringValue = OnlineSettings.shared.apiKey ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        // NSSecureTextField's internal editor can suppress the normal paste
        // action. Intercept Command-V while this modal alert is active so the
        // clipboard value is inserted without ever displaying it in plain text.
        let pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "v",
                  event.window === alert.window else {
                return event
            }

            field.paste(nil)
            return nil
        }
        defer {
            if let pasteMonitor {
                NSEvent.removeMonitor(pasteMonitor)
            }
        }

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let enteredKey = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !enteredKey.isEmpty else {
            batteryDiagnosticLog("[MenuBarController] Empty NVIDIA API key was not saved", type: .error)
            return
        }

        if OnlineSettings.shared.saveAPIKey(enteredKey) {
            batteryDiagnosticLog("[MenuBarController] NVIDIA API key saved to local app settings")
            OnlineSettings.shared.isOnlineMode = true
            statusMenuItem.title = "Online mode ready"
            updateMenuState()
        } else {
            batteryDiagnosticLog("[MenuBarController] NVIDIA API key could not be saved", type: .error)
            let failureAlert = NSAlert()
            failureAlert.messageText = "Could Not Save API Key"
            failureAlert.informativeText = "The API key could not be saved. Please try again."
            failureAlert.addButton(withTitle: "OK")
            failureAlert.runModal()
        }
    }

    @objc private func clearNVIDIAKeyClicked() {
        guard OnlineSettings.shared.deleteAPIKey() else { return }
        OnlineSettings.shared.isOnlineMode = false
        batteryDiagnosticLog("[MenuBarController] NVIDIA API key removed from local app settings")
        updateMenuState()
    }

    @objc private func debugBlinkClicked(_ sender: NSMenuItem) {
        guard (1...4).contains(sender.tag) else { return }
        batteryDiagnosticLog("[MenuBarController] User selected Blink Debug option \(sender.tag)")
        FeedbackManager.shared.triggerDebugCapsLockBlinks(count: sender.tag)
    }

    @objc private func debugHeartbeatClicked() {
        batteryDiagnosticLog("[MenuBarController] User selected Blink Debug heartbeat")
        FeedbackManager.shared.triggerDebugNoMCQHeartbeat()
    }

    @objc private func openModelsFolderClicked() {
        let dir = AppConfiguration.shared.applicationSupportDirectory
        NSWorkspace.shared.open(dir)
    }

    @objc private func openScreenRecordingSettingsClicked() {
        batteryDiagnosticLog("[MenuBarController] User clicked Screen Recording permission menu item -> opening System Settings")
        ScreenCaptureService.shared.openSystemSettingsScreenRecording()
        updateMenuState()
    }

    @objc private func requestScreenPermClicked() {
        batteryDiagnosticLog("[MenuBarController] User requested Screen Recording permission prompt")
        ScreenCaptureService.shared.requestScreenCapturePermission()
        updateMenuState()
    }

    @objc private func requestAccessPermClicked() {
        batteryDiagnosticLog("[MenuBarController] User requested global shortcut registration retry")
        _ = ShortcutManager.shared.start()
        updateMenuState()
    }

    @objc private func quitClicked() {
        batteryDiagnosticLog("[MenuBarController] User requested application termination")
        NSApplication.shared.terminate(nil)
    }

    // MARK: - NSMenuDelegate

    public func menuWillOpen(_ menu: NSMenu) {
        if ShortcutManager.shared.registrationStatus != .active {
            _ = ShortcutManager.shared.start()
        }
        updateMenuState()
    }

    // MARK: - FeedbackDelegate

    public func didProduceResult(answer: String, confidenceSummary: String) {
        setPipelineState(.inferenceSuccess(answer: answer, summary: confidenceSummary))
    }

    public func didEncounterStatus(status: String) {
        if status == "Analyzing..." {
            setPipelineState(.analyzing)
        } else if status.contains("No MCQ") {
            setPipelineState(.noMCQFound(status))
        } else {
            statusMenuItem.title = status
        }
    }
}
