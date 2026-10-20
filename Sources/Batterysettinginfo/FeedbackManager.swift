import AppKit
import CoreGraphics
import IOKit
import IOKit.hid
import IOKit.hidsystem

// The HID framework exports these LED-event entry points, but current macOS
// SDKs do not ship their declarations. They are used only as a best-effort
// hardware feedback path; the standard IOHID output-report path and synthetic
// key-event fallback remain available if the system rejects them.
private typealias BatteryHIDEventRef = OpaquePointer

// macOS Tahoe (26+) exports this client constructor, but omits it from the
// public SDK headers. Client type 2 is the passive service-property client used
// to control the built-in keyboard's HIDCapsLockLED override.
@_silgen_name("IOHIDEventSystemClientCreateWithType")
private func batteryHIDEventSystemClientCreateWithType(
    _ allocator: CFAllocator?,
    _ clientType: UInt32,
    _ attributes: CFDictionary?
) -> IOHIDEventSystemClient?

@_silgen_name("IOHIDEventSystemClientCreate")
private func batteryHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> BatteryHIDEventRef?

@_silgen_name("IOHIDEventCreateLEDEvent")
private func batteryHIDEventCreateLEDEvent(
    _ allocator: CFAllocator?,
    _ timestamp: UInt64,
    _ usagePage: UInt32,
    _ usage: UInt32,
    _ value: UInt32
) -> BatteryHIDEventRef?

@_silgen_name("IOHIDEventSystemClientDispatchEvent")
private func batteryHIDEventSystemClientDispatchEvent(
    _ client: BatteryHIDEventRef,
    _ event: BatteryHIDEventRef
)

/// Protocol for notifying feedback listeners (such as the menu bar controller)
public protocol FeedbackDelegate: AnyObject {
    func didProduceResult(answer: String, confidenceSummary: String)
    func didEncounterStatus(status: String)
}

/// Manages feedback delivery across hardware indicators and menu bar UI.
public final class FeedbackManager {
    public static let shared = FeedbackManager()

    public weak var delegate: FeedbackDelegate?
    private let queue = DispatchQueue(label: "com.local.Batterysettinginfo.feedback", qos: .userInteractive)

    private init() {}

    /// Delivers the inference result to the user.
    /// 1. Keeps the menu bar icon unchanged while reporting the answer in the menu.
    /// 2. If configured, triggers safe natural Caps Lock feedback.
    public func deliverResult(answer: String, summary: String = "") {
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.didProduceResult(answer: answer, confidenceSummary: summary)
        }

