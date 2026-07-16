import AppKit
import GlossCore
import PDFKit

@MainActor
final class PDFTranslatedPageView: NSView {
    private var page: PDFPage?
    private var pageBounds = CGRect.zero
    private var blocks: [DocumentBlock] = []
    private var translations: [String: String] = [:]
    private var pageInset: CGFloat = 24

    override var isFlipped: Bool { true }

    func update(
        page: PDFPage,
        blocks: [DocumentBlock],
        translations: [String: String],
        availableWidth: CGFloat,
        pageInset: CGFloat = 24
    ) {
        self.page = page
        pageBounds = page.bounds(for: .mediaBox)
        self.blocks = blocks
        self.translations = translations
        self.pageInset = pageInset

        let width = max(pageBounds.width + pageInset * 2, availableWidth)
        let drawingWidth = max(1, width - pageInset * 2)
        let scale = drawingWidth / max(1, pageBounds.width)
        let height = pageBounds.height * scale + pageInset * 2
        frame = NSRect(x: 0, y: 0, width: width, height: height)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let page, pageBounds.width > 0, pageBounds.height > 0 else {
            NSColor.windowBackgroundColor.setFill()
            dirtyRect.fill()
            return
        }

        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        let drawingWidth = max(1, bounds.width - pageInset * 2)
        let scale = drawingWidth / pageBounds.width
        let pageRect = CGRect(
            x: pageInset,
            y: pageInset,
            width: pageBounds.width * scale,
            height: pageBounds.height * scale
        )

        NSColor.white.setFill()
        pageRect.fill()
        draw(page, in: pageRect, scale: scale)
        drawTranslations(in: pageRect, scale: scale)

        NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
        let border = NSBezierPath(rect: pageRect)
        border.lineWidth = 0.5
        border.stroke()
    }

    private func draw(_ page: PDFPage, in pageRect: CGRect, scale: CGFloat) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: pageRect.minX, y: pageRect.maxY)
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -pageBounds.minX, y: -pageBounds.minY)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()
    }

    private func drawTranslations(in pageRect: CGRect, scale: CGFloat) {
        for block in blocks {
            guard let translation = translations[block.id],
                !block.boundingRects.isEmpty
            else { continue }

            let sourceRect = block.boundingRects.reduce(CGRect.null) { partial, rect in
                partial.union(rect)
            }
            guard !sourceRect.isNull, sourceRect.width > 1, sourceRect.height > 1 else {
                continue
            }

            var targetRect = CGRect(
                x: pageRect.minX + (sourceRect.minX - pageBounds.minX) * scale,
                y: pageRect.minY + (pageBounds.maxY - sourceRect.maxY) * scale,
                width: sourceRect.width * scale,
                height: sourceRect.height * scale
            )
            targetRect = targetRect.insetBy(dx: -1.5, dy: -1)
            targetRect = targetRect.intersection(pageRect)
            guard targetRect.width > 4, targetRect.height > 4 else { continue }

            NSColor.white.setFill()
            targetRect.fill()
            drawFitted(translation, in: targetRect, block: block, scale: scale)
        }
    }

    private func drawFitted(
        _ text: String,
        in rect: CGRect,
        block: DocumentBlock,
        scale: CGFloat
    ) {
        let lineHeights = block.boundingRects.map(\.height).filter { $0 > 0 }.sorted()
        let medianLineHeight =
            lineHeights.isEmpty
            ? block.boundingRects.first?.height ?? 10
            : lineHeights[lineHeights.count / 2]
        var fontSize = min(22, max(6.5, medianLineHeight * scale * 0.82))
        let minimumFontSize = max(5, min(7, fontSize * 0.58))
        var attributes = textAttributes(fontSize: fontSize)

        while fontSize > minimumFontSize {
            let measured = (text as NSString).boundingRect(
                with: rect.size,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes
            )
            if measured.height <= rect.height + 0.5 {
                break
            }
            fontSize -= 0.5
            attributes = textAttributes(fontSize: fontSize)
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        (text as NSString).draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    private func textAttributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 0
        paragraph.paragraphSpacing = 0
        paragraph.alignment = .natural
        return [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph,
        ]
    }
}
