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
                self?.pulseCapsLock()
            }
        }
    }

    /// Safely pulses the Caps Lock key state and restores original state.
    /// Note on Apple Silicon macOS: Synthetic CGEvent posts toggle the system modifier flag,
    /// but hardware LED response varies by keyboard firmware/controller. Original state is always restored.
    public func pulseCapsLock() {
        let initialCapsLockState = NSEvent.modifierFlags.contains(.capsLock)

        // Virtual keycode for Caps Lock is 57 (0x39)
        let capsKeyCode: CGKeyCode = 57
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }

        func postEvent(down: Bool) {
            if let event = CGEvent(keyboardEventSource: source, virtualKey: capsKeyCode, keyDown: down) {
                event.post(tap: .cghidEventTap)
            }
        }

        // Pulse Caps Lock
        postEvent(down: true)
        postEvent(down: false)
        usleep(150_000) // 150 ms pulse

        postEvent(down: true)
        postEvent(down: false)
        usleep(50_000)

        // Verify and ensure restoration of original state
        let finalState = NSEvent.modifierFlags.contains(.capsLock)
        if finalState != initialCapsLockState {
            postEvent(down: true)
            postEvent(down: false)
        }
    }

    public func deliverStatus(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.didEncounterStatus(status: message)
        }
    }
}
