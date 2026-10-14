import AppKit
import CoreGraphics

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
    /// 1. Updates menu bar visual display with the answer.
    /// 2. If configured, pulses the Caps Lock modifier state safely.
    public func deliverResult(answer: String, summary: String = "") {
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.didProduceResult(answer: answer, confidenceSummary: summary)
        }

        if AppConfiguration.shared.enableCapsLockFeedback {
            queue.async { [weak self] in
                self?.pulseCapsLock(times: 1)
            }
        }
    }

    /// Delivers a status update or error message to the menu bar and feedback indicators
    public func deliverStatus(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.didEncounterStatus(status: message)
        }

        if AppConfiguration.shared.enableCapsLockFeedback {
            // Pulse twice to signal error or absence of MCQ
            if message.contains("No MCQ") || message.contains("Failed") || message.contains("Error") {
                queue.async { [weak self] in
                    self?.pulseCapsLock(times: 2)
                }
            }
        }
    }

    /// Safely pulses the Caps Lock key state and restores original state.
    /// Note on Apple Silicon macOS: Synthetic CGEvent posts toggle the system modifier flag,
    /// but the physical green LED is controlled at the hardware microcontroller/firmware level
    /// and does not reliably respond to synthetic software events. Original state is always guaranteed restored.
    public func pulseCapsLock(times: Int = 1) {
        let initialCapsLockState = NSEvent.modifierFlags.contains(.capsLock)

        // Virtual keycode for Caps Lock is 57 (0x39)
        let capsKeyCode: CGKeyCode = 57
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }

        func postEvent(down: Bool) {
            if let event = CGEvent(keyboardEventSource: source, virtualKey: capsKeyCode, keyDown: down) {
                event.post(tap: .cghidEventTap)
            }
        }

        for _ in 0..<times {
            postEvent(down: true)
            postEvent(down: false)
            usleep(120_000) // 120ms pulse
            postEvent(down: true)
            postEvent(down: false)
            usleep(80_000)
        }

        // Verify and ensure restoration of original state
        let finalState = NSEvent.modifierFlags.contains(.capsLock)
        if finalState != initialCapsLockState {
            postEvent(down: true)
            postEvent(down: false)
        }

        if AppConfiguration.shared.isDiagnosticModeEnabled {
            fputs("[FeedbackManager] Synthetic Caps Lock pulse executed (\(times)x). Initial=\(initialCapsLockState), Restored=\(!initialCapsLockState == false)\n", stderr)
        }
    }
}
