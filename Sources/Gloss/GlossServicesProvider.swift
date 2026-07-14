import AppKit
import CoreGraphics

@MainActor
final class GlossServicesProvider: NSObject {
    var onTranslate: ((String, String) -> Void)?
    var onTranslateImage: ((CGImage, String) -> Void)?

    @objc func translateTextWithGloss(
        _ pasteboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let sourceName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "系统服务"
        guard let text = pasteboard.string(forType: .string),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            error.pointee = "没有可翻译的文本。"
            return
        }
        onTranslate?(text, sourceName)
    }

    @objc func translateImageWithGloss(
        _ pasteboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let sourceName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "系统服务"
        do {
            onTranslateImage?(try ClipboardImage.read(from: pasteboard), sourceName)
        } catch let imageError {
            error.pointee = imageError.localizedDescription as NSString
        }
    }
}
