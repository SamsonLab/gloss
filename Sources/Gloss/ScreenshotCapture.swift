import CoreGraphics
import Foundation
import ImageIO

enum ScreenshotCaptureError: LocalizedError, Equatable {
    case cancelled
    case failed(Int32)
    case unreadable
    case tooLarge(width: Int, height: Int)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            "已取消截图。"
        case .failed(let status):
            "无法完成截图（状态码 \(status)）。"
        case .unreadable:
            "Gloss 无法读取截图。"
        case .tooLarge(let width, let height):
            "截图尺寸为 \(width) × \(height)，超过 5,000 万像素限制。"
        }
    }
}

@MainActor
enum ScreenshotCapture {
    private static let maximumPixelCount = 50_000_000

    static func selection() async throws -> CGImage {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "Gloss",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let file = directory.appendingPathComponent("screenshot-\(UUID().uuidString).png")
        defer { try? fileManager.removeItem(at: file) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        let waiter = Task.detached(priority: .userInitiated) {
            process.waitUntilExit()
            return process.terminationStatus
        }
        let status = await withTaskCancellationHandler {
            await waiter.value
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
            waiter.cancel()
        }

        try Task.checkCancellation()
        switch status {
        case 0:
            return try loadImage(at: file)
        case 1:
            throw ScreenshotCaptureError.cancelled
        default:
            throw ScreenshotCaptureError.failed(status)
        }
    }

    static func loadImage(at file: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            image.width > 0,
            image.height > 0
        else { throw ScreenshotCaptureError.unreadable }
        guard image.width <= Self.maximumPixelCount / image.height else {
            throw ScreenshotCaptureError.tooLarge(
                width: image.width,
                height: image.height
            )
        }
        return image
    }
}
