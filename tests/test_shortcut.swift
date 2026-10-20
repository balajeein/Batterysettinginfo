import AppKit
import Foundation
import CoreGraphics

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
        print("✓ Target keycode ('\''): \(manager.targetKeyCode)")
        print("✓ Shortcut display string: \(manager.shortcutDisplayString)")

        assertTrue(manager.targetKeyCode == 39, "Target keycode should be 39 for ANSI quote")
        assertTrue(manager.shortcutDisplayString == "⌘⇧'", "Displayed shortcut must be ⌘⇧'")

        print("✓ Accessibility permission status: \(manager.isAccessibilityGranted)")

        class MockDelegate: ShortcutManagerDelegate {
            var triggerCount = 0
            func didTriggerAnalysisShortcut() {
                triggerCount += 1
            }
        }

        let mock = MockDelegate()
        manager.delegate = mock

        let quoteCode: Int64 = manager.targetKeyCode // 39
        let semicolonCode: Int64 = 41 // ANSI Semicolon

        let cmdShift: CGEventFlags = [.maskCommand, .maskShift]
        let cmdOnly: CGEventFlags = [.maskCommand]
        let shiftOnly: CGEventFlags = [.maskShift]
        let noModifiers: CGEventFlags = []

        // Test 1: Command + Shift + Quote triggers once
        print("\n--- Test 1: Command + Shift + Quote triggers once ---")
        mock.triggerCount = 0
        let t1 = manager.handleKeyEvent(keyCode: quoteCode, flags: cmdShift, isDown: true, isAutorepeat: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        assertTrue(t1 == true, "handleKeyEvent should return true for ⌘⇧'")
        assertTrue(mock.triggerCount == 1, "⌘⇧' must trigger callback exactly once")

        // Release quote
        manager.handleKeyEvent(keyCode: quoteCode, flags: noModifiers, isDown: false, isAutorepeat: false)

        // Wait past cooldown
        Thread.sleep(forTimeInterval: 0.6)

        // Test 2: Quote without Command does not trigger
        print("\n--- Test 2: Quote without Command does not trigger ---")
        mock.triggerCount = 0
        let t2 = manager.handleKeyEvent(keyCode: quoteCode, flags: shiftOnly, isDown: true, isAutorepeat: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        assertTrue(t2 == false, "handleKeyEvent should return false without Command")
        assertTrue(mock.triggerCount == 0, "Quote with Shift only must not trigger")
        manager.handleKeyEvent(keyCode: quoteCode, flags: noModifiers, isDown: false, isAutorepeat: false)

        // Wait past cooldown
        Thread.sleep(forTimeInterval: 0.6)

        // Test 3: Quote without Shift does not trigger
        print("\n--- Test 3: Quote without Shift does not trigger ---")
        mock.triggerCount = 0
        let t3 = manager.handleKeyEvent(keyCode: quoteCode, flags: cmdOnly, isDown: true, isAutorepeat: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        assertTrue(t3 == false, "handleKeyEvent should return false without Shift")
        assertTrue(mock.triggerCount == 0, "Quote with Command only must not trigger")
        manager.handleKeyEvent(keyCode: quoteCode, flags: noModifiers, isDown: false, isAutorepeat: false)

        // Wait past cooldown
        Thread.sleep(forTimeInterval: 0.6)

        // Test 4: Command + Shift + Semicolon does not trigger
        print("\n--- Test 4: Command + Shift + Semicolon does not trigger ---")
        mock.triggerCount = 0
        let t4 = manager.handleKeyEvent(keyCode: semicolonCode, flags: cmdShift, isDown: true, isAutorepeat: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        assertTrue(t4 == false, "handleKeyEvent should return false for Semicolon")
        assertTrue(mock.triggerCount == 0, "⌘⇧; must not trigger")
        manager.handleKeyEvent(keyCode: semicolonCode, flags: noModifiers, isDown: false, isAutorepeat: false)

        // Wait past cooldown
        Thread.sleep(forTimeInterval: 0.6)

        // Test 5: Repeated quote key-down events do not trigger duplicate captures
        print("\n--- Test 5: Repeated quote key-down events do not trigger duplicate captures ---")
        mock.triggerCount = 0
        // First key-down
        let t5_initial = manager.handleKeyEvent(keyCode: quoteCode, flags: cmdShift, isDown: true, isAutorepeat: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        assertTrue(t5_initial == true, "Initial press should trigger")
        assertTrue(mock.triggerCount == 1, "Count should be 1 after initial press")

        // Auto-repeat event while held down
        let t5_repeat1 = manager.handleKeyEvent(keyCode: quoteCode, flags: cmdShift, isDown: true, isAutorepeat: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        assertTrue(t5_repeat1 == false, "Auto-repeat key-down must be ignored")
        assertTrue(mock.triggerCount == 1, "Count must remain 1 on auto-repeat")

        // Another key-down without preceding key-up (holding key down)
        let t5_repeat2 = manager.handleKeyEvent(keyCode: quoteCode, flags: cmdShift, isDown: true, isAutorepeat: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        assertTrue(t5_repeat2 == false, "Duplicate key-down while held down must be ignored")
        assertTrue(mock.triggerCount == 1, "Count must remain 1 while key is held down")

        // Test 6: Releasing and pressing the shortcut again triggers a new capture
        print("\n--- Test 6: Releasing and pressing shortcut again triggers a new capture ---")
        // Key-up release
        let t6_release = manager.handleKeyEvent(keyCode: quoteCode, flags: noModifiers, isDown: false, isAutorepeat: false)
        assertTrue(t6_release == false, "Key-up should not trigger callback")

        // Wait past cooldown
        Thread.sleep(forTimeInterval: 0.6)

        // Press again
        let t6_pressAgain = manager.handleKeyEvent(keyCode: quoteCode, flags: cmdShift, isDown: true, isAutorepeat: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        assertTrue(t6_pressAgain == true, "Subsequent press after release must trigger")
        assertTrue(mock.triggerCount == 2, "Trigger count should now be 2")

        // Clean release
        manager.handleKeyEvent(keyCode: quoteCode, flags: noModifiers, isDown: false, isAutorepeat: false)

        // Test 7: A failed event-tap registration is reported clearly
        print("\n--- Test 7: Failed event-tap registration is reported clearly ---")
        let simulatedFailureReason = "CGEventTap creation denied by missing Accessibility permission"
        manager.simulateRegistrationFailure(forTestingReason: simulatedFailureReason)

        assertTrue(manager.registrationStatus != .active, "Registration status must reflect non-active state on failure")
        assertTrue(manager.registrationDiagnostic.contains(simulatedFailureReason), "Registration diagnostic must report failure reason clearly")
        print("✓ Diagnostic report upon failure: \"\(manager.registrationDiagnostic)\"")

        // Reset to clean state
        _ = manager.start()

        print("\n======================================================================")
        print(" MANUAL VERIFICATION PROCEDURE (Packaged Application):")
        print(" 1. Launch packaged app: ./dev.sh run")
        print(" 2. Confirm 🔋 icon appears in macOS menu bar.")
        print(" 3. Click 🔋 icon, confirm menu shows 'Trigger Analysis (⌘⇧')'.")
        print(" 4. Confirm 'Screen Recording: Granted ✓' (or click to open System Settings).")
        print(" 5. Switch focus to Google Chrome with an MCQ visible.")
        print(" 6. Press Command + Shift + Quote (⌘ + ⇧ + ').")
        print(" 7. Verify menu bar status transitions: 🔋 -> ⏳... -> result.")
        print("======================================================================")
        print("=== ShortcutManager Independent Tests PASSED Successfully ===")
    }
}
