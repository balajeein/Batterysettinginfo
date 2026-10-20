import Foundation

/// Specific reasons why a screen text segment was rejected as an MCQ
public enum ParserRejectionReason: String, Error, CustomStringConvertible {
    case insufficientLines = "Fewer than 3 non-empty text lines recognized on screen"
    case noOptionClusterFound = "No coherent option sequence (e.g. A-D or 1-4) found among recognized text"
    case questionTextTooShort = "Question text immediately before options is too short or empty (< 6 characters)"
    case emptyOptionText = "One or more detected options has empty text"
    case duplicateOptionLabels = "Option labels are not unique"
    case insufficientOptions = "Fewer than 3 options found (expected 3-5 options for standard MCQ)"
    case ambiguousOptionExtraction = "Option text contains another option marker or review-page feedback"

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

    /// Generates a standardized prompt for the local LLM.
    public var promptForLLM: String {
        let labels = options.map { $0.label }.joined(separator: ", ")
        var optsText = ""
        for opt in options {
            optsText += "\(opt.label)) \(opt.text)\n"
        }
        let domainGuidance = technicalGuidanceForLLM

        return """
<|im_start|>system
You are an expert examination assistant. Solve the multiple-choice question from the exact question and options. Reason through the meaning of the question and compare every option against the full wording before deciding; do not choose an option merely because one phrase sounds related. For technical questions, identify the relevant mechanism or definition and check the direction, inputs, outputs, and constraints described. Respond with ONLY the single correct option letter (\(labels)). Do not write explanations.<|im_end|>
<|im_start|>user
Question:
\(question)

Options:
\(optsText)
\(domainGuidance)<|im_end|>
<|im_start|>assistant
Answer:
"""
    }

