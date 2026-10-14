import AppKit
import Foundation
import CoreGraphics
import ScreenCaptureKit

public enum ScreenCaptureError: LocalizedError {
    case permissionDenied
    case noDisplayAvailable
    case captureFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen Recording permission is not granted. Please allow in System Settings > Privacy & Security > Screen Recording."
        case .noDisplayAvailable:
            return "No active display was detected for capture."
        case .captureFailed(let msg):
            return "Screen capture failed: \(msg)"
        }
    }
}

/// In-memory native screen capture service using ScreenCaptureKit with Retina support
public final class ScreenCaptureService {
    public static let shared = ScreenCaptureService()

    private init() {}

    /// Checks if screen recording access is preflighted
    public func hasScreenCapturePermission() -> Bool {
        return CGPreflightScreenCaptureAccess()
    }

    /// Prompts user for screen capture permission if not yet granted
    public func requestScreenCapturePermission() {
        _ = CGRequestScreenCaptureAccess()
    }

    /// Captures the main active display directly into memory as a high-resolution CGImage.
    /// Does not write to disk or show any preview window.
    public func captureMainScreen() async throws -> CGImage {
        guard hasScreenCapturePermission() else {
            requestScreenCapturePermission()
            throw ScreenCaptureError.permissionDenied
        }

        do {
            let shareableContent = try await SCShareableContent.current
            var targetDisplay = shareableContent.displays.first

            // Select display matching the active main screen
            if let mainScreen = NSScreen.main {
                let screenFrame = mainScreen.frame
                for d in shareableContent.displays {
                    if abs(d.frame.origin.x - screenFrame.origin.x) < 10 &&
                       abs(d.frame.origin.y - screenFrame.origin.y) < 10 {
                        targetDisplay = d
                        break
                    }
                }
            }

            guard let display = targetDisplay else {
                throw ScreenCaptureError.noDisplayAvailable
            }

            // Exclude current application windows
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let excludingWindows = shareableContent.windows.filter { $0.owningApplication?.processID == ownPID }
            let filter = SCContentFilter(display: display, excludingWindows: excludingWindows)

            let configuration = SCStreamConfiguration()
            let scale = Int(NSScreen.main?.backingScaleFactor ?? 2.0)
            let nativeWidth = display.width * max(scale, 2)
            let nativeHeight = display.height * max(scale, 2)

            configuration.width = nativeWidth
            configuration.height = nativeHeight
            configuration.showsCursor = false
            configuration.scalesToFit = false

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            if AppConfiguration.shared.isDiagnosticModeEnabled {
                let winCount = shareableContent.windows.count
                fputs("[Diagnostic 1] Screen capture: Succeeded (Display ID: \(display.displayID), bounds: \(display.width)x\(display.height))\n", stderr)
                fputs("[Diagnostic 2] Captured image dimensions: \(image.width)x\(image.height) (Scale factor: \(scale)x native)\n", stderr)
                fputs("[Diagnostic 3] Captured content: Active display with \(winCount) window layers visible\n", stderr)
            }

            return image
        } catch {
            if AppConfiguration.shared.isDiagnosticModeEnabled {
                fputs("[Diagnostic 1] Screen capture: FAILED with error: \(error.localizedDescription)\n", stderr)
            }
            throw ScreenCaptureError.captureFailed(error.localizedDescription)
        }
    }
}
