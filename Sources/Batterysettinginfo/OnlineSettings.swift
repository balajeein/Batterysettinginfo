import Foundation
import Security

/// Stores per-user online-mode preferences and the NVIDIA API key.
/// The key is never written to UserDefaults, logs, diagnostics, or the app bundle.
public final class OnlineSettings: @unchecked Sendable {
    public static let shared = OnlineSettings()

    public enum AnalysisMode: String {
        case offline
        case online
    }

    private let defaultsKey = "Batterysettinginfo.analysisMode"
    private let keychainService = "com.local.Batterysettinginfo.nvidia-api"
    private let keychainAccount = "default"
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

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
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

        let primaryAttributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let data = Data(normalized.utf8)

        let updateStatus = SecItemUpdate(
            primaryAttributes as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return true
        }

        guard updateStatus == errSecItemNotFound else {
            batteryDiagnosticLog("[OnlineSettings] Keychain update failed with status (updateStatus)", type: .error)
            return false
        }

        var addAttributes = primaryAttributes
        addAttributes[kSecValueData as String] = data
        addAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addAttributes as CFDictionary, nil)
        if addStatus != errSecSuccess {
            batteryDiagnosticLog("[OnlineSettings] Keychain save failed with status (addStatus)", type: .error)
        }
        return addStatus == errSecSuccess
    }

    @discardableResult
    public func deleteAPIKey() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            batteryDiagnosticLog("[OnlineSettings] Keychain delete failed with status (status)", type: .error)
        }
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
