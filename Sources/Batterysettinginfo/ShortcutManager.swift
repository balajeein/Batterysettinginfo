import AppKit
import CoreGraphics
import ApplicationServices
import Carbon

/// Protocol for shortcut trigger callbacks
public protocol ShortcutManagerDelegate: AnyObject {
    func didTriggerAnalysisShortcut()
}

public enum ShortcutRegistrationStatus: Equatable {
    case uninitialized
    case active
    case failedAccessibilityNotGranted
    case failedTapCreation(String)
}

/// Global keyboard shortcut manager for Command + Shift + Quote (⌘⇧').
///
/// Carbon's RegisterEventHotKey is used instead of a listen-only CGEventTap.
/// The former is designed for global application hotkeys and continues to
/// receive the chord while another application owns keyboard focus.
public final class ShortcutManager {
    public static let shared = ShortcutManager()

    public weak var delegate: ShortcutManagerDelegate?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private let hotKeyID = EventHotKeyID(signature: OSType(0x42534948), id: 1) // "BSIH"

    public private(set) var registrationStatus: ShortcutRegistrationStatus = .uninitialized
    public private(set) var registrationDiagnostic: String = "Not initialized"

    public private(set) var targetKeyCode: Int64 = 39 // ANSI Quote '\''
    public let shortcutDisplayString = "⌘⇧'"

    // State tracking to prevent duplicate triggers
    private var isTargetKeyDown = false
    private var lastTriggerTime: Date = Date.distantPast
    private let cooldownInterval: TimeInterval = 0.5

    private init() {
        resolveKeyCodes()
    }

    deinit {
        stop()
    }

    private static let hotKeyHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else {
            return OSStatus(eventNotHandledErr)
        }

