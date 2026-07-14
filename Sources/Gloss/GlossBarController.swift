import AppKit
import GlossCore

private final class GlossBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class GlossBarController: NSObject {
    var onTranslate: (() -> Void)?

    private let panel: GlossBarPanel
    private let translateButton: NSButton
    private let progressIndicator = NSProgressIndicator()

    override init() {
        panel = GlossBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 176, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        translateButton = NSButton(title: "翻译", target: nil, action: nil)
        super.init()
        configurePanel()
    }

    func show(at anchor: NSPoint, targetLanguage: String) {
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        translateButton.isEnabled = true
        translateButton.title = "译为\(TranslationLanguages.shortTitle(forTargetName: targetLanguage))"

        let size = panel.frame.size
        let screen = NSScreen.screens.first { NSPointInRect(anchor, $0.frame) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? .zero
        let preferred = NSPoint(x: anchor.x - size.width / 2, y: anchor.y + 18)
        let origin = NSPoint(
            x: min(max(preferred.x, visibleFrame.minX + 8), visibleFrame.maxX - size.width - 8),
            y: min(max(preferred.y, visibleFrame.minY + 8), visibleFrame.maxY - size.height - 8)
        )
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    func setLoading(_ loading: Bool) {
        translateButton.isEnabled = !loading
        progressIndicator.isHidden = !loading
        if loading {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
    }

    func hide() {
        panel.orderOut(nil)
    }

    func contains(_ point: NSPoint) -> Bool {
        panel.isVisible && panel.frame.insetBy(dx: -4, dy: -4).contains(point)
    }

    private func configurePanel() {
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor
        panel.contentView = effect

        let icon = NSImageView()
        icon.image = GlossBrand.markImage(pointSize: 18)
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        translateButton.target = self
        translateButton.action = #selector(translate)
        translateButton.bezelStyle = .inline
        translateButton.font = .systemFont(ofSize: 13, weight: .semibold)
        translateButton.translatesAutoresizingMaskIntoConstraints = false

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isHidden = true
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [icon, translateButton, progressIndicator])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            progressIndicator.widthAnchor.constraint(equalToConstant: 16),
            progressIndicator.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    @objc private func translate() {
        onTranslate?()
    }

}
