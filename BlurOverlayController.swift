import AppKit
import QuartzCore

/// 模糊覆盖范围，可在菜单栏切换。
enum BlurMode: String, CaseIterable {
    /// 半屏：只模糊偏转方向对应的那一侧，另一侧保持清晰。
    case halfScreen
    /// 全屏：整块屏幕一起模糊。
    case fullScreen

    var menuTitle: String {
        switch self {
        case .halfScreen: return "半屏（跟随转头方向）"
        case .fullScreen: return "全屏"
        }
    }
}

/// 半屏模式下“转头方向”与“遮挡哪一侧”的对应关系。
enum HalfScreenSide: String, CaseIterable {
    /// 同侧：往左看时遮挡左边。
    case same
    /// 对侧：往左看时遮挡右边。
    case opposite

    var menuTitle: String {
        switch self {
        case .same: return "同侧（往左看遮挡左边）"
        case .opposite: return "对侧（往左看遮挡右边）"
        }
    }
}

/// 遮罩中央提示卡的文案。
struct OverlayMessage {
    let title: String
    let subtitle: String

    /// 正常的隐私遮挡提示。
    static let privacy = OverlayMessage(
        title: "内容已自动隐藏",
        subtitle: "重新看向 Mac 即可恢复清晰"
    )
}

/// 所有遮罩与浮层共用的外观颜色，保证切换系统深浅色模式时文字和玻璃色调同步变化。
struct AxisVeilPalette {
    let isDark: Bool

    init(appearance: NSAppearance) {
        isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    var overlayGradientColors: [CGColor] {
        if isDark {
            return [
                NSColor(calibratedRed: 0.01, green: 0.02, blue: 0.06, alpha: 0.62).cgColor,
                NSColor(calibratedRed: 0.08, green: 0.22, blue: 0.43, alpha: 0.42).cgColor,
                NSColor(calibratedRed: 0.01, green: 0.01, blue: 0.04, alpha: 0.66).cgColor
            ]
        }
        return [
            NSColor(calibratedRed: 0.91, green: 0.96, blue: 1.00, alpha: 0.66).cgColor,
            NSColor(calibratedRed: 0.55, green: 0.73, blue: 0.96, alpha: 0.40).cgColor,
            NSColor(calibratedRed: 0.88, green: 0.93, blue: 1.00, alpha: 0.62).cgColor
        ]
    }

    var topSheenColors: [CGColor] {
        if isDark {
            return [
                NSColor.white.withAlphaComponent(0.13).cgColor,
                NSColor.white.withAlphaComponent(0.035).cgColor,
                NSColor.clear.cgColor
            ]
        }
        return [
            NSColor.white.withAlphaComponent(0.34).cgColor,
            NSColor.white.withAlphaComponent(0.10).cgColor,
            NSColor.clear.cgColor
        ]
    }

    var edgeGlowColors: [CGColor] {
        let edgeColor = isDark
            ? NSColor.white.withAlphaComponent(0.16)
            : NSColor(calibratedRed: 0.72, green: 0.84, blue: 1.00, alpha: 0.30)
        return [
            NSColor.clear.cgColor,
            NSColor.clear.cgColor,
            edgeColor.withAlphaComponent(edgeColor.alphaComponent * 0.34).cgColor,
            edgeColor.cgColor
        ]
    }

    var cardMaterial: NSVisualEffectView.Material { isDark ? .hudWindow : .popover }
    var cardFillColor: CGColor {
        (isDark
            ? NSColor(calibratedWhite: 0.035, alpha: 0.48)
            : NSColor(calibratedWhite: 1.0, alpha: 0.62)).cgColor
    }
    var cardBorderColor: CGColor {
        (isDark
            ? NSColor.white.withAlphaComponent(0.26)
            : NSColor.white.withAlphaComponent(0.92)).cgColor
    }
    var cardTitleColor: NSColor {
        isDark
            ? NSColor(calibratedWhite: 1.0, alpha: 0.98)
            : NSColor(calibratedWhite: 0.06, alpha: 0.96)
    }
    var cardBodyColor: NSColor {
        isDark
            ? NSColor(calibratedWhite: 1.0, alpha: 0.88)
            : NSColor(calibratedWhite: 0.10, alpha: 0.82)
    }
    var cardSecondaryColor: NSColor {
        isDark
            ? NSColor(calibratedWhite: 1.0, alpha: 0.74)
            : NSColor(calibratedWhite: 0.16, alpha: 0.68)
    }
    var cardIconColor: NSColor {
        isDark
            ? NSColor(calibratedRed: 0.75, green: 0.87, blue: 1.0, alpha: 1)
            : NSColor(calibratedRed: 0.08, green: 0.34, blue: 0.72, alpha: 1)
    }
    var cardShadowOpacity: Float { isDark ? 0.42 : 0.20 }
}

/// 管理每块显示器上的系统毛玻璃遮罩。
final class BlurOverlayController: NSObject {
    private var panels: [NSPanel] = []
    private var overlayVisuals: [OverlayVisuals] = []
    private var displayProgress: CGFloat = 0
    private var lastDirection: BlurDirection = .none
    private var transitionID = 0
    private var messageText: OverlayMessage? = .privacy

