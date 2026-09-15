import AVFAudio
import Foundation

/// 在没有用户可听见声音的情况下保持音频输出图运行。
/// 某些 AirPods / macOS 组合只有在音频路由活跃时才会持续上报头部姿态。
final class HeadphoneAudioKeepAlive {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let keepAliveBuffer: AVAudioPCMBuffer
    private var wantsToRun = false
    private var restartWorkItem: DispatchWorkItem?
    private var configurationObserver: NSObjectProtocol?

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let frameCapacity = AVAudioFrameCount(format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity)!
        buffer.frameLength = frameCapacity

        // 全零 PCM 在部分系统/固件组合上会被当作空闲流。使用约 -96 dBFS 的
        // 零均值抖动信号让蓝牙音频链路保持活跃，正常环境中不可感知。
        if let channels = buffer.floatChannelData {
            var noiseState: UInt32 = 0xA17B_10C5
            let amplitude: Float = 0.000_016
            for frame in 0 ..< Int(frameCapacity) {
                noiseState = 1_664_525 &* noiseState &+ 1_013_904_223
                let unit = Float(noiseState) / Float(UInt32.max)
                let sample = (unit * 2 - 1) * amplitude
                for channel in 0 ..< Int(format.channelCount) {
                    channels[channel][frame] = sample
                }
            }
        }
        keepAliveBuffer = buffer

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleRestart(after: 0.35)
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    func start() {
        wantsToRun = true
        guard !engine.isRunning || !playerNode.isPlaying else { return }
        startEngine()
    }

    /// 音频路由或耳机姿态流休眠时，完整重建输出图。
    func restart() {
        guard wantsToRun else { return }
        scheduleRestart(after: 0.15)
    }

    func stop() {
        wantsToRun = false
        restartWorkItem?.cancel()
        restartWorkItem = nil
        playerNode.stop()
        engine.stop()
    }

    private func startEngine() {
        guard wantsToRun else { return }

        restartWorkItem?.cancel()
        restartWorkItem = nil
        playerNode.stop()
        if engine.isRunning {
            engine.stop()
        }

        playerNode.scheduleBuffer(keepAliveBuffer, at: nil, options: .loops)
        engine.prepare()

        do {
            try engine.start()
            playerNode.play()
        } catch {
            NSLog("AxisVeil audio keep-alive unavailable: %@", error.localizedDescription)
            scheduleRestart(after: 3)
        }
    }

    private func scheduleRestart(after delay: TimeInterval) {
        guard wantsToRun else { return }
        restartWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.startEngine()
        }
        restartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
}
