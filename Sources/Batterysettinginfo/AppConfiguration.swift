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

    /// Finds the first valid .gguf model from env, Application Support, or app bundle.
    public func resolveModelPath() -> String? {
        let fileManager = FileManager.default

        // 1. Check environment variable override
        if let envPath = customModelPath, fileManager.fileExists(atPath: envPath) {
            return envPath
        }

        // 2. Check Application Support/Batterysettinginfo/models/
        let appSupportDir = applicationSupportDirectory
        if let items = try? fileManager.contentsOfDirectory(atPath: appSupportDir.path) {
            for item in items where item.hasSuffix(".gguf") {
                let fullPath = appSupportDir.appendingPathComponent(item).path
                return fullPath
            }
        }

        // 3. Check App Bundle Resources
        if let bundlePath = Bundle.main.resourcePath {
            if let items = try? fileManager.contentsOfDirectory(atPath: bundlePath) {
                for item in items where item.hasSuffix(".gguf") {
                    let fullPath = (bundlePath as NSString).appendingPathComponent(item)
                    return fullPath
                }
            }
        }

        return nil
    }

    // Keyboard shortcut defaults (; + ')
    public let primaryKeyCode: UInt16 = 41    // ANSI semicolon ';'
    public let secondaryKeyCode: UInt16 = 39  // ANSI quote/apostrophe '\''
    public let chordTimeWindowSeconds: TimeInterval = 0.35

    // Inference parameters
    public let defaultContextSize: Int32 = 2048
    public let defaultGpuLayers: Int32 = 99
    public let defaultMaxTokens: Int32 = 64
    public let defaultTemperature: Float = 0.0 // Greedy for MCQ

    // Privacy & Hardware
    public let strictPrivacy: Bool = true
    public let enableCapsLockFeedback: Bool = true
}
