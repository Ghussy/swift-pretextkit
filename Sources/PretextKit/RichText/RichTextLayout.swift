import CoreGraphics
import Foundation

/// One attributed line produced from `PreparedRichText`.
public struct RichTextLayoutLine: @unchecked Sendable {
    public let attributedText: NSAttributedString
    public let width: CGFloat
    public let start: LayoutCursor
    public let end: LayoutCursor
}

/// Full attributed-line layout result.
public struct RichTextLayoutLinesResult: @unchecked Sendable {
    public let lineCount: Int
    public let height: CGFloat
    public let lines: [RichTextLayoutLine]
}

/// Cheap arithmetic layout for prepared attributed text.
public func layout(
    _ prepared: PreparedRichText,
    maxWidth: CGFloat,
    lineHeight: CGFloat
) -> LayoutResult {
    let lineCount = countPreparedLines(prepared.core, maxWidth: Float(maxWidth))
    return LayoutResult(
        lineCount: lineCount,
        height: CGFloat(lineCount) * lineHeight
    )
}

/// Materializes attributed lines while retaining every source attribute.
public func layoutWithLines(
    _ prepared: PreparedRichText,
    maxWidth: CGFloat,
    lineHeight: CGFloat
) -> RichTextLayoutLinesResult {
    var lines: [RichTextLayoutLine] = []
    let plainSegments = prepared.attributedSegments.map(\.string)

    walkPreparedLines(
        prepared.core,
        segments: plainSegments,
        maxWidth: Float(maxWidth)
    ) { internalLine in
        lines.append(RichTextLayoutLine(
            attributedText: materializeRichLine(
                prepared.attributedSegments,
                core: prepared.core,
                line: internalLine
            ),
            width: CGFloat(internalLine.width),
            start: LayoutCursor(
                segmentIndex: internalLine.startSegmentIndex,
                graphemeIndex: internalLine.startGraphemeIndex
            ),
            end: LayoutCursor(
                segmentIndex: internalLine.endSegmentIndex,
                graphemeIndex: internalLine.endGraphemeIndex
            )
        ))
    }

    return RichTextLayoutLinesResult(
        lineCount: lines.count,
        height: CGFloat(lines.count) * lineHeight,
        lines: lines
    )
}

/// Walks rich line geometry without allocating attributed line strings.
@discardableResult
public func walkLineRanges(
    _ prepared: PreparedRichText,
    maxWidth: CGFloat,
    onLine: (LayoutLineRange) -> Void
) -> Int {
    var lineCount = 0
    walkPreparedLines(
        prepared.core,
        segments: prepared.attributedSegments.map(\.string),
        maxWidth: Float(maxWidth)
    ) { internalLine in
        onLine(LayoutLineRange(
            width: CGFloat(internalLine.width),
            start: LayoutCursor(
                segmentIndex: internalLine.startSegmentIndex,
                graphemeIndex: internalLine.startGraphemeIndex
            ),
            end: LayoutCursor(
                segmentIndex: internalLine.endSegmentIndex,
                graphemeIndex: internalLine.endGraphemeIndex
            )
        ))
        lineCount += 1
    }
    return lineCount
}

private func materializeRichLine(
    _ segments: [NSAttributedString],
    core: PreparedCore,
    line: InternalLayoutLine
) -> NSAttributedString {
    let result = NSMutableAttributedString(string: "")
    guard line.startSegmentIndex < line.endSegmentIndex else { return result }

    for index in line.startSegmentIndex..<line.endSegmentIndex {
        let segment = segments[index]
        let kind = core.kinds[index]

        if kind == .space, index == line.endSegmentIndex - 1 { continue }

        if index == line.startSegmentIndex, line.startGraphemeIndex > 0 {
            result.append(attributedGraphemeSlice(
                segment,
                from: line.startGraphemeIndex,
                to: nil
            ))
        } else if index == line.endSegmentIndex - 1,
                  line.endGraphemeIndex > 0 {
            result.append(attributedGraphemeSlice(
                segment,
                from: 0,
                to: line.endGraphemeIndex
            ))
        } else if kind == .softHyphen {
            if index == line.endSegmentIndex - 1 {
                let attributes = segment.length > 0
                    ? segment.attributes(at: 0, effectiveRange: nil)
                    : [:]
                result.append(NSAttributedString(
                    string: "-",
                    attributes: attributes
                ))
            }
        } else {
            result.append(segment)
        }
    }

    return result.copy() as! NSAttributedString
}

private func attributedGraphemeSlice(
    _ text: NSAttributedString,
    from start: Int,
    to end: Int?
) -> NSAttributedString {
    let string = text.string as NSString
    var ranges: [NSRange] = []
    ranges.reserveCapacity(text.string.count)
    var offset = 0
    while offset < string.length {
        let range = string.rangeOfComposedCharacterSequence(at: offset)
        ranges.append(range)
        offset = NSMaxRange(range)
    }

    let lower = min(max(start, 0), ranges.count)
    let upper = min(max(end ?? ranges.count, lower), ranges.count)
    guard lower < upper else { return NSAttributedString(string: "") }
    let range = NSRange(
        location: ranges[lower].location,
        length: NSMaxRange(ranges[upper - 1]) - ranges[lower].location
    )
    return text.attributedSubstring(from: range)
}
