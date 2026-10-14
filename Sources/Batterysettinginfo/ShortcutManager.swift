import AppKit
import Carbon
import CoreGraphics

/// Protocol for shortcut trigger callbacks
public protocol ShortcutManagerDelegate: AnyObject {
    func didTriggerAnalysisShortcut()
}

/// Global keyboard shortcut manager detecting simultaneous chord presses (default: ';' and '\'')
public final class ShortcutManager {
    public static let shared = ShortcutManager()

    public weak var delegate: ShortcutManagerDelegate?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?

    private var isKey1Down = false
    private var isKey2Down = false
    private var key1DownTime: Date?
    private var key2DownTime: Date?
    private var hasTriggeredCurrentChord = false

    private var lastTriggerTime: Date = Date.distantPast
    private let cooldownInterval: TimeInterval = 1.2
    private let chordWindow: TimeInterval = 0.35

    public private(set) var primaryKey: Int64 = 41   // ANSI Semicolon ';'
    public private(set) var secondaryKey: Int64 = 39 // ANSI Quote '\''

    private init() {
        resolveKeyCodes()
    }

    deinit {
        stop()
    }

    /// Resolves virtual key codes for ';' and '\'' from the active keyboard layout
    private func resolveKeyCodes() {
        if let k1 = findKeyCode(for: ";") {
            self.primaryKey = Int64(k1)
        } else {
            self.primaryKey = Int64(AppConfiguration.shared.primaryKeyCode)
        }

        if let k2 = findKeyCode(for: "'") {
            self.secondaryKey = Int64(k2)
        } else {
            self.secondaryKey = Int64(AppConfiguration.shared.secondaryKeyCode)
        }

        if AppConfiguration.shared.isDiagnosticModeEnabled {
            fputs("[ShortcutManager] Initialized keycodes: ';'=\(primaryKey), '\''=\(secondaryKey)\n", stderr)
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

    /// Starts global event tap monitoring and secondary AppKit global monitor
    public func start() -> Bool {
        guard eventTap == nil else { return true }

        let trusted = isAccessibilityGranted
        if AppConfiguration.shared.isDiagnosticModeEnabled {
            fputs("[ShortcutManager] Starting shortcut monitor. Accessibility trusted: \(trusted)\n", stderr)
        }

        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)

        let callback: CGEventTapCallBack = { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<ShortcutManager>.fromOpaque(refcon).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = manager.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            manager.handleKeyEvent(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Use .cgSessionEventTap which receives all login session events under standard Accessibility
        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: selfPtr
        ) {
            self.eventTap = tap
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            self.runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            if AppConfiguration.shared.isDiagnosticModeEnabled {
                fputs("[ShortcutManager] CGEventTap (.cgSessionEventTap) created and attached to main run loop successfully\n", stderr)
            }
        } else {
            if AppConfiguration.shared.isDiagnosticModeEnabled {
                fputs("[ShortcutManager] WARNING: CGEvent.tapCreate returned nil. Check Accessibility permissions.\n", stderr)
            }
        }

        // Install secondary AppKit global event monitor for dual-path reliability
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] nsEvent in
                guard let self = self else { return }
                let code = Int64(nsEvent.keyCode)
                if nsEvent.type == .keyDown {
                    self.processRawKey(code: code, isDown: true)
                } else if nsEvent.type == .keyUp {
                    self.processRawKey(code: code, isDown: false)
                }
            }
            if AppConfiguration.shared.isDiagnosticModeEnabled {
                fputs("[ShortcutManager] AppKit global event monitor installed\n", stderr)
            }
        }

        return eventTap != nil || globalMonitor != nil
    }

    /// Stops monitoring
    public func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        isKey1Down = false
        isKey2Down = false
        hasTriggeredCurrentChord = false
    }

    /// Internal handler from CGEventTap
    private func handleKeyEvent(type: CGEventType, event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isDown = (type == .keyDown)
        processRawKey(code: keyCode, isDown: isDown)
    }

    /// Central chord processing logic
    public func processRawKey(code: Int64, isDown: Bool) {
        let now = Date()

        if code == primaryKey {
            if isDown {
                isKey1Down = true
                key1DownTime = now
                if AppConfiguration.shared.isDiagnosticModeEnabled {
                    fputs("[ShortcutManager] Detected chord key: ';' (down), chord active: \(isKey1Down && isKey2Down)\n", stderr)
                }
                evaluateChord()
            } else {
                isKey1Down = false
                if !isKey1Down && !isKey2Down {
                    hasTriggeredCurrentChord = false
                }
            }
        } else if code == secondaryKey {
            if isDown {
                isKey2Down = true
                key2DownTime = now
                if AppConfiguration.shared.isDiagnosticModeEnabled {
                    fputs("[ShortcutManager] Detected chord key: '\'' (down), chord active: \(isKey1Down && isKey2Down)\n", stderr)
                }
                evaluateChord()
            } else {
                isKey2Down = false
                if !isKey1Down && !isKey2Down {
                    hasTriggeredCurrentChord = false
                }
            }
        }
        // Notice: zero logging for any other keycode, preserving complete user privacy
    }

    private func evaluateChord() {
        guard !hasTriggeredCurrentChord else { return }

        var shouldTrigger = false

        // Condition 1: Both keys currently held down
        if isKey1Down && isKey2Down {
            shouldTrigger = true
        }

        // Condition 2: Overlapping rapid press within chord time window
        if !shouldTrigger, let t1 = key1DownTime, let t2 = key2DownTime {
            if abs(t1.timeIntervalSince(t2)) <= chordWindow {
                shouldTrigger = true
            }
        }

        if shouldTrigger {
            let now = Date()
            if now.timeIntervalSince(lastTriggerTime) >= cooldownInterval {
                lastTriggerTime = now
                hasTriggeredCurrentChord = true
                if AppConfiguration.shared.isDiagnosticModeEnabled {
                    fputs("[ShortcutManager] *** CHORD DETECTED (';' + '\'') -> TRIGGERING PIPELINE ***\n", stderr)
                }
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.didTriggerAnalysisShortcut()
                }
            }
        }
    }

    /// Programmatic trigger for testing and menu item activation
    public func triggerManually() {
        if AppConfiguration.shared.isDiagnosticModeEnabled {
            fputs("[ShortcutManager] Manual trigger invoked via menu or test\n", stderr)
        }
        delegate?.didTriggerAnalysisShortcut()
    }
}
