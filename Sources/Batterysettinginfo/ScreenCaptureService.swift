import AppKit
import Foundation
import CoreGraphics
import ScreenCaptureKit

public enum ScreenCaptureStatus: Equatable {
    case permissionNotGranted
    case permissionUnknown(String)
    case captureRequestFailed(domain: String, code: Int, message: String)
    case noValidDisplayOrFilter(String)
    case succeeded
}

public enum ScreenCaptureError: LocalizedError, Equatable {
    case permissionDenied
    case permissionUnknown(String)
    case captureRequestFailed(domain: String, code: Int, message: String)
    case noValidDisplayOrFilter(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen Recording permission is not granted. Please allow in System Settings > Privacy & Security > Screen Recording."
        case .permissionUnknown(let detail):
            return "Screen Recording permission status unknown: \(detail)"
        case .captureRequestFailed(let domain, let code, let msg):
            return "Screen capture request failed [\(domain) code \(code)]: \(msg)"
        case .noValidDisplayOrFilter(let detail):
            return "No valid display or capture filter: \(detail)"
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

    /// Directs user to macOS System Settings Screen Recording panel
    public func openSystemSettingsScreenRecording() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Logs current permission diagnostics to unified log and stderr
    public func logCurrentPermissionDiagnostics() {
        let preflight = CGPreflightScreenCaptureAccess()
        let axTrusted = AXIsProcessTrusted()
        let bundleID = Bundle.main.bundleIdentifier ?? "nil"
        let bundlePath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        batteryDiagnosticLog("[Permission Diagnostics] BundleID: \(bundleID), Path: \(bundlePath), PID: \(pid), CGPreflightScreenCaptureAccess() = \(preflight), AXIsProcessTrusted() = \(axTrusted)")
    }

    /// Captures the main active display directly into memory as a high-resolution CGImage.
    /// Does not write to disk or show any preview window.
    public func captureMainScreen() async throws -> CGImage {
        let preflight = hasScreenCapturePermission()
        let axTrusted = AXIsProcessTrusted()
        batteryDiagnosticLog("[ScreenCaptureService] Starting captureMainScreen. CGPreflightScreenCaptureAccess() = \(preflight), AXIsProcessTrusted() = \(axTrusted), PID = \(ProcessInfo.processInfo.processIdentifier)")

        // 1. Fetch shareable content via ScreenCaptureKit without prematurely aborting on preflight
        let shareableContent: SCShareableContent
        do {
            shareableContent = try await SCShareableContent.current
            batteryDiagnosticLog("[ScreenCaptureService] SCShareableContent.current succeeded: \(shareableContent.displays.count) display(s), \(shareableContent.windows.count) window(s)")
        } catch {
            let nsError = error as NSError
            batteryDiagnosticLog("[ScreenCaptureService] SCShareableContent.current failed: domain=\(nsError.domain), code=\(nsError.code), description=\(nsError.localizedDescription), userInfo=\(nsError.userInfo)", type: .error)

            // SCStreamErrorDomain with code -3801 corresponds to userDeclined
            if nsError.domain == "com.apple.ScreenCaptureKit.StreamErrorDomain" || nsError.domain == SCStreamErrorDomain {
                if nsError.code == -3801 {
                    batteryDiagnosticLog("[ScreenCaptureService] Permission DENIED: SCStreamError.userDeclined (-3801). Requesting system prompt.", type: .error)
                    requestScreenCapturePermission()
                    throw ScreenCaptureError.permissionDenied
                }
            }

            if !preflight {
                if nsError.code == -3801 || nsError.code == -3802 {
                    batteryDiagnosticLog("[ScreenCaptureService] Permission DENIED (preflight false + stream error code \(nsError.code)). Requesting system prompt.", type: .error)
                    requestScreenCapturePermission()
                    throw ScreenCaptureError.permissionDenied
                }
                batteryDiagnosticLog("[ScreenCaptureService] Permission status UNKNOWN: preflight false, error [\(nsError.domain):\(nsError.code)]: \(nsError.localizedDescription)", type: .error)
                throw ScreenCaptureError.permissionUnknown("Preflight was false and SCShareableContent error [\(nsError.domain):\(nsError.code)]: \(nsError.localizedDescription)")
            }

            batteryDiagnosticLog("[ScreenCaptureService] Capture request FAILED despite permission: [\(nsError.domain):\(nsError.code)]: \(nsError.localizedDescription)", type: .error)
            throw ScreenCaptureError.captureRequestFailed(
                domain: nsError.domain,
                code: nsError.code,
                message: nsError.localizedDescription
            )
        }

        // 2. Locate active display
        guard !shareableContent.displays.isEmpty else {
            batteryDiagnosticLog("[ScreenCaptureService] SCShareableContent returned 0 active displays", type: .error)
            throw ScreenCaptureError.noValidDisplayOrFilter("No active displays found")
        }

        var targetDisplay = shareableContent.displays.first
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

        guard let display = targetDisplay, display.width > 0, display.height > 0 else {
            batteryDiagnosticLog("[ScreenCaptureService] Selected display has invalid dimensions", type: .error)
            throw ScreenCaptureError.noValidDisplayOrFilter("Main display has invalid dimensions")
        }

        batteryDiagnosticLog("[ScreenCaptureService] Target display selected: ID=\(display.displayID), bounds=\(display.width)x\(display.height)")

        // 3. Exclude current application windows
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let excludingWindows = shareableContent.windows.filter { $0.owningApplication?.processID == ownPID }
        let filter = SCContentFilter(display: display, excludingWindows: excludingWindows)

        // 4. Configure stream configuration with retina backing scale
        let configuration = SCStreamConfiguration()
        let scale = Int(NSScreen.main?.backingScaleFactor ?? 2.0)
        let nativeWidth = display.width * max(scale, 2)
        let nativeHeight = display.height * max(scale, 2)

        configuration.width = nativeWidth
        configuration.height = nativeHeight
        configuration.showsCursor = false
        configuration.scalesToFit = false

        // 5. In-memory capture without writing to disk
        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            let winCount = shareableContent.windows.count
            batteryDiagnosticLog("[Diagnostic 1] Screen capture: Succeeded (Display ID: \(display.displayID), bounds: \(display.width)x\(display.height))")
            batteryDiagnosticLog("[Diagnostic 2] Captured image dimensions: \(image.width)x\(image.height) (Scale factor: \(scale)x native)")
            batteryDiagnosticLog("[Diagnostic 3] Captured content: Active display with \(winCount) window layers visible (in-memory only)")

            return image
        } catch {
            let nsError = error as NSError
            batteryDiagnosticLog("[Diagnostic 1] Screen capture: FAILED - domain=\(nsError.domain), code=\(nsError.code), description=\(nsError.localizedDescription), userInfo=\(nsError.userInfo)", type: .error)

            if nsError.domain == "com.apple.ScreenCaptureKit.StreamErrorDomain" || nsError.domain == SCStreamErrorDomain {
                if nsError.code == -3801 {
                    batteryDiagnosticLog("[ScreenCaptureService] Permission DENIED on captureImage: code -3801", type: .error)
                    requestScreenCapturePermission()
                    throw ScreenCaptureError.permissionDenied
                }
            }

            throw ScreenCaptureError.captureRequestFailed(
                domain: nsError.domain,
                code: nsError.code,
                message: nsError.localizedDescription
            )
        }
    }
}
