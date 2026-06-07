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
    // private var inferenceHelper:        InferenceHelper!     // 已弃用：ML Kit + ST-GCN++
    private var videoClassifier:        VideoClassifierHelper!  // MobileNetV3Small + TAP + 3class
    private var audioHelper:            AudioInferenceHelper!
    private var audioLoudnessEstimator: AudioLoudnessLevelEstimator!
    // private var videoRhythmEstimator:   VideoMotionWaveEstimator!  // 视频节律已移除
    private var pcmBuffer:              PcmCircularBuffer!
    private let analysisResults =       ThreadSafeAnalysisResults()

    // MARK: - 分析队列与循环
    private let videoAnalysisQueue = DispatchQueue(label: "com.xcup.online.video",  qos: .userInitiated)
    private let audioAnalysisQueue = DispatchQueue(label: "com.xcup.online.audio",  qos: .userInitiated)
    private let VIDEO_INTERVAL_MS:    Int64 = 250    // 抽帧轮询 250ms
    private let VIDEO_INFER_STEP_MS:  Int64 = 1000   // 推理步长 1s
    private let AUDIO_INTERVAL_MS:    Int64 = 1000
    private let FUSION_INTERVAL_MS:   Int64 = 1000   // 主线程融合 1s
    private var videoLoopItem:  DispatchWorkItem?
    private var audioLoopItem:  DispatchWorkItem?
    private var fusionLoopItem: DispatchWorkItem?

    // MARK: - 视频分类滑动窗口（12 帧 × 160×160，3s 窗口）
    private let FRAME_BUFFER_SIZE: Int = VideoClassifierHelper.TIME
    private var frameBuffer: [UIImage] = []
    private var lastVideoInferenceMs: Int64 = 0

    // MARK: - 阈值（与 VideoProcessViewController 一致）
    private let VIDEO_CONF_TH:     Float = 0.4
    private let AUDIO_TH_NOISE:    Float = 0.6
    private let AUDIO_TH_ACTION:   Float = 0.5

    // MARK: - 分析暂停状态
    private let stateLock = NSLock()
    private var _isPaused = true
    private var isAnalysisPaused: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _isPaused }
        set { stateLock.lock(); defer { stateLock.unlock() }; _isPaused = newValue }
    }

    /* 旧版姿态窗口（ST-GCN++），已弃用：
    private var poseWindow: [PoseFrame] = []
    private let WINDOW_SIZE  = 32
    private let MULTI_STEP   = 8
    private var framesSinceLastMulti = 0
    */

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

    // VAD（子窗口 + RMS/Peak dBFS + 迟滞）
    // samples 已是 mono Float32 / [-1,1]，dBFS 公式直接对归一化值取 20*log10
    private let VAD_SUB_WINDOWS:       Int   = 4
    private let VAD_ACTIVATE_RMS_DB:   Float = -55.0   // 当前"无声" → 激活阈值（较严格）
    private let VAD_ACTIVATE_PEAK_DB:  Float = -42.0
    private let VAD_KEEP_RMS_DB:       Float = -60.0   // 当前"有声" → 保持阈值（较宽松，避免抖动）
    private let VAD_KEEP_PEAK_DB:      Float = -48.0
    private let VAD_LOG_INTERVAL_MS:   Int64 = 5000
    private var lastVadLogTimeMs:      Int64 = 0

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
        view.backgroundColor = .md3Background

        // 屏幕预览（广播开始后显示）
        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        previewImageView.contentMode = .scaleAspectFit
        previewImageView.backgroundColor = .md3Background
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
            label.font             = .systemFont(ofSize: 12, weight: .medium)
            label.text             = titles[i]
            label.backgroundColor  = UIColor.black.withAlphaComponent(0.55)
            label.layer.cornerRadius = 8
            label.layer.cornerCurve  = .continuous
            label.clipsToBounds    = true
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
                label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor,
                                           constant: CGFloat(12 + i * 26))
            ])
        }

        // 状态标签（顶部居中）
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor        = .white
        statusLabel.font             = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.text             = ""
        statusLabel.backgroundColor  = UIColor.black.withAlphaComponent(0.6)
        statusLabel.layer.cornerRadius = 10
        statusLabel.layer.cornerCurve  = .continuous
        statusLabel.clipsToBounds    = true
        statusLabel.textAlignment    = .center
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

        // 返回主页面按钮：z 轴最高，始终在覆盖层之上可点击
        btnStop.translatesAutoresizingMaskIntoConstraints = false
        btnStop.setTitle("返回主页面", for: .normal)
        btnStop.setTitleColor(.md3OnError, for: .normal)
        btnStop.backgroundColor    = .md3Error
        btnStop.layer.cornerRadius = 20
        btnStop.layer.cornerCurve  = .continuous
        btnStop.titleLabel?.font   = .systemFont(ofSize: 15, weight: .medium)
        btnStop.addTarget(self, action: #selector(onStopTapped), for: .touchUpInside)
        view.addSubview(btnStop)
        NSLayoutConstraint.activate([
            btnStop.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            btnStop.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            btnStop.widthAnchor.constraint(equalToConstant: 120),
            btnStop.heightAnchor.constraint(equalToConstant: 40)
        ])
    }

    private func setupStartOverlay() {
        startOverlay.translatesAutoresizingMaskIntoConstraints = false
        startOverlay.backgroundColor = .md3Background
        view.addSubview(startOverlay)
        NSLayoutConstraint.activate([
            startOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            startOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            startOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            startOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

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

        // ── 可滚动内容区域（提示内容较多，小屏设备可能需要滚动）──
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsVerticalScrollIndicator = false
        startOverlay.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: startOverlay.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: startOverlay.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: startOverlay.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: startOverlay.bottomAnchor)
        ])

        let contentView = UIView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])

        // 图标（MD3 hero icon）
        let iconView = UIImageView()
        iconView.image = UIImage(systemName: "dot.radiowaves.left.and.right",
                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: 56, weight: .regular))
        iconView.tintColor = .md3Primary
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        // 标题（MD3 Headline Medium）
        let titleLabel = UILabel()
        titleLabel.text = "在线模式"
        titleLabel.font = .systemFont(ofSize: 28, weight: .medium)
        titleLabel.textColor = .md3OnBackground
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        // 说明文字（MD3 Body Medium）
        let descLabel = UILabel()
        descLabel.text = "点击下方按钮，在弹出的系统对话框中选择「开始直播」即开始在线视频模式，可以返回桌面，观看在线视频。所有信息皆在本地处理，不会上传至服务器。"
        descLabel.font = .systemFont(ofSize: 14, weight: .regular)
        descLabel.textColor = .md3OnSurfaceVariant
        descLabel.textAlignment = .center
        descLabel.numberOfLines = 0
        descLabel.translatesAutoresizingMaskIntoConstraints = false

        // ── 用户提示卡片 ──
        let tip1 = makeTipCard(
            icon: "play.rectangle",
            title: "推荐观看方式",
            body: "建议将手机横屏并全屏播放视频，识别效果最佳。"
        )
        let tip2 = makeTipCard(
            icon: "exclamationmark.triangle",
            title: "温馨提示",
            body: "部分浏览器（如 Chrome、Firefox）出于安全考虑，会自动将屏幕共享中的视频画面遮黑，并显示「为了安全起见，屏幕共享画面已隐藏此应用的内容」等提示。为了保证分析的准确性，录屏模式建议使用对应视频网站的官方 App 直接观看视频（部分 App 会禁止屏幕/音频抓取）。"
        )
        let tip3 = makeTipCard(
            icon: "stop.circle",
            title: "退出提示",
            body: "如需退出在线分析，可点击屏幕上方通知栏「直播屏幕」，并点击停止按钮。"
        )

        // ── MD3 Filled Primary 按钮 ──
        let broadcastBtn = UIButton(type: .system)
        broadcastBtn.translatesAutoresizingMaskIntoConstraints = false
        broadcastBtn.setTitle("开始广播", for: .normal)
        broadcastBtn.setTitleColor(.md3OnPrimary, for: .normal)
        broadcastBtn.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        broadcastBtn.backgroundColor = .md3Primary
        broadcastBtn.layer.cornerRadius = 28
        broadcastBtn.layer.cornerCurve = .continuous
        broadcastBtn.layer.masksToBounds = true
        broadcastBtn.addTarget(self, action: #selector(onBroadcastButtonTapped), for: .touchUpInside)

        [iconView, titleLabel, descLabel, tip1, tip2, tip3, broadcastBtn].forEach {
            contentView.addSubview($0)
        }

        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            iconView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 40),
            iconView.widthAnchor.constraint(equalToConstant: 80),
            iconView.heightAnchor.constraint(equalToConstant: 80),

            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 16),
            titleLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

            descLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            descLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 32),
            descLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -32),

            tip1.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 24),
            tip1.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            tip1.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            tip2.topAnchor.constraint(equalTo: tip1.bottomAnchor, constant: 12),
            tip2.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            tip2.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            tip3.topAnchor.constraint(equalTo: tip2.bottomAnchor, constant: 12),
            tip3.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            tip3.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            broadcastBtn.topAnchor.constraint(equalTo: tip3.bottomAnchor, constant: 32),
            broadcastBtn.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            broadcastBtn.widthAnchor.constraint(equalToConstant: 220),
            broadcastBtn.heightAnchor.constraint(equalToConstant: 56),
            broadcastBtn.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -40)
        ])
    }

    private func makeTipCard(icon: String, title: String, body: String) -> UIView {
        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = .md3Surface
        card.layer.cornerRadius = 12
        card.layer.cornerCurve = .continuous

        let iconView = UIImageView()
        iconView.image = UIImage(systemName: icon,
                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        iconView.tintColor = .md3Primary
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .md3OnSurface
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let bodyLabel = UILabel()
        bodyLabel.text = body
        bodyLabel.font = .systemFont(ofSize: 13, weight: .regular)
        bodyLabel.textColor = .md3OnSurfaceVariant
        bodyLabel.numberOfLines = 0
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false

        [iconView, titleLabel, bodyLabel].forEach { card.addSubview($0) }

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            iconView.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),

            bodyLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 8),
            bodyLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            bodyLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            bodyLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14)
        ])

        return card
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
        // 旧的 ML Kit + ST-GCN++ 已弃用：
        // inferenceHelper        = InferenceHelper()
        // inferenceHelper.setupPoseDetector()
        videoClassifier        = VideoClassifierHelper()
        audioHelper            = AudioInferenceHelper()
        audioLoudnessEstimator = AudioLoudnessLevelEstimator(sampleRate: 16000)
        // videoRhythmEstimator   = VideoMotionWaveEstimator()  // 视频节律已移除
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
        let wasActive = !isAnalysisPaused
        let hasAudio  = detectAudioActivity(samples: samples, currentlyActive: wasActive)
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

    /// 子窗口 + RMS/Peak(dBFS) + 迟滞 的 VAD（对位 Android `detectAudioActivity`）。
    /// samples 已是单声道 Float32，归一化到 [-1, 1]。
    private func detectAudioActivity(samples: [Float], currentlyActive: Bool) -> Bool {
        let sampleCount = samples.count
        if sampleCount <= 0 { return currentlyActive }

        let samplesPerWindow = max(1, sampleCount / VAD_SUB_WINDOWS)

        let rmsThreshold  = currentlyActive ? VAD_KEEP_RMS_DB  : VAD_ACTIVATE_RMS_DB
        let peakThreshold = currentlyActive ? VAD_KEEP_PEAK_DB : VAD_ACTIVATE_PEAK_DB

        var active = false
        var maxRmsDb:  Float = -.infinity
        var maxPeakDb: Float = -.infinity

        samples.withUnsafeBufferPointer { ptr in
            for w in 0..<VAD_SUB_WINDOWS {
                let start = w * samplesPerWindow
                let end   = (w == VAD_SUB_WINDOWS - 1) ? sampleCount : min(start + samplesPerWindow, sampleCount)
                let subCount = end - start
                if subCount <= 0 { continue }

                var sumSquare: Double = 0
                var peakAbs:   Float  = 0
                for i in start..<end {
                    let s = ptr[i]
                    let a = abs(s)
                    if a > peakAbs { peakAbs = a }
                    sumSquare += Double(s) * Double(s)
                }

                let rms    = sqrt(sumSquare / Double(subCount))
                let peak   = Double(peakAbs)
                let rmsDb  = Float(20.0 * log10(max(rms,  1e-9)))
                let peakDb = Float(20.0 * log10(max(peak, 1e-9)))

                if rmsDb  > maxRmsDb  { maxRmsDb  = rmsDb }
                if peakDb > maxPeakDb { maxPeakDb = peakDb }

                if rmsDb > rmsThreshold || peakDb > peakThreshold {
                    active = true
                }
            }
        }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if nowMs - lastVadLogTimeMs > VAD_LOG_INTERVAL_MS {
            lastVadLogTimeMs = nowMs
            print(String(format: "[音频检测] maxSubRMS=%.1fdB maxSubPeak=%.1fdB -> active=%@ (state=%@, th: RMS>%.0fdB or Peak>%.0fdB)",
                         maxRmsDb, maxPeakDb,
                         active ? "true" : "false",
                         currentlyActive ? "ACTIVE" : "SILENT",
                         rmsThreshold, peakThreshold))
        }

        return active
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

        // 清空视频分类窗口
        videoAnalysisQueue.async { [weak self] in
            self?.frameBuffer.removeAll()
            self?.lastVideoInferenceMs = 0
        }

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
    //
    // 每 250ms 一轮：取一帧 → 缩放到 160×160 → 推入环形缓冲（最多 12 帧 = 3 秒窗口）
    //   若 缓冲 < 12 帧：return（预热）
    //   若 now - lastVideoInferenceMs < 1000ms：return
    //   否则：classifier.predict(12帧) → applyVideoResult()
    private func performVideoAnalysis() {
        frameLock.lock()
        let frame = latestFrame
        latestFrame = nil
        frameLock.unlock()
        guard let frame = frame else { return }

        // 1. 缩放为 160×160（在线模式原帧通常是全屏 JPEG，及早压小避免缓冲占用过多内存）
        guard let frame160 = VideoClassifierHelper.resizeTo160(frame) else {
            print("❌ [在线-视频] 帧缩放失败")
            return
        }

        // 2. 推入环形缓冲（最多 12 帧）
        frameBuffer.append(frame160)
        if frameBuffer.count > FRAME_BUFFER_SIZE {
            frameBuffer.removeFirst(frameBuffer.count - FRAME_BUFFER_SIZE)
        }

        // 3. 预热不足
        if frameBuffer.count < FRAME_BUFFER_SIZE { return }

        // 4. 推理步长门控（1000ms）
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if nowMs - lastVideoInferenceMs < VIDEO_INFER_STEP_MS { return }
        lastVideoInferenceMs = nowMs

        // 5. 推理
        let inferStart = Date()
        guard let result = videoClassifier.predict(frames: frameBuffer) else {
            print("❌ [在线-视频] MobileNetV3 推理失败")
            return
        }
        let inferMs = Date().timeIntervalSince(inferStart) * 1000
        let probs = result.probs

        // 6. 阈值映射（单一阈值 0.4，低于则 unclear）
        //    索引 0=normal_plot -> "Noise"（不转）
        //    索引 1=oral / 2=sex -> "do"（转）
        let action: String
        let confidence: Float

        if result.index < 0 {
            action = ""
            confidence = 0
        } else if result.confidence < VIDEO_CONF_TH {
            action = ""
            confidence = 0
            print(String(format: "📸 [在线-视频] unclear: 最大概率=%.3f < 阈值=%.2f (idx=%d)",
                         result.confidence, VIDEO_CONF_TH, result.index))
        } else if result.index == 0 {
            action = "Noise"
            confidence = result.confidence
        } else {
            action = "do"
            confidence = result.confidence
        }

        print(String(format: "📸 [在线-视频] 推理 %.1fms | %@ p=%.3f | normal=%.3f oral=%.3f sex=%.3f",
                     inferMs,
                     action.isEmpty ? "(unclear)" : action,
                     confidence,
                     probs.count > 0 ? probs[0] : 0,
                     probs.count > 1 ? probs[1] : 0,
                     probs.count > 2 ? probs[2] : 0))

        analysisResults.videoResult = (action, confidence, Date().timeIntervalSince1970 * 1000)

        DispatchQueue.main.async {
            if action.isEmpty {
                self.tvVideoAction.text = "V: (unclear)"
            } else {
                self.tvVideoAction.text = String(format: "V: %@ (%.2f)", action, confidence)
            }
        }
    }

    // MARK: - 音频分析
    //
    // YAMNet + 微调分类器输出索引：0=do(sex), 1=oral, 2=Noise
    //   index<0 → "" (unclear)
    //   index==2 noise: 置信度 ≥ AUDIO_TH_NOISE → "Noise"
    //   index==0/1 sex/oral: 置信度 ≥ AUDIO_TH_ACTION → "do"
    private func performAudioAnalysis() {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if let segment = pcmBuffer.readWindowRelaxed(currentTimeMs: nowMs, sampleCount: 32000) {
            let (index, confidence) = audioHelper.predict(audioBuffer: segment)

            let action: String
            let outConf: Float

            if index < 0 {
                action = ""
                outConf = 0
            } else if index == 2 {
                if confidence >= AUDIO_TH_NOISE {
                    action = "Noise"
                    outConf = confidence
                } else {
                    action = ""
                    outConf = 0
                    print(String(format: "🎵 [在线-音频] Noise unclear: p=%.3f < %.2f",
                                 confidence, AUDIO_TH_NOISE))
                }
            } else {
                if confidence >= AUDIO_TH_ACTION {
                    action = "do"
                    outConf = confidence
                } else {
                    action = ""
                    outConf = 0
                    print(String(format: "🎵 [在线-音频] do unclear: p=%.3f < %.2f (idx=%d)",
                                 confidence, AUDIO_TH_ACTION, index))
                }
            }

            analysisResults.audioResult = (action, outConf, Date().timeIntervalSince1970 * 1000)
            print(String(format: "🎵 [在线-音频] 识别结果: %@ (idx=%d, raw_p=%.3f)",
                         action.isEmpty ? "(unclear)" : action, index, confidence))

            DispatchQueue.main.async {
                if action.isEmpty {
                    self.tvAudioAction.text = "A: (unclear)"
                } else {
                    self.tvAudioAction.text = String(format: "A: %@ (%.2f)", action, outConf)
                }
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
        // 视频节律已移除
        // let vFreqRes = analysisResults.videoFreq
        let now      = Date().timeIntervalSince1970 * 1000
        let MAX_AGE  = 2000.0

        let vAge    = vRes.timestamp > 0 ? now - vRes.timestamp        : Double.greatestFiniteMagnitude
        let aAge    = aRes.timestamp > 0 ? now - aRes.timestamp        : Double.greatestFiniteMagnitude
        let loudAge = loud.tsMs > 0      ? now - Double(loud.tsMs)     : Double.greatestFiniteMagnitude

        let vAction = vAge  < MAX_AGE ? vRes.action     : ""
        let aAction = aAge  < MAX_AGE ? aRes.action     : ""
        let vConf   = vAge  < MAX_AGE ? vRes.confidence : Float(0)
        let aConf   = aAge  < MAX_AGE ? aRes.confidence : Float(0)
        let aLevel: Float  = (loud.valid && loudAge < MAX_AGE) ? Float(loud.level) : .nan
        let aLConf: Float  = (loud.valid && loudAge < MAX_AGE) ? loud.conf : 0

        // 视频/音频统一词表已经是 {"do", "Noise", ""}，不再需要 oral→do 映射
        // if vAction == "oral" { vAction = "do" }
        // if aAction == "oral" { aAction = "do" }

        let finalFreq   = computeFinalFreq(audioHz: aLevel, audioConf: aLConf, videoHz: .nan, videoConf: 0)
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
    // 计算最终节律档位：当前先以“音频节律”为主，但带置信度阈值 + 方向性门控（涨档更严格、降档更宽松）
    private func computeFinalFreq(
        audioHz: Float, audioConf: Float,
        videoHz: Float, videoConf: Float
    ) -> Int {

        // 先做“临时策略”：candidate 仍以音频为主（后续要融合音视频节律，就只改这里）
        // var finalFreq = mapFreqToLevel(audioHz)
        var finalFreq = clampLevelFromLoudness(audioHz)  // [MOD] audioHz 实际承载的是 loudness level

        let videoLvl = mapFreqToLevel(videoHz)

        // 日志：对齐 Android，方便你对比
        NSLog("[视频节律] 得到视频节律: %.3f 置信度: %.3f 档位: %d", videoHz, videoConf, videoLvl)
        NSLog("[音频节律] 得到音频节律: %.3f 置信度: %.3f 档位: %d", audioHz, audioConf, finalFreq)

        // === 方向性置信度门控（涨档更严格，降档更宽松） ===
        let CONF_IGNORE: Float = 0.10   // 极低置信度：整体忽略本次节律
        let CONF_UP: Float     = 0.10   // 涨档所需置信度（更严格）
        let CONF_DOWN: Float   = 0.10   // 降档所需置信度（相对宽松）

        let curLevel = self.currentLevel              // 当前已生效档位（0..10）:contentReference[oaicite:2]{index=2}
        let candidateLevel = finalFreq                // 本次根据 audioHz 映射出的档位

        // 1) 极低置信度 or 无效频率：直接忽略，沿用 currentLevel（不给 updateBluetoothState 变档机会）
        if audioHz.isNaN || audioConf < CONF_IGNORE {
            NSLog("[音频节律] conf=%.2f < CONF_IGNORE=%.2f，本次节律整体忽略，沿用 currentLevel=%d",
                  audioConf, CONF_IGNORE, curLevel)
            finalFreq = curLevel
            return finalFreq
        }

        // 2) 按“变档方向”应用不同门槛
        if candidateLevel > curLevel && audioConf < CONF_UP {
            NSLog("[音频节律] 尝试涨档 %d→%d 但 conf=%.2f < CONF_UP=%.2f，本次不生效，沿用 currentLevel=%d",
                  curLevel, candidateLevel, audioConf, CONF_UP, curLevel)
            finalFreq = curLevel
        } else if candidateLevel < curLevel && audioConf < CONF_DOWN {
            NSLog("[音频节律] 尝试降档 %d→%d 但 conf=%.2f < CONF_DOWN=%.2f，本次不生效，沿用 currentLevel=%d",
                  curLevel, candidateLevel, audioConf, CONF_DOWN, curLevel)
            finalFreq = curLevel
        }
        // candidateLevel == curLevel：无需处理

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
    
    // [ADD] audioHz 实际承载的是 loudness level（Float），这里钳制到 0..8
    private func clampLevelFromLoudness(_ levelLike: Float) -> Int {
        if levelLike.isNaN { return 0 }
        var lv = Int(levelLike.rounded())
        if lv < 0 { lv = 0 }
        if lv > 8 { lv = 8 }
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
                scores[rec.audioAction, default: 0] += rec.audioConfidence * w * 1.2
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

    // MARK: - 更新蓝牙状态 - 二级平滑策略
    private func updateBluetoothState(_ newAction: String, _ finalFreq: Int) {
        let currentTime = Date().timeIntervalSince1970 * 1000  // ms
        
        // 1) 本地暂停保护
        if BluetoothManager.shared.isPausedByLocal {
            print("[蓝牙] ⚠️ 设备已暂停App控制，忽略动作: \(newAction)")
            return
        }
        
        // ===================== [档位确认：立即生效版] =====================
        // 只根据本轮 newAction 判断是否支持变速。
        // 不再依赖 currentBluetoothState，避免 Noise -> do/oral 时档位状态不同步。
        let supportsLevel = isSexAction(newAction)
        
        if supportsLevel {
            var latestLevel = finalFreq
            
            // 安全钳制到 0..8，与 Android 新逻辑一致
            if latestLevel < 0 { latestLevel = 0 }
            if latestLevel > 8 { latestLevel = 8 }
            
            // 迟滞：只有跨过 currentLevel ± 1 才认为值得处理
            let worthHandling =
                latestLevel >= upThreshold(currentLevel) ||
                latestLevel <= downThreshold(currentLevel)
            
            if worthHandling {
                // 关键修复：
                // LEVEL_STABLE_MS = 0 时，第一次看到新档位就立即生效，
                // 不再要求连续两轮融合循环给出同一档位。
                if LEVEL_STABLE_MS <= 0 &&
                    (currentTime - currentLevelSinceMs >= LEVEL_MIN_DUR_MS) {
                    
                    if latestLevel != currentLevel {
                        print(String(format: "[档位确认] 立即生效: %d -> %d",
                                     currentLevel,
                                     latestLevel))
                    }
                    
                    currentLevel = latestLevel
                    currentLevelSinceMs = currentTime
                    pendingLevel = nil
                    pendingLevelSinceMs = 0
                    
                } else {
                    // 如果以后 LEVEL_STABLE_MS 改成 >0，则走短稳确认逻辑
                    if pendingLevel == nil || pendingLevel! != latestLevel {
                        pendingLevel = latestLevel
                        pendingLevelSinceMs = currentTime
                        
                        print(String(format: "[档位确认] 新 pendingLevel=%d，开始等待稳定",
                                     latestLevel))
                        
                    } else {
                        let dwell = currentTime - pendingLevelSinceMs
                        let stableOk = dwell >= LEVEL_STABLE_MS
                        let minDurOk = currentTime - currentLevelSinceMs >= LEVEL_MIN_DUR_MS
                        
                        if stableOk && minDurOk {
                            if pendingLevel! != currentLevel {
                                print(String(format: "[档位确认] pending 生效: %d -> %d, dwell=%.0fms",
                                             currentLevel,
                                             pendingLevel!,
                                             dwell))
                            }
                            
                            currentLevel = pendingLevel!
                            currentLevelSinceMs = currentTime
                            pendingLevel = nil
                            pendingLevelSinceMs = 0
                        }
                    }
                }
            } else {
                // 未跨过迟滞门槛，不处理档位变化
                pendingLevel = nil
                pendingLevelSinceMs = 0
            }
        } else {
            // Noise 或其他不支持变速的动作，不处理档位
            pendingLevel = nil
            pendingLevelSinceMs = 0
        }
        // ===================== [档位确认结束] =====================
        
        
        // ===================== [动作待确认] =====================
        if newAction != pendingBluetoothState {
            pendingBluetoothState = newAction
            pendingStateStartTime = currentTime
            print(String(format: "[蓝牙] 检测到新动作: %@, 等待确认...", newAction))
        }
        
        // 动作稳定确认时间：
        // 默认 0ms；如果从 do/oral 切到 Noise，则延长到 1000ms，避免动作中突然停。
        var actionStableMs: TimeInterval = 0
        if isSexAction(currentBluetoothState) && newAction == "Noise" {
            actionStableMs = 1000
        }
        
        let actionStableOk =
            pendingBluetoothState == newAction &&
            (currentTime - pendingStateStartTime) >= actionStableMs
        
        if !actionStableOk {
            print(String(format: "[蓝牙] 动作尚未稳定: pending=%@, new=%@, 已稳定=%.0fms, 需要=%.0fms",
                         pendingBluetoothState,
                         newAction,
                         currentTime - pendingStateStartTime,
                         actionStableMs))
            return
        }
        
        
        // ===================== 情况 A：动作发生变化 =====================
        if pendingBluetoothState != currentBluetoothState {
            
            let minDurationOk =
                currentBluetoothState.isEmpty ||
                (currentTime - currentStateStartTime) >= BLUETOOTH_MIN_DURATION
            
            if !minDurationOk {
                let remainingTime = BLUETOOTH_MIN_DURATION - (currentTime - currentStateStartTime)
                print(String(format: "[蓝牙] 当前动作%@需继续保持%.0fms，暂不切换到%@",
                             currentBluetoothState,
                             remainingTime,
                             pendingBluetoothState))
                return
            }
            
            let gapOk = (currentTime - lastBluetoothSendTime) >= BLUETOOTH_SEND_INTERVAL
            
            if !gapOk {
                print(String(format: "[蓝牙] 动作切换等待发送间隔: gap=%.0fms, need=%.0fms",
                             currentTime - lastBluetoothSendTime,
                             BLUETOOTH_SEND_INTERVAL))
                return
            }
            
            let levelToSend: Int
            if isSexAction(pendingBluetoothState) {
                // 切换到 do/oral 时，携带当前已确认档位
                levelToSend = currentLevel
            } else {
                // 切换到 Noise 时，档位置 0
                levelToSend = 0
            }
            
            print(String(format: "[蓝牙] [同步分析] ✅ 发送指令: action=%@, level=%d, 已稳定=%.0fms",
                         pendingBluetoothState,
                         levelToSend,
                         currentTime - pendingStateStartTime))
            
            latestBluetoothAction = pendingBluetoothState
            
            if BluetoothManager.shared.isConnected {
                BluetoothManager.shared.sendAction(pendingBluetoothState, levelToSend)
                print("[蓝牙] [同步分析] ✅ 已通过BLE发送指令(动作切换/含档位)")
                print("[音频节律] ✅ 发送节律：\(levelToSend)")
            } else {
                print("[蓝牙] BLE未连接，仅更新UI显示")
            }
            
            currentBluetoothState = pendingBluetoothState
            currentStateStartTime = currentTime
            lastBluetoothSendTime = currentTime
            
            // 关键同步：
            // 保证 currentLevel / lastSentLevel / 实际发送档位一致。
            if isSexAction(currentBluetoothState) {
                currentLevel = levelToSend
                currentLevelSinceMs = currentTime
                lastSentLevel = levelToSend
            } else {
                lastSentLevel = 0
            }
            
            return
        }
        
        
        // ===================== 情况 B：动作未变，但档位变化 =====================
        // 例如当前仍然是 do，但档位从 8 降到 4。
        // 由于协议没有单独速度帧，所以重发同一动作并携带新档位。
        let levelChanged = supportsLevel && (currentLevel != lastSentLevel)
        let gapOk = (currentTime - lastBluetoothSendTime) >= BLUETOOTH_SEND_INTERVAL
        
        print(String(format: "[档位发送判断] action=%@, supportsLevel=%@, currentLevel=%d, lastSentLevel=%d, levelChanged=%@, gapOk=%@, gap=%.0fms",
                     currentBluetoothState,
                     supportsLevel ? "true" : "false",
                     currentLevel,
                     lastSentLevel,
                     levelChanged ? "true" : "false",
                     gapOk ? "true" : "false",
                     currentTime - lastBluetoothSendTime))
        
        if levelChanged && gapOk {
            let levelToSend = currentLevel
            
            print(String(format: "[蓝牙] 同动作更新档位：%@ -> level=%d",
                         currentBluetoothState,
                         levelToSend))
            
            if BluetoothManager.shared.isConnected {
                BluetoothManager.shared.sendAction(currentBluetoothState, levelToSend)
                print("[蓝牙] [同步分析] ✅ 已通过BLE发送指令(同动作/更新档位)")
                print("[音频节律] ✅ 发送节律：\(levelToSend)")
            } else {
                print("[蓝牙] BLE未连接，无法更新档位（同动作）")
            }
            
            lastSentLevel = levelToSend
            lastBluetoothSendTime = currentTime
        }
    }

    // ===================== 蓝牙更新状态的工具类函数 =====================

    // 迟滞阈值
    @inline(__always) private func upThreshold(_ cur: Int) -> Int {
        return min(8, cur + 1)
    }

    @inline(__always) private func downThreshold(_ cur: Int) -> Int {
        return max(0, cur - 1)
    }

    // 当前动作是否属于支持变速的动作
    private func isSexAction(_ action: String) -> Bool {
        let lower = action.lowercased()
        return lower.hasPrefix("do") || lower.hasPrefix("oral")
    }

    // 新版 updateBluetoothState 已不再依赖这个函数。
    // 如果其他地方没用，可以保留，也可以删除。
    private func currentStateSupportsSpeed() -> Bool {
        let lower = currentBluetoothState.lowercased()
        return lower.hasPrefix("do") || lower.hasPrefix("oral")
    }
}