    /// Adds narrowly scoped factual checks for code questions whose meaning is
    /// easy to confuse with a nearby output string.
    public var technicalGuidanceForLLM: String {
        let lower = "\(question)\n\(options.map(\.text).joined(separator: "\n"))".lowercased()
        if lower.contains("process.stdin") ||
            lower.contains("escape sequence") ||
            lower.contains("ansi") ||
            lower.contains("key[2]") ||
            lower.contains("key [2]") {
            return """

Technical check for terminal key sequences: decode the numeric bytes in the condition, not the word printed by console.log. ESC is 27, '[' is 91, and the final byte 65 ('A') is Up Arrow; 66 ('B') is Down Arrow, 67 ('C') is Right Arrow, and 68 ('D') is Left Arrow.
"""
        }
        return ""
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
    // Regex matching a duplicated/embedded option marker at the start of text
    private let leadingOptionRegex: NSRegularExpression
    // Regex used to reject unlabeled fallback text that still contains labels
    private let anyOptionMarkerRegex: NSRegularExpression
    // Regex matching UI noise above the question (browser tabs, headers, timers)
    private let uiNoiseRegex: NSRegularExpression
    // Regex matching UI buttons and footer text below options
    private let footerNoiseRegex: NSRegularExpression
    // Regex matching score/point noise lines
    private let questionNoiseRegex: NSRegularExpression
    // Regex matching an interrogative/question stem even when OCR loses "?"
    private let questionLeadRegex: NSRegularExpression
    // Regex matching code/example lines that belong to the question, not an answer card
    private let codeLikeRegex: NSRegularExpression

    public init() {
        self.singleLabelRegex = try! NSRegularExpression(
            pattern: #"^(?:○|●|•|\*|\[\s*\]|\(\s*\))?\s*(?:\(?([A-Ea-e1-6])[\.\)\:\-\]]|\[([A-Ea-e1-6])\]|^([A-Ea-e1-6]))\s*$"#
        )
        self.optionLineRegex = try! NSRegularExpression(
            pattern: #"^(?:○|●|•|\*|\[\s*\]|\(\s*\))?\s*(?:\(?([A-Ea-e1-6])[\.\)\:\-\]]|\[([A-Ea-e1-6])\])\s*(.*)$"#
        )
        self.leadingOptionRegex = try! NSRegularExpression(
            pattern: #"^\s*(?:\(?([A-Ea-e1-6])[\.\)\:\-\]]|\[([A-Ea-e1-6])\])\s+"#
        )
        self.anyOptionMarkerRegex = try! NSRegularExpression(
            pattern: #"(?i)(?:^|\s)(?:[A-E]|[1-6])[\.\)\:\-\]]\s+"#
        )
        self.uiNoiseRegex = try! NSRegularExpression(
            pattern: #"(?i)^(?:file|edit|view|history|bookmarks|profiles|tab\b|window|help|https?://|chrome|time\s+remaining|score|points|question\s+\d+\s*(?:of|/)\s*\d+|question\s+id|newton\s+school\b|.*\bask\s+gemini\b|.*\bmy\.newtonschool\.|.*\bapplication\s+development\s+\d+)"#
        )
        self.footerNoiseRegex = try! NSRegularExpression(
            pattern: #"(?i)^(?:\<|\>|\[|\()?\s*(?:previous|next|submit|flag|review|clear|save|back|finish|page\s+\d+|copyright|all\s+rights|score|show\s+original|attempt|note:\s*this\s+revision|revision:|incorrect\s+answer|correct\s+answer|explanation|answer\s+key|your\s+answer|selected\s+answer)\b"#
        )
        self.questionNoiseRegex = try! NSRegularExpression(
            pattern: #"^(?:[•\*\s]*\d+\s*/\s*\d+|[•\*\s]*\d+\s+points?|score:?\s*\d+)\s*$"#
        )
        self.questionLeadRegex = try! NSRegularExpression(
            pattern: #"(?i)^\s*(?:which|what|why|how|when|where|who|select|choose|identify|consider|in\s+which|according\s+to)\b"#
        )
        self.codeLikeRegex = try! NSRegularExpression(
            pattern: #"(?i)(?:\b(?:process|console|stdout|stderr)\s*\.\s*(?:stdout|stderr|write|log|print)|\\x[0-9a-f]{2}|^\s*(?:func|function|import|class|return|const|let|var)\b|[{};])"#
        )
    }

    private func matches(_ regex: NSRegularExpression, in text: String) -> Bool {
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    private func isLikelyQuestionLine(_ line: String) -> Bool {
        if line.contains("?") || matches(questionLeadRegex, in: line) {
            return true
        }

        let words = line.split(whereSeparator: { $0.isWhitespace })
        return words.count >= 4 && line.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(":")
    }

    private func isCodeLikeLine(_ line: String) -> Bool {
        matches(codeLikeRegex, in: line)
    }

    private func isUIOnlyOptionText(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = normalized.lowercased()
        if matches(uiNoiseRegex, in: normalized) || matches(questionNoiseRegex, in: normalized) {
            return true
        }
        if lower == "school" || lower == "question" || lower.hasPrefix("question ") {
            return true
        }
        return isLikelyQuestionLine(normalized)
    }

    private func leadingOptionMarker(in text: String) -> (label: String, remainder: String)? {
        let range = NSRange(location: 0, length: text.utf16.count)
        guard let match = leadingOptionRegex.firstMatch(in: text, options: [], range: range) else {
            return nil
        }

        var label = ""
        for group in 1...2 {
            let groupRange = match.range(at: group)
            if groupRange.location != NSNotFound, let swiftRange = Range(groupRange, in: text) {
                label = String(text[swiftRange]).uppercased()
                break
            }
        }

        guard let markerRange = Range(match.range, in: text), !label.isEmpty else { return nil }
        return (
            label: label,
            remainder: String(text[markerRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Evaluates raw text lines and returns a detailed Result with the ParsedMCQ or the exact rejection reason
    public func parseWithDiagnostics(lines: [String]) -> Result<ParsedMCQ, ParserRejectionReason> {
        let rawLines = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        batteryDiagnosticLog("[Diagnostic 6] Supplied lines to parser: count=\(rawLines.count)")
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

        // A two-label sequence is too easy to obtain from ordinary UI text or
        // prose. Require at least three options before treating it as an MCQ.
        if bestCluster.count >= 3 {
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
            // Browser chrome can expose an unrelated A-B-C-D sequence before
            // the real answer cards. An explicit cluster is usable only when
            // the preceding text contains a recognizable question stem.
            if question.count >= 6 && questionLines.contains(where: { self.isLikelyQuestionLine($0) }) {
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

                // OCR can duplicate a badge marker inside the option text or
                // merge the next card into the current card. Strip only a
                // duplicated marker for the same option; reject any other
                // marker so the pipeline retries OCR instead of answering
                // from shifted choices.
                    var normalizedOptionText = cleanedText
                    if let marker = leadingOptionMarker(in: cleanedText) {
                        guard marker.label == opt.label else {
                            return .failure(.ambiguousOptionExtraction)
                        }
                        normalizedOptionText = marker.remainder
                    }

                    let normalizedRange = NSRange(location: 0, length: normalizedOptionText.utf16.count)
                    if footerNoiseRegex.firstMatch(in: normalizedOptionText, options: [], range: normalizedRange) != nil ||
                       normalizedOptionText.range(of: #"(?i)\b(?:incorrect|correct)\s+answer\b"#, options: .regularExpression) != nil {
                        return .failure(.ambiguousOptionExtraction)
                    }
                    if isUIOnlyOptionText(normalizedOptionText) {
                        bestCluster.removeAll()
                        break
                    }

                    finalOptions.append(MCQOption(label: opt.label, text: normalizedOptionText))
                }

                if !bestCluster.isEmpty {
                    let parsed = ParsedMCQ(
                        question: question,
                        options: finalOptions,
                        rawText: normalizedLines.joined(separator: "\n")
                    )
                    return .success(parsed)
                }
            }
        }

        // Pass 3b: Fallback for web assessment platforms with unlabeled option cards
        let urlNoiseRegex = try! NSRegularExpression(
            pattern: #"(?i)(?:https?://|www\.|\.com/|\.co/|\.org/|\.net/|\?tab=|\?show=|\?id=|\&[a-z]+=|\bindex\.html\b)"#
        )
        let isUrlLine = { (line: String) -> Bool in
            let r = NSRange(location: 0, length: line.utf16.count)
            return urlNoiseRegex.firstMatch(in: line, options: [], range: r) != nil
        }

        var questionEndIdx: Int? = nil
        for (idx, line) in normalizedLines.enumerated().reversed() {
            if isLikelyQuestionLine(line) && !isUrlLine(line) {
                // OCR may put the final few words of a wrapped question on a
                // short line (for example, just "step?"). Validate the
                // complete nearby question block instead of the last line.
                let start = max(0, idx - 5)
                let questionCandidate = normalizedLines[start...idx]
                    .filter { line in
                        let r = NSRange(location: 0, length: line.utf16.count)
                        return uiNoiseRegex.firstMatch(in: line, options: [], range: r) == nil &&
                            footerNoiseRegex.firstMatch(in: line, options: [], range: r) == nil
                    }
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                let words = questionCandidate.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if words.count >= 3 && questionCandidate.count >= 15 {
                    questionEndIdx = idx
                    break
                }
            }
        }

        if let qEnd = questionEndIdx {
            var qLines = [normalizedLines[qEnd]]
            var back = qEnd - 1
            while back >= 0 && qLines.count < 6 {
                let prev = normalizedLines[back]
                if isUrlLine(prev) { break }
                let r = NSRange(location: 0, length: prev.utf16.count)
                if uiNoiseRegex.firstMatch(in: prev, options: [], range: r) != nil ||
                   footerNoiseRegex.firstMatch(in: prev, options: [], range: r) != nil {
                    break
                }
                if prev.range(of: #"(?i)^question\b"#, options: .regularExpression) != nil {
                    qLines.insert(prev, at: 0)
                    break
                }
                qLines.insert(prev, at: 0)
                back -= 1
            }

            let question = qLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if question.count >= 15 {
                // A question may introduce a code sample with a colon and
                // OCR may omit the option badges. Keep that code sample in
                // the prompt, but never treat it as an answer choice.
                var questionWithContinuation = qLines
                var continuationIndex = qEnd + 1
                while continuationIndex < normalizedLines.count && questionWithContinuation.count < 8 {
                    let continuation = normalizedLines[continuationIndex].trimmingCharacters(in: .whitespaces)
                    if isCodeLikeLine(continuation) {
                        questionWithContinuation.append(continuation)
                        continuationIndex += 1
                    } else {
                        break
                    }
                }
                let completeQuestion = questionWithContinuation.joined(separator: " ").trimmingCharacters(in: .whitespaces)

                var rawCandidates: [String] = []
                let defaultLabels = ["A", "B", "C", "D", "E"]

                for f in (qEnd + 1)..<normalizedLines.count {
                    let line = normalizedLines[f].trimmingCharacters(in: .whitespaces)
                    if line.isEmpty { continue }

                    if isUrlLine(line) { break }

                    let r = NSRange(location: 0, length: line.utf16.count)
                    // Skip score/points noise
                    if questionNoiseRegex.firstMatch(in: line, options: [], range: r) != nil {
                        continue
                    }
                    // Stop on footer or UI noise
                    if footerNoiseRegex.firstMatch(in: line, options: [], range: r) != nil ||
                       uiNoiseRegex.firstMatch(in: line, options: [], range: r) != nil {
                        break
                    }
                    // Code/example lines belong to the question stem. They
                    // must not consume one of the positional answer slots.
                    if isCodeLikeLine(line) {
                        continue
                    }
                    // Reject navigation lines (dashboard, menu, course lists)
                    if line.range(of: #"(?i)^(?:dashboard|announcements|overview|assessments|modules|grades|people|settings|logout|sign\s*out|sign\s*in|login|course\s+material)\b"#, options: .regularExpression) != nil {
                        break
                    }

                    rawCandidates.append(line)
                    if rawCandidates.count == 8 { break }
                }

                // This fallback assigns A/B/C/D by position. If OCR still
                // sees any explicit labels, positional assignment could shift
                // choices (for example B's text receiving C's answer). Reject
                // it and let the caller retry with another OCR pass instead.
                let hasExplicitMarker = rawCandidates.contains { line in
                    let range = NSRange(location: 0, length: line.utf16.count)
                    return anyOptionMarkerRegex.firstMatch(in: line, options: [], range: range) != nil
                }
                if hasExplicitMarker {
                    return .failure(.ambiguousOptionExtraction)
                }

                // Merge multiline wrapped options (e.g. continuation lines starting with lowercase or after conjunctions)
                var candidateLines: [String] = []
                for line in rawCandidates {
                    if let last = candidateLines.last {
                        let startsWithLower = line.first?.isLowercase == true
                        let startsWithPunctuation = line.first == "," || line.first == ";" || line.first == ")" || line.first == "]" || line.first == "-"
                        let lastEndsWithContinuation = last.hasSuffix(",") || last.hasSuffix("-") ||
                            last.range(of: #"(?i)\b(?:the|and|or|that|of|in|to|with|for|a|an|is|are|which|from|by|as)$"#, options: .regularExpression) != nil

                        if startsWithLower || startsWithPunctuation || lastEndsWithContinuation {
                            candidateLines[candidateLines.count - 1] = "\(last) \(line)"
                            continue
                        }
                    }
                    candidateLines.append(line)
                    if candidateLines.count == 4 { break } // Standard MCQ has 4 options A-D; do not invent Option E
                }

                if candidateLines.count >= 3 && candidateLines.count <= 4 {
                    var finalOptions: [MCQOption] = []
                    for (cIdx, cLine) in candidateLines.enumerated() {
                        let expectedLabel = defaultLabels[cIdx]
                        var optionText = cLine

                        // Some badge layouts are OCR'd as "C Only ..." or
                        // "D A ..." while the first badges are omitted. Do
                        // not strip "A single ..."-style option text; only
                        // treat the prefix as a badge when the remainder
                        // starts with an uppercase word.
                        let prefix = "\(expectedLabel) "
                        if optionText.hasPrefix(prefix) {
                            let remainder = String(optionText.dropFirst(prefix.count))
                            if remainder.first?.isUppercase == true {
                                optionText = remainder
                            }
                        }

                        finalOptions.append(MCQOption(label: expectedLabel, text: optionText))
                    }
                    let parsed = ParsedMCQ(
                        question: completeQuestion,
                        options: finalOptions,
                        rawText: normalizedLines.joined(separator: "\n")
                    )
                    return .success(parsed)
                }
            }
        }

        return .failure(.noOptionClusterFound)
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