    /// 遮罩中央提示卡的文案；传 nil 表示不显示提示卡
    /// （例如耳机断开时，改由重连卡片承担提示）。
    func setMessage(_ message: OverlayMessage?) {
        messageText = message
        refreshVisuals()
    }

    /// 切换覆盖范围后立即刷新已有遮罩，无需等待下一帧姿态数据。
    var blurMode: BlurMode = .halfScreen {
        didSet {
            guard blurMode != oldValue else { return }
            refreshVisuals()
        }
    }

    /// 半屏模式下“转头方向”与“遮挡哪一侧”的对应关系。
    var halfScreenSide: HalfScreenSide = .same {
        didSet {
            guard halfScreenSide != oldValue else { return }
            refreshVisuals()
        }
    }

    /// 菜单等需要临时看清屏幕的界面打开时抑制遮罩，关闭后自动恢复。
    var isSuppressed = false {
        didSet {
            guard isSuppressed != oldValue else { return }
            if isSuppressed {
                panels.forEach {
                    $0.alphaValue = 0
                    $0.orderOut(nil)
                }
            } else if displayProgress > 0.001 {
                panels.forEach {
                    $0.alphaValue = 1
                    $0.orderFrontRegardless()
                }
            }
        }
    }

    override init() {
        super.init()
        rebuildPanels()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func setBlurred(_ blurred: Bool, animated: Bool) {
        setBlurProgress(blurred ? 1 : 0, animated: animated)
    }

    func updatePose(
        direction: BlurDirection,
        blurProgress: Double,
        animated: Bool = false
    ) {
        lastDirection = direction
        setBlurProgress(blurProgress, animated: animated)
    }

    /// 用当前保存的姿态、方向与模式重绘所有遮罩层。
    private func refreshVisuals() {
        let direction = mappedDirection(lastDirection)
        overlayVisuals.forEach {
            $0.update(progress: displayProgress, direction: direction, mode: blurMode)
        }
    }

    /// 对侧模式下把遮挡方向翻到转头的相反一侧。
    private func mappedDirection(_ direction: BlurDirection) -> BlurDirection {
        guard halfScreenSide == .opposite else { return direction }
        switch direction {
        case .left: return .right
        case .right: return .left
        case .top: return .bottom
        case .bottom: return .top
        case .none: return .none
        }
    }

    private func setBlurProgress(_ progress: Double, animated: Bool) {
        let targetProgress = CGFloat(min(max(progress, 0), 1))
        guard abs(targetProgress - displayProgress) > 0.001 else {
            refreshVisuals()
            return
        }

        displayProgress = targetProgress
        transitionID += 1
        let currentTransition = transitionID

        // 菜单等界面正在展示：只更新图层状态，不显示遮罩窗口。
        guard !isSuppressed else {
            refreshVisuals()
            return
        }

        if targetProgress > 0.001 {
            for panel in panels {
                if panel.alphaValue <= 0.001 {
                    panel.alphaValue = animated ? 0 : 1
                }
                panel.orderFrontRegardless()
            }

            refreshVisuals()

            guard animated else {
                panels.forEach { $0.alphaValue = 1 }
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.panels.forEach { $0.animator().alphaValue = 1 }
            }
        } else {
            guard animated else {
                refreshVisuals()
                panels.forEach {
                    $0.alphaValue = 0
                    $0.orderOut(nil)
                }
                return
            }

            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.panels.forEach { $0.animator().alphaValue = 0 }
            }, completionHandler: { [weak self] in
                guard let self,
                      self.transitionID == currentTransition,
                      self.displayProgress <= 0.001 else { return }
                self.refreshVisuals()
                self.panels.forEach { $0.orderOut(nil) }
            })
        }
    }

