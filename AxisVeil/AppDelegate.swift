import AppKit

/// 菜单栏应用入口：连接头部追踪器与全屏模糊遮罩。
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let tracker = AirPodsHeadTracker()
    private let overlayController = BlurOverlayController()
    private let audioKeepAlive = HeadphoneAudioKeepAlive()

    private var statusItem: NSStatusItem!
    private var stateMenuItem: NSMenuItem!
    private var poseMenuItem: NSMenuItem!
    private var pauseMenuItem: NSMenuItem!
    private var centerAngleControl: MenuSliderView!
    private var clearRangeControl: MenuSliderView!
    private var pitchRangeControl: MenuSliderView!
    private var blurModeMenuItems: [NSMenuItem] = []
    private var halfScreenSideMenuItems: [NSMenuItem] = []

    private var detectedFacingScreen = true
    private var trackingPaused = false
    /// 耳机确认掉线后，屏幕会在无法检测朝向的情况下保持全屏模糊。
    private var airpodsDisconnected = false
    private let reconnectPrompt = ReconnectPromptController()
    private var lastPoseMenuUpdate = Date.distantPast
    private var currentYawDegrees = 0.0
    private var currentPitchDegrees = 0.0
    private var currentBlurProgress = 0.0
    private var yawCenterOffsetDegrees = 0.0
    private var clearYawRangeDegrees = 60.0
    private var clearPitchRangeDegrees = 40.0
    private var blurMode = BlurMode.halfScreen
    private var halfScreenSide = HalfScreenSide.same
    private enum PreferenceKey {
        static let yawCenterOffsetDegrees = "yawCenterOffsetDegrees"
        static let clearYawRangeDegrees = "clearYawRangeDegrees"
        static let clearPitchRangeDegrees = "clearPitchRangeDegrees"
        static let blurMode = "blurMode"
        static let halfScreenSide = "halfScreenSide"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadTrackingPreferences()
        tracker.setYawCenterOffsetDegrees(yawCenterOffsetDegrees)
        tracker.setClearYawRangeDegrees(clearYawRangeDegrees)
        tracker.setClearPitchRangeDegrees(clearPitchRangeDegrees)
        overlayController.blurMode = blurMode
        overlayController.halfScreenSide = halfScreenSide
        configureStatusMenu()
        bindTracker()
        audioKeepAlive.start()
        tracker.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        tracker.stop()
        audioKeepAlive.stop()
        overlayController.setBlurred(false, animated: false)
    }

    private func configureStatusMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()

        let menu = NSMenu()
        menu.delegate = self

        let versionItem = NSMenuItem(title: versionDescription, action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        stateMenuItem = NSMenuItem(title: "正在启动…", action: nil, keyEquivalent: "")
        stateMenuItem.isEnabled = false
        menu.addItem(stateMenuItem)

        poseMenuItem = NSMenuItem(title: "偏转：--", action: nil, keyEquivalent: "")
        poseMenuItem.isEnabled = false
        menu.addItem(poseMenuItem)
        menu.addItem(.separator())

        centerAngleControl = MenuSliderView(
            title: "校准中心角度",
            minimumValue: -30,
            maximumValue: 30,
            step: 1,
            value: yawCenterOffsetDegrees,
            valueText: Self.centerAngleText
        )
        centerAngleControl.onValueChanged = { [weak self] value in
            self?.setYawCenterOffsetDegrees(value)
        }
        let centerAngleItem = NSMenuItem()
        centerAngleItem.view = centerAngleControl
        menu.addItem(centerAngleItem)

        clearRangeControl = MenuSliderView(
            title: "左右清晰范围（总宽）",
            minimumValue: 30,
            maximumValue: 120,
            step: 2,
            value: clearYawRangeDegrees,
            valueText: { String(format: "%.0f°", $0) }
        )
        clearRangeControl.onValueChanged = { [weak self] value in
            self?.setClearYawRangeDegrees(value)
        }
        let clearRangeItem = NSMenuItem()
        clearRangeItem.view = clearRangeControl
        menu.addItem(clearRangeItem)

        pitchRangeControl = MenuSliderView(
            title: "上下清晰范围（总高）",
            minimumValue: 20,
            maximumValue: 80,
            step: 2,
            value: clearPitchRangeDegrees,
            valueText: { String(format: "%.0f°", $0) }
        )
        pitchRangeControl.onValueChanged = { [weak self] value in
            self?.setClearPitchRangeDegrees(value)
        }
        let pitchRangeItem = NSMenuItem()
        pitchRangeItem.view = pitchRangeControl
        menu.addItem(pitchRangeItem)

        menu.addItem(makeBlurModeMenuItem())
        menu.addItem(makeHalfScreenSideMenuItem())
        menu.addItem(.separator())

        let calibrateItem = NSMenuItem(
            title: "以当前朝向校准",
            action: #selector(calibrate),
            keyEquivalent: "r"
        )
        calibrateItem.target = self
        menu.addItem(calibrateItem)

        pauseMenuItem = NSMenuItem(
            title: "暂停检测",
            action: #selector(togglePause),
            keyEquivalent: "p"
        )
        pauseMenuItem.target = self
        menu.addItem(pauseMenuItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 AxisVeil", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    /// “模糊区域”子菜单：半屏方向遮罩或全屏模糊。
    private func makeBlurModeMenuItem() -> NSMenuItem {
        let modeItem = NSMenuItem(title: "模糊区域", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()

        for mode in BlurMode.allCases {
            let item = NSMenuItem(
                title: mode.menuTitle,
                action: #selector(selectBlurMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode == blurMode ? .on : .off
            modeMenu.addItem(item)
            blurModeMenuItems.append(item)
        }

        modeItem.submenu = modeMenu
        return modeItem
    }

    /// “半屏遮挡方向”子菜单：转头方向与遮挡侧的对应关系。
    private func makeHalfScreenSideMenuItem() -> NSMenuItem {
        let sideItem = NSMenuItem(title: "半屏遮挡方向", action: nil, keyEquivalent: "")
        let sideMenu = NSMenu()

        for side in HalfScreenSide.allCases {
            let item = NSMenuItem(
                title: side.menuTitle,
                action: #selector(selectHalfScreenSide(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = side.rawValue
            item.state = side == halfScreenSide ? .on : .off
            sideMenu.addItem(item)
            halfScreenSideMenuItems.append(item)
        }

        sideItem.submenu = sideMenu
        return sideItem
    }

    private func bindTracker() {
        tracker.onFacingChanged = { [weak self] isFacing in
            guard let self else { return }
            self.detectedFacingScreen = isFacing
            self.updateStatusIcon()
        }

        tracker.onStatusChanged = { [weak self] message in
            self?.stateMenuItem.title = message
        }

        tracker.onPoseChanged = { [weak self] yaw, pitch in
            guard let self else { return }

            self.currentYawDegrees = yaw
            self.currentPitchDegrees = pitch
            self.currentBlurProgress = self.tracker.blurProgress(
                forYawDegrees: yaw,
                pitchDegrees: pitch
            )
            self.applyPrivacyState()

            // 菜单文字不需要跟随 60 Hz 的传感器频率刷新，10 Hz 足够流畅。
            let now = Date()
            guard now.timeIntervalSince(self.lastPoseMenuUpdate) >= 0.1 else { return }
            self.lastPoseMenuUpdate = now
            self.poseMenuItem.title = String(format: "偏转：左右 %+.1f°  上下 %+.1f°", yaw, pitch)
        }

        tracker.onMotionStreamStalled = { [weak self] in
            self?.audioKeepAlive.restart()
        }

        tracker.onDeviceDisconnected = { [weak self] in
            self?.handleHeadphoneDisconnected()
        }

        tracker.onDeviceReconnected = { [weak self] in
            self?.handleHeadphoneReconnected()
        }

        tracker.onReconnectStatusChanged = { [weak self] message in
            guard let self else { return }
            self.reconnectPrompt.setStatus(message)
            self.stateMenuItem.title = message
        }
    }

    /// 耳机确认掉线：立刻整屏模糊兜底，并提示重连或暂停检测。
    private func handleHeadphoneDisconnected() {
        guard !trackingPaused else { return }

        airpodsDisconnected = true
        reconnectPrompt.onReconnect = { [weak self] in
            self?.tracker.beginReconnect()
        }
        reconnectPrompt.onPause = { [weak self] in
            self?.pauseAfterDisconnect()
        }
        // 遮罩提示卡同步说明断联原因，与上方的重连卡片形成双保险。
        overlayController.setMessage(OverlayMessage(
            title: "AirPods 已断开",
            subtitle: "屏幕已全屏模糊 · 请在提示卡中选择重新连接或暂停"
        ))
        reconnectPrompt.show()
        stateMenuItem.title = "AirPods 已断开 · 屏幕已模糊保护"
        applyPrivacyState(animated: true)
    }

    /// 重新收到姿态数据：退出兜底模糊、收起提示，并恢复常规检测。
    private func handleHeadphoneReconnected() {
        guard airpodsDisconnected || reconnectPrompt.isPresenting else { return }

        airpodsDisconnected = false
        reconnectPrompt.dismiss()
        overlayController.setMessage(.privacy)
        applyPrivacyState(animated: true)
    }

    /// 断联状态下选择“暂停检测”：停止追踪并移除遮罩。
    private func pauseAfterDisconnect() {
        if trackingPaused {
            reconnectPrompt.dismiss()
            airpodsDisconnected = false
            overlayController.setMessage(.privacy)
            applyPrivacyState(animated: true)
        } else {
            togglePause()
        }
    }

    private func applyPrivacyState(animated: Bool = false) {
        let displayProgress: Double
        if trackingPaused {
            displayProgress = 0
        } else if airpodsDisconnected {
            // 断联时无法判断朝向，直接整屏模糊兜底。
            displayProgress = 1
        } else {
            displayProgress = currentBlurProgress
        }

        overlayController.updatePose(
            direction: overlayDirection(),
            blurProgress: displayProgress,
            animated: animated
        )
        updateStatusIcon()
    }

    /// 当前遮罩方向。断联时没有姿态可依据，只能整屏覆盖。
    private func overlayDirection() -> BlurDirection {
        if trackingPaused || airpodsDisconnected { return .none }
        return tracker.blurDirection(
            forYawDegrees: currentYawDegrees,
            pitchDegrees: currentPitchDegrees
        )
    }

    private func updateStatusIcon() {
        let isBlurred = !trackingPaused
            && (airpodsDisconnected || !detectedFacingScreen || currentBlurProgress > 0.04)
        let symbolName = isBlurred ? "eye.slash.fill" : "eye.fill"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "AxisVeil")
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = isBlurred ? "AxisVeil：屏幕已模糊" : "AxisVeil：屏幕清晰"
    }

    private func loadTrackingPreferences() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: PreferenceKey.yawCenterOffsetDegrees) != nil {
            yawCenterOffsetDegrees = min(max(
                defaults.double(forKey: PreferenceKey.yawCenterOffsetDegrees),
                -30
            ), 30)
        }
        if defaults.object(forKey: PreferenceKey.clearYawRangeDegrees) != nil {
            clearYawRangeDegrees = min(max(
                defaults.double(forKey: PreferenceKey.clearYawRangeDegrees),
                30
            ), 120)
        }
        if defaults.object(forKey: PreferenceKey.clearPitchRangeDegrees) != nil {
            clearPitchRangeDegrees = min(max(
                defaults.double(forKey: PreferenceKey.clearPitchRangeDegrees),
                20
            ), 80)
        }
        if let rawValue = defaults.string(forKey: PreferenceKey.blurMode),
           let storedMode = BlurMode(rawValue: rawValue) {
            blurMode = storedMode
        }
        if let rawValue = defaults.string(forKey: PreferenceKey.halfScreenSide),
           let storedSide = HalfScreenSide(rawValue: rawValue) {
            halfScreenSide = storedSide
        }
    }

    private func setYawCenterOffsetDegrees(_ degrees: Double) {
        yawCenterOffsetDegrees = degrees
        tracker.setYawCenterOffsetDegrees(degrees)
        UserDefaults.standard.set(degrees, forKey: PreferenceKey.yawCenterOffsetDegrees)
    }

    private func setClearYawRangeDegrees(_ degrees: Double) {
        clearYawRangeDegrees = degrees
        tracker.setClearYawRangeDegrees(degrees)
        UserDefaults.standard.set(degrees, forKey: PreferenceKey.clearYawRangeDegrees)
    }

    private func setClearPitchRangeDegrees(_ degrees: Double) {
        clearPitchRangeDegrees = degrees
        tracker.setClearPitchRangeDegrees(degrees)
        UserDefaults.standard.set(degrees, forKey: PreferenceKey.clearPitchRangeDegrees)
    }

    private func setBlurMode(_ mode: BlurMode) {
        blurMode = mode
        overlayController.blurMode = mode
        blurModeMenuItems.forEach {
            $0.state = ($0.representedObject as? String) == mode.rawValue ? .on : .off
        }
        UserDefaults.standard.set(mode.rawValue, forKey: PreferenceKey.blurMode)
    }

    @objc private func selectBlurMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = BlurMode(rawValue: rawValue) else { return }
        setBlurMode(mode)
    }

    private func setHalfScreenSide(_ side: HalfScreenSide) {
        halfScreenSide = side
        overlayController.halfScreenSide = side
        halfScreenSideMenuItems.forEach {
            $0.state = ($0.representedObject as? String) == side.rawValue ? .on : .off
        }
        UserDefaults.standard.set(side.rawValue, forKey: PreferenceKey.halfScreenSide)
    }

    @objc private func selectHalfScreenSide(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let side = HalfScreenSide(rawValue: rawValue) else { return }
        setHalfScreenSide(side)
    }

    private static func centerAngleText(_ value: Double) -> String {
        if abs(value) < 0.5 { return "0°" }
        return value < 0
            ? String(format: "向左 %.0f°", abs(value))
            : String(format: "向右 %.0f°", value)
    }

    @objc private func calibrate() {
        yawCenterOffsetDegrees = 0
        centerAngleControl.setValue(0)
        tracker.setYawCenterOffsetDegrees(0)
        UserDefaults.standard.set(0, forKey: PreferenceKey.yawCenterOffsetDegrees)
        tracker.calibrateToCurrentPose()
        detectedFacingScreen = true
        currentYawDegrees = 0
        currentPitchDegrees = 0
        currentBlurProgress = 0
        applyPrivacyState(animated: true)
    }

    @objc private func togglePause() {
        trackingPaused.toggle()

        if trackingPaused {
            tracker.stop()
            audioKeepAlive.stop()
            pauseMenuItem.title = "继续检测"
            stateMenuItem.title = "检测已暂停"
            // 暂停即退出断联兜底状态。
            airpodsDisconnected = false
            reconnectPrompt.dismiss()
            overlayController.setMessage(.privacy)
        } else {
            pauseMenuItem.title = "暂停检测"
            detectedFacingScreen = true
            currentYawDegrees = 0
            currentPitchDegrees = 0
            currentBlurProgress = 0
            audioKeepAlive.start()
            tracker.start()
        }

        applyPrivacyState(animated: true)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    /// 菜单打开时临时隐藏遮罩，保证屏幕已模糊时也能看清并操作菜单。
    func menuWillOpen(_ menu: NSMenu) {
        overlayController.isSuppressed = true
    }

    func menuDidClose(_ menu: NSMenu) {
        overlayController.isSuppressed = false
    }

    /// 菜单里显示版本号，便于确认当前运行的是哪个构建。
    private var versionDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "开发版"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "AxisVeil \(version) · build \(build)"
    }
}

/// 菜单中的紧凑滑杆，拖动时保持菜单打开并实时应用设置。
private final class MenuSliderView: NSView {
    var onValueChanged: ((Double) -> Void)?

    private let slider: NSSlider
    private let valueLabel = NSTextField(labelWithString: "")
    private let step: Double
    private let valueText: (Double) -> String

    init(
        title: String,
        minimumValue: Double,
        maximumValue: Double,
        step: Double,
        value: Double,
        valueText: @escaping (Double) -> String
    ) {
        self.step = step
        self.valueText = valueText
        slider = NSSlider(
            value: value,
            minValue: minimumValue,
            maxValue: maximumValue,
            target: nil,
            action: nil
        )
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 64))

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)

        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right

        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.controlSize = .small
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.setAccessibilityLabel(title)

        addSubview(titleLabel)
        addSubview(valueLabel)
        addSubview(slider)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            valueLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            slider.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4)
        ])
        setValue(value)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setValue(_ value: Double) {
        slider.doubleValue = value
        valueLabel.stringValue = valueText(value)
    }

    @objc private func sliderChanged() {
        let snappedValue = (slider.doubleValue / step).rounded() * step
        setValue(snappedValue)
        onValueChanged?(snappedValue)
    }
}
