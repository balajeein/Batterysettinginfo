import Foundation
import CoreGraphics
import ImageIO

public enum OnlineInferenceError: LocalizedError {
    case apiKeyMissing
    case imageEncodingFailed
    case requestFailed(String)
    case invalidResponse(String)
    case unparseableAnswer(String)

    public var errorDescription: String? {
        switch self {
        case .apiKeyMissing:
            return "NVIDIA API key is not configured. Choose Set NVIDIA API Key from the menu bar."
        case .imageEncodingFailed:
            return "Could not encode the captured screenshot for NVIDIA vision analysis."
        case .requestFailed(let message):
            return "NVIDIA online request failed: \(message)"
        case .invalidResponse(let message):
            return "NVIDIA returned an invalid response: \(message)"
        case .unparseableAnswer(let raw):
            return "NVIDIA response did not contain a clear A/B/C/D answer: \(raw.prefix(180))"
        }
    }
}

/// Direct screenshot-to-vision inference through NVIDIA's OpenAI-compatible API.
/// This path is opt-in; the normal Offline mode never creates a network request.
public final class OnlineInferenceEngine: @unchecked Sendable {
    public static let shared = OnlineInferenceEngine()

    // NVIDIA retired the previous Gemma endpoint. Muse Glimmer is a current
    // free multimodal endpoint and accepts the same image_url chat format.
    public static let modelName = "meta/muse-glimmer-30b"
    private let endpoint = URL(string: "https://integrate.api.nvidia.com/v1/chat/completions")!
    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    public var statusDescription: String {
        OnlineSettings.shared.apiKey == nil ? "Not configured" : "API key configured"
    }

    public func solve(cgImage: CGImage) async throws -> InferenceResult {
        guard let apiKey = OnlineSettings.shared.apiKey else {
            throw OnlineInferenceError.apiKeyMissing
        }

        guard let imageData = jpegData(from: cgImage) else {
            throw OnlineInferenceError.imageEncodingFailed
        }

        let base64Image = imageData.base64EncodedString()
        let prompt = """
        Analyze this screenshot as an examination expert. Find the currently visible multiple-choice question and all of its answer choices. Ignore browser tabs, menus, timers, scores, previous-answer panels, and unrelated page text. Solve the question from the screenshot itself.

        Return exactly this format and nothing else before it:
        ANSWER: <one letter A, B, C, or D>
        EXPLANATION: <one concise sentence explaining why>

        Never choose an answer merely because a word appears in the question or code output. For code questions, trace the actual condition and values. If the page is not an MCQ, return ANSWER: NONE and explain why.
        """

        let body: [String: Any] = [
            "model": Self.modelName,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": prompt],
                    [
                        "type": "image_url",
                        "image_url": ["url": "data:image/jpeg;base64,\(base64Image)"]
                    ]
                ]
            ]],
            "temperature": 0.0,
            "top_p": 1.0,
            "max_tokens": 256,
            "stream": false
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let startTime = DispatchTime.now()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OnlineInferenceError.requestFailed(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OnlineInferenceError.invalidResponse("No HTTP response received")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let serverMessage = String(data: data, encoding: .utf8) ?? "No response body"
            throw OnlineInferenceError.requestFailed("HTTP \(httpResponse.statusCode): \(serverMessage.prefix(400))")
        }

        let raw = try extractMessageText(from: data)
        let parsed = try parseAnswer(from: raw)
        let elapsed = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds

        batteryDiagnosticLog("[OnlineInferenceEngine] NVIDIA vision answer: Option \(parsed.label)")

        return InferenceResult(
            optionLabel: parsed.label,
            formattedAnswer: "\(parsed.label) — \(parsed.explanation)",
            explanation: parsed.explanation,
            rawOutput: raw,
            durationMs: Int(elapsed / 1_000_000),
            validationResult: "Parsed direct screenshot response from NVIDIA \(Self.modelName)",
            retryAttempted: false
        )
    }

    private func jpegData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.82
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func extractMessageText(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OnlineInferenceError.invalidResponse("Response was not a JSON object")
        }

        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw OnlineInferenceError.requestFailed(message)
        }

        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            throw OnlineInferenceError.invalidResponse("Missing choices[0].message")
        }

        if let content = message["content"] as? String {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let contentParts = message["content"] as? [[String: Any]] {
            let text = contentParts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            if !text.isEmpty {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        throw OnlineInferenceError.invalidResponse("Missing textual message content")
    }

    private func parseAnswer(from raw: String) throws -> (label: String, explanation: String) {
        guard !raw.isEmpty else {
            throw OnlineInferenceError.unparseableAnswer(raw)
        }

        let patterns = [
            #"(?im)^\s*(?:ANSWER|FINAL\s+ANSWER|OPTION|CHOICE)\s*:?\s*[\(\[]?([A-D])[\)\]]?\b"#,
            #"(?i)\b(?:the\s+)?(?:correct\s+)?(?:answer|option|choice)\s*(?:is|:)\s*[\(\[]?([A-D])[\)\]]?\b"#
        ]

        var answerLabel: String?
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
            if let match = regex.firstMatch(in: raw, options: [], range: range),
               let answerRange = Range(match.range(at: 1), in: raw) {
                answerLabel = String(raw[answerRange]).uppercased()
                break
            }
        }

        guard let label = answerLabel, ["A", "B", "C", "D"].contains(label) else {
            throw OnlineInferenceError.unparseableAnswer(raw)
        }

        let explanation: String
        if let regex = try? NSRegularExpression(pattern: #"(?is)EXPLANATION\s*:\s*(.+)$"#),
           let match = regex.firstMatch(in: raw, options: [], range: NSRange(raw.startIndex..<raw.endIndex, in: raw)),
           let range = Range(match.range(at: 1), in: raw) {
            explanation = String(raw[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            explanation = raw
                .replacingOccurrences(of: #"(?im)^\s*(?:ANSWER|FINAL\s+ANSWER)\s*:?.*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return (label, explanation.isEmpty ? "Direct screenshot analysis selected this option." : explanation)
    }
}
