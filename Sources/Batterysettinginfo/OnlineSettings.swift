import Foundation

/// Stores per-user online-mode preferences and the NVIDIA API key.
/// The key is kept only in this user's local app preferences and is never
/// written to logs, diagnostics, or the app bundle. This intentionally avoids
/// macOS Keychain access so opening the menu bar cannot trigger a password prompt.
public final class OnlineSettings: @unchecked Sendable {
    public static let shared = OnlineSettings()

    public enum AnalysisMode: String {
        case offline
        case online
    }

    private let defaultsKey = "Batterysettinginfo.analysisMode"
    private let apiKeyDefaultsKey = "Batterysettinginfo.nvidiaAPIKey"
    private let lock = NSLock()

    private init() {}

    public var analysisMode: AnalysisMode {
        get {
            let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? AnalysisMode.offline.rawValue
            return AnalysisMode(rawValue: raw) ?? .offline
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    public var isOnlineMode: Bool {
        get { analysisMode == .online }
        set { analysisMode = newValue ? .online : .offline }
    }

    public var apiKey: String? {
        lock.lock()
        defer { lock.unlock() }

        guard let value = UserDefaults.standard.string(forKey: apiKeyDefaultsKey),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    public func saveAPIKey(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        lock.lock()
        defer { lock.unlock() }
        UserDefaults.standard.set(normalized, forKey: apiKeyDefaultsKey)
        return true
    }

    @discardableResult
    public func deleteAPIKey() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: apiKeyDefaultsKey)
        return true
    }
}
