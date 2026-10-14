import AppKit

public protocol MenuBarControllerDelegate: AnyObject {
    func menuBarDidRequestTrigger()
    func menuBarDidRequestPermissionCheck()
}

/// Controls the background menu bar status item and status menu
public final class MenuBarController: NSObject, FeedbackDelegate {
    public static let shared = MenuBarController()

    public weak var delegate: MenuBarControllerDelegate?

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!

    private var statusMenuItem: NSMenuItem!
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
        revertTimer?.invalidate()

        if let button = statusItem.button {
            button.title = "✓ [ \(answer) ]"
        }
        statusMenuItem.title = "Result: Option \(answer)"

        revertTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            self?.resetToIdle()
        }
    }

    public func didEncounterStatus(status: String) {
        revertTimer?.invalidate()

        if let button = statusItem.button {
            if status == "Analyzing..." {
                button.title = "⏳..."
            } else if status.contains("No MCQ") {
                button.title = "⚠️ No MCQ"
            } else if status.contains("Error") {
                button.title = "❌ Error"
            }
        }
        statusMenuItem.title = "Status: \(status)"

        revertTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { [weak self] _ in
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
}
