//
//  OnlineAnalysisViewController.swift
//  Xcup
//
//  iOS 在线模式 v2 — 通过 Broadcast Upload Extension 采集全系统音频输出与屏幕画面
//
//  数据流：
//    [XcupBroadcast Extension]
//        ├─ audioApp（全系统音频混音）→ AudioRingWriter → App Group 共享文件
//        └─ video（屏幕画面 JPEG）   → VideoFrameWriter → App Group 共享文件
//    [主 App]
//        ├─ AudioRingReader → processAudio() → 音频分析 Loop
//        └─ VideoFrameReader → processVideo() → 视频分析 Loop
//
//  注意：两端均需开启 App Groups 能力，且 Group ID = group.com.aibei.Xcup
//

import UIKit
import ReplayKit
import AVFoundation

class OnlineAnalysisViewController: UIViewController {

    // MARK: - UI 元素
    private let previewImageView  = UIImageView()
    private let statusLabel       = UILabel()
    private let tvVideoAction     = UILabel()
    private let tvAudioAction     = UILabel()
    private let tvOverlay         = UILabel()
    // private let tvDiag            = UILabel()
    private let btnStop           = UIButton(type: .system)
    private var broadcastPicker:  RPSystemBroadcastPickerView?

    // 未广播时的居中覆盖层
    private let startOverlay      = UIView()

    // MARK: - 诊断计数器
    // private var audioChunksReceived  = 0
    // private var videoFramesReceived  = 0
    // private var rawAudioReceived     = 0   // 扩展侧 .audioApp 原始到达次数
    // private var lastDiagUpdate: TimeInterval = 0

    // MARK: - IPC 读端
    private var audioReader: AudioRingReader?
    private let videoReader = VideoFrameReader()

    // MARK: - Darwin 通知令牌
    private var audioToken:    AnyObject?
    private var videoToken:    AnyObject?
    private var startToken:    AnyObject?
    private var stopToken:     AnyObject?
    // private var rawAudioToken: AnyObject?   // 诊断令牌

    // MARK: - 广播状态
    private var isBroadcasting = false

    // MARK: - 帧节流
    private var lastFrameProcessTime: TimeInterval = 0
    private let FRAME_INTERVAL: TimeInterval = 0.1
    private var latestFrame: UIImage?
    private let frameLock = NSLock()

    // MARK: - 推理模块
    private var inferenceHelper:        InferenceHelper!
    private var audioHelper:            AudioInferenceHelper!
    private var audioLoudnessEstimator: AudioLoudnessLevelEstimator!
    private var videoRhythmEstimator:   VideoMotionWaveEstimator!
    private var pcmBuffer:              PcmCircularBuffer!
    private let analysisResults =       ThreadSafeAnalysisResults()

    // MARK: - 分析队列与循环
    private let videoAnalysisQueue = DispatchQueue(label: "com.xcup.online.video",  qos: .userInitiated)
    private let audioAnalysisQueue = DispatchQueue(label: "com.xcup.online.audio",  qos: .userInitiated)
    private let VIDEO_INTERVAL_MS:  Int64 = 100
    private let AUDIO_INTERVAL_MS:  Int64 = 1000
    private let FUSION_INTERVAL_MS: Int64 = 800
    private var videoLoopItem:  DispatchWorkItem?
    private var audioLoopItem:  DispatchWorkItem?
    private var fusionLoopItem: DispatchWorkItem?

