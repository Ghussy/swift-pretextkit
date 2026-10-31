import CoreText
import Foundation
import Testing
@testable import PretextKit

@Suite("Rich Text")
struct RichTextTests {
    private let regular = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
    private let largeBold = CTFontCreateWithName("Helvetica-Bold" as CFString, 24, nil)

    private var regularDescriptor: FontDescriptor { FontDescriptor(regular) }
    private var fontKey: NSAttributedString.Key {
        NSAttributedString.Key(rawValue: kCTFontAttributeName as String)
    }

    @Test("mixed fonts match CoreText line counts")
    func mixedFontAccuracy() {
        let text = NSMutableAttributedString(
            string: "Faith makes the impossible possible",
            attributes: [fontKey: regular]
        )
        text.addAttribute(
            fontKey,
            value: largeBold,
            range: (text.string as NSString).range(of: "impossible")
        )
        let prepared = prepareRichText(text, defaultFont: regularDescriptor)

        for width in stride(from: 90, through: 320, by: 10) {
            let measured = layout(
                prepared,
                maxWidth: CGFloat(width),
                lineHeight: 30
            ).lineCount
            #expect(measured == referenceLineCount(text, maxWidth: CGFloat(width)))
        }
    }

    @Test("link and color attributes survive line materialization")
    func attributesSurviveLayout() throws {
        let link = try #require(URL(string: "https://example.com/verse"))
        let colorKey = NSAttributedString.Key(
            rawValue: kCTForegroundColorAttributeName as String
        )
        let linkedColor = CGColor(
            red: 0.2,
            green: 0.6,
            blue: 1,
            alpha: 1
        )
        let text = NSMutableAttributedString(
            string: "Read Alma 7:10 in context",
            attributes: [fontKey: regular]
        )
        let linkedRange = (text.string as NSString).range(of: "Alma 7:10")
        text.addAttributes([
            .link: link,
            colorKey: linkedColor,
        ], range: linkedRange)

        let prepared = prepareRichText(text, defaultFont: regularDescriptor)
        let lines = layoutWithLines(
            prepared,
            maxWidth: 130,
            lineHeight: 22
        )
        let materialized = NSMutableAttributedString(string: "")
        for line in lines.lines { materialized.append(line.attributedText) }
        let materializedRange = (materialized.string as NSString).range(of: "Alma 7:10")

        #expect(materializedRange.location != NSNotFound)
        #expect(materialized.attribute(.link, at: materializedRange.location, effectiveRange: nil) as? URL == link)
        #expect(materialized.attribute(colorKey, at: materializedRange.location, effectiveRange: nil) != nil)
    }

    @Test("a style boundary inside a word does not create a wrap point")
    func styleBoundaryIsNotBreakOpportunity() {
        let text = NSMutableAttributedString(
            string: "extraordinary",
            attributes: [fontKey: regular]
        )
        text.addAttribute(
            fontKey,
            value: largeBold,
            range: NSRange(location: 5, length: 3)
        )
        let prepared = prepareRichText(text, defaultFont: regularDescriptor)

        #expect(prepared.attributedSegments.count == 1)
        #expect(prepared.attributedSegments[0].string == "extraordinary")
    }

    @Test("normal whitespace keeps the following styled run intact")
    func whitespaceNormalization() {
        let text = NSMutableAttributedString(
            string: "  one\t\n  two  ",
            attributes: [fontKey: regular]
        )
        let prepared = prepareRichText(text, defaultFont: regularDescriptor)

        #expect(prepared.segments.joined() == "one two")
    }

    private func referenceLineCount(
        _ text: NSAttributedString,
        maxWidth: CGFloat
    ) -> Int {
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let path = CGPath(
            rect: CGRect(x: 0, y: 0, width: maxWidth, height: 100_000),
            transform: nil
        )
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRangeMake(0, 0),
            path,
            nil
        )
        return (CTFrameGetLines(frame) as? [CTLine] ?? []).count
    }
}
