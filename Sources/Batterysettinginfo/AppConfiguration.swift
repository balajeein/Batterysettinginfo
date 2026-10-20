import Foundation

/// Central configuration for Batterysettinginfo
public struct AppConfiguration {
    public static let shared = AppConfiguration()

    public let appName = "Batterysettinginfo"
    public let appVersion = "1.0.0"
    public let bundleIdentifier = "com.local.Batterysettinginfo"

    // Model management
    public var customModelPath: String? {
        if let env = ProcessInfo.processInfo.environment["BATTERY_MODEL_PATH"], !env.isEmpty {
            return env
        }
        return nil
    }

    public var applicationSupportDirectory: URL {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent(appName, isDirectory: true)
        let modelsDir = appDir.appendingPathComponent("models", isDirectory: true)
        if !fileManager.fileExists(atPath: modelsDir.path) {
            try? fileManager.createDirectory(at: modelsDir, withIntermediateDirectories: true, attributes: nil)
        }
        return modelsDir
    }

    public var customMmprojPath: String? {
        if let env = ProcessInfo.processInfo.environment["BATTERY_MMPROJ_PATH"], !env.isEmpty {
            return env
        }
        return nil
    }

    /// Finds the main LLM .gguf model, prioritizing Qwen3-VL and ignoring mmproj projector files.
    public func resolveModelPath() -> String? {
        let fileManager = FileManager.default

        // 1. Check environment variable override
        if let envPath = customModelPath, fileManager.fileExists(atPath: envPath) {
            return envPath
        }

        // 2. Check Application Support/Batterysettinginfo/models/
        let appSupportDir = applicationSupportDirectory
        if let items = try? fileManager.contentsOfDirectory(atPath: appSupportDir.path) {
            // Prefer the installed Qwen3-VL 4B model explicitly. This prevents
            // directory enumeration order from selecting an older Qwen3 file.
            let qwen3Items = items
                .filter { $0.hasSuffix(".gguf") && !$0.hasPrefix("mmproj") && $0.localizedCaseInsensitiveContains("qwen3") }
                .sorted()
            if let preferred = qwen3Items.first(where: {
                $0.localizedCaseInsensitiveContains("qwen3vl-4b") ||
                $0.localizedCaseInsensitiveContains("qwen3-vl-4b")
            }) {
                return appSupportDir.appendingPathComponent(preferred).path
            }
            // Fallback: any Qwen3-VL instruct model.
            for item in qwen3Items {
                return appSupportDir.appendingPathComponent(item).path
            }
            // Priority 2: Any non-projector gguf model
            for item in items.sorted() where item.hasSuffix(".gguf") && !item.hasPrefix("mmproj") {
                return appSupportDir.appendingPathComponent(item).path
            }
        }

        // 3. Check App Bundle Resources
        if let bundlePath = Bundle.main.resourcePath {
            if let items = try? fileManager.contentsOfDirectory(atPath: bundlePath) {
                let qwen3Items = items
                    .filter { $0.hasSuffix(".gguf") && !$0.hasPrefix("mmproj") && $0.localizedCaseInsensitiveContains("qwen3") }
                    .sorted()
                if let preferred = qwen3Items.first(where: {
                    $0.localizedCaseInsensitiveContains("qwen3vl-4b") ||
                    $0.localizedCaseInsensitiveContains("qwen3-vl-4b")
                }) {
                    return (bundlePath as NSString).appendingPathComponent(preferred)
                }
                for item in qwen3Items {
                    return (bundlePath as NSString).appendingPathComponent(item)
                }
                for item in items.sorted() where item.hasSuffix(".gguf") && !item.hasPrefix("mmproj") {
                    return (bundlePath as NSString).appendingPathComponent(item)
                }
            }
        }

        return nil
    }

    /// Finds the mmproj multimodal projector .gguf file.
    public func resolveMmprojPath() -> String? {
        let fileManager = FileManager.default

        // 1. Check environment variable override
        if let envPath = customMmprojPath, fileManager.fileExists(atPath: envPath) {
            return envPath
        }

        // 2. Check Application Support/Batterysettinginfo/models/
        let appSupportDir = applicationSupportDirectory
        if let items = try? fileManager.contentsOfDirectory(atPath: appSupportDir.path) {
            let projectorItems = items
                .filter { $0.hasSuffix(".gguf") && $0.hasPrefix("mmproj") }
                .sorted()
            if let preferred = projectorItems.first(where: {
                $0.localizedCaseInsensitiveContains("qwen3vl-4b") ||
                $0.localizedCaseInsensitiveContains("qwen3-vl-4b")
            }) {
                return appSupportDir.appendingPathComponent(preferred).path
            }
            for item in projectorItems {
                return appSupportDir.appendingPathComponent(item).path
            }
        }

        // 3. Check App Bundle Resources
        if let bundlePath = Bundle.main.resourcePath {
            if let items = try? fileManager.contentsOfDirectory(atPath: bundlePath) {
                let projectorItems = items
                    .filter { $0.hasSuffix(".gguf") && $0.hasPrefix("mmproj") }
                    .sorted()
                if let preferred = projectorItems.first(where: {
                    $0.localizedCaseInsensitiveContains("qwen3vl-4b") ||
                    $0.localizedCaseInsensitiveContains("qwen3-vl-4b")
                }) {
                    return (bundlePath as NSString).appendingPathComponent(preferred)
                }
                for item in projectorItems {
                    return (bundlePath as NSString).appendingPathComponent(item)
                }
            }
        }

        return nil
    }

    // Keyboard shortcut configuration: Command + Shift + Quote (⌘⇧')
    public let primaryKeyCode: UInt16 = 39    // ANSI quote '\''
    public let shortcutDisplayName: String = "⌘⇧'"
    public let shortcutCooldownSeconds: TimeInterval = 0.5

    // Inference parameters
    public let defaultContextSize: Int32 = 4096
    public let defaultGpuLayers: Int32 = 99
    public let defaultMaxTokens: Int32 = 128
    public let defaultTemperature: Float = 0.0 // Greedy for MCQ

    // Privacy & Hardware
    public let strictPrivacy: Bool = true
    public let enableCapsLockFeedback: Bool = true

    /// Diagnostic development mode for console logging
    public var isDiagnosticModeEnabled: Bool {
        if let env = ProcessInfo.processInfo.environment["BATTERY_DEBUG"] {
            return env != "0" && env.lowercased() != "false"
        }
        return true // Enabled by default for local development
    }

    /// Checks if a valid GGUF model exists
    public func hasConfiguredModel() -> Bool {
        return resolveModelPath() != nil
    }
}

import os

private let batteryOSLog = OSLog(subsystem: "com.local.Batterysettinginfo", category: "Diagnostics")

/// Unified diagnostic logger writing to stderr, NSLog, and Apple Unified Logging (os_log)
public func batteryDiagnosticLog(_ message: String, type: OSLogType = .default) {
    if AppConfiguration.shared.isDiagnosticModeEnabled {
        fputs("\(message)\n", stderr)
    }
    NSLog("%@", message)
    os_log(type, log: batteryOSLog, "%{public}@", message)
}
