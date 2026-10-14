import Foundation

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

/// Parses raw OCR text lines and validates MCQ structure
public final class QuestionParser {
    public static let shared = QuestionParser()

    // Regex patterns for option prefixes:
    // Matches: A), A., (A), [A], A:, 1), 1., (1), [1], etc.
    private let optionRegex: NSRegularExpression

    public init() {
        let pattern = #"^\s*(?:\(?([A-Ea-e1-9])[\.\)\:\-\]]|\[([A-Ea-e1-9])\])\s*(.*)$"#
        self.optionRegex = try! NSRegularExpression(pattern: pattern, options: [])
    }

    /// Evaluates raw text and returns a validated MCQ or nil if not an MCQ
    public func parse(lines: [String]) -> ParsedMCQ? {
        let cleanedLines = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard cleanedLines.count >= 3 else {
            return nil
        }

        var detectedOptions: [MCQOption] = []
        var questionLines: [String] = []
        var hasStartedOptions = false

        for line in cleanedLines {
            let range = NSRange(location: 0, length: line.utf16.count)
            if let match = optionRegex.firstMatch(in: line, options: [], range: range) {
                // Extract label
                var label = ""
                if let r1 = Range(match.range(at: 1), in: line) {
                    label = String(line[r1])
                } else if let r2 = Range(match.range(at: 2), in: line) {
                    label = String(line[r2])
                }

                // Extract text
                var optText = ""
                if let r3 = Range(match.range(at: 3), in: line) {
                    optText = String(line[r3])
                }

                if !label.isEmpty {
                    hasStartedOptions = true
                    detectedOptions.append(MCQOption(label: label, text: optText))
                    continue
                }
            }

            if hasStartedOptions {
                // If options already started and this line is not a new option prefix,
                // it is likely a continuation of the previous option's text
                if let last = detectedOptions.popLast() {
                    let updatedText = last.text.isEmpty ? line : "\(last.text) \(line)"
                    detectedOptions.append(MCQOption(label: last.label, text: updatedText))
                }
            } else {
                // Pre-option lines are part of question statement
                questionLines.append(line)
            }
        }

        // Validate extracted MCQ
        guard validate(questionLines: questionLines, options: detectedOptions) else {
            return nil
        }

        let fullQuestion = questionLines.joined(separator: " ")
        let rawText = cleanedLines.joined(separator: "\n")
        return ParsedMCQ(question: fullQuestion, options: detectedOptions, rawText: rawText)
    }

    public func parse(rawText: String) -> ParsedMCQ? {
        let lines = rawText.components(separatedBy: .newlines)
        return parse(lines: lines)
    }

    private func validate(questionLines: [String], options: [MCQOption]) -> Bool {
        // Must have at least 2 options (standard MCQ has 3 to 5 options)
        guard options.count >= 2 && options.count <= 10 else {
            return false
        }

        // Question body must have sufficient content (at least 8 chars)
        let questionText = questionLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard questionText.count >= 8 else {
            return false
        }

        // Ensure option labels are reasonably unique
        let labels = options.map { $0.label }
        let uniqueLabels = Set(labels)
        guard uniqueLabels.count == labels.count else {
            return false
        }

        // Ensure each option has some non-empty text
        for opt in options {
            if opt.text.trimmingCharacters(in: .whitespaces).isEmpty {
                return false
            }
        }

        // Check if labels follow an expected progression:
        // Either letters (A, B, C...) or numbers (1, 2, 3...)
        let firstLabel = labels.first!
        if firstLabel == "A" {
            let expected = ["A", "B", "C", "D", "E", "F"]
            let prefix = Array(expected.prefix(labels.count))
            if labels != prefix {
                // Allow minor deviations if at least A and B are present
                guard labels.contains("A") && labels.contains("B") else { return false }
            }
        } else if firstLabel == "1" {
            let expected = ["1", "2", "3", "4", "5", "6"]
            let prefix = Array(expected.prefix(labels.count))
            if labels != prefix {
                guard labels.contains("1") && labels.contains("2") else { return false }
            }
        }

        return true
    }
}
