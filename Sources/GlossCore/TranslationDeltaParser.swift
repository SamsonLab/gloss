import Foundation

struct TranslationDeltaParser {
    struct Item: Decodable, Equatable {
        let id: String
        let index: Int
        let text: String
    }

    private static let translationsKey = Data("\"translations\"".utf8)

    private var data = Data()
    private var keyFound = false
    private var arrayFound = false
    private var scanIndex = 0
    private var objectStart: Int?
    private var objectDepth = 0
    private var inString = false
    private var escaped = false

    mutating func append(_ delta: String) -> [Item] {
        data.append(contentsOf: delta.utf8)

        if !keyFound {
            guard let range = data.range(of: Self.translationsKey) else { return [] }
            keyFound = true
            scanIndex = range.upperBound
        }

        if !arrayFound {
            while scanIndex < data.count {
                if data[scanIndex] == 0x5B {
                    arrayFound = true
                    scanIndex += 1
                    break
                }
                scanIndex += 1
            }
            guard arrayFound else { return [] }
        }

        var items: [Item] = []
        while scanIndex < data.count {
            let byte = data[scanIndex]
            if objectStart == nil {
                if byte == 0x7B {
                    objectStart = scanIndex
                    objectDepth = 1
                    inString = false
                    escaped = false
                }
                scanIndex += 1
                continue
            }

            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
            } else if byte == 0x22 {
                inString = true
            } else if byte == 0x7B {
                objectDepth += 1
            } else if byte == 0x7D {
                objectDepth -= 1
                if objectDepth == 0, let start = objectStart {
                    let object = data.subdata(in: start..<(scanIndex + 1))
                    if let item = try? JSONDecoder().decode(Item.self, from: object) {
                        items.append(item)
                    }
                    objectStart = nil
                }
            }
            scanIndex += 1
        }
        return items
    }
}
