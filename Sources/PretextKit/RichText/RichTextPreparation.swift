import CoreText
import Foundation

/// Prepares attributed text for fast arithmetic reflow while preserving its
/// font, color, link, and custom attributes.
///
/// Like Cheng Lou's rich-inline API, the full paragraph is analyzed before its
/// styled runs are measured. Styling a portion of a word therefore does not
/// turn that style boundary into a line-break opportunity.
///
/// - Parameters:
///   - text: Immutable attributed text to prepare.
///   - defaultFont: Font applied only where the input has no font attribute.
///   - options: Paragraph white-space behavior.
/// - Returns: A reusable rich-text handle for `layout()` and
///   `layoutWithLines()`.
public func prepareRichText(
    _ text: NSAttributedString,
    defaultFont: FontDescriptor,
    options: PrepareOptions = PrepareOptions()
) -> PreparedRichText {
    let normalized = normalizeRichText(
        text,
        defaultFont: defaultFont,
        whiteSpace: options.whiteSpace
    )
    let analysis = analyzeText(normalized.string, whiteSpace: options.whiteSpace)
    return measureRichText(
        analysis,
        attributedText: normalized,
        defaultFont: defaultFont
    )
}

private let coreTextFontKey = NSAttributedString.Key(
    rawValue: kCTFontAttributeName as String
)

private func normalizeRichText(
    _ source: NSAttributedString,
    defaultFont: FontDescriptor,
    whiteSpace: WhiteSpaceMode
) -> NSAttributedString {
    let normalized: NSMutableAttributedString

    switch whiteSpace {
    case .normal:
        normalized = normalizeRichWhitespace(source)
    case .preWrap:
        normalized = normalizeRichLineEndings(source)
    }

    let fullRange = NSRange(location: 0, length: normalized.length)
    normalized.enumerateAttribute(
        coreTextFontKey,
        in: fullRange,
        options: []
    ) { value, range, _ in
        guard value == nil else { return }
        normalized.addAttribute(
            coreTextFontKey,
            value: defaultFont.font,
            range: range
        )
    }
    return normalized.copy() as! NSAttributedString
}

/// CSS-like `white-space: normal`: leading/trailing collapsible whitespace is
/// removed and interior runs collapse to one attributed space.
private func normalizeRichWhitespace(
    _ source: NSAttributedString
) -> NSMutableAttributedString {
    let result = NSMutableAttributedString(string: "")
    let sourceString = source.string as NSString
    var pendingSpaceAttributes: [NSAttributedString.Key: Any]?
    var offset = 0

    while offset < sourceString.length {
        let range = sourceString.rangeOfComposedCharacterSequence(at: offset)
        let value = sourceString.substring(with: range)
        let isCollapsible = value.unicodeScalars.allSatisfy { scalar in
            scalar == " " || scalar == "\t" || scalar == "\n"
                || scalar == "\r" || scalar == "\u{000C}"
        }

        if isCollapsible {
            if result.length > 0, pendingSpaceAttributes == nil {
                pendingSpaceAttributes = source.attributes(
                    at: range.location,
                    effectiveRange: nil
                )
            }
        } else {
            if let attributes = pendingSpaceAttributes {
                result.append(NSAttributedString(
                    string: " ",
                    attributes: attributes
                ))
                pendingSpaceAttributes = nil
            }
            result.append(source.attributedSubstring(from: range))
        }
        offset = NSMaxRange(range)
    }

    return result
}

/// CSS-like `white-space: pre-wrap`: preserve spacing while normalizing CRLF,
/// CR, and form-feed to LF without dropping the source attributes.
private func normalizeRichLineEndings(
    _ source: NSAttributedString
) -> NSMutableAttributedString {
    let result = NSMutableAttributedString(string: "")
    let sourceString = source.string as NSString
    var offset = 0

    while offset < sourceString.length {
        let codeUnit = sourceString.character(at: offset)
        if codeUnit == 0x000D || codeUnit == 0x000C {
            let attributes = source.attributes(at: offset, effectiveRange: nil)
            result.append(NSAttributedString(string: "\n", attributes: attributes))
            if codeUnit == 0x000D,
               offset + 1 < sourceString.length,
               sourceString.character(at: offset + 1) == 0x000A {
                offset += 2
            } else {
                offset += 1
            }
            continue
        }

        let range = sourceString.rangeOfComposedCharacterSequence(at: offset)
        result.append(source.attributedSubstring(from: range))
        offset = NSMaxRange(range)
    }

    return result
}

