import Foundation
import CoreGraphics
import CoreText
import Vision

@main
struct TestOCRMain {
    static func createSyntheticMCQImage() -> CGImage? {
        let width = 800
        let height = 400
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        // Fill background white
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Text lines to draw
        let lines = [
            "Which layer of the OSI model handles end-to-end communication?",
            "A) Physical",
            "B) Data Link",
            "C) Transport",
            "D) Network"
        ]

        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        let textColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

        // Draw lines from top to bottom
        var yPosition: CGFloat = CGFloat(height) - 70.0
        for line in lines {
            let attrs: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: textColor
            ]
            let attrString = CFAttributedStringCreate(nil, line as CFString, attrs as CFDictionary)!
            let lineRef = CTLineCreateWithAttributedString(attrString)

            ctx.textPosition = CGPoint(x: 50, y: yPosition)
            CTLineDraw(lineRef, ctx)
            yPosition -= 50.0
        }

        return ctx.makeImage()
    }

    static func main() async {
        print("=== Running Vision OCR & Pipeline Test ===")

        guard let cgImage = createSyntheticMCQImage() else {
            print("❌ FAILED: Failed to create synthetic image in memory")
            exit(1)
        }
        print("✓ Created synthetic in-memory test image (\(cgImage.width)x\(cgImage.height))")

        do {
            let lines = try await OCRService.shared.recognizeText(from: cgImage)
            print("✓ Vision recognized \(lines.count) lines from synthetic image:")
            for l in lines {
                print("   - \(l)")
            }

            guard let parsed = QuestionParser.shared.parse(lines: lines) else {
                print("❌ FAILED: QuestionParser failed to validate OCR result")
                exit(1)
            }

            print("✓ Successfully parsed MCQ from OCR:")
            print("   Question: \(parsed.question)")
            print("   Options count: \(parsed.options.count)")
            for opt in parsed.options {
                print("     \(opt.label): \(opt.text)")
            }

            guard parsed.options.count == 4 else {
                print("❌ FAILED: Expected 4 options, got \(parsed.options.count)")
                exit(1)
            }

            guard parsed.options[2].label == "C" && parsed.options[2].text.lowercased().contains("transport") else {
                print("❌ FAILED: Option C Transport did not match accurately")
                exit(1)
            }

            print("=== OCR & Pipeline Test PASSED Successfully ===")
        } catch {
            print("❌ FAILED with error: \(error)")
            exit(1)
        }
    }
}
