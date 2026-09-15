import CoreMotion
import Foundation

/// 模糊遮罩覆盖的屏幕方向。半屏模式据此决定从哪一侧先开始模糊。
enum BlurDirection {
    case left
    case right
    case top
    case bottom
    /// 没有明显偏转方向（正对屏幕），此时覆盖整块屏幕。
    case none
}

/// 使用 AirPods 的头部姿态判断用户是否仍在正视校准方向。
final class AirPodsHeadTracker: NSObject, CMHeadphoneMotionManagerDelegate {
    struct Configuration {
        /// 校准中心周围的默认清晰范围。左右各 30°，合计约 60°。
        let clearYawDegrees = 30.0
        let clearPitchDegrees = 20.0

        /// 越过清晰范围后再偏转多少度达到完全模糊，与清晰范围一同生效。
        /// 例如左右清晰范围为每侧 30° 时，偏转 60° 达到最大模糊。
        let fullBlurYawOffsetDegrees = 30.0
        let fullBlurPitchOffsetDegrees = 20.0

        /// 回到略小的范围后更新“正视”状态，避免边界附近反复切换。
        let returnYawDegrees = 27.0
        let returnPitchDegrees = 18.0

        /// 姿态低通滤波强度。越小越稳，越大响应越快。
        let smoothingFactor = 0.22

        /// 姿态持续越界/回正一小段时间才切换，过滤快速扫视和瞬时抖动。
        let transitionDelay: TimeInterval = 0.18

        /// 断开回调后等待这么久仍收不到姿态数据，才确认耳机掉线。
        /// 切换音频路由等瞬时抖动也会触发断开回调，延迟确认可以避免误报。
        let disconnectConfirmDelay: TimeInterval = 1.0

        /// 主动重连时检测耳机是否接入的轮询间隔。
        let reconnectProbeInterval: TimeInterval = 1.5
    }

    var onFacingChanged: ((Bool) -> Void)?
    var onStatusChanged: ((String) -> Void)?
    var onPoseChanged: ((_ yawDegrees: Double, _ pitchDegrees: Double) -> Void)?
    /// macOS 偶尔会在音频路由休眠后停止提供耳机姿态；由上层重启保活音频。
    var onMotionStreamStalled: (() -> Void)?
    /// 防抖确认耳机掉线后触发；上层据此模糊全屏并提示重连。
    var onDeviceDisconnected: (() -> Void)?
    /// 重连后重新收到姿态数据时触发。
    var onDeviceReconnected: (() -> Void)?
    /// 重连检测过程中的进度文案。
    var onReconnectStatusChanged: ((String) -> Void)?

    private let motionManager = CMHeadphoneMotionManager()
    private let configuration = Configuration()

    private var isRunning = false
    private var shouldCalibrateOnNextSample = true
    private var receivedMotionSample = false
    private var noSampleStatusWorkItem: DispatchWorkItem?
    private var restartMotionWorkItem: DispatchWorkItem?
    private var recoveryAttempt = 0
    private var disconnectConfirmWorkItem: DispatchWorkItem?
    private var reconnectProbeWorkItem: DispatchWorkItem?
    private var isAwaitingReconnect = false
    private var reconnectProbeCount = 0

    private var filteredYaw: Double?
    private var filteredPitch: Double?
    private var baselineYaw: Double?
    private var baselinePitch: Double?
    private var yawCenterOffsetDegrees = 0.0
    private var clearYawHalfRangeDegrees = 30.0
    private var clearPitchHalfRangeDegrees = 20.0

    private var facingScreen = true
    private var pendingFacingState: Bool?
    private var pendingStateSince: Date?

    override init() {
        super.init()
        motionManager.delegate = self
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        motionManager.delegate = self
        clearPoseState()
        setFacingScreen(true)

        if motionManager.isDeviceMotionAvailable {
            startMotionUpdates()
        } else {
            onStatusChanged?("等待支持头部追踪的 AirPods…")
        }
    }

    func stop() {
        isRunning = false
        motionManager.stopDeviceMotionUpdates()
        noSampleStatusWorkItem?.cancel()
        noSampleStatusWorkItem = nil
        restartMotionWorkItem?.cancel()
        restartMotionWorkItem = nil
        cancelReconnect()
        pendingFacingState = nil
        pendingStateSince = nil
    }

    /// 将此刻的头部姿态设为“正视屏幕”。如果尚无数据，则在下一帧自动校准。
    func calibrateToCurrentPose() {
        if let filteredYaw, let filteredPitch {
            baselineYaw = filteredYaw
            baselinePitch = filteredPitch
            shouldCalibrateOnNextSample = false
            setFacingScreen(true)
            onPoseChanged?(0, 0)
            onStatusChanged?("已校准 · 正在检测")
        } else {
            shouldCalibrateOnNextSample = true
            onStatusChanged?("等待姿态数据后校准…")
        }
    }

