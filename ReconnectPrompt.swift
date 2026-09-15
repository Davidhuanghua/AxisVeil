import AppKit
import QuartzCore

/// 耳机断联后的“重新连接 / 暂停检测”操作卡片。
///
/// 以不抢键盘焦点的浮动玻璃卡片呈现，不会打断正在进行的输入，
/// 也不会升级为会夺取焦点的系统对话框。
final class ReconnectPromptController {
    /// 点击“重新连接”。
    var onReconnect: (() -> Void)?
    /// 点击“暂停检测”。
    var onPause: (() -> Void)?

    private let titleText = "AirPods 已断开"
    private let subtitleText = "无法继续检测头部朝向，屏幕已全屏模糊。"
    private let defaultStatusText = "请重新连接耳机，或暂停检测。"

    private var statusText = "请重新连接耳机，或暂停检测。"
    private var panel: NSPanel?
    private var statusLabel: NSTextField?

    var isPresenting: Bool { panel != nil }

    /// 开始提示。重复调用会以最新文案重新显示浮动卡片。
    func show() {
        closePanel()
        showPanel()
    }

    /// 刷新检测进度文案（例如“未检测到 AirPods · 请确认耳机已连接并佩戴”）。
    func setStatus(_ text: String) {
        statusText = text
        statusLabel?.stringValue = text
    }

    /// 结束提示并复位文案。
    func dismiss() {
        closePanel()
        statusText = defaultStatusText
    }

    private func showPanel() {
        let panel = makePanel()
        self.panel = panel
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func closePanel() {
        panel?.orderOut(nil)
        panel = nil
        statusLabel = nil
    }

    private func makePanel() -> NSPanel {
        let size = NSSize(width: 460, height: 272)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        // 只有真正需要输入时（例如点击文本）才成为 key window，不抢键盘焦点。
        panel.becomesKeyOnlyIfNeeded = true

        panel.contentView = makeCard()

        let screen = NSScreen.main ?? NSScreen.screens.first
        if let screen {
            // 放在屏幕中央偏上：为遮罩上的提示卡留出位置，两者不重叠。
            panel.setFrameOrigin(NSPoint(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.midY + screen.visibleFrame.height * 0.16 - size.height / 2
            ))
        }
        return panel
    }

    private func makeCard() -> NSView {
        let card = AppearanceObservingEffectView()
        card.blendingMode = .behindWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 26
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowRadius = 30
        card.layer?.shadowOffset = CGSize(width: 0, height: -10)

        let iconBackground = NSView()
        iconBackground.translatesAutoresizingMaskIntoConstraints = false
        iconBackground.wantsLayer = true
        iconBackground.layer?.cornerRadius = 24
        iconBackground.layer?.cornerCurve = .continuous

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "headphones", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 25, weight: .semibold)
        iconBackground.addSubview(icon)

        let title = NSTextField(labelWithString: titleText)
        title.font = .systemFont(ofSize: 21, weight: .bold)
        title.alignment = .center
        title.cell?.usesSingleLineMode = true

        let subtitle = NSTextField(labelWithString: subtitleText)
        subtitle.font = .systemFont(ofSize: 14, weight: .medium)
        subtitle.alignment = .center
        subtitle.cell?.usesSingleLineMode = true

        let status = NSTextField(labelWithString: statusText)
        status.translatesAutoresizingMaskIntoConstraints = false
        status.font = .systemFont(ofSize: 13, weight: .medium)
        status.alignment = .center
        statusLabel = status

        let statusBackground = NSView()
        statusBackground.translatesAutoresizingMaskIntoConstraints = false
        statusBackground.wantsLayer = true
        statusBackground.layer?.cornerRadius = 10
        statusBackground.layer?.cornerCurve = .continuous
        statusBackground.addSubview(status)

        let reconnectButton = FirstMouseButton(
            title: "重新连接",
            target: self,
            action: #selector(reconnectTapped)
        )
        reconnectButton.bezelStyle = .rounded
        reconnectButton.controlSize = .large
        reconnectButton.keyEquivalent = "\r"
        reconnectButton.font = .systemFont(ofSize: 13, weight: .semibold)
        reconnectButton.bezelColor = .controlAccentColor

        let pauseButton = FirstMouseButton(
            title: "暂停检测",
            target: self,
            action: #selector(pauseTapped)
        )
        pauseButton.bezelStyle = .rounded
        pauseButton.controlSize = .large
        pauseButton.font = .systemFont(ofSize: 13, weight: .semibold)

        let buttons = NSStackView(views: [reconnectButton, pauseButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        buttons.alignment = .centerY

        let stack = NSStackView(views: [iconBackground, title, subtitle, statusBackground, buttons])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(13, after: iconBackground)
        stack.setCustomSpacing(16, after: statusBackground)
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -30),
            stack.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            iconBackground.widthAnchor.constraint(equalToConstant: 48),
            iconBackground.heightAnchor.constraint(equalToConstant: 48),
            icon.centerXAnchor.constraint(equalTo: iconBackground.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBackground.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            statusBackground.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusBackground.heightAnchor.constraint(equalToConstant: 34),
            status.leadingAnchor.constraint(equalTo: statusBackground.leadingAnchor, constant: 14),
            status.trailingAnchor.constraint(equalTo: statusBackground.trailingAnchor, constant: -14),
            status.centerYAnchor.constraint(equalTo: statusBackground.centerYAnchor),
            reconnectButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 126),
            pauseButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 126)
        ])

        card.onEffectiveAppearanceChange = { [weak card, weak iconBackground, weak icon,
                                              weak title, weak subtitle, weak status,
                                              weak statusBackground, weak pauseButton] appearance in
            let palette = AxisVeilPalette(appearance: appearance)
            card?.material = palette.cardMaterial
            card?.layer?.backgroundColor = palette.cardFillColor
            card?.layer?.borderColor = palette.cardBorderColor
            card?.layer?.shadowOpacity = palette.cardShadowOpacity
            iconBackground?.layer?.backgroundColor = (palette.isDark
                ? NSColor.white.withAlphaComponent(0.10)
                : NSColor(calibratedRed: 0.08, green: 0.34, blue: 0.72, alpha: 0.10)).cgColor
            icon?.contentTintColor = palette.cardIconColor
            title?.textColor = palette.cardTitleColor
            subtitle?.textColor = palette.cardBodyColor
            status?.textColor = palette.cardSecondaryColor
            statusBackground?.layer?.backgroundColor = (palette.isDark
                ? NSColor.white.withAlphaComponent(0.075)
                : NSColor.black.withAlphaComponent(0.05)).cgColor
            pauseButton?.contentTintColor = palette.cardTitleColor
        }
        card.applyCurrentAppearance()

        return card
    }

    @objc private func reconnectTapped() {
        onReconnect?()
    }

    @objc private func pauseTapped() {
        onPause?()
    }
}

/// 将 NSApp 继承下来的深浅色变化同步给自定义 CALayer 和固定颜色文字。
private final class AppearanceObservingEffectView: NSVisualEffectView {
    var onEffectiveAppearanceChange: ((NSAppearance) -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyCurrentAppearance()
    }

    func applyCurrentAppearance() {
        onEffectiveAppearanceChange?(effectiveAppearance)
    }
}

/// 面板尚未成为 key window 时，第一次点击也能直接触发按钮。
private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