    @objc private func screenConfigurationDidChange() {
        rebuildPanels()
    }

    private func rebuildPanels() {
        panels.forEach { $0.orderOut(nil) }
        overlayVisuals.removeAll()
        panels.removeAll()

        for screen in NSScreen.screens {
            let result = makePanel(for: screen)
            panels.append(result.panel)
            overlayVisuals.append(result.visuals)
        }

        refreshVisuals()

        if displayProgress > 0.001 {
            panels.forEach {
                $0.alphaValue = 1
                $0.orderFrontRegardless()
            }
        }
    }

    private func makePanel(for screen: NSScreen) -> (panel: NSPanel, visuals: OverlayVisuals) {
        let panel = PrivacyPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )

        panel.setFrame(screen.frame, display: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false

        let root = AppearanceObservingView(frame: NSRect(origin: .zero, size: screen.frame.size))
        root.wantsLayer = true

        // 两层系统原生背景毛玻璃按进度交叉增强，不截取屏幕内容。
        let softBlurView = makeBlurView(frame: root.bounds, material: .underWindowBackground)
        root.addSubview(softBlurView)

        let strongBlurView = makeBlurView(frame: root.bounds, material: .fullScreenUI)
        root.addSubview(strongBlurView)

        // iPhone Duo 风格的冷色渐变 + 液态玻璃的顶部柔光与边缘光晕。
        let tintView = NSView(frame: root.bounds)
        tintView.autoresizingMask = [.width, .height]
        tintView.wantsLayer = true
        let gradient = CAGradientLayer()
        gradient.frame = tintView.bounds
        gradient.locations = [0, 0.48, 1]
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        tintView.layer?.addSublayer(gradient)

        // 液态玻璃的顶部反光：大范围柔和白光向下淡出，不是一条线。
        let topSheen = CAGradientLayer()
        topSheen.frame = tintView.bounds
        topSheen.locations = [0, 0.42, 0.88]
        topSheen.startPoint = CGPoint(x: 0.5, y: 1)
        topSheen.endPoint = CGPoint(x: 0.5, y: 0)
        tintView.layer?.addSublayer(topSheen)

        // 液态玻璃的边缘光晕：中心透明、四周泛白，形成一整块玻璃覆在屏幕上的观感。
        let edgeGlow = CAGradientLayer()
        edgeGlow.type = .radial
        edgeGlow.frame = tintView.bounds
        edgeGlow.locations = [0, 0.5, 0.83, 1]
        edgeGlow.startPoint = CGPoint(x: 0.5, y: 0.5)
        edgeGlow.endPoint = CGPoint(x: 1, y: 1)
        tintView.layer?.addSublayer(edgeGlow)
        root.addSubview(tintView)

        // 每层使用独立遮罩；同一 CALayer 不能同时作为多个图层的 mask。
        let softBlurMask = makeDirectionalMask(frame: root.bounds)
        let strongBlurMask = makeDirectionalMask(frame: root.bounds)
        let tintMask = makeDirectionalMask(frame: root.bounds)
        softBlurView.layer?.mask = softBlurMask
        strongBlurView.layer?.mask = strongBlurMask
        tintView.layer?.mask = tintMask

        let messageCard = MessageCard()
        root.addSubview(CenteredOverlayContainer(card: messageCard))
        panel.contentView = root

        let visuals = OverlayVisuals(
            softBlurView: softBlurView,
            strongBlurView: strongBlurView,
            tintView: tintView,
            gradient: gradient,
            topSheen: topSheen,
            edgeGlow: edgeGlow,
            messageCard: messageCard,
            softBlurMask: softBlurMask,
            strongBlurMask: strongBlurMask,
            tintMask: tintMask,
            screenSize: screen.frame.size
        )
        visuals.setMessage(messageText)
        root.onEffectiveAppearanceChange = { [weak visuals] appearance in
            visuals?.updateAppearance(appearance)
        }
        visuals.updateAppearance(root.effectiveAppearance)
        return (panel, visuals)
    }