    /// 在已校准方向的基础上微调左右中心；正值向右，负值向左。
    func setYawCenterOffsetDegrees(_ degrees: Double) {
        yawCenterOffsetDegrees = min(max(degrees, -30), 30)
        publishCurrentPoseIfAvailable()
    }

    /// 设置左右清晰范围的总宽度，例如 60 表示中心左右各 30°。
    func setClearYawRangeDegrees(_ degrees: Double) {
        clearYawHalfRangeDegrees = min(max(degrees, 30), 120) / 2
        publishCurrentPoseIfAvailable()
    }

    /// 设置上下清晰范围的总高度，例如 40 表示中心上下各 20°。
    func setClearPitchRangeDegrees(_ degrees: Double) {
        clearPitchHalfRangeDegrees = min(max(degrees, 20), 80) / 2
        publishCurrentPoseIfAvailable()
    }

    /// 将偏转角映射为 0...1 的连续模糊进度，用于让遮罩随转头角度渐变。
    func blurProgress(forYawDegrees yaw: Double, pitchDegrees pitch: Double) -> Double {
        let yawProgress = normalizedOverflow(
            angle: abs(yaw),
            clearUntil: clearYawHalfRangeDegrees,
            fullyBlurredAt: clearYawHalfRangeDegrees + configuration.fullBlurYawOffsetDegrees
        )
        let pitchProgress = normalizedOverflow(
            angle: abs(pitch),
            clearUntil: clearPitchHalfRangeDegrees,
            fullyBlurredAt: clearPitchHalfRangeDegrees + configuration.fullBlurPitchOffsetDegrees
        )
        let normalized = max(yawProgress, pitchProgress)

        // smoothstep：清晰范围内严格为 0，越过边界后缓慢、连续地增强。
        return normalized * normalized * (3 - 2 * normalized)
    }

    /// 当前偏转的主方向。两轴各自用自己的清晰范围归一化后再比较，
    /// 因此左右与上下范围不同宽时，方向判断依然是对称的。
    func blurDirection(forYawDegrees yaw: Double, pitchDegrees pitch: Double) -> BlurDirection {
        let yawWeight = abs(yaw) / max(clearYawHalfRangeDegrees, 0.001)
        let pitchWeight = abs(pitch) / max(clearPitchHalfRangeDegrees, 0.001)
        guard max(yawWeight, pitchWeight) > 0.02 else { return .none }

        if yawWeight >= pitchWeight {
            return yaw < 0 ? .left : .right
        }
        return pitch < 0 ? .top : .bottom
    }

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        guard isRunning else { return }
        // 断连确认期内耳机就回来了，取消掉线判定。
        disconnectConfirmWorkItem?.cancel()
        disconnectConfirmWorkItem = nil
        shouldCalibrateOnNextSample = true
        recoveryAttempt = 0
        onStatusChanged?("AirPods 已连接 · 正在校准…")
        onMotionStreamStalled?()
        startMotionUpdates()
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        guard isRunning else { return }
        motionManager.stopDeviceMotionUpdates()
        clearPoseState()
        setFacingScreen(true)
        onPoseChanged?(0, 0)
        onStatusChanged?("AirPods 已断开 · 正在确认…")

