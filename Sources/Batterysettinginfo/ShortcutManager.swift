import AppKit
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
    private var activePressedKeys: Set<Int64> = []
    private var lastTriggerTime: Date = Date.distantPast
    private let cooldownInterval: TimeInterval = 1.5

    private let primaryKey: Int64
    private let secondaryKey: Int64

    private init() {
        self.primaryKey = Int64(AppConfiguration.shared.primaryKeyCode)
        self.secondaryKey = Int64(AppConfiguration.shared.secondaryKeyCode)
    }

    deinit {
        stop()
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

    /// Starts global event tap monitoring
    public func start() -> Bool {
        guard eventTap == nil else { return true }

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

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: selfPtr
        ) else {
            return false
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        return true
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
        activePressedKeys.removeAll()
    }

    /// Processes keyboard events for the chord
    private func handleKeyEvent(type: CGEventType, event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if type == .keyDown {
            activePressedKeys.insert(keyCode)

            // Check if both chord keys are held down simultaneously
            if activePressedKeys.contains(primaryKey) && activePressedKeys.contains(secondaryKey) {
                let now = Date()
                if now.timeIntervalSince(lastTriggerTime) >= cooldownInterval {
                    lastTriggerTime = now
                    DispatchQueue.main.async { [weak self] in
                        self?.delegate?.didTriggerAnalysisShortcut()
                    }
                }
            }
        } else if type == .keyUp {
            activePressedKeys.remove(keyCode)
        }
    }

    /// Programmatic trigger for testing and menu item activation
    public func triggerManually() {
        delegate?.didTriggerAnalysisShortcut()
    }
}
