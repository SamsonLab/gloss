import AppKit
import CoreGraphics

enum ClipboardImageError: LocalizedError {
    case unavailable
    case unreadable
    case tooLarge(width: Int, height: Int)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "剪贴板中没有可识别的图片。"
        case .unreadable:
            "Gloss 无法读取这张图片。"
        case .tooLarge(let width, let height):
            "图片尺寸为 \(width) × \(height)，超过 5,000 万像素限制。"
        }
    }
}

@MainActor
enum ClipboardImage {
    private static let maximumPixelCount = 50_000_000

    static func read(from pasteboard: NSPasteboard) throws -> CGImage {
        guard let image = NSImage(pasteboard: pasteboard) ?? imageFromFileURL(in: pasteboard) else {
            throw ClipboardImageError.unavailable
        }

        for representation in image.representations
        where representation.pixelsWide > 0 && representation.pixelsHigh > 0 {
            try validateSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        }

        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard
            let image = image.cgImage(
                forProposedRect: &proposedRect,
                context: nil,
                hints: nil
            ),
            image.width > 0,
            image.height > 0
        else {
            throw ClipboardImageError.unreadable
        }

        try validateSize(width: image.width, height: image.height)
        return image
    }

    private static func imageFromFileURL(in pasteboard: NSPasteboard) -> NSImage? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        guard
            let url = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: options
            )?.first as? URL
        else { return nil }
        return NSImage(contentsOf: url)
    }

    private static func validateSize(width: Int, height: Int) throws {
        guard width <= maximumPixelCount / height else {
            throw ClipboardImageError.tooLarge(width: width, height: height)
        }
    }
}