        // 确认期内重新收到姿态数据就视为瞬时抖动，不做断线处理。
        disconnectConfirmWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning, !self.receivedMotionSample else { return }
            self.confirmDisconnection()
        }
        disconnectConfirmWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + configuration.disconnectConfirmDelay,
            execute: workItem
        )
    }

    /// 用户请求重连：立即重建姿态流，并持续检测耳机是否已接入。
    /// 检测进度通过 onReconnectStatusChanged 刷新到界面，直到重新收到姿态数据。
    func beginReconnect() {
        guard isRunning else { return }
        isAwaitingReconnect = true
        reconnectProbeCount = 0
        onReconnectStatusChanged?("正在检测 AirPods…")
        // 重建音频路由，促使耳机恢复姿态上报。
        onMotionStreamStalled?()
        motionManager.stopDeviceMotionUpdates()
        scheduleReconnectProbe(after: 0.4)
    }

    /// 放弃等待重连（例如用户改为暂停检测）。
    func cancelReconnect() {
        isAwaitingReconnect = false
        reconnectProbeCount = 0
        reconnectProbeWorkItem?.cancel()
        reconnectProbeWorkItem = nil
        disconnectConfirmWorkItem?.cancel()
        disconnectConfirmWorkItem = nil
    }

    private func scheduleReconnectProbe(after delay: TimeInterval) {
        reconnectProbeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.probeHeadphoneAvailability()
        }
        reconnectProbeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// 检测耳机是否接入并刷新提示；收到姿态数据前一直轮询。
    private func probeHeadphoneAvailability() {
        guard isRunning, isAwaitingReconnect else { return }

        guard motionManager.isDeviceMotionAvailable else {
            reconnectProbeCount = 0
            onReconnectStatusChanged?("未检测到 AirPods · 请确认耳机已连接并佩戴")
            scheduleReconnectProbe(after: configuration.reconnectProbeInterval)
            return
        }

        reconnectProbeCount += 1

        if motionManager.isDeviceMotionActive {
            // 姿态流已经在跑，只等第一帧数据。
            onReconnectStatusChanged?("已连接 AirPods · 正在等待姿态数据…")
        } else if reconnectProbeCount == 1 || reconnectProbeCount % 3 == 0 {
            // 首次尝试，或连续几次都没激活：再重建一次音频路由和姿态流。
            onReconnectStatusChanged?("已检测到 AirPods · 正在恢复姿态…")
            onMotionStreamStalled?()
            startMotionUpdates()
        } else {
            onReconnectStatusChanged?("已检测到 AirPods · 正在等待姿态数据…")
        }

        scheduleReconnectProbe(after: configuration.reconnectProbeInterval)
    }

    private func startMotionUpdates() {
        guard isRunning, motionManager.isDeviceMotionAvailable else { return }
        guard !motionManager.isDeviceMotionActive else { return }

        receivedMotionSample = false
        onStatusChanged?("等待 AirPods 姿态数据…")

        noSampleStatusWorkItem?.cancel()
        let statusWorkItem = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning, !self.receivedMotionSample else { return }
            self.recoverStalledMotionStream()
        }
        noSampleStatusWorkItem = statusWorkItem
        // 首次无样本时快速复查；之后再退避，避免频繁重建蓝牙音频路由。
        let retryDelay: TimeInterval
        switch recoveryAttempt {
        case 0: retryDelay = 2.0
        case 1: retryDelay = 3.0
        default: retryDelay = min(3.0 * pow(1.7, Double(recoveryAttempt - 1)), 12)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: statusWorkItem)

        motionManager.startDeviceMotionUpdates(to: OperationQueue.main) { [weak self] motion, error in
            guard let self else { return }

            if let error {
                self.onStatusChanged?("姿态读取失败：\(error.localizedDescription)")
                return
            }

            guard let motion else { return }
            self.consume(motion)
        }
    }

    private func consume(_ motion: CMDeviceMotion) {
        if !receivedMotionSample {
            receivedMotionSample = true
            recoveryAttempt = 0
            noSampleStatusWorkItem?.cancel()
            noSampleStatusWorkItem = nil

            if isAwaitingReconnect {
                isAwaitingReconnect = false
                reconnectProbeWorkItem?.cancel()
                reconnectProbeWorkItem = nil
                onDeviceReconnected?()
            }
        }

        let rawYaw = motion.attitude.yaw
        let rawPitch = motion.attitude.pitch
        let alpha = configuration.smoothingFactor

        if let previousYaw = filteredYaw {
            // 角度经过 ±π 边界时按最短方向平滑，避免突然跳变 360°。
            filteredYaw = previousYaw + normalizedAngle(rawYaw - previousYaw) * alpha
        } else {
            filteredYaw = rawYaw
        }

        if let previousPitch = filteredPitch {
            filteredPitch = previousPitch + (rawPitch - previousPitch) * alpha
        } else {
            filteredPitch = rawPitch
        }

        guard let filteredYaw, let filteredPitch else { return }

        if shouldCalibrateOnNextSample || baselineYaw == nil || baselinePitch == nil {
            baselineYaw = filteredYaw
            baselinePitch = filteredPitch
            shouldCalibrateOnNextSample = false
            setFacingScreen(true)
            onStatusChanged?("已校准 · 正在检测")
        }

        guard let baselineYaw, let baselinePitch else { return }
        let unadjustedYaw = radiansToDegrees(normalizedAngle(filteredYaw - baselineYaw))
        let relativeYaw = normalizedDegrees(unadjustedYaw - yawCenterOffsetDegrees)
        let relativePitch = radiansToDegrees(filteredPitch - baselinePitch)

        onPoseChanged?(relativeYaw, relativePitch)
        updateFacingState(relativeYaw: relativeYaw, relativePitch: relativePitch)
    }

    private func updateFacingState(relativeYaw: Double, relativePitch: Double) {
        let desiredFacingState: Bool

        if facingScreen {
            let turnedAway = abs(relativeYaw) > clearYawHalfRangeDegrees
                || abs(relativePitch) > clearPitchHalfRangeDegrees
            desiredFacingState = !turnedAway
        } else {
            // 回正阈值同步跟随菜单里的清晰范围，左右收窄 3°、上下收窄 2°。
            let yawHysteresis = configuration.clearYawDegrees - configuration.returnYawDegrees
            let pitchHysteresis = configuration.clearPitchDegrees - configuration.returnPitchDegrees
            let returnYawRange = max(clearYawHalfRangeDegrees - yawHysteresis, 0)
            let returnPitchRange = max(clearPitchHalfRangeDegrees - pitchHysteresis, 0)
            let returnedToCenter = abs(relativeYaw) <= returnYawRange
                && abs(relativePitch) <= returnPitchRange
            desiredFacingState = returnedToCenter
        }

        guard desiredFacingState != facingScreen else {
            pendingFacingState = nil
            pendingStateSince = nil
            return
        }

        let now = Date()
        if pendingFacingState != desiredFacingState {
            pendingFacingState = desiredFacingState
            pendingStateSince = now
            return
        }

        guard let pendingStateSince,
              now.timeIntervalSince(pendingStateSince) >= configuration.transitionDelay else {
            return
        }

        setFacingScreen(desiredFacingState)
        self.pendingFacingState = nil
        self.pendingStateSince = nil
    }

    private func setFacingScreen(_ newValue: Bool) {
        guard facingScreen != newValue else { return }
        facingScreen = newValue
        onFacingChanged?(newValue)
        onStatusChanged?(newValue ? "已回到正视范围" : "已转开 · 内容已模糊")
    }

    private func clearPoseState() {
        filteredYaw = nil
        filteredPitch = nil
        baselineYaw = nil
        baselinePitch = nil
        shouldCalibrateOnNextSample = true
        receivedMotionSample = false
        noSampleStatusWorkItem?.cancel()
        noSampleStatusWorkItem = nil
        restartMotionWorkItem?.cancel()
        restartMotionWorkItem = nil
        recoveryAttempt = 0
        pendingFacingState = nil
        pendingStateSince = nil
    }

    private func recoverStalledMotionStream() {
        guard isRunning else { return }

        recoveryAttempt += 1

        // 耳机静默掉线时系统可能不会发断开回调，只是不再有任何姿态数据。
        // 连续两次唤醒仍收不到数据，就按掉线处理：整屏模糊兜底并提示重连。
        if recoveryAttempt >= 2 {
            recoveryAttempt = 0
            noSampleStatusWorkItem?.cancel()
            noSampleStatusWorkItem = nil
            confirmDisconnection()
            return
        }

        onStatusChanged?("正在唤醒 AirPods 姿态传感器…")
        onMotionStreamStalled?()
        motionManager.stopDeviceMotionUpdates()

        restartMotionWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.startMotionUpdates()
        }
        restartMotionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: workItem)
    }

    /// 确认掉线：通知上层进入保护状态，并自动开始检测耳机何时回来。
    private func confirmDisconnection() {
        onDeviceDisconnected?()
        beginReconnect()
    }

    private func normalizedAngle(_ angle: Double) -> Double {
        var result = angle
        while result > .pi { result -= 2 * .pi }
        while result < -.pi { result += 2 * .pi }
        return result
    }

    private func radiansToDegrees(_ radians: Double) -> Double {
        radians * 180 / .pi
    }

    private func normalizedDegrees(_ degrees: Double) -> Double {
        var result = degrees
        while result > 180 { result -= 360 }
        while result < -180 { result += 360 }
        return result
    }

    private func publishCurrentPoseIfAvailable() {
        guard let filteredYaw, let filteredPitch, let baselineYaw, let baselinePitch else { return }
        let unadjustedYaw = radiansToDegrees(normalizedAngle(filteredYaw - baselineYaw))
        let relativeYaw = normalizedDegrees(unadjustedYaw - yawCenterOffsetDegrees)
        let relativePitch = radiansToDegrees(filteredPitch - baselinePitch)
        onPoseChanged?(relativeYaw, relativePitch)
        updateFacingState(relativeYaw: relativeYaw, relativePitch: relativePitch)
    }

    private func normalizedOverflow(
        angle: Double,
        clearUntil: Double,
        fullyBlurredAt: Double
    ) -> Double {
        min(max((angle - clearUntil) / (fullyBlurredAt - clearUntil), 0), 1)
    }
}
