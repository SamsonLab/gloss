import AppKit

enum GlossBrand {
    static func menuHeaderTitle(version: String) -> NSAttributedString {
        let title = NSMutableAttributedString(
            string: "Gloss",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        title.append(
            NSAttributedString(
                string: "  v\(version)",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )
        )
        return title
    }

    static func markImage(pointSize: CGFloat, template: Bool = true) -> NSImage {
        let image = NSImage(
            size: NSSize(width: pointSize, height: pointSize),
            flipped: false
        ) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }

            let scale = min(rect.width, rect.height) / 18
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let lineWidth = max(1.35, 2.25 * scale)

            context.saveGState()
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(lineWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)

            let outerRibbon = CGMutablePath()
            outerRibbon.addArc(
                center: center,
                radius: 6.1 * scale,
                startAngle: .pi * 0.17,
                endAngle: .pi * 1.82,
                clockwise: false
            )
            context.addPath(outerRibbon)
            context.strokePath()

            let innerRibbon = CGMutablePath()
            innerRibbon.move(to: CGPoint(x: center.x + 0.65 * scale, y: center.y))
            innerRibbon.addLine(to: CGPoint(x: center.x + 5.1 * scale, y: center.y))
            innerRibbon.addCurve(
                to: CGPoint(x: center.x + 3.35 * scale, y: center.y - 4.35 * scale),
                control1: CGPoint(x: center.x + 5.1 * scale, y: center.y - 1.95 * scale),
                control2: CGPoint(x: center.x + 4.65 * scale, y: center.y - 3.25 * scale)
            )
            context.addPath(innerRibbon)
            context.strokePath()
            context.restoreGState()
            return true
        }
        image.isTemplate = template
        return image
    }
}
