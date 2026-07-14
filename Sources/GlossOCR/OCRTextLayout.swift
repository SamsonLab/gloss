import Foundation

package struct OCRTextRegion: Sendable, Equatable {
    package let text: String
    package let boundingBox: CGRect
    package let confidence: Float

    package init(text: String, boundingBox: CGRect, confidence: Float) {
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
    }
}

package enum OCRError: LocalizedError, Equatable {
    case noText
    case tooMuchText(Int)

    package var errorDescription: String? {
        switch self {
        case .noText:
            "图片中没有识别到可翻译的文字。"
        case .tooMuchText(let count):
            "识别结果包含 \(count) 个字符，超过单次 50,000 字符限制。"
        }
    }
}

package enum OCRTextLayout {
    private struct Row {
        var regions: [OCRTextRegion]
        var midY: CGFloat
        var minY: CGFloat
        var maxY: CGFloat
    }

    package static func orderedText(
        from regions: [OCRTextRegion],
        maximumCharacters: Int = 50_000
    ) throws -> String {
        let usable = regions.compactMap { region -> OCRTextRegion? in
            let text = normalize(region.text)
            guard region.confidence >= 0.15, !text.isEmpty else { return nil }
            return OCRTextRegion(text: text, boundingBox: region.boundingBox, confidence: region.confidence)
        }
        guard !usable.isEmpty else { throw OCRError.noText }

        let heights = usable.map(\.boundingBox.height).filter { $0 > 0 }.sorted()
        let medianHeight = heights.isEmpty ? 0.02 : heights[heights.count / 2]
        let sorted = usable.sorted {
            if abs($0.boundingBox.midY - $1.boundingBox.midY) > medianHeight * 0.45 {
                return $0.boundingBox.midY > $1.boundingBox.midY
            }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }

        var rows: [Row] = []
        for region in sorted {
            let threshold = max(medianHeight * 0.5, region.boundingBox.height * 0.4)
            if let index = rows.indices.last,
                abs(rows[index].midY - region.boundingBox.midY) <= threshold
            {
                rows[index].regions.append(region)
                let count = CGFloat(rows[index].regions.count)
                rows[index].midY += (region.boundingBox.midY - rows[index].midY) / count
                rows[index].minY = min(rows[index].minY, region.boundingBox.minY)
                rows[index].maxY = max(rows[index].maxY, region.boundingBox.maxY)
            } else {
                rows.append(
                    Row(
                        regions: [region],
                        midY: region.boundingBox.midY,
                        minY: region.boundingBox.minY,
                        maxY: region.boundingBox.maxY
                    )
                )
            }
        }

        rows.sort { $0.midY > $1.midY }
        var output = ""
        for index in rows.indices {
            let row = rows[index]
            let line = row.regions.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                .map(\.text)
                .joined(separator: " ")

            if index > rows.startIndex {
                let previous = rows[index - 1]
                let verticalGap = previous.minY - row.maxY
                output += verticalGap > medianHeight * 0.85 ? "\n\n" : "\n"
            }
            output += line
            guard output.count <= maximumCharacters else {
                throw OCRError.tooMuchText(output.count)
            }
        }
        return output
    }

    private static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
