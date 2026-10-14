import Foundation

typealias LlamaEngineHandle = OpaquePointer

@_silgen_name("llama_engine_create")
func c_llama_engine_create(_ modelPath: UnsafePointer<CChar>?, _ nCtx: Int32, _ nThreads: Int32, _ nGpuLayers: Int32) -> LlamaEngineHandle?

@_silgen_name("llama_engine_destroy")
func c_llama_engine_destroy(_ engine: LlamaEngineHandle?)

@_silgen_name("llama_engine_is_valid_gguf")
func c_llama_engine_is_valid_gguf(_ modelPath: UnsafePointer<CChar>?) -> Bool

@_silgen_name("llama_engine_get_backend_info")
func c_llama_engine_get_backend_info() -> UnsafePointer<CChar>?

@_silgen_name("llama_engine_infer")
func c_llama_engine_infer(
    _ engine: LlamaEngineHandle?,
    _ prompt: UnsafePointer<CChar>?,
    _ outputBuf: UnsafeMutablePointer<CChar>?,
    _ maxOutputLen: Int32,
    _ maxTokens: Int32,
    _ temperature: Float
) -> Int32

public enum InferenceError: LocalizedError {
    case modelNotFound(String)
    case invalidModelFormat(String)
    case engineInitializationFailed
    case inferenceFailed(Int32)
    case emptyOutput

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let path):
            return "No GGUF model found at: \(path). Please place a compatible GGUF model in ~/Library/Application Support/Batterysettinginfo/models/."
        case .invalidModelFormat(let path):
            return "File at \(path) is not a valid GGUF model file."
        case .engineInitializationFailed:
            return "Failed to initialize embedded llama.cpp engine with the selected model."
        case .inferenceFailed(let code):
            return "llama.cpp inference failed with error code \(code)."
        case .emptyOutput:
            return "Model returned empty output."
        }
    }
}

/// Native offline inference engine powered by embedded llama.cpp
public final class LocalInferenceEngine: @unchecked Sendable {
    public static let shared = LocalInferenceEngine()

    private var engineHandle: LlamaEngineHandle?
    private var loadedModelPath: String?
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.local.Batterysettinginfo.inference", qos: .userInitiated)

    private init() {}

    deinit {
        unloadModel()
    }

    /// Returns the active backend description
    public var backendInfo: String {
        if let info = c_llama_engine_get_backend_info() {
            return String(cString: info)
        }
        return "Unknown Backend"
    }

    /// Checks if a model is currently loaded
    public var isModelLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return engineHandle != nil
    }

    public var currentModelPath: String? {
        lock.lock()
        defer { lock.unlock() }
        return loadedModelPath
    }

    /// Checks if a valid GGUF model file is installed in the configured paths
    public func hasModelFileAvailable() -> Bool {
        return AppConfiguration.shared.resolveModelPath() != nil
    }

    /// Attempts to load the active model configured in AppConfiguration
    @discardableResult
    public func loadModelIfNeeded() -> Result<String, InferenceError> {
        lock.lock()
        defer { lock.unlock() }

        guard let path = AppConfiguration.shared.resolveModelPath() else {
            let expectedDir = AppConfiguration.shared.applicationSupportDirectory.path
            return .failure(.modelNotFound(expectedDir))
        }

        if engineHandle != nil && loadedModelPath == path {
            return .success(path)
        }

        // Unload previous if path changed
        if let current = engineHandle {
            c_llama_engine_destroy(current)
            engineHandle = nil
            loadedModelPath = nil
        }

        guard c_llama_engine_is_valid_gguf(path) else {
            return .failure(.invalidModelFormat(path))
        }

        let config = AppConfiguration.shared
        guard let handle = c_llama_engine_create(
            path,
            config.defaultContextSize,
            0, // auto threads
            config.defaultGpuLayers
        ) else {
            return .failure(.engineInitializationFailed)
        }

        self.engineHandle = handle
        self.loadedModelPath = path
        return .success(path)
    }

    public func unloadModel() {
        lock.lock()
        defer { lock.unlock() }
        if let handle = engineHandle {
            c_llama_engine_destroy(handle)
            engineHandle = nil
            loadedModelPath = nil
        }
    }

    /// Solves an MCQ using the local embedded model
    public func solve(mcq: ParsedMCQ) async throws -> (answer: String, rawOutput: String) {
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self = self else { return }

                let loadResult = self.loadModelIfNeeded()
                switch loadResult {
                case .failure(let err):
                    continuation.resume(throwing: err)
                    return
                case .success:
                    break
                }

                self.lock.lock()
                guard let handle = self.engineHandle else {
                    self.lock.unlock()
                    continuation.resume(throwing: InferenceError.engineInitializationFailed)
                    return
                }

                let prompt = mcq.promptForLLM
                let maxLen: Int32 = 256
                var buffer = [CChar](repeating: 0, count: Int(maxLen))

                let status = c_llama_engine_infer(
                    handle,
                    prompt,
                    &buffer,
                    maxLen,
                    AppConfiguration.shared.defaultMaxTokens,
                    AppConfiguration.shared.defaultTemperature
                )
                self.lock.unlock()

                guard status >= 0 else {
                    continuation.resume(throwing: InferenceError.inferenceFailed(status))
                    return
                }

                let raw = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else {
                    continuation.resume(throwing: InferenceError.emptyOutput)
                    return
                }

                // Extract predicted answer label
                let extracted = self.extractAnswerLabel(from: raw, availableOptions: mcq.options)
                continuation.resume(returning: (answer: extracted, rawOutput: raw))
            }
        }
    }

    private func extractAnswerLabel(from output: String, availableOptions: [MCQOption]) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if output starts directly with an option label (e.g. "B" or "B)" or "B.")
        for opt in availableOptions {
            if trimmed.hasPrefix(opt.label) {
                return opt.label
            }
        }

        // Search for patterns like "Answer: B" or "Option B"
        let upper = trimmed.uppercased()
        for opt in availableOptions {
            let patterns = ["ANSWER: \(opt.label)", "ANSWER IS \(opt.label)", "OPTION \(opt.label)", "(\(opt.label))", " \(opt.label) "]
            for p in patterns {
                if upper.contains(p) {
                    return opt.label
                }
            }
        }

        // Fallback: check if the first non-whitespace character matches an option label
        if let firstChar = trimmed.first {
            let charStr = String(firstChar).uppercased()
            if availableOptions.contains(where: { $0.label == charStr }) {
                return charStr
            }
        }

        // Return first option or truncated raw as fallback
        return availableOptions.first?.label ?? trimmed
    }
}