private func measureRichText(
    _ analysis: TextAnalysis,
    attributedText: NSAttributedString,
    defaultFont: FontDescriptor
) -> PreparedRichText {
    let segmentation = analysis.segmentation
    var builder = PreparedSegmentBuilder()
    builder.reserveCapacity(segmentation.count)
    var attributedSegments: [NSAttributedString] = []
    attributedSegments.reserveCapacity(segmentation.count)

    let defaultMeasurer = SegmentMeasurer(font: defaultFont.font)
    let spaceWidth = defaultMeasurer.measureSpaceWidth()
    let hyphenWidth = defaultMeasurer.measureHyphenWidth()

    for index in 0..<segmentation.count {
        let text = segmentation.texts[index]
        let kind = segmentation.kinds[index]
        let sourceRange = NSRange(
            location: segmentation.starts[index],
            length: (text as NSString).length
        )
        guard NSMaxRange(sourceRange) <= attributedText.length else { continue }
        let attributedSegment = attributedText.attributedSubstring(from: sourceRange)

        switch kind {
        case .softHyphen:
            let hyphen = attributedReplacement("-", attributesFrom: attributedSegment)
            let width = measureRichWidth(hyphen)
            pushRichSegment(
                attributedSegment,
                width: 0,
                fitAdvance: width,
                paintAdvance: width,
                kind: kind,
                builder: &builder,
                attributedSegments: &attributedSegments
            )

        case .hardBreak, .tab, .zeroWidthBreak:
            pushRichSegment(
                attributedSegment,
                width: 0,
                fitAdvance: 0,
                paintAdvance: 0,
                kind: kind,
                builder: &builder,
                attributedSegments: &attributedSegments
            )

        case .space, .preservedSpace:
            let width = measureRichWidth(attributedSegment)
            pushRichSegment(
                attributedSegment,
                width: width,
                fitAdvance: 0,
                paintAdvance: 0,
                kind: kind,
                builder: &builder,
                attributedSegments: &attributedSegments
            )

        case .glue:
            let width = measureRichWidth(attributedSegment)
            pushRichSegment(
                attributedSegment,
                width: width,
                fitAdvance: width,
                paintAdvance: width,
                kind: kind,
                builder: &builder,
                attributedSegments: &attributedSegments
            )

        case .text:
            if isCJK(text) {
                pushRichCJKSegments(
                    attributedSegment,
                    builder: &builder,
                    attributedSegments: &attributedSegments
                )
            } else {
                let width = measureRichWidth(attributedSegment)
                let breakable = segmentation.isWordLike[index] && text.count > 1
                    ? measureRichGraphemeWidths(attributedSegment)
                    : nil
                pushRichSegment(
                    attributedSegment,
                    width: width,
                    fitAdvance: width,
                    paintAdvance: width,
                    kind: kind,
                    breakable: breakable,
                    builder: &builder,
                    attributedSegments: &attributedSegments
                )
            }
        }
    }

    let chunks = richPreparedChunks(for: builder)
    let core = PreparedCore(
        widths: builder.widths,
        lineEndFitAdvances: builder.lineEndFitAdvances,
        lineEndPaintAdvances: builder.lineEndPaintAdvances,
        kinds: builder.kinds,
        simpleLineWalkFastPath: builder.simpleLineWalkFastPath,
        breakableWidths: builder.breakableWidths,
        discretionaryHyphenWidth: hyphenWidth,
        tabStopAdvance: spaceWidth * 8,
        chunks: chunks
    )
    return PreparedRichText(core: core, attributedSegments: attributedSegments)
}

private func attributedReplacement(
    _ replacement: String,
    attributesFrom source: NSAttributedString
) -> NSAttributedString {
    let attributes = source.length > 0
        ? source.attributes(at: 0, effectiveRange: nil)
        : [:]
    return NSAttributedString(string: replacement, attributes: attributes)
}

