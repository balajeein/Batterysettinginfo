import Foundation

/// Specific reasons why a screen text segment was rejected as an MCQ
public enum ParserRejectionReason: String, Error, CustomStringConvertible {
    case insufficientLines = "Fewer than 3 non-empty text lines recognized on screen"
    case noOptionClusterFound = "No coherent option sequence (e.g. A-D or 1-4) found among recognized text"
    case questionTextTooShort = "Question text immediately before options is too short or empty (< 6 characters)"
    case emptyOptionText = "One or more detected options has empty text"
    case duplicateOptionLabels = "Option labels are not unique"
    case insufficientOptions = "Fewer than 2 options found (expected 3-5 options for standard MCQ)"

    public var description: String { rawValue }
}

/// Represents a single multiple-choice option
public struct MCQOption: Equatable, Sendable {
    public let label: String
    public let text: String

    public init(label: String, text: String) {
        self.label = label.uppercased()
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Represents a validated multiple-choice question extracted from OCR
public struct ParsedMCQ: Equatable, Sendable {
    public let question: String
    public let options: [MCQOption]
    public let rawText: String

    public init(question: String, options: [MCQOption], rawText: String) {
        self.question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        self.options = options
        self.rawText = rawText
    }

    /// Generates a standardized prompt for the local LLM
    public var promptForLLM: String {
        var p = """
You are an expert exam solver. Below is a multiple-choice question with candidate options.
Determine the single correct option label.
Respond with ONLY the exact option letter or number corresponding to the correct answer.

Question:
\(question)

Options:

"""
        for opt in options {
            p += "\(opt.label)) \(opt.text)\n"
        }
        let labels = options.map { $0.label }.joined(separator: ", ")
        p += "\nRespond with only one label (\(labels)).\nAnswer: "
        return p
    }
}

private struct RawOptionMatch {
    let lineIndex: Int
    let label: String
    let text: String
}

/// Parses raw OCR text lines and validates MCQ structure
public final class QuestionParser {
    public static let shared = QuestionParser()

    // Regex matching single option labels on their own line (Badge UI in web forms)
    private let singleLabelRegex: NSRegularExpression
    // Regex matching lines with option markers
    private let optionLineRegex: NSRegularExpression
    // Regex matching UI noise above the question (browser tabs, headers, timers)
    private let uiNoiseRegex: NSRegularExpression
    // Regex matching UI buttons and footer text below options
    private let footerNoiseRegex: NSRegularExpression

    public init() {
        self.singleLabelRegex = try! NSRegularExpression(
            pattern: #"^(?:○|●|•|\*|\[\s*\]|\(\s*\))?\s*(?:\(?([A-Ea-e1-6])[\.\)\:\-\]]|\[([A-Ea-e1-6])\]|^([A-Ea-e1-6]))\s*$"#
        )
        self.optionLineRegex = try! NSRegularExpression(
            pattern: #"^(?:○|●|•|\*|\[\s*\]|\(\s*\))?\s*(?:\(?([A-Ea-e1-6])[\.\)\:\-\]]|\[([A-Ea-e1-6])\])\s*(.*)$"#
        )
        self.uiNoiseRegex = try! NSRegularExpression(
            pattern: #"(?i)^(?:file|edit|view|history|bookmarks|profiles|tab\b|window|help|https?://|chrome|time\s+remaining|score|points|question\s+\d+\s+of\s+\d+|question\s+id)\b"#
        )
        self.footerNoiseRegex = try! NSRegularExpression(
            pattern: #"(?i)^(?:\<|\>|\[|\()?\s*(?:previous|next|submit|flag|review|clear|save|back|finish|page\s+\d+|copyright|all\s+rights|score)\b"#
        )
    }

    /// Evaluates raw text lines and returns a detailed Result with the ParsedMCQ or the exact rejection reason
    public func parseWithDiagnostics(lines: [String]) -> Result<ParsedMCQ, ParserRejectionReason> {
        let rawLines = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if AppConfiguration.shared.isDiagnosticModeEnabled {
            fputs("[Diagnostic 6] Supplied lines to parser: count=\(rawLines.count)\n", stderr)
        }

        guard rawLines.count >= 3 else {
            return .failure(.insufficientLines)
        }

        // Pass 1: Merge separated labels where badge "A" is on one line and option text is on the next line
        var normalizedLines: [String] = []
        var i = 0
        while i < rawLines.count {
            let current = rawLines[i]
            let range = NSRange(location: 0, length: current.utf16.count)

            if let match = singleLabelRegex.firstMatch(in: current, options: [], range: range), i + 1 < rawLines.count {
                var label = ""
                for g in 1...3 {
                    let r = match.range(at: g)
                    if r.location != NSNotFound, let swiftRange = Range(r, in: current) {
                        label = String(current[swiftRange]).uppercased()
                        break
                    }
                }
                let nextLine = rawLines[i + 1]
                let nextRange = NSRange(location: 0, length: nextLine.utf16.count)
                // If next line is not another single label, merge them
                if singleLabelRegex.firstMatch(in: nextLine, options: [], range: nextRange) == nil {
                    normalizedLines.append("\(label)) \(nextLine)")
                    i += 2
                    continue
                }
            }
            normalizedLines.append(current)
            i += 1
        }

        // Pass 2: Detect lines starting with option prefixes
        var matches: [RawOptionMatch] = []
        for (idx, line) in normalizedLines.enumerated() {
            let range = NSRange(location: 0, length: line.utf16.count)
            if let m = optionLineRegex.firstMatch(in: line, options: [], range: range) {
                var label = ""
                if let r1 = Range(m.range(at: 1), in: line) {
                    label = String(line[r1]).uppercased()
                } else if let r2 = Range(m.range(at: 2), in: line) {
                    label = String(line[r2]).uppercased()
                }
                var text = ""
                if let r3 = Range(m.range(at: 3), in: line) {
                    text = String(line[r3]).trimmingCharacters(in: .whitespaces)
                }
                if !label.isEmpty {
                    matches.append(RawOptionMatch(lineIndex: idx, label: label, text: text))
                }
            }
        }

        // Pass 3: Locate the best coherent option cluster
        let targetSequences = [
            ["A", "B", "C", "D", "E"],
            ["A", "B", "C", "D"],
            ["A", "B", "C"],
            ["1", "2", "3", "4", "5"],
            ["1", "2", "3", "4"],
            ["1", "2", "3"]
        ]

        var bestCluster: [RawOptionMatch] = []
        for target in targetSequences {
            var matchPointer = 0
            var currentCluster: [RawOptionMatch] = []
            for expected in target {
                var found = false
                for mIdx in matchPointer..<matches.count {
                    let m = matches[mIdx]
                    if m.label == expected {
                        if let last = currentCluster.last {
                            // Consecutive options should not be separated by excessive lines
                            if (m.lineIndex - last.lineIndex) > 8 { break }
                        }
                        currentCluster.append(m)
                        matchPointer = mIdx + 1
                        found = true
                        break
                    }
                }
                if !found {
                    currentCluster.removeAll()
                    break
                }
            }
            if currentCluster.count >= 3 {
                bestCluster = currentCluster
                break
            }
        }

        guard bestCluster.count >= 2 else {
            return .failure(.noOptionClusterFound)
        }

        // Pass 4: Extract question text by walking backwards from the first option
        let firstOptionLineIdx = bestCluster[0].lineIndex
        var questionLines: [String] = []

        var backIdx = firstOptionLineIdx - 1
        while backIdx >= 0 && questionLines.count < 6 {
            let line = normalizedLines[backIdx]
            let range = NSRange(location: 0, length: line.utf16.count)
            if uiNoiseRegex.firstMatch(in: line, options: [], range: range) != nil {
                break
            }
            questionLines.insert(line, at: 0)
            if line.contains("?") && questionLines.count >= 1 {
                // If previous line is question number (e.g. "Question 4:"), include it
                if backIdx - 1 >= 0 {
                    let prev = normalizedLines[backIdx - 1]
                    if prev.range(of: #"(?i)^question\s+\d+"#, options: .regularExpression) != nil {
                        questionLines.insert(prev, at: 0)
                    }
                }
                break
            }
            backIdx -= 1
        }

        let question = questionLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard question.count >= 6 else {
            return .failure(.questionTextTooShort)
        }

        // Pass 5: Extract option texts with continuation lines, terminating before footer noise
        var finalOptions: [MCQOption] = []
        for (cIdx, opt) in bestCluster.enumerated() {
            var optText = opt.text
            let startLine = opt.lineIndex + 1
            let endLine = (cIdx + 1 < bestCluster.count) ? bestCluster[cIdx + 1].lineIndex : min(normalizedLines.count, opt.lineIndex + 6)

            for lIdx in startLine..<endLine {
                let line = normalizedLines[lIdx]
                let range = NSRange(location: 0, length: line.utf16.count)
                if footerNoiseRegex.firstMatch(in: line, options: [], range: range) != nil {
                    break
                }
                optText = optText.isEmpty ? line : "\(optText) \(line)"
            }

            let cleanedText = optText.trimmingCharacters(in: .whitespaces)
            guard !cleanedText.isEmpty else {
                return .failure(.emptyOptionText)
            }
            finalOptions.append(MCQOption(label: opt.label, text: cleanedText))
        }

        let parsed = ParsedMCQ(
            question: question,
            options: finalOptions,
            rawText: normalizedLines.joined(separator: "\n")
        )
        return .success(parsed)
    }

    /// Evaluates raw text and returns a validated MCQ or nil if not an MCQ
    public func parse(lines: [String]) -> ParsedMCQ? {
        switch parseWithDiagnostics(lines: lines) {
        case .success(let mcq):
            return mcq
        case .failure:
            return nil
        }
    }

    public func parse(rawText: String) -> ParsedMCQ? {
        let lines = rawText.components(separatedBy: .newlines)
        return parse(lines: lines)
    }
}
