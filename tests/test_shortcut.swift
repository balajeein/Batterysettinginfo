import AppKit
import Foundation

@main
struct TestShortcutMain {
    static func assertTrue(_ condition: Bool, _ message: String) {
        if !condition {
            print("❌ FAILED: \(message)")
            exit(1)
        } else {
            print("✓ PASSED: \(message)")
        }
    }

    static func main() {
        print("=== Running ShortcutManager Independent Unit & Logic Tests ===")

        let manager = ShortcutManager.shared
        print("✓ Resolved primary keycode (';'): \(manager.primaryKey)")
        print("✓ Resolved secondary keycode ('\''): \(manager.secondaryKey)")

        assertTrue(manager.primaryKey == 41, "Primary keycode should be 41 for ANSI semicolon")
        assertTrue(manager.secondaryKey == 39, "Secondary keycode should be 39 for ANSI quote")

        print("✓ Accessibility permission status: \(manager.isAccessibilityGranted)")

        // Test Chord State Simulation
        class MockDelegate: ShortcutManagerDelegate {
            var triggerCount = 0
            func didTriggerAnalysisShortcut() {
                triggerCount += 1
            }
        }

        let mock = MockDelegate()
        manager.delegate = mock

        // Case 1: Press Key 1, then Key 2 (simultaneous hold)
        manager.processRawKey(code: manager.primaryKey, isDown: true)
        manager.processRawKey(code: manager.secondaryKey, isDown: true)

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        assertTrue(mock.triggerCount == 1, "Simultaneous hold should trigger chord once")

        // Case 2: Key repeat while held down should NOT trigger again
        manager.processRawKey(code: manager.primaryKey, isDown: true)
        manager.processRawKey(code: manager.secondaryKey, isDown: true)

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        assertTrue(mock.triggerCount == 1, "Key repeat while holding chord keys must not re-trigger")

        // Release both
        manager.processRawKey(code: manager.primaryKey, isDown: false)
        manager.processRawKey(code: manager.secondaryKey, isDown: false)

        // Case 3: Overlapping rapid press (Key 2 down, then Key 1 down within 100ms)
        Thread.sleep(forTimeInterval: 1.3) // Wait for cooldown
        manager.processRawKey(code: manager.secondaryKey, isDown: true)
        Thread.sleep(forTimeInterval: 0.05)
        manager.processRawKey(code: manager.primaryKey, isDown: true)

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        assertTrue(mock.triggerCount == 2, "Overlapping rapid press within window should trigger chord")

        manager.processRawKey(code: manager.secondaryKey, isDown: false)
        manager.processRawKey(code: manager.primaryKey, isDown: false)

        print("=== ShortcutManager Independent Tests PASSED Successfully ===")
    }
}