    // MARK: - 分析暂停状态
    private let stateLock = NSLock()
    private var _isPaused = true
    private var isAnalysisPaused: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _isPaused }
        set { stateLock.lock(); defer { stateLock.unlock() }; _isPaused = newValue }
    }

    // MARK: - 姿态窗口
    private var poseWindow: [PoseFrame] = []
    private let WINDOW_SIZE  = 32
    private let MULTI_STEP   = 8
    private var framesSinceLastMulti = 0

    // MARK: - 平滑融合
    private var actionHistory: [ActionRecord] = []
    private let historyLock  = NSLock()
    private let SMOOTH_WINDOW_SIZE = 10
    private var latestBluetoothAction = ""

    // MARK: - 蓝牙状态管理
    private var pendingBluetoothState  = ""
    private var currentBluetoothState  = ""
    private var pendingStateStartTime:  TimeInterval = 0
    private var currentStateStartTime:  TimeInterval = 0
    private var lastBluetoothSendTime:  TimeInterval = 0
    private let BLUETOOTH_MIN_DURATION:      TimeInterval = 2000
    private let BLUETOOTH_SEND_INTERVAL:     TimeInterval = 1600
    private let BLUETOOTH_STABLE_CONFIRM_MS: TimeInterval = 1600
    private var currentLevel:        Int = 1
    private var currentLevelSinceMs: TimeInterval = 0
    private var pendingLevel:        Int? = nil
    private var pendingLevelSinceMs: TimeInterval = 0
    private var lastSentLevel:       Int = 0
    private let LEVEL_STABLE_MS:     TimeInterval = 0
    private let LEVEL_MIN_DUR_MS:    TimeInterval = 0
    private let LEVEL_SEND_GAP_MS:   TimeInterval = 1600
    private let LEVEL_RANGES: [ClosedRange<Float>?] = [
        nil,
        0.95...1.12, 1.12...1.27, 1.27...1.40, 1.40...1.53, 1.53...1.58,
        1.58...1.63, 1.63...1.66, 1.66...1.70, 1.70...1.75, 1.75...1.85
    ]

    // MARK: - 静音检测
    private var lastAudioActiveTime:      TimeInterval = 0
    private let SILENCE_THRESHOLD_SEC:    TimeInterval = 5.0
    private var consecutiveSilentFrames   = 0
    private let MIN_SILENT_FRAMES         = 10
    private let AUDIO_AMPLITUDE_THRESHOLD: Float = 0.005

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupInference()
        setupIPC()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // iOS 16+ 禁止程序化触发 RPSystemBroadcastPickerView，由用户手动点击大按钮
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopAllActivity()
    }

    deinit {
        videoLoopItem?.cancel()
        audioLoopItem?.cancel()
        fusionLoopItem?.cancel()
        if let t = audioToken    { unregisterDarwinObserver(t) }
        if let t = videoToken    { unregisterDarwinObserver(t) }
        if let t = startToken    { unregisterDarwinObserver(t) }
        if let t = stopToken     { unregisterDarwinObserver(t) }
        // if let t = rawAudioToken { unregisterDarwinObserver(t) }
    }

    // MARK: - UI 布局

    private func setupUI() {
        view.backgroundColor = .black

        // 屏幕预览（广播开始后显示）
        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        previewImageView.contentMode = .scaleAspectFit
        previewImageView.backgroundColor = .black
        view.addSubview(previewImageView)
        NSLayoutConstraint.activate([
            previewImageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewImageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewImageView.topAnchor.constraint(equalTo: view.topAnchor),
            previewImageView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // 分析结果标签
        let labels = [tvVideoAction, tvAudioAction, tvOverlay]
        let titles  = ["V: 等待...", "A: 等待...", "Final: 等待..."]
        for (i, label) in labels.enumerated() {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.textColor        = .white
            label.font             = UIFont.systemFont(ofSize: 13)
            label.text             = titles[i]
            label.backgroundColor  = UIColor.black.withAlphaComponent(0.45)
            label.layer.cornerRadius = 4
            label.clipsToBounds    = true
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
                label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor,
                                           constant: CGFloat(12 + i * 24))
            ])
        }

        // 状态标签（顶部居中）
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor        = .yellow
        statusLabel.font             = UIFont.systemFont(ofSize: 14, weight: .semibold)
        statusLabel.text             = ""
        statusLabel.backgroundColor  = UIColor.black.withAlphaComponent(0.5)
        statusLabel.layer.cornerRadius = 6
        statusLabel.clipsToBounds    = true
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12)
        ])

        // 诊断面板
        /*
        tvDiag.translatesAutoresizingMaskIntoConstraints = false
        tvDiag.numberOfLines = 0
        tvDiag.textColor     = .cyan
        tvDiag.font          = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tvDiag.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        tvDiag.layer.cornerRadius = 6
        tvDiag.clipsToBounds = true
        tvDiag.text = "⬛ Extension: 未连接\n⬛ 音频块: 0\n⬛ 视频帧: 0\n⬛ 推理: 未开始"
        tvDiag.isHidden = true
        view.addSubview(tvDiag)
        NSLayoutConstraint.activate([
            tvDiag.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            tvDiag.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])
        */

        // ── 未广播时的居中覆盖层（在诊断面板之后加入，遮住背景内容）──
        setupStartOverlay()

        // 停止按钮：最后加入，z 轴最高，始终在覆盖层之上可点击
        btnStop.translatesAutoresizingMaskIntoConstraints = false
        btnStop.setTitle("停止", for: .normal)
        btnStop.setTitleColor(.white, for: .normal)
        btnStop.backgroundColor    = UIColor.systemRed.withAlphaComponent(0.85)
        btnStop.layer.cornerRadius = 8
        btnStop.titleLabel?.font   = UIFont.systemFont(ofSize: 15, weight: .semibold)
        btnStop.addTarget(self, action: #selector(onStopTapped), for: .touchUpInside)
        view.addSubview(btnStop)
        NSLayoutConstraint.activate([
            btnStop.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            btnStop.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            btnStop.widthAnchor.constraint(equalToConstant: 72),
            btnStop.heightAnchor.constraint(equalToConstant: 36)
        ])
    }

    private func setupStartOverlay() {
        startOverlay.translatesAutoresizingMaskIntoConstraints = false
        startOverlay.backgroundColor = UIColor(white: 0.08, alpha: 1)
        view.addSubview(startOverlay)
        NSLayoutConstraint.activate([
            startOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            startOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            startOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            startOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // 图标
        let iconLabel = UILabel()
        iconLabel.text = ""
        iconLabel.font = UIFont.systemFont(ofSize: 60)
        iconLabel.textAlignment = .center
        iconLabel.translatesAutoresizingMaskIntoConstraints = false

        // 标题
        let titleLabel = UILabel()
        titleLabel.text = "在线模式"
        titleLabel.font = UIFont.systemFont(ofSize: 26, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        // 说明文字
        let descLabel = UILabel()
        descLabel.text = "点击下方红色按钮，在弹出的系统对话框中选择「开始直播」即开始在线视频模式，可以返回桌面，观看在线视频。所有信息皆在本地处理，不会上传至服务器。"
        descLabel.font = UIFont.systemFont(ofSize: 15)
        descLabel.textColor = UIColor(white: 0.75, alpha: 1)
        descLabel.textAlignment = .center
        descLabel.numberOfLines = 0
        descLabel.translatesAutoresizingMaskIntoConstraints = false

        // ── 隐藏的系统 Picker（1×1，藏在角落，仅用于通过代码触发系统广播对话框）──
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        picker.preferredExtension = "com.aibei.Xcup.XcupBroadcast"
        picker.showsMicrophoneButton = false
        picker.translatesAutoresizingMaskIntoConstraints = false
        broadcastPicker = picker
        startOverlay.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.leadingAnchor.constraint(equalTo: startOverlay.leadingAnchor),
            picker.topAnchor.constraint(equalTo: startOverlay.topAnchor),
            picker.widthAnchor.constraint(equalToConstant: 1),
            picker.heightAnchor.constraint(equalToConstant: 1),
        ])

        // ── 普通 UIButton 作为视觉按钮（完全可控，样式自由）──
        let broadcastBtn = UIButton(type: .system)
        broadcastBtn.translatesAutoresizingMaskIntoConstraints = false
        broadcastBtn.setTitle("开始广播", for: .normal)
        broadcastBtn.setTitleColor(.white, for: .normal)
        broadcastBtn.titleLabel?.font = UIFont.systemFont(ofSize: 20, weight: .semibold)
        broadcastBtn.backgroundColor = UIColor.systemRed
        broadcastBtn.layer.cornerRadius = 20
        broadcastBtn.layer.masksToBounds = true
        broadcastBtn.addTarget(self, action: #selector(onBroadcastButtonTapped), for: .touchUpInside)

        [iconLabel, titleLabel, descLabel, broadcastBtn].forEach {
            startOverlay.addSubview($0)
        }

        NSLayoutConstraint.activate([
            iconLabel.centerXAnchor.constraint(equalTo: startOverlay.centerXAnchor),
            iconLabel.centerYAnchor.constraint(equalTo: startOverlay.centerYAnchor, constant: -150),

            titleLabel.topAnchor.constraint(equalTo: iconLabel.bottomAnchor, constant: 12),
            titleLabel.centerXAnchor.constraint(equalTo: startOverlay.centerXAnchor),

            descLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            descLabel.leadingAnchor.constraint(equalTo: startOverlay.leadingAnchor, constant: 32),
            descLabel.trailingAnchor.constraint(equalTo: startOverlay.trailingAnchor, constant: -32),

            broadcastBtn.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 48),
            broadcastBtn.centerXAnchor.constraint(equalTo: startOverlay.centerXAnchor),
            broadcastBtn.widthAnchor.constraint(equalToConstant: 220),
            broadcastBtn.heightAnchor.constraint(equalToConstant: 64),
        ])
    }

    // 点击红色按钮 → 找到 picker 内部的系统按钮并程序化触发，弹出系统广播选择对话框
    @objc private func onBroadcastButtonTapped() {
        guard let picker = broadcastPicker else { return }
        for subview in picker.subviews {
            if let button = subview as? UIButton {
                button.sendActions(for: .touchUpInside)
                return
            }
        }
    }

    // MARK: - 推理模块初始化

    private func setupInference() {
        inferenceHelper        = InferenceHelper()
        inferenceHelper.setupPoseDetector()
        audioHelper            = AudioInferenceHelper()
        audioLoudnessEstimator = AudioLoudnessLevelEstimator(sampleRate: 16000)
        videoRhythmEstimator   = VideoMotionWaveEstimator()
        pcmBuffer              = PcmCircularBuffer(sampleRate: 16000, capacityInSeconds: 20)
    }

    // MARK: - IPC 初始化与 Darwin 通知注册

    private func setupIPC() {
        // 广播启动通知
        startToken = registerDarwinObserver(name: kDarwinStart) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { self.handleBroadcastStarted() }
        }

        // 广播停止通知
        stopToken = registerDarwinObserver(name: kDarwinStop) { [weak self] in
            DispatchQueue.main.async { self?.handleBroadcastStopped() }
        }

        // 新音频数据通知（驱动音频写入 pcmBuffer）
        // 同时作为广播已启动的兜底检测：若 startToken 未触发但数据已到达，在此激活
        audioToken = registerDarwinObserver(name: kDarwinAudio) { [weak self] in
            guard let self else { return }
            if !self.isBroadcasting {
                DispatchQueue.main.async { self.handleBroadcastStarted() }
            }
            self.onNewAudioData()
        }

        // 新视频帧通知（更新预览图）
        // 同上，作为广播已启动的兜底检测
        videoToken = registerDarwinObserver(name: kDarwinVideo) { [weak self] in
            guard let self else { return }
            if !self.isBroadcasting {
                DispatchQueue.main.async { self.handleBroadcastStarted() }
            }
            self.onNewVideoFrame()
        }

        // 诊断：扩展侧首条 .audioApp 样本到达（处理前）的通知
        /*
        rawAudioToken = registerDarwinObserver(name: kDarwinAudioRaw) { [weak self] in
            guard let self else { return }
            self.rawAudioReceived += 1
            self.refreshDiagIfNeeded()
        }
        */
    }

    // MARK: - 广播启动处理（由 startToken 触发，或由首条音视频数据兜底触发）

    private func handleBroadcastStarted() {
        guard !isBroadcasting else { return }
        let reader = AudioRingReader()
        audioReader = reader
        let ipcOk = (reader != nil)
        isBroadcasting = true
        startOverlay.isHidden = true
        // tvDiag.isHidden = false
        if ipcOk {
            statusLabel.text = "Extension 已连接 — 等待声音..."
            // updateDiag(extensionConnected: true, ipcOk: true)
        } else {
            statusLabel.text = "⚠️ App Groups 未配置，数据无法传输"
            // updateDiag(extensionConnected: true, ipcOk: false)
        }
        startAnalysisLoops()
        print("[在线模式] 广播已开始，IPC读端=\(ipcOk ? "就绪" : "失败（检查App Groups配置）")")
    }

    // MARK: - 新音频数据回调（Darwin 通知线程，非主线程）

    private func onNewAudioData() {
        guard let reader = audioReader else { return }
        guard let samples = reader.readLatest(count: 4800), !samples.isEmpty else { return }
        let nowMs   = Int64(Date().timeIntervalSince1970 * 1000)
        let startMs = nowMs - Int64(samples.count * 1000 / 16000)
        pcmBuffer.write(samples, startTimestampMs: startMs, sampleRate: 16000)
        handleSilenceDetection(samples: samples)

        // audioChunksReceived += 1
        // refreshDiagIfNeeded()
    }

    // MARK: - 新视频帧回调（Darwin 通知线程，非主线程）

    private func onNewVideoFrame() {
        let now = Date().timeIntervalSince1970
        guard now - lastFrameProcessTime >= FRAME_INTERVAL else { return }
        lastFrameProcessTime = now

        guard let jpeg = videoReader.readLatestJpeg(),
              let image = UIImage(data: jpeg) else { return }

        frameLock.lock()
        latestFrame = image
        frameLock.unlock()

        // videoFramesReceived += 1
        // refreshDiagIfNeeded()

        DispatchQueue.main.async { [weak self] in
            self?.previewImageView.image = image
        }
    }

    // MARK: - 诊断面板更新
    /*
    private func updateDiag(extensionConnected: Bool, ipcOk: Bool) {
        let extIcon = extensionConnected ? "🟢" : "⬛"
        let ipcNote = ipcOk ? "" : " ⚠️ App Groups 未配置"
        tvDiag.text = "\(extIcon) Extension: \(extensionConnected ? "已连接" : "未连接")\(ipcNote)\n⬛ 音频块: 0\n⬛ 视频帧: 0\n⬛ 推理: 未开始"
    }

    private func refreshDiagIfNeeded() {
        let now = Date().timeIntervalSince1970
        guard now - lastDiagUpdate > 0.5 else { return }   // 最多每 500ms 刷新一次
        lastDiagUpdate = now
        let audio    = audioChunksReceived
        let video    = videoFramesReceived
        let rawAudio = rawAudioReceived
        let paused   = isAnalysisPaused

        // 读取扩展侧通过 UserDefaults 写入的诊断信息
        let defaults  = UserDefaults(suiteName: kBroadcastAppGroupID)
        let rawFlag   = defaults?.string(forKey: kDiagAudioRaw)  ?? "未收到"
        let fmtInfo   = defaults?.string(forKey: kDiagAudioFmt)  ?? "-"
        let convInfo  = defaults?.string(forKey: kDiagAudioConv) ?? "-"

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let audioIcon = audio > 0 ? "🟢" : "🔴"
            let videoIcon = video > 0 ? "🟢" : "🔴"
            let rawIcon   = rawAudio > 0 ? "🟢" : "🔴"
            let inferIcon = (!paused && audio > 0) ? "🟢" : (paused ? "🟡" : "⬛")
            let inferText = !paused ? "运行中" : (audio > 0 ? "静音暂停" : "等待声音")
            self.tvDiag.text = """
            🟢 Extension: 已连接
            \(rawIcon) .audioApp原始: \(rawAudio) UD=\(rawFlag)
            \(audioIcon) 音频块(处理后): \(audio)
            📋 格式: \(fmtInfo)
            📋 转换: \(convInfo)
            \(videoIcon) 视频帧: \(video)
            \(inferIcon) 推理: \(inferText)
            """
        }
    }
    */

    // MARK: - 静音检测

    private func handleSilenceDetection(samples: [Float]) {
        guard !samples.isEmpty else { return }
        let amplitude = samples.map { abs($0) }.reduce(0, +) / Float(samples.count)
        let hasAudio  = amplitude > AUDIO_AMPLITUDE_THRESHOLD
        if hasAudio {
            lastAudioActiveTime     = Date().timeIntervalSince1970
            consecutiveSilentFrames = 0
            if isAnalysisPaused {
                resumeAnalysis()
                DispatchQueue.main.async { self.statusLabel.text = "在线分析中" }
            }
        } else {
            consecutiveSilentFrames += 1
            if consecutiveSilentFrames >= MIN_SILENT_FRAMES {
                let silenced = Date().timeIntervalSince1970 - lastAudioActiveTime
                if silenced > SILENCE_THRESHOLD_SEC && !isAnalysisPaused {
                    pauseAnalysis()
                    DispatchQueue.main.async { self.statusLabel.text = "在线分析中 — 等待声音..." }
                }
            }
        }
    }

    // MARK: - 广播停止处理

    private func handleBroadcastStopped() {
        isBroadcasting = false
        statusLabel.text = ""
        videoLoopItem?.cancel()
        audioLoopItem?.cancel()
        fusionLoopItem?.cancel()
        audioReader = nil
        // audioChunksReceived = 0
        // videoFramesReceived = 0
        // 重新显示启动覆盖层
        startOverlay.isHidden = false
        // tvDiag.isHidden = true
    }

    // MARK: - 启动三路分析循环

    private func startAnalysisLoops() {
        startVideoLoop()
        startAudioLoop()
        startFusionLoop()
    }

    private func startVideoLoop() {
        videoLoopItem?.cancel()
        scheduleVideoTick(afterMs: 0)
    }
    private func scheduleVideoTick(afterMs d: Int64) {
        let item = DispatchWorkItem { [weak self] in self?.runVideoTick() }
        videoLoopItem = item
        videoAnalysisQueue.asyncAfter(deadline: .now() + .milliseconds(Int(d)), execute: item)
    }
    private func runVideoTick() {
        let t0 = DispatchTime.now()
        if !isAnalysisPaused { performVideoAnalysis() }
        let elapsed = Int64((DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000)
        scheduleVideoTick(afterMs: max(0, VIDEO_INTERVAL_MS - elapsed))
    }

    private func startAudioLoop() {
        audioLoopItem?.cancel()
        scheduleAudioTick(afterMs: 0)
    }
    private func scheduleAudioTick(afterMs d: Int64) {
        let item = DispatchWorkItem { [weak self] in self?.runAudioTick() }
        audioLoopItem = item
        audioAnalysisQueue.asyncAfter(deadline: .now() + .milliseconds(Int(d)), execute: item)
    }
    private func runAudioTick() {
        let t0 = DispatchTime.now()
        if !isAnalysisPaused { performAudioAnalysis() }
        let elapsed = Int64((DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000)
        scheduleAudioTick(afterMs: max(0, AUDIO_INTERVAL_MS - elapsed))
    }

    private func startFusionLoop() {
        fusionLoopItem?.cancel()
        scheduleFusionTick(afterMs: 0)
    }
    private func scheduleFusionTick(afterMs d: Int64) {
        let item = DispatchWorkItem { [weak self] in self?.runFusionTick() }
        fusionLoopItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(d)), execute: item)
    }
    private func runFusionTick() {
        let t0 = DispatchTime.now()
        if !isAnalysisPaused { performFusion() }
        let elapsed = Int64((DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000)
        scheduleFusionTick(afterMs: max(0, FUSION_INTERVAL_MS - elapsed))
    }

    // MARK: - 视频分析

    private func performVideoAnalysis() {
        frameLock.lock()
        let frame = latestFrame
        latestFrame = nil
        frameLock.unlock()
        guard let frame = frame else { return }

        inferenceHelper.runPoseModel(on: frame) { [weak self] keypoints in
            guard let self = self else { return }
            let framePtsMs = Int64(Date().timeIntervalSince1970 * 1000)

            // 🆕 关键点为 nil（未检测到人）→ 触发节律器场景切换处理；ST-GCN++ 跳过本帧
            guard let keypoints = keypoints else {
                self.videoRhythmEstimator.pushFrame(timestampMs: framePtsMs, frame: nil, keypointsNorm: nil)
                self.analysisResults.videoFreq = (hz: .nan, conf: 0, tsMs: framePtsMs)
                return
            }

            self.videoRhythmEstimator.pushFrame(timestampMs: framePtsMs,
                                                frame: frame,
                                                keypointsNorm: keypoints)
            let vr = self.videoRhythmEstimator.getLatestResult()
            if vr.valid {
                self.analysisResults.videoFreq = (hz: vr.freqHz,
                                                   conf: vr.confidence,
                                                   tsMs: vr.timestampMs)
                print(String(format: "[频率测试] [在线模式] 视频运动波形 - f=%.2fHz, conf=%.2f, per=%.2f, mE=%.3f, dir=(%.2f,%.2f), pos01=%.2f, locked=%@",
                             vr.freqHz, vr.confidence, vr.periodicity, vr.motionEnergy,
                             vr.mainDirX, vr.mainDirY, vr.position01,
                             vr.locked ? "true" : "false"))
                print("[VideoWave] " + vr.debugInfo)
            } else {
                self.analysisResults.videoFreq = (hz: .nan, conf: 0, tsMs: framePtsMs)
            }
            self.videoAnalysisQueue.async {
                self.poseWindow.append(keypoints)
                if self.poseWindow.count > self.WINDOW_SIZE { self.poseWindow.removeFirst() }
                self.framesSinceLastMulti += 1
                guard self.poseWindow.count == self.WINDOW_SIZE,
                      self.framesSinceLastMulti >= self.MULTI_STEP else { return }
                self.framesSinceLastMulti = 0

                var input = self.poseWindow.toStgcnInput()
                input = ActionUtilsSwift.preNormalize2D(input)
                guard let scores = self.inferenceHelper.runStgcnModel(input: input) else { return }

                let probs     = scores.softmax()
                let probOral  = probs[0] + probs[1]
                let probDo    = probs[2] + probs[3] + probs[4] + probs[5]
                let noiseProb = probs[6] + probs[7]
                let targetProb = probOral + probDo

                var action: String; var score: Float
                if noiseProb > targetProb * 1.5 { action = "Noise"; score = 0.0 }
                else if probOral > probDo         { action = "oral";  score = probOral }
                else                              { action = "do";    score = probDo }
                if score < 0 { action = "Noise"; score = 1.0 }

                self.analysisResults.videoResult = (action, score, Date().timeIntervalSince1970 * 1000)
                print(String(format: "📸 [在线-视频] 识别结果: %@ (p=%.3f) | oral=%.3f, do=%.3f, noise=%.3f",
                      action, score, probOral, probDo, noiseProb))
                DispatchQueue.main.async {
                    self.tvVideoAction.text = String(format: "V: %@ (%.2f)", action, score)
                }
            }
        }
    }

    // MARK: - 音频分析

    private func performAudioAnalysis() {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if let segment = pcmBuffer.readWindowRelaxed(currentTimeMs: nowMs, sampleCount: 32000) {
            let (index, confidence) = audioHelper.predict(audioBuffer: segment)
            let classes = ["do", "oral", "Noise"]
            if index >= 0 && index < classes.count {
                var cls = classes[index]; var conf = confidence
                if cls == "Noise" && conf < 0.6 { cls = "do"; conf = 1.0 - conf }
                analysisResults.audioResult = (cls, conf, Date().timeIntervalSince1970 * 1000)
                print(String(format: "🎵 [在线-音频] 识别结果: %@ (p=%.3f)", cls, conf))
                DispatchQueue.main.async { self.tvAudioAction.text = String(format: "A: %@ (%.2f)", cls, conf) }
            }
        }
        if let last05s = pcmBuffer.readWindowRelaxed(currentTimeMs: nowMs, sampleCount: 8000) {
            audioLoudnessEstimator.push(pcm: last05s)
            let lr = audioLoudnessEstimator.estimate(nowMs: nowMs)
            analysisResults.audioLoudnessLevel = (level: lr.level, conf: lr.confidence,
                                                   tsMs: lr.timestampMs, valid: lr.valid)
        }
    }

    // MARK: - 融合

    private func performFusion() {
        let vRes     = analysisResults.videoResult
        let aRes     = analysisResults.audioResult
        let loud     = analysisResults.audioLoudnessLevel
        let vFreqRes = analysisResults.videoFreq
        let now      = Date().timeIntervalSince1970 * 1000
        let MAX_AGE  = 2000.0

        let vAge    = vRes.timestamp > 0 ? now - vRes.timestamp        : Double.greatestFiniteMagnitude
        let aAge    = aRes.timestamp > 0 ? now - aRes.timestamp        : Double.greatestFiniteMagnitude
        let loudAge = loud.tsMs > 0      ? now - Double(loud.tsMs)     : Double.greatestFiniteMagnitude
        let vFAge   = vFreqRes.tsMs > 0  ? now - Double(vFreqRes.tsMs) : Double.greatestFiniteMagnitude

        var vAction = vAge  < MAX_AGE ? vRes.action     : ""
        var aAction = aAge  < MAX_AGE ? aRes.action     : ""
        let vConf   = vAge  < MAX_AGE ? vRes.confidence : Float(0)
        let aConf   = aAge  < MAX_AGE ? aRes.confidence : Float(0)
        let aLevel: Float  = (loud.valid && loudAge < MAX_AGE) ? Float(loud.level) : .nan
        let aLConf: Float  = (loud.valid && loudAge < MAX_AGE) ? loud.conf : 0
        let vHz:    Float  = vFAge < MAX_AGE ? vFreqRes.hz   : .nan
        let vHzCnf: Float  = vFAge < MAX_AGE ? vFreqRes.conf : 0

        if vAction == "oral" { vAction = "do" }
        if aAction == "oral" { aAction = "do" }

        let finalFreq   = computeFinalFreq(audioHz: aLevel, audioConf: aLConf, videoHz: vHz, videoConf: vHzCnf)
        let finalAction = smoothedFusion(videoAction: vAction, audioAction: aAction, videoConf: vConf, audioConf: aConf)

        if !finalAction.isEmpty { updateBluetoothState(finalAction, finalFreq) }
        tvOverlay.text = latestBluetoothAction.isEmpty
            ? "Final: 等待识别..."
            : "Final: \(latestBluetoothAction) | freq: \(finalFreq)"
    }

    // MARK: - 暂停 / 恢复

    private func pauseAnalysis() {
        isAnalysisPaused = true
        if BluetoothManager.shared.isConnected && !BluetoothManager.shared.isPausedByLocal {
            BluetoothManager.shared.sendAction("Noise", 0)
        }
        // refreshDiagIfNeeded()
    }
    private func resumeAnalysis() {
        isAnalysisPaused = false
        // refreshDiagIfNeeded()
    }

    // MARK: - 停止

    @objc private func onStopTapped() { stopAllActivity(); dismiss(animated: true) }

    private func stopAllActivity() {
        videoLoopItem?.cancel()
        audioLoopItem?.cancel()
        fusionLoopItem?.cancel()
        isBroadcasting = false
        audioReader = nil
        if BluetoothManager.shared.isConnected {
            BluetoothManager.shared.sendAction("Noise", 0)
        }
    }

    // 🆕 MARK: - 计算最终节律档位
    // 计算最终节律档位：优先使用视频节律；如果视频节律为空/无效，则回退使用音频响度档位。
    // 音频仍保留“置信度阈值 + 方向性门控（涨档更严格、降档更宽松）”这一套逻辑。
    private func computeFinalFreq(
        audioHz: Float, audioConf: Float,
        videoHz: Float, videoConf: Float
    ) -> Int {

        // [ADD] 判断视频节律是否有效：videoHz 不是 NaN 且大于 0
        let useVideoFreq = !videoHz.isNaN && videoHz > 0

        // [ADD] 根据当前实际来源选择候选档位、置信度、来源名称
        var finalFreq: Int
        let selectedConf: Float
        let rhythmSource: String

        if useVideoFreq {
            // [ADD] 视频节律有效：优先使用视频 Hz 映射档位
            finalFreq = mapFreqToLevel(videoHz)
            selectedConf = videoConf
            rhythmSource = "视频节律"

            NSLog(
                "[最终节律] 使用来源=%@, videoHz=%.3fHz, videoConf=%.2f, candidateLevel=%d",
                rhythmSource, videoHz, videoConf, finalFreq
            )
        } else {
            // [ADD] 视频节律无效：回退使用音频响度档位
            finalFreq = clampLevelFromLoudness(audioHz)  // [MOD] audioHz 实际承载的是 loudness level
            selectedConf = audioConf
            rhythmSource = "音频响度"

            NSLog(
                "[最终节律] 使用来源=%@, 原因=videoHz为NaN或<=0, audioLevelLike=%.3f, audioConf=%.2f, candidateLevel=%d",
                rhythmSource, audioHz, audioConf, finalFreq
            )
        }

        // [ADD] 保留两路原始结果日志，方便对比排查
        let audioLevel = clampLevelFromLoudness(audioHz)
        let videoLevel = mapFreqToLevel(videoHz)

        NSLog(
            "[视频节律] 得到视频节律: %.3f 置信度: %.3f 档位: %d",
            videoHz, videoConf, videoLevel
        )

        NSLog(
            "[音频响度] 得到音频档位: %.3f 置信度: %.3f 档位: %d",
            audioHz, audioConf, audioLevel
        )

        // === 方向性置信度门控（涨档更严格，降档更宽松） ===
        let CONF_IGNORE: Float = 0.10   // 极低置信度：整体忽略本次节律
        let CONF_UP: Float     = 0.10   // 涨档所需置信度
        let CONF_DOWN: Float   = 0.10   // 降档所需置信度

        let curLevel = self.currentLevel
        let candidateLevel = finalFreq

        // [ADD] 当前实际来源是否无效
        let selectedInvalid = useVideoFreq ? videoHz.isNaN : audioHz.isNaN

        // 1) 极低置信度 or 无效频率：直接忽略，沿用 currentLevel
        if selectedInvalid || selectedConf < CONF_IGNORE {
            NSLog(
                "[最终节律] 来源=%@, conf=%.2f < CONF_IGNORE=%.2f，本次节律整体忽略，沿用 currentLevel=%d",
                rhythmSource, selectedConf, CONF_IGNORE, curLevel
            )
            finalFreq = curLevel
            return finalFreq
        }

        // 2) 按“变档方向”应用不同门槛
        if candidateLevel > curLevel && selectedConf < CONF_UP {
            NSLog(
                "[最终节律] 来源=%@，尝试涨档 %d→%d 但 conf=%.2f < CONF_UP=%.2f，本次不生效，沿用 currentLevel=%d",
                rhythmSource, curLevel, candidateLevel, selectedConf, CONF_UP, curLevel
            )
            finalFreq = curLevel
        } else if candidateLevel < curLevel && selectedConf < CONF_DOWN {
            NSLog(
                "[最终节律] 来源=%@，尝试降档 %d→%d 但 conf=%.2f < CONF_DOWN=%.2f，本次不生效，沿用 currentLevel=%d",
                rhythmSource, curLevel, candidateLevel, selectedConf, CONF_DOWN, curLevel
            )
            finalFreq = curLevel
        }
        // candidateLevel == curLevel：无需处理

        NSLog(
            "[最终节律] 最终使用来源=%@, 输出档位=%d",
            rhythmSource, finalFreq
        )

        return finalFreq
    }
    
    // === 🆕 把 Hz 映射为 0..9 档（0为停止），10档也当作第9档 ===
    // 等工厂确定值后，只需替换 LEVEL_RANGES 即可
    private func mapFreqToLevel(_ hz: Float) -> Int {
        if hz.isNaN || hz <= 0 {
            return 0
        }
        for lvl in 1...9 {
            if let range = LEVEL_RANGES[lvl],
               range.contains(hz) {
                return lvl
            }
        }
        return 9 // 超出则钳到最高档
    }
    
    // [ADD] audioHz 实际承载的是 loudness level（Float），这里钳制到 0..9
    private func clampLevelFromLoudness(_ levelLike: Float) -> Int {
        if levelLike.isNaN { return 0 }
        var lv = Int(levelLike.rounded())
        if lv < 0 { lv = 0 }
        if lv > 9 { lv = 9 }
        return lv
    }
    
    // MARK: - ===== 以下与 VideoProcessViewController 逻辑完全一致 =====

    private func smoothedFusion(videoAction: String, audioAction: String,
                                 videoConf: Float, audioConf: Float) -> String {
        historyLock.lock(); defer { historyLock.unlock() }
        actionHistory.append(ActionRecord(videoAction: videoAction, audioAction: audioAction,
                                          videoConfidence: videoConf, audioConfidence: audioConf,
                                          timestamp: Date().timeIntervalSince1970))
        while actionHistory.count > SMOOTH_WINDOW_SIZE { actionHistory.removeFirst() }
        if actionHistory.count < 3 {
            return selectBestAction(vA: videoAction, aA: audioAction, vC: videoConf, aC: audioConf)
        }
        var scores = [String: Float](); var counts = [String: Int]()
        for (i, rec) in actionHistory.enumerated() {
            let w = Float(i + 1) / Float(actionHistory.count)
            if !rec.videoAction.isEmpty && rec.videoAction != "Background" {
                scores[rec.videoAction, default: 0] += rec.videoConfidence * w * 0.7
                counts[rec.videoAction, default: 0] += 1
            }
            if !rec.audioAction.isEmpty {
                scores[rec.audioAction, default: 0] += rec.audioConfidence * w * 1.3
                counts[rec.audioAction, default: 0] += 1
            }
        }
        var best = ""; var bestScore: Float = 0
        for (a, s) in scores { if (counts[a] ?? 0) >= 3 && s > bestScore { bestScore = s; best = a } }
        if best.isEmpty, let last = actionHistory.last {
            best = selectBestAction(vA: last.videoAction, aA: last.audioAction,
                                    vC: last.videoConfidence, aC: last.audioConfidence)
        }
        return best
    }

    private func selectBestAction(vA: String, aA: String, vC: Float, aC: Float) -> String {
        if !aA.isEmpty && (aA != "Noise" || aC > 0.7) { return aA }
        if !vA.isEmpty && vA != "Background" && (vA != "Noise" || vC > 0.7) { return vA }
        if aA == "Noise" || vA == "Noise" { return "Noise" }
        return ""
    }

    private func updateBluetoothState(_ newAction: String, _ finalFreq: Int) {
        let now = Date().timeIntervalSince1970 * 1000
        if BluetoothManager.shared.isPausedByLocal { return }
        let supportsLevel = isSexAction(newAction) && currentStateSupportsSpeed()
        if supportsLevel {
            if finalFreq >= upThreshold(currentLevel) || finalFreq <= downThreshold(currentLevel) {
                if pendingLevel == nil || pendingLevel! != finalFreq {
                    pendingLevel = finalFreq; pendingLevelSinceMs = now
                } else if (now - pendingLevelSinceMs >= LEVEL_STABLE_MS) &&
                          (now - currentLevelSinceMs >= LEVEL_MIN_DUR_MS) {
                    currentLevel = pendingLevel!; currentLevelSinceMs = now
                }
            } else { pendingLevel = nil }
        } else { pendingLevel = nil }

        if newAction != pendingBluetoothState { pendingBluetoothState = newAction; pendingStateStartTime = now }
        let stableMs: TimeInterval = (isSexAction(currentBluetoothState) && newAction == "Noise")
            ? 2400 : BLUETOOTH_STABLE_CONFIRM_MS

        if pendingBluetoothState == newAction && (now - pendingStateStartTime) >= stableMs {
            if pendingBluetoothState != currentBluetoothState {
                if currentBluetoothState.isEmpty || (now - currentStateStartTime) >= BLUETOOTH_MIN_DURATION {
                    if (now - lastBluetoothSendTime) >= BLUETOOTH_SEND_INTERVAL {
                        let lvl = supportsLevel ? currentLevel : finalFreq
                        latestBluetoothAction = pendingBluetoothState
                        if BluetoothManager.shared.isConnected {
                            BluetoothManager.shared.sendAction(pendingBluetoothState, lvl)
                            lastSentLevel = lvl
                        }
                        currentBluetoothState = pendingBluetoothState
                        currentStateStartTime = now; lastBluetoothSendTime = now
                    }
                }
            } else {
                if supportsLevel && currentLevel != lastSentLevel &&
                   (now - lastBluetoothSendTime) >= LEVEL_SEND_GAP_MS {
                    if BluetoothManager.shared.isConnected {
                        BluetoothManager.shared.sendAction(currentBluetoothState, currentLevel)
                        lastSentLevel = currentLevel; lastBluetoothSendTime = now
                    }
                }
            }
        }
    }

    @inline(__always) private func upThreshold(_ c: Int)   -> Int { min(10, c + 1) }
    @inline(__always) private func downThreshold(_ c: Int) -> Int { max(0,  c - 1) }
    private func isSexAction(_ a: String) -> Bool {
        let l = a.lowercased(); return l.hasPrefix("do") || l.hasPrefix("oral")
    }
    private func currentStateSupportsSpeed() -> Bool {
        let l = currentBluetoothState.lowercased(); return l.hasPrefix("do") || l.hasPrefix("oral")
    }
}