    private func makeBlurView(
        frame: NSRect,
        material: NSVisualEffectView.Material
    ) -> NSVisualEffectView {
        let blurView = NSVisualEffectView(frame: frame)
        blurView.autoresizingMask = [.width, .height]
        blurView.wantsLayer = true
        blurView.material = material
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        blurView.alphaValue = 0
        return blurView
    }

    private func makeDirectionalMask(frame: NSRect) -> CAGradientLayer {
        let mask = CAGradientLayer()
        mask.frame = frame
        mask.colors = [NSColor.white.cgColor, NSColor.white.cgColor]
        mask.locations = [0, 1]
        return mask
    }
}

/// 遮罩中央的玻璃提示卡，文案可随状态切换；不需要时整卡隐藏。
private final class MessageCard: NSVisualEffectView {
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 28
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowRadius = 24
        layer?.shadowOffset = CGSize(width: 0, height: -8)

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "eye.slash.fill", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 30, weight: .semibold)

        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.alignment = .center
        titleLabel.cell?.usesSingleLineMode = true

        subtitleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        subtitleLabel.alignment = .center
        subtitleLabel.cell?.usesSingleLineMode = true

        let stack = NSStackView(views: [icon, titleLabel, subtitleLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(14, after: icon)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 25),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -25),
            icon.widthAnchor.constraint(equalToConstant: 36),
            icon.heightAnchor.constraint(equalToConstant: 36)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setText(title: String, subtitle: String) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
    }

    func applyAppearance(_ appearance: NSAppearance) {
        let palette = AxisVeilPalette(appearance: appearance)
        material = palette.cardMaterial
        layer?.backgroundColor = palette.cardFillColor
        layer?.borderColor = palette.cardBorderColor
        layer?.shadowOpacity = palette.cardShadowOpacity
        icon.contentTintColor = palette.cardIconColor
        titleLabel.textColor = palette.cardTitleColor
        subtitleLabel.textColor = palette.cardBodyColor
    }
}

/// 保存遮罩的可调视觉层，并根据偏转方向与进度更新覆盖区域。
private final class OverlayVisuals {
    private let softBlurView: NSVisualEffectView
    private let strongBlurView: NSVisualEffectView
    private let tintView: NSView
    private let gradient: CAGradientLayer
    private let topSheen: CAGradientLayer
    private let edgeGlow: CAGradientLayer
    private let messageCard: MessageCard
    private let softBlurMask: CAGradientLayer
    private let strongBlurMask: CAGradientLayer
    private let tintMask: CAGradientLayer
    private let screenSize: CGSize
    /// nil 表示当前状态不需要提示卡（由重连卡片等其它界面承担提示）。
    private var message: OverlayMessage?

    /// 半屏模式下模糊区域占屏幕的比例：刚越界时约 42%，完全模糊时约 62%。
    private let initialCoverage: CGFloat = 0.42
    private let fullCoverage: CGFloat = 0.62
    /// 三层各自的过渡带宽度。宽度互不相同、叠在一起才形成连续的强度梯度，
    /// 单层都不会留下可见的边界线。
    private let softBlurFeather: CGFloat = 0.34
    private let strongBlurFeather: CGFloat = 0.22
    private let tintFeather: CGFloat = 0.30

    init(
        softBlurView: NSVisualEffectView,
        strongBlurView: NSVisualEffectView,
        tintView: NSView,
        gradient: CAGradientLayer,
        topSheen: CAGradientLayer,
        edgeGlow: CAGradientLayer,
        messageCard: MessageCard,
        softBlurMask: CAGradientLayer,
        strongBlurMask: CAGradientLayer,
        tintMask: CAGradientLayer,
        screenSize: CGSize
    ) {
        self.softBlurView = softBlurView
        self.strongBlurView = strongBlurView
        self.tintView = tintView
        self.gradient = gradient
        self.topSheen = topSheen
        self.edgeGlow = edgeGlow
        self.messageCard = messageCard
        self.softBlurMask = softBlurMask
        self.strongBlurMask = strongBlurMask
        self.tintMask = tintMask
        self.screenSize = screenSize
        messageCard.wantsLayer = true
    }

    /// 设置提示卡文案；nil 表示当前状态不需要提示卡。
    func setMessage(_ message: OverlayMessage?) {
        self.message = message
        guard let message else { return }
        messageCard.setText(title: message.title, subtitle: message.subtitle)
    }