private func measureRichWidth(_ text: NSAttributedString) -> Float {
    let line = CTLineCreateWithAttributedString(text as CFAttributedString)
    return Float(CTLineGetTypographicBounds(line, nil, nil, nil))
}

private func measureRichGraphemeWidths(
    _ text: NSAttributedString
) -> ContiguousArray<Float> {
    let string = text.string as NSString
    var widths = ContiguousArray<Float>()
    widths.reserveCapacity(text.string.count)
    var offset = 0
    while offset < string.length {
        let range = string.rangeOfComposedCharacterSequence(at: offset)
        widths.append(measureRichWidth(text.attributedSubstring(from: range)))
        offset = NSMaxRange(range)
    }
    return widths
}

private func pushRichSegment(
    _ attributedText: NSAttributedString,
    width: Float,
    fitAdvance: Float,
    paintAdvance: Float,
    kind: SegmentBreakKind,
    breakable: ContiguousArray<Float>? = nil,
    builder: inout PreparedSegmentBuilder,
    attributedSegments: inout [NSAttributedString]
) {
    builder.push(
        text: attributedText.string,
        width: width,
        fitAdvance: fitAdvance,
        paintAdvance: paintAdvance,
        kind: kind,
        breakable: breakable
    )
    attributedSegments.append(attributedText)
}

private func pushRichCJKSegments(
    _ text: NSAttributedString,
    builder: inout PreparedSegmentBuilder,
    attributedSegments: inout [NSAttributedString]
) {
    let string = text.string as NSString
    var unitRange: NSRange?
    var offset = 0

    func flush(_ range: NSRange) {
        let unit = text.attributedSubstring(from: range)
        let width = measureRichWidth(unit)
        pushRichSegment(
            unit,
            width: width,
            fitAdvance: width,
            paintAdvance: width,
            kind: .text,
            builder: &builder,
            attributedSegments: &attributedSegments
        )
    }

    while offset < string.length {
        let characterRange = string.rangeOfComposedCharacterSequence(at: offset)
        let grapheme = string.substring(with: characterRange)

        if let existing = unitRange {
            let currentText = string.substring(with: existing)
            let scalar = grapheme.unicodeScalars.first
            let sticksToCurrent = richIsKinsokuEndUnit(currentText)
                || scalar.map(kinsokuStartScalars.contains) == true
                || scalar.map(leftStickyPunctuation.contains) == true

            if sticksToCurrent {
                unitRange = NSRange(
                    location: existing.location,
                    length: NSMaxRange(characterRange) - existing.location
                )
            } else {
                flush(existing)
                unitRange = characterRange
            }
        } else {
            unitRange = characterRange
        }
        offset = NSMaxRange(characterRange)
    }

    if let unitRange { flush(unitRange) }
}

private func richIsKinsokuEndUnit(_ text: String) -> Bool {
    guard !text.isEmpty else { return false }
    return text.unicodeScalars.allSatisfy(kinsokuEndScalars.contains)
}

private func richPreparedChunks(
    for builder: PreparedSegmentBuilder
) -> [PreparedLineChunk] {
    guard !builder.kinds.isEmpty else { return [] }
    var chunks: [PreparedLineChunk] = []
    var start = 0

    for index in builder.kinds.indices where builder.kinds[index] == .hardBreak {
        chunks.append(PreparedLineChunk(
            startSegmentIndex: start,
            endSegmentIndex: index,
            consumedEndSegmentIndex: index + 1
        ))
        start = index + 1
    }

    if start < builder.kinds.count {
        chunks.append(PreparedLineChunk(
            startSegmentIndex: start,
            endSegmentIndex: builder.kinds.count,
            consumedEndSegmentIndex: builder.kinds.count
        ))
    } else if chunks.isEmpty {
        chunks.append(PreparedLineChunk(
            startSegmentIndex: 0,
            endSegmentIndex: builder.kinds.count,
            consumedEndSegmentIndex: builder.kinds.count
        ))
    }

    return chunks
}