        var receivedID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &receivedID
        )

        guard status == noErr else {
            batteryDiagnosticLog("[ShortcutManager] Could not read Carbon hotkey event parameter (status=\(status))", type: .error)
            return status
        }

        let manager = Unmanaged<ShortcutManager>.fromOpaque(userData).takeUnretainedValue()
        guard receivedID.signature == manager.hotKeyID.signature,
              receivedID.id == manager.hotKeyID.id else {
            return OSStatus(eventNotHandledErr)
        }

        batteryDiagnosticLog("[ShortcutManager] *** SHORTCUT DETECTED (\(manager.shortcutDisplayString)) -> TRIGGERING PIPELINE ***")
        DispatchQueue.main.async { [weak manager] in
            manager?.delegate?.didTriggerAnalysisShortcut()
        }
        return noErr
    }

    /// Resolves virtual key code for '\'' from the active keyboard layout, falling back to 39
    private func resolveKeyCodes() {
        if let k = findKeyCode(for: "'") {
            self.targetKeyCode = Int64(k)
        } else {
            self.targetKeyCode = Int64(AppConfiguration.shared.primaryKeyCode)
        }

        if AppConfiguration.shared.isDiagnosticModeEnabled {
            fputs("[ShortcutManager] Initialized target keycode: '\''=\(targetKeyCode) (displayed as \(shortcutDisplayString))\n", stderr)
        }
    }

    /// Helper to look up keycode from active keyboard layout
    private func findKeyCode(for targetChar: Character) -> CGKeyCode? {
        guard let currentKeyboard = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        guard let layoutData = TISGetInputSourceProperty(currentKeyboard, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layout = unsafeBitCast(layoutData, to: CFData.self)
        guard let bytePtr = CFDataGetBytePtr(layout) else { return nil }
        let keyboardLayout = bytePtr.withMemoryRebound(to: CoreServices.UCKeyboardLayout.self, capacity: 1) { $0 }

        var keysDown: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var realLength: Int = 0

        for keyCode: UInt16 in 0..<128 {
            let status = CoreServices.UCKeyTranslate(
                keyboardLayout,
                keyCode,
                UInt16(CoreServices.kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(CoreServices.kUCKeyTranslateNoDeadKeysBit),
                &keysDown,
                chars.count,
                &realLength,
                &chars
            )
            if status == noErr && realLength > 0 {
                let str = String(utf16CodeUnits: chars, count: realLength)
                if str.first == targetChar {
                    return CGKeyCode(keyCode)
                }
            }
        }
        return nil
    }

    /// Checks if Accessibility permission is granted
    public var isAccessibilityGranted: Bool {
        return AXIsProcessTrusted()
    }

    /// Prompts user for Accessibility permissions if missing
    public func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Starts the system-wide Carbon hotkey for ⌘⇧'.
    public func start() -> Bool {
        guard hotKeyRef == nil else { return true }

        batteryDiagnosticLog("[ShortcutManager] Registering Carbon global hotkey for \(shortcutDisplayString) (keycode \(targetKeyCode))")

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            ShortcutManager.hotKeyHandler,
            1,
            &eventType,
            userData,
            &eventHandlerRef
        )
        guard handlerStatus == noErr else {
            registrationStatus = .failedTapCreation("InstallEventHandler failed with status \(handlerStatus)")
            registrationDiagnostic = "Carbon hotkey event handler installation failed (status=\(handlerStatus))"
            batteryDiagnosticLog("[ShortcutManager] Registration failed: \(registrationDiagnostic)", type: .error)
            return false
        }

        var registeredHotKey: EventHotKeyRef?
        let hotKeyStatus = RegisterEventHotKey(
            UInt32(targetKeyCode),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &registeredHotKey
        )
        guard hotKeyStatus == noErr, let registeredHotKey else {
            if let handler = eventHandlerRef {
                RemoveEventHandler(handler)
                eventHandlerRef = nil
            }
            registrationStatus = .failedTapCreation("RegisterEventHotKey failed with status \(hotKeyStatus)")
            registrationDiagnostic = "Carbon global hotkey registration failed (status=\(hotKeyStatus)); another application may own this shortcut"
            batteryDiagnosticLog("[ShortcutManager] Registration failed: \(registrationDiagnostic)", type: .error)
            return false
        }

        hotKeyRef = registeredHotKey
        registrationStatus = .active
        registrationDiagnostic = "Active (Carbon RegisterEventHotKey for \(shortcutDisplayString), no Accessibility permission required)"
        batteryDiagnosticLog("[ShortcutManager] Carbon global hotkey registered successfully for \(shortcutDisplayString)")
        return true
    }

    /// Stops monitoring and detaches from run loop
    public func stop() {
        if let hotKey = hotKeyRef {
            UnregisterEventHotKey(hotKey)
            hotKeyRef = nil
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
        isTargetKeyDown = false
        registrationStatus = .uninitialized
        registrationDiagnostic = "Stopped"
    }

    /// Core shortcut rule evaluator: Command + Shift + Quote (⌘⇧')
    /// Returns true if the shortcut triggered the delegate.
    @discardableResult
    public func handleKeyEvent(keyCode: Int64, flags: CGEventFlags, isDown: Bool, isAutorepeat: Bool = false) -> Bool {
        // 1. Only respond to target key
        guard keyCode == targetKeyCode else {
            return false
        }

        // 2. Key up: reset down state to allow subsequent triggers
        if !isDown {
            isTargetKeyDown = false
            return false
        }

        // 3. Ignore auto-repeat events
        if isAutorepeat {
            if AppConfiguration.shared.isDiagnosticModeEnabled {
                fputs("[ShortcutManager] Quote key-down ignored: auto-repeat\n", stderr)
            }
            return false
        }

        // 4. Ignore repeated key-down while already held down
        if isTargetKeyDown {
            return false
        }

        // 5. Explicitly require Command and Shift modifiers
        let hasCommand = flags.contains(.maskCommand)
        let hasShift = flags.contains(.maskShift)
        let hasForbiddenModifiers = flags.contains(.maskControl) || flags.contains(.maskAlternate)

        guard hasCommand && hasShift && !hasForbiddenModifiers else {
            isTargetKeyDown = true // Marked down without trigger
            return false
        }

        // 6. Cooldown interval check
        let now = Date()
        guard now.timeIntervalSince(lastTriggerTime) >= cooldownInterval else {
            isTargetKeyDown = true
            return false
        }

        isTargetKeyDown = true
        lastTriggerTime = now

        if AppConfiguration.shared.isDiagnosticModeEnabled {
            fputs("[ShortcutManager] *** SHORTCUT DETECTED (\(shortcutDisplayString)) -> TRIGGERING PIPELINE ***\n", stderr)
        }

        DispatchQueue.main.async { [weak self] in
            self?.delegate?.didTriggerAnalysisShortcut()
        }
        return true
    }

    /// Simulates registration failure for diagnostic and unit testing
    public func simulateRegistrationFailure(forTestingReason reason: String) {
        stop()
        registrationStatus = .failedTapCreation(reason)
        registrationDiagnostic = "Registration failure: \(reason)"
    }

    /// Programmatic trigger for testing and menu item activation
    public func triggerManually() {
        if AppConfiguration.shared.isDiagnosticModeEnabled {
            fputs("[ShortcutManager] Manual trigger invoked via menu or test\n", stderr)
        }
        delegate?.didTriggerAnalysisShortcut()
    }
}