    /// CALayer 不会自动解析动态系统色，因此在外观变化时显式刷新渐变和卡片配色。
    func updateAppearance(_ appearance: NSAppearance) {
        let palette = AxisVeilPalette(appearance: appearance)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.colors = palette.overlayGradientColors
        topSheen.colors = palette.topSheenColors
        edgeGlow.colors = palette.edgeGlowColors
        messageCard.applyAppearance(appearance)
        CATransaction.commit()
    }

    func update(progress: CGFloat, direction: BlurDirection, mode: BlurMode) {
        let progress = min(max(progress, 0), 1)
        // 全屏模式整块屏幕一起模糊；没有明确方向时同样退化为整屏覆盖。
        let coversWholeScreen = mode == .fullScreen || direction == .none
        // 模糊区域随偏转进度从屏幕边缘向内扩展，转头越多遮挡越多。
        let coverage = initialCoverage + (fullCoverage - initialCoverage) * progress

        // 在传感器的连续更新中关闭 Core Animation 隐式动画，避免拖尾和延迟。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateMasks(coverage: coverage, direction: direction, coversWholeScreen: coversWholeScreen)
        updateGlass(progress: progress, direction: direction, coversWholeScreen: coversWholeScreen)
        CATransaction.commit()

        // 低角度先出现轻柔毛玻璃，较大角度再叠加强层，视觉强度连续增长。
        softBlurView.alphaValue = min(1, progress * 1.6)
        strongBlurView.alphaValue = smoothstep(remap(progress, from: 0.26, to: 1))
        tintView.alphaValue = pow(progress, 1.15) * 0.92

        // 提示卡只在接近完全模糊时浮现；半屏模式下跟随模糊区域偏移，落在被遮挡的一侧。
        let cardProgress = smoothstep(remap(progress, from: 0.65, to: 1))
        messageCard.alphaValue = message == nil ? 0 : cardProgress
        let cardScale = 0.94 + cardProgress * 0.06
        let cardOffset = cardOffset(for: direction, coversWholeScreen: coversWholeScreen)
        var cardTransform = CATransform3DMakeTranslation(cardOffset.x, cardOffset.y, 0)
        cardTransform = CATransform3DScale(cardTransform, cardScale, cardScale, 1)
        messageCard.layer?.transform = cardTransform
    }

    private func unitVector(for direction: BlurDirection) -> CGVector {
        switch direction {
        case .left: return CGVector(dx: -1, dy: 0)
        case .right: return CGVector(dx: 1, dy: 0)
        case .top: return CGVector(dx: 0, dy: 1)
        case .bottom: return CGVector(dx: 0, dy: -1)
        case .none: return CGVector(dx: 1, dy: 0)
        }
    }

    /// 三层各自用不同宽度的过渡带叠出连续的模糊强度梯度，任何单层都不会留下可见边界。
    private func updateMasks(coverage: CGFloat, direction: BlurDirection, coversWholeScreen: Bool) {
        applyMask(
            softBlurMask,
            coverage: coverage,
            feather: softBlurFeather,
            direction: direction,
            coversWholeScreen: coversWholeScreen
        )
        applyMask(
            strongBlurMask,
            coverage: coverage,
            feather: strongBlurFeather,
            direction: direction,
            coversWholeScreen: coversWholeScreen
        )
        applyMask(
            tintMask,
            coverage: coverage,
            feather: tintFeather,
            direction: direction,
            coversWholeScreen: coversWholeScreen
        )
    }

