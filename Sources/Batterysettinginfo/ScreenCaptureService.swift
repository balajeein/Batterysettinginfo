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

/// In-memory native screen capture service using ScreenCaptureKit
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

    /// Captures the main active display directly into memory as a CGImage.
    /// Does not write to disk or show any preview window.
    public func captureMainScreen() async throws -> CGImage {
        guard hasScreenCapturePermission() else {
            requestScreenCapturePermission()
            throw ScreenCaptureError.permissionDenied
        }

        do {
            let shareableContent = try await SCShareableContent.current
            guard let display = shareableContent.displays.first else {
                throw ScreenCaptureError.noDisplayAvailable
            }

            // Exclude current application from capture if needed
            let filter = SCContentFilter(display: display, excludingWindows: [])

            let configuration = SCStreamConfiguration()
            configuration.width = display.width
            configuration.height = display.height
            configuration.showsCursor = false

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            return image
        } catch {
            throw ScreenCaptureError.captureFailed(error.localizedDescription)
        }
    }
}