        if AppConfiguration.shared.enableCapsLockFeedback {
            queue.async { [weak self] in
                guard let self else { return }
                let blinkCount = self.blinkCount(for: answer)
                batteryDiagnosticLog(
                    "[FeedbackManager] Answer Option \(answer) mapped to \(blinkCount) Caps Lock blink(s)"
                )
                self.runCapsLockBlinkPattern(count: blinkCount)
            }
        }
    }

    /// Gives the No-MCQ condition a recognizable double-beat heartbeat pattern
    /// instead of the single pulse used for ordinary status messages.
    private func triggerNoMCQHeartbeat() {
        batteryDiagnosticLog("[FeedbackManager] Starting No-MCQ heartbeat LED pattern")
        triggerNaturalCapsLockFeedback()
        usleep(120_000)
        triggerNaturalCapsLockFeedback()
        batteryDiagnosticLog("[FeedbackManager] Finished No-MCQ heartbeat LED pattern")
    }

    /// Delivers a status update or error message to the menu bar and feedback indicators
    public func deliverStatus(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.didEncounterStatus(status: message)
        }

        if AppConfiguration.shared.enableCapsLockFeedback {
            queue.async { [weak self] in
                if message.hasPrefix("No MCQ") {
                    self?.triggerNoMCQHeartbeat()
                } else {
                    self?.triggerNaturalCapsLockFeedback()
                }
            }
        }
    }

    /// Runs an explicit LED diagnostic pattern from the menu bar. This path is
    /// intentionally independent of the normal feedback setting so it can
    /// prove whether the physical LED path works even when normal feedback is
    /// disabled.
    public func triggerDebugCapsLockBlinks(count: Int) {
        let blinkCount = min(max(count, 1), 4)
        queue.async { [weak self] in
            guard let self else { return }

            batteryDiagnosticLog("[FeedbackManager] Starting Caps Lock LED debug pattern: \(blinkCount) blink(s)")
            self.runCapsLockBlinkPattern(count: blinkCount)
            batteryDiagnosticLog("[FeedbackManager] Finished Caps Lock LED debug pattern: \(blinkCount) blink(s)")
        }
    }

    /// Runs the same double-beat pattern used when no MCQ is detected.
    public func triggerDebugNoMCQHeartbeat() {
        queue.async { [weak self] in
            self?.triggerNoMCQHeartbeat()
        }
    }

    private func blinkCount(for answer: String) -> Int {
        switch answer.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "A": return 1
        case "B": return 2
        case "C": return 3
        case "D": return 4
        default: return 1
        }
    }

    private func runCapsLockBlinkPattern(count: Int) {
        let blinkCount = min(max(count, 1), 4)
        for index in 0..<blinkCount {
            triggerNaturalCapsLockFeedback()
            if index + 1 < blinkCount {
                usleep(300_000)
            }
        }
    }

    /// Pulses the physical Caps Lock LED without changing the user's Caps Lock
    /// state. On Tahoe, built-in keyboards require the HIDCapsLockLED service
    /// override; external keyboards use their normal HID LED output path.
    /// Synthetic key events remain only as a last-resort compatibility fallback.
    public func triggerNaturalCapsLockFeedback() {
        let initialCapsLockState = currentCapsLockState()

        if pulseTahoeBuiltInCapsLockLED() {
            return
        }

        if pulseHardwareCapsLockLED(initialState: initialCapsLockState) {
            return
        }

        if pulseHIDSystemCapsLockLED(initialState: initialCapsLockState) {
            return
        }

        // Fallback for keyboards whose driver does not expose a writable HID LED
        // report. This preserves the old behavior and still restores the state.
        let capsKeyCode: CGKeyCode = 57 // Virtual keycode for Caps Lock (0x39)
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            batteryDiagnosticLog("[FeedbackManager] Could not create HID event source for Caps Lock feedback", type: .error)
            return
        }

        func pressCapsLock() -> Bool {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: capsKeyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: capsKeyCode, keyDown: false) else {
                return false
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            return true
        }

        // One transition turns the LED/state on or off; the second restores the
        // user's original state. This also gives a visible pulse when the LED is
        // exposed to synthetic HID events by the keyboard/OS combination.
        guard pressCapsLock() else {
            batteryDiagnosticLog("[FeedbackManager] Could not create Caps Lock key events", type: .error)
            return
        }
        usleep(180_000)
        guard pressCapsLock() else {
            batteryDiagnosticLog("[FeedbackManager] Caps Lock restoration event could not be created", type: .error)
            return
        }
        usleep(40_000)

        // Verify via the combined session state rather than NSEvent's cached flags.
        let finalState = currentCapsLockState()
        if finalState != initialCapsLockState {
            batteryDiagnosticLog("[FeedbackManager] Caps Lock state did not restore after pulse; retrying restoration", type: .error)
            _ = pressCapsLock()
            usleep(40_000)
        }

        let verifiedRestoration = currentCapsLockState() == initialCapsLockState
        batteryDiagnosticLog("[FeedbackManager] Caps Lock key-event feedback completed. Restored=\(verifiedRestoration), initial=\(initialCapsLockState)")
    }

    /// macOS Tahoe stopped honoring direct HID LED writes for the built-in
    /// keyboard. Its HID service accepts the private `HIDCapsLockLED` property
    /// with the values `On`, `Off`, and `Auto`. `Auto` hands ownership back to
    /// macOS so the user's real Caps Lock state remains authoritative.
    private func pulseTahoeBuiltInCapsLockLED() -> Bool {
        guard let client = batteryHIDEventSystemClientCreateWithType(
            kCFAllocatorDefault,
            2,
            nil
        ) else {
            return false
        }

        let services = IOHIDEventSystemClientCopyServices(client)
        var builtInKeyboardServices: [IOHIDServiceClient] = []

        if let services {
            let serviceCount = CFArrayGetCount(services)
            for index in 0..<serviceCount {
                let service = unsafeBitCast(
                    CFArrayGetValueAtIndex(services, index),
                    to: IOHIDServiceClient.self
                )

                guard IOHIDServiceClientConformsTo(service, 0x01, 0x06) != 0 else {
                    continue
                }

                guard let builtIn = IOHIDServiceClientCopyProperty(
                    service,
                    kIOHIDBuiltInKey as CFString
                ) else {
                    continue
                }

                let isBuiltIn = (builtIn as? NSNumber)?.boolValue ?? false
                if isBuiltIn {
                    builtInKeyboardServices.append(service)
                }
            }
        }

        guard !builtInKeyboardServices.isEmpty else {
            return false
        }

        func setMode(_ mode: CFString) -> Bool {
            var changed = false
            for service in builtInKeyboardServices {
                if IOHIDServiceClientSetProperty(
                    service,
                    "HIDCapsLockLED" as CFString,
                    mode
                ) {
                    changed = true
                }
            }
            return changed
        }

        guard setMode("On" as CFString) else {
            batteryDiagnosticLog("[FeedbackManager] Tahoe HIDCapsLockLED override was unavailable", type: .error)
            return false
        }

        usleep(220_000)
        let restoredToAuto = setMode("Auto" as CFString)
        batteryDiagnosticLog(
            "[FeedbackManager] Tahoe built-in Caps Lock LED pulse completed. RestoredAuto=\(restoredToAuto)"
        )
        return restoredToAuto
    }

    /// Sends the standard USB HID keyboard LED output report (report ID 1,
    /// Caps Lock bit 1) to attached keyboard devices. The report is intentionally
    /// sent only to Generic Desktop/Keyboard devices, never to Apple's unrelated
    /// internal trackpad or sensor HID services.
    private func pulseHardwareCapsLockLED(initialState: Bool) -> Bool {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(0))

        let matching: [String: Any] = [
            kIOHIDPrimaryUsagePageKey: NSNumber(value: 0x01), // Generic Desktop
            kIOHIDPrimaryUsageKey: NSNumber(value: 0x06)       // Keyboard
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        guard IOHIDManagerOpen(manager, IOOptionBits(0)) == kIOReturnSuccess else {
            batteryDiagnosticLog("[FeedbackManager] Could not open HID manager for Caps Lock LED feedback", type: .error)
            return false
        }
        defer { IOHIDManagerClose(manager, IOOptionBits(0)) }

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !devices.isEmpty else {
            batteryDiagnosticLog("[FeedbackManager] No writable keyboard HID device found; using synthetic Caps Lock fallback")
            return false
        }

        func setLED(capsLockOn: Bool) -> Bool {
            var didWrite = false
            for device in devices {
                let maxOutputSize = (IOHIDDeviceGetProperty(device, kIOHIDMaxOutputReportSizeKey as CFString) as? NSNumber)?.intValue ?? 0
                guard maxOutputSize > 0 else { continue }

                let openStatus = IOHIDDeviceOpen(device, IOOptionBits(0))
                guard openStatus == kIOReturnSuccess || openStatus == kIOReturnExclusiveAccess else {
                    batteryDiagnosticLog("[FeedbackManager] Could not open keyboard HID device for LED report (status=\(openStatus))", type: .error)
                    continue
                }
                defer {
                    if openStatus == kIOReturnSuccess {
                        IOHIDDeviceClose(device, IOOptionBits(0))
                    }
                }

                // Standard keyboard LED output reports use bit 1 for Caps Lock.
                // The report ID is supplied separately to IOHIDDeviceSetReport.
                var report: UInt8 = capsLockOn ? 0x02 : 0x00
                let status = withUnsafePointer(to: &report) { pointer in
                    IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 1, pointer, 1)
                }
                if status == kIOReturnSuccess {
                    didWrite = true
                } else {
                    batteryDiagnosticLog("[FeedbackManager] Keyboard rejected Caps Lock LED output report (status=\(status))", type: .error)
                }
            }
            return didWrite
        }

        guard setLED(capsLockOn: !initialState) else {
            batteryDiagnosticLog("[FeedbackManager] Hardware Caps Lock LED report was unavailable; using synthetic fallback")
            return false
        }
        usleep(220_000)
        let restored = setLED(capsLockOn: initialState)
        batteryDiagnosticLog("[FeedbackManager] Hardware Caps Lock LED pulse completed. Restored=\(restored), initial=\(initialState)")
        return restored
    }

    /// Sends an LED event through the macOS HID event system. This is the path
    /// used by the OS keyboard stack for built-in Apple keyboards, which often
    /// reject direct user-space IOHIDDevice output reports.
    private func pulseHIDSystemCapsLockLED(initialState: Bool) -> Bool {
        func setLED(capsLockOn: Bool) -> Bool {
            guard let client = batteryHIDEventSystemClientCreate(kCFAllocatorDefault) else {
                return false
            }
            guard let event = batteryHIDEventCreateLEDEvent(
                kCFAllocatorDefault,
                mach_absolute_time(),
                0x08, // HID LED usage page
                0x02, // Caps Lock
                capsLockOn ? 1 : 0
            ) else {
                Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(client)).release()
                return false
            }

            batteryHIDEventSystemClientDispatchEvent(client, event)
            Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(event)).release()
            Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(client)).release()
            return true
        }

        guard setLED(capsLockOn: !initialState) else {
            batteryDiagnosticLog("[FeedbackManager] HID system LED event path unavailable; trying direct keyboard report")
            return false
        }
        usleep(220_000)
        let restored = setLED(capsLockOn: initialState)
        batteryDiagnosticLog("[FeedbackManager] HID system Caps Lock LED pulse completed. Restored=\(restored), initial=\(initialState)")
        return restored
    }

    private func currentCapsLockState() -> Bool {
        CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
    }
}