    /// 遮罩只控制可见范围：模糊从偏转方向那一侧铺开，内边缘用宽过渡带渐隐。
    private func applyMask(
        _ mask: CAGradientLayer,
        coverage: CGFloat,
        feather: CGFloat,
        direction: BlurDirection,
        coversWholeScreen: Bool
    ) {
        let opaque = NSColor.white.cgColor
        let clear = NSColor.clear.cgColor

        // 各边缘位置用同一条渐变轴表示，起点始终是屏幕清晰侧的外缘。
        let edgeFromStart = coverage
        let edgeFromStartFeather = min(coverage + feather, 1)
        let edgeFromEnd = 1 - coverage
        let edgeFromEndFeather = max(1 - coverage - feather, 0)

        var colors: [CGColor]
        var locations: [NSNumber]
        var startPoint = CGPoint(x: 0, y: 0.5)
        var endPoint = CGPoint(x: 1, y: 0.5)

        switch (coversWholeScreen, direction) {
        case (true, _), (false, .none):
            colors = [opaque, opaque]
            locations = [0, 1]
        case (false, .left):
            colors = [opaque, opaque, clear, clear]
            locations = [0, edgeFromStart, edgeFromStartFeather, 1].map { NSNumber(value: Double($0)) }
        case (false, .right):
            colors = [clear, clear, opaque, opaque]
            locations = [0, edgeFromEndFeather, edgeFromEnd, 1].map { NSNumber(value: Double($0)) }
        case (false, .top):
            colors = [clear, clear, opaque, opaque]
            locations = [0, edgeFromEndFeather, edgeFromEnd, 1].map { NSNumber(value: Double($0)) }
            startPoint = CGPoint(x: 0.5, y: 0)
            endPoint = CGPoint(x: 0.5, y: 1)
        case (false, .bottom):
            colors = [opaque, opaque, clear, clear]
            locations = [0, edgeFromStart, edgeFromStartFeather, 1].map { NSNumber(value: Double($0)) }
            startPoint = CGPoint(x: 0.5, y: 0)
            endPoint = CGPoint(x: 0.5, y: 1)
        }

        mask.colors = colors
        mask.locations = locations
        mask.startPoint = startPoint
        mask.endPoint = endPoint
    }

    /// 色调与玻璃质感：全屏时保持整屏均匀，半屏时才让色彩过渡指向偏转侧。
    private func updateGlass(progress: CGFloat, direction: BlurDirection, coversWholeScreen: Bool) {
        if coversWholeScreen {
            // 整屏均匀：固定对角渐变，避免左右明暗差被误读成一条分割。
            gradient.startPoint = CGPoint(x: 0.1, y: 1)
            gradient.endPoint = CGPoint(x: 0.9, y: 0)
        } else {
            let vector = unitVector(for: direction)
            gradient.startPoint = CGPoint(x: 0.5 - vector.dx * 0.5, y: 0.5 - vector.dy * 0.5)
            gradient.endPoint = CGPoint(x: 0.5 + vector.dx * 0.5, y: 0.5 + vector.dy * 0.5)
        }

        // 玻璃反光随进度增强，保留一点“液态”的呼吸感。
        topSheen.opacity = Float(0.5 + 0.5 * progress)
        edgeGlow.opacity = Float(0.45 + 0.55 * progress)
    }

    /// 全屏模式提示卡居中；半屏模式移到被遮挡的一侧，避免压住仍清晰的内容。
    private func cardOffset(for direction: BlurDirection, coversWholeScreen: Bool) -> CGPoint {
        guard !coversWholeScreen else { return .zero }
        switch direction {
        case .left: return CGPoint(x: -screenSize.width * 0.24, y: 0)
        case .right: return CGPoint(x: screenSize.width * 0.24, y: 0)
        case .top: return CGPoint(x: 0, y: screenSize.height * 0.22)
        case .bottom: return CGPoint(x: 0, y: -screenSize.height * 0.22)
        case .none: return .zero
        }
    }

    private func remap(_ value: CGFloat, from lowerBound: CGFloat, to upperBound: CGFloat) -> CGFloat {
        min(max((value - lowerBound) / (upperBound - lowerBound), 0), 1)
    }

    private func smoothstep(_ value: CGFloat) -> CGFloat {
        value * value * (3 - 2 * value)
    }
}

/// 让提示卡始终位于每块屏幕中央。
private final class CenteredOverlayContainer: NSView {
    init(card: NSView) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(greaterThanOrEqualToConstant: 330),
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 176)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let superview else { return }
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: superview.leadingAnchor),
            trailingAnchor.constraint(equalTo: superview.trailingAnchor),
            topAnchor.constraint(equalTo: superview.topAnchor),
            bottomAnchor.constraint(equalTo: superview.bottomAnchor)
        ])
    }
}

/// NSWindow 会自动继承 NSApp 的系统外观；通过视图回调把变化同步到 CALayer 颜色。
private final class AppearanceObservingView: NSView {
    var onEffectiveAppearanceChange: ((NSAppearance) -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChange?(effectiveAppearance)
    }
}

/// 不抢焦点、不进入窗口循环的全屏面板。
private final class PrivacyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
