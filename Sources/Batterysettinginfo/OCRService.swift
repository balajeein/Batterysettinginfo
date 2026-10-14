import Foundation
import CoreGraphics
import Vision

/// Handles on-device text recognition using Apple's native Vision framework
public final class OCRService {
    public static let shared = OCRService()

    private init() {}

    /// Performs optical character recognition on an in-memory CGImage.
    /// Returns extracted lines ordered naturally from top to bottom, left to right.
    public func recognizeText(from cgImage: CGImage) async throws -> [String] {
        return try await withCheckedThrowingContinuation { continuation in
            var textLines: [(y: CGFloat, x: CGFloat, text: String)] = []

            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: [])
                    return
                }

                for observation in observations {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    let box = observation.boundingBox
                    // Vision Y origin is at the bottom (0.0 to 1.0)
                    textLines.append((y: box.origin.y, x: box.origin.x, text: candidate.string))
                }

                // Sort lines top-to-bottom (descending Y) with a small threshold for same-line text (ascending X)
                let threshold: CGFloat = 0.018
                textLines.sort { a, b in
                    if abs(a.y - b.y) < threshold {
                        return a.x < b.x
                    }
                    return a.y > b.y
                }

                let result = textLines.map { $0.text }

                if AppConfiguration.shared.isDiagnosticModeEnabled {
                    fputs("[Diagnostic 4] Vision OCR observations: \(observations.count) text regions detected\n", stderr)
                    fputs("[Diagnostic 5] OCR lines recognized (top-to-bottom): \(result.count) lines\n", stderr)
                    for (idx, line) in result.prefix(15).enumerated() {
                        fputs("    [\(idx)] \(line)\n", stderr)
                    }
                    if result.count > 15 {
                        fputs("    ... and \(result.count - 15) more lines\n", stderr)
                    }
                }

                continuation.resume(returning: result)
            }

            request.recognitionLevel = .fast
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
