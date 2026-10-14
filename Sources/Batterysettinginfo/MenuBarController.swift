import AppKit

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

/// Controls the background menu bar status item and status menu
public final class MenuBarController: NSObject, FeedbackDelegate {
    public static let shared = MenuBarController()

    public weak var delegate: MenuBarControllerDelegate?

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!

    private var statusMenuItem: NSMenuItem!
    private var mcqDetailsMenuItem: NSMenuItem!
    private var modelMenuItem: NSMenuItem!
    private var backendMenuItem: NSMenuItem!
    private var screenPermMenuItem: NSMenuItem!
    private var accessPermMenuItem: NSMenuItem!

    private var revertTimer: Timer?

    private override init() {
        super.init()
    }

    public func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.title = "🔋"
            button.toolTip = "Batterysettinginfo (Offline MCQ Agent)"
        }

        buildMenu()
        FeedbackManager.shared.delegate = self
        updateMenuState()
    }

    private func buildMenu() {
        menu = NSMenu(title: "Batterysettinginfo")

        statusMenuItem = NSMenuItem(title: "Batterysettinginfo: Ready", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        mcqDetailsMenuItem = NSMenuItem(title: "Last Detection: None", action: nil, keyEquivalent: "")
        mcqDetailsMenuItem.isEnabled = false
        mcqDetailsMenuItem.isHidden = true
        menu.addItem(mcqDetailsMenuItem)

        let triggerItem = NSMenuItem(
            title: "Trigger Analysis (; + ')",
            action: #selector(triggerClicked),
            keyEquivalent: "t"
        )
        triggerItem.target = self
        menu.addItem(triggerItem)

        menu.addItem(NSMenuItem.separator())

        modelMenuItem = NSMenuItem(title: "Model: Checking...", action: nil, keyEquivalent: "")
        modelMenuItem.isEnabled = false
        menu.addItem(modelMenuItem)

        backendMenuItem = NSMenuItem(title: "Backend: Embedded llama.cpp", action: nil, keyEquivalent: "")
        backendMenuItem.isEnabled = false
        menu.addItem(backendMenuItem)

        let openFolderItem = NSMenuItem(
            title: "Open Models Directory...",
            action: #selector(openModelsFolderClicked),
            keyEquivalent: "m"
        )
        openFolderItem.target = self
        menu.addItem(openFolderItem)

        menu.addItem(NSMenuItem.separator())

        screenPermMenuItem = NSMenuItem(title: "Screen Recording: Checking...", action: #selector(requestScreenPermClicked), keyEquivalent: "")
        screenPermMenuItem.target = self
        menu.addItem(screenPermMenuItem)

        accessPermMenuItem = NSMenuItem(title: "Accessibility: Checking...", action: #selector(requestAccessPermClicked), keyEquivalent: "")
        accessPermMenuItem.target = self
        menu.addItem(accessPermMenuItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Batterysettinginfo", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    public func updateMenuState() {
        // Model state
        let modelLoaded = LocalInferenceEngine.shared.isModelLoaded
        let modelPath = LocalInferenceEngine.shared.currentModelPath ?? AppConfiguration.shared.resolveModelPath()

        if let path = modelPath {
            let filename = (path as NSString).lastPathComponent
            modelMenuItem.title = modelLoaded ? "Model: \(filename) (Active)" : "Model: \(filename) (Ready)"
        } else {
            modelMenuItem.title = "Model: No GGUF Found (Click Open Folder)"
        }

        // Backend
        backendMenuItem.title = "Backend: \(LocalInferenceEngine.shared.backendInfo)"

        // Screen recording permission
        let hasScreen = ScreenCaptureService.shared.hasScreenCapturePermission()
        screenPermMenuItem.title = hasScreen ? "Screen Recording: Granted ✓" : "Screen Recording: Not Granted (Click to Allow)"

        // Accessibility permission
        let hasAccess = ShortcutManager.shared.isAccessibilityGranted
        accessPermMenuItem.title = hasAccess ? "Accessibility (; + '): Granted ✓" : "Accessibility: Not Granted (Click to Allow)"
    }

    public func setPipelineState(_ state: PipelineState) {
        revertTimer?.invalidate()

        switch state {
        case .idle:
            resetToIdle()

        case .analyzing:
            if let button = statusItem.button { button.title = "⏳..." }
            statusMenuItem.title = "Status: Analyzing Screen..."
            mcqDetailsMenuItem.isHidden = true

        case .captureFailed(let err):
            if let button = statusItem.button { button.title = "❌ Capture Failed" }
            statusMenuItem.title = "Capture Failed: \(err)"
            scheduleRevert()

        case .ocrFailed(let err):
            if let button = statusItem.button { button.title = "⚠️ No Text" }
            statusMenuItem.title = "OCR: \(err)"
            scheduleRevert()

        case .noMCQFound(let reason):
            if let button = statusItem.button { button.title = "⚠️ No MCQ" }
            statusMenuItem.title = "No MCQ Found: \(reason)"
            scheduleRevert()

        case .mcqFoundNoModel(let mcq):
            if let button = statusItem.button { button.title = "✓ MCQ (No Model)" }
            statusMenuItem.title = "MCQ Detected ✓ (\(mcq.options.count) options) — Missing Model"
            mcqDetailsMenuItem.isHidden = false
            let preview = mcq.question.prefix(40)
            mcqDetailsMenuItem.title = "Question: \"\(preview)...\" (Place .gguf in models folder)"
            scheduleRevert(after: 6.0)

        case .modelLoadFailed(let err):
            if let button = statusItem.button { button.title = "❌ Model Error" }
            statusMenuItem.title = "Model Load Failed: \(err)"
            scheduleRevert()

        case .inferenceFailed(let err):
            if let button = statusItem.button { button.title = "❌ Inference Error" }
            statusMenuItem.title = "Inference Failed: \(err)"
            scheduleRevert()

        case .inferenceSuccess(let answer, let summary):
            if let button = statusItem.button { button.title = "✓ [ \(answer) ]" }
            statusMenuItem.title = "Result: Predicted Option \(answer)"
            mcqDetailsMenuItem.isHidden = false
            mcqDetailsMenuItem.title = "Output: \(summary.prefix(50))"
            scheduleRevert(after: 5.0)
        }
    }

    private func scheduleRevert(after seconds: TimeInterval = 4.0) {
        revertTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.resetToIdle()
        }
    }

    private func resetToIdle() {
        if let button = statusItem.button {
            button.title = "🔋"
        }
        statusMenuItem.title = "Batterysettinginfo: Ready"
        updateMenuState()
    }

    @objc private func triggerClicked() {
        delegate?.menuBarDidRequestTrigger()
    }

    @objc private func openModelsFolderClicked() {
        let dir = AppConfiguration.shared.applicationSupportDirectory
        NSWorkspace.shared.open(dir)
    }

    @objc private func requestScreenPermClicked() {
        ScreenCaptureService.shared.requestScreenCapturePermission()
        updateMenuState()
    }

    @objc private func requestAccessPermClicked() {
        ShortcutManager.shared.requestAccessibilityPermission()
        updateMenuState()
    }

    @objc private func quitClicked() {
        NSApplication.shared.terminate(nil)
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
