//
//  WebVideoAnalysisViewController.swift
//  Xcup
//
//  网页视频模式的"分析页"：
//   - AVPlayer 重放从 WebView 嗅到的视频流（mp4 / m3u8）
//   - 同时输出到屏幕（用户看的） + 抽帧到 160×160（视频模型用）+ tap PCM（音频模型用）
//   - 复用 VideoClassifierHelper / AudioInferenceHelper / AudioLoudnessLevelEstimator
//     / smoothedFusion / updateBluetoothState 全链路
//   - VAD 驱动 pauseAnalysis / resumeAnalysis（不依赖 player.rate，因为广告/缓冲会误判）
//   - 用户拖动进度条 → onUserSeek → 清状态
//
//  对应 Android: VideoProcessActivity 的 setupExoPlayerForWebMode 分支
//

import UIKit
import AVFoundation
import CoreBluetooth

class WebVideoAnalysisViewController: UIViewController {

    // MARK: - 由调用方设置（presentAnalysisVC 注入）
    var videoURL: URL!
    var requestHeaders: [String: String] = [:]
    var startMs: Int64 = 0

    // MARK: - UI
    private let videoView = UIView()
    private let tvVideoAction = UILabel()
    private let tvAudioAction = UILabel()
    private let tvOverlay = UILabel()
    private let progressSlider = UISlider()
    private let currentTimeLabel = UILabel()
    private let totalTimeLabel = UILabel()
    private let btnPlayPause = UIButton(type: .system)
    private let btnClose = UIButton(type: .system)
    private let statusLabel = UILabel()  // "等待声音" / "在线分析中"

    // MARK: - 播放引擎
    private var engine: WebVideoPlayerEngine!
    private var pcmBuffer: PcmCircularBuffer!

    // MARK: - 推理模块
    private var videoClassifier: VideoClassifierHelper!
    private var audioHelper: AudioInferenceHelper!
    private var audioLoudnessEstimator: AudioLoudnessLevelEstimator!
    private let analysisResults = ThreadSafeAnalysisResults()

    // MARK: - 分析队列与循环
    private let videoAnalysisQueue = DispatchQueue(label: "com.xcup.webvideo.video", qos: .userInitiated)
    private let audioAnalysisQueue = DispatchQueue(label: "com.xcup.webvideo.audio", qos: .userInitiated)
    private let VIDEO_INTERVAL_MS:   Int64 = 250
    private let VIDEO_INFER_STEP_MS: Int64 = 1000
    private let AUDIO_INTERVAL_MS:   Int64 = 1000
    private let FUSION_INTERVAL_MS:  Int64 = 1000
    private var videoLoopItem:  DispatchWorkItem?
    private var audioLoopItem:  DispatchWorkItem?
    private var fusionLoopItem: DispatchWorkItem?

    // MARK: - 视频分类滑动窗口（12 帧 × 160×160）
    private let FRAME_BUFFER_SIZE: Int = VideoClassifierHelper.TIME
    private var frameBuffer: [UIImage] = []
    private var lastVideoInferenceMs: Int64 = 0

    // MARK: - 阈值
    private let VIDEO_CONF_TH: Float = 0.4
    private let AUDIO_TH_NOISE: Float = 0.6
    private let AUDIO_TH_ACTION: Float = 0.5

    // MARK: - 平滑融合
    private var actionHistory: [ActionRecord] = []
    private let historyLock = NSLock()
    private let SMOOTH_WINDOW_SIZE = 10
    private var latestBluetoothAction = ""

    // MARK: - 蓝牙状态
    private var pendingBluetoothState = ""
    private var currentBluetoothState = ""
    private var pendingStateStartTime: TimeInterval = 0
    private var currentStateStartTime: TimeInterval = 0
    private var lastBluetoothSendTime: TimeInterval = 0
    private let BLUETOOTH_MIN_DURATION: TimeInterval = 2000
    private let BLUETOOTH_SEND_INTERVAL: TimeInterval = 1600
    private var currentLevel: Int = 1
    private var currentLevelSinceMs: TimeInterval = 0
    private var pendingLevel: Int? = nil
    private var pendingLevelSinceMs: TimeInterval = 0
    private var lastSentLevel: Int = 0
    private let LEVEL_STABLE_MS:  TimeInterval = 0
    private let LEVEL_MIN_DUR_MS: TimeInterval = 0
    private let LEVEL_SEND_GAP_MS: TimeInterval = 1600
    private var suspendedBluetoothState = ""
    private var suspendedLevel = 0

    // MARK: - 暂停 / VAD
    private let stateLock = NSLock()
    private var _isPaused = true  // 起始为 true，等 VAD 检测到声音才开始
    private var isAnalysisPaused: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _isPaused }
        set { stateLock.lock(); defer { stateLock.unlock() }; _isPaused = newValue }
    }

    // VAD（与 OnlineAnalysisViewController 同样的子窗口 + RMS/Peak dBFS + 迟滞）
    private let WEB_VAD_SUB_WINDOWS:       Int   = 4
    private let WEB_VAD_ACTIVATE_RMS_DB:   Float = -55.0
    private let WEB_VAD_ACTIVATE_PEAK_DB:  Float = -42.0
    private let WEB_VAD_KEEP_RMS_DB:       Float = -60.0
    private let WEB_VAD_KEEP_PEAK_DB:      Float = -48.0
    private let WEB_VAD_MIN_SILENT_TICKS:  Int = 5  // 5 个 1s tick 才转 SILENT
    private var webVadSilentTicks: Int = 0
    private var webVadActive: Bool = false

    // MARK: - 起始保护（与 VideoProcessVC 同样的 4s buffer 预热门控）
    private var audioStartTimeMs: Int64 = 0

    // MARK: - 是否已经准备好（避免 ready 多次触发）
    private var didStartLoops = false

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupUI()
        setupInference()
        setupEngine()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        cleanup()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        engine?.playerLayer.frame = videoView.bounds
    }

    deinit {
        videoLoopItem?.cancel()
        audioLoopItem?.cancel()
        fusionLoopItem?.cancel()
    }

    // MARK: - UI

    private func setupUI() {
        videoView.backgroundColor = .black
        videoView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(videoView)

        // 三个分析结果标签
        let labels = [tvVideoAction, tvAudioAction, tvOverlay]
        let titles = ["V: ", "A: ", "Final: "]
        for (i, label) in labels.enumerated() {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.textColor = .white
            label.font = .systemFont(ofSize: 13)
            label.text = titles[i]
            label.backgroundColor = UIColor.black.withAlphaComponent(0.55)
            label.layer.cornerRadius = 6
            label.clipsToBounds = true
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
                label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor,
                                            constant: CGFloat(12 + i * 24))
            ])
        }

        // 状态栏（顶部居中）
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.text = "等待声音..."
        statusLabel.textAlignment = .center
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        statusLabel.layer.cornerRadius = 8
        statusLabel.clipsToBounds = true
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            statusLabel.heightAnchor.constraint(equalToConstant: 22),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 140)
        ])

        // 关闭按钮（右上）
        btnClose.translatesAutoresizingMaskIntoConstraints = false
        btnClose.setTitle("返回", for: .normal)
        btnClose.setTitleColor(.white, for: .normal)
        btnClose.backgroundColor = UIColor.red.withAlphaComponent(0.75)
        btnClose.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        btnClose.layer.cornerRadius = 14
        btnClose.clipsToBounds = true
        btnClose.addTarget(self, action: #selector(onCloseTapped), for: .touchUpInside)
        view.addSubview(btnClose)
        NSLayoutConstraint.activate([
            btnClose.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            btnClose.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            btnClose.widthAnchor.constraint(equalToConstant: 64),
            btnClose.heightAnchor.constraint(equalToConstant: 28)
        ])

        // 播放/暂停（右下偏上）
        btnPlayPause.translatesAutoresizingMaskIntoConstraints = false
        btnPlayPause.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        btnPlayPause.tintColor = .white
        btnPlayPause.addTarget(self, action: #selector(onPlayPauseTapped), for: .touchUpInside)
        view.addSubview(btnPlayPause)

        // 进度条 + 时间
        progressSlider.translatesAutoresizingMaskIntoConstraints = false
        progressSlider.addTarget(self, action: #selector(sliderTouchDown), for: .touchDown)
        progressSlider.addTarget(self, action: #selector(sliderValueChanged), for: .valueChanged)
        progressSlider.addTarget(self, action: #selector(sliderTouchUp), for: [.touchUpInside, .touchUpOutside])
        view.addSubview(progressSlider)

        currentTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        currentTimeLabel.textColor = .white
        currentTimeLabel.font = .systemFont(ofSize: 12)
        currentTimeLabel.text = "0:00"
        view.addSubview(currentTimeLabel)

        totalTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        totalTimeLabel.textColor = .white
        totalTimeLabel.font = .systemFont(ofSize: 12)
        totalTimeLabel.text = "0:00"
        view.addSubview(totalTimeLabel)

        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            videoView.topAnchor.constraint(equalTo: view.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            progressSlider.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            progressSlider.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            progressSlider.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),

            currentTimeLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            currentTimeLabel.bottomAnchor.constraint(equalTo: progressSlider.topAnchor, constant: -4),

            totalTimeLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            totalTimeLabel.bottomAnchor.constraint(equalTo: progressSlider.topAnchor, constant: -4),

            btnPlayPause.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            btnPlayPause.bottomAnchor.constraint(equalTo: currentTimeLabel.topAnchor, constant: -16),
            btnPlayPause.widthAnchor.constraint(equalToConstant: 40),
            btnPlayPause.heightAnchor.constraint(equalToConstant: 40)
        ])
    }

    // MARK: - 推理模块

    private func setupInference() {
        pcmBuffer = PcmCircularBuffer(sampleRate: 16000, capacityInSeconds: 20)
        videoClassifier = VideoClassifierHelper()
        audioHelper = AudioInferenceHelper()
        audioLoudnessEstimator = AudioLoudnessLevelEstimator(sampleRate: 16000)
    }

    // MARK: - 播放引擎

    private func setupEngine() {
        let eng = WebVideoPlayerEngine(
            videoURL: videoURL,
            headers: requestHeaders,
            startMs: startMs,
            pcmBuffer: pcmBuffer
        )
        // PCM 时间戳用 wall-clock：兼容 HLS 直播流（lastKnownPositionMs 始终为 0 的场景）
        eng.audioTimestampProvider = { Int64(Date().timeIntervalSince1970 * 1000) }
        engine = eng
        videoView.layer.insertSublayer(eng.playerLayer, at: 0)
        eng.playerLayer.frame = videoView.bounds

        eng.onReady = { [weak self] in
            guard let self = self else { return }
            // 起播时间作为 PCM 预热门控的基准 — 同样用 wall-clock
            self.audioStartTimeMs = Int64(Date().timeIntervalSince1970 * 1000)
            // 配置进度条上下限
            let dur = self.engine.durationMs
            if dur > 0 {
                self.progressSlider.minimumValue = 0
                self.progressSlider.maximumValue = Float(dur) / 1000.0
                self.totalTimeLabel.text = Self.formatTime(Double(dur) / 1000.0)
            } else {
                // 直播流：禁用进度条
                self.progressSlider.isEnabled = false
                self.totalTimeLabel.text = "Live"
            }
            // 启动分析循环（推理只在 isAnalysisPaused=false 时执行；VAD 会切换）
            if !self.didStartLoops {
                self.didStartLoops = true
                self.startAnalysisLoops()
                self.startUIProgressTimer()
            }
            self.engine.play()
        }
        eng.onPlayPauseChanged = { [weak self] playing in
            guard let self = self else { return }
            let icon = playing ? "pause.fill" : "play.fill"
            self.btnPlayPause.setImage(UIImage(systemName: icon), for: .normal)
            // 注意：不要在这里 pauseAnalysis/resumeAnalysis ——
            // 网页流的 isPlaying=true 时也可能是广告/缓冲。交给 VAD 控制。
        }
        eng.onUserSeek = { [weak self] ms in
            self?.handleSeekCleanup(toMs: ms)
        }
        eng.onEnded = { [weak self] in
            self?.pauseAnalysis(reason: "ended")
        }
    }

    // MARK: - 分析循环

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
        // VAD 总是先跑（不分析也要跟踪声音是否回来）
        runVadTick()
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

    // MARK: - VAD（每 1s 一次，从 PCM 缓冲最近 0.25s 取数据；逻辑与 OnlineAnalysisViewController 对齐）

    private func runVadTick() {
        let curMs = Int64(Date().timeIntervalSince1970 * 1000)
        // 4 秒预热门控（wall-clock）
        if curMs - audioStartTimeMs < 4000 { return }
        guard let samples = pcmBuffer.readWindowRelaxed(currentTimeMs: curMs, sampleCount: 4000),
              !samples.isEmpty else { return }

        let active = detectAudioActivity(samples: samples, currentlyActive: webVadActive)
        if active {
            webVadSilentTicks = 0
            if !webVadActive {
                webVadActive = true
                resumeAnalysis(reason: "VAD active")
                DispatchQueue.main.async { self.statusLabel.text = "在线分析中" }
            }
        } else {
            webVadSilentTicks += 1
            if webVadActive && webVadSilentTicks >= WEB_VAD_MIN_SILENT_TICKS {
                webVadActive = false
                pauseAnalysis(reason: "VAD silent")
                DispatchQueue.main.async { self.statusLabel.text = "等待声音..." }
            }
        }
    }

    /// 子窗口 + RMS/Peak(dBFS) + 迟滞 的 VAD
    private func detectAudioActivity(samples: [Float], currentlyActive: Bool) -> Bool {
        let n = samples.count
        if n <= 0 { return currentlyActive }
        let per = max(1, n / WEB_VAD_SUB_WINDOWS)

        let rmsTh = currentlyActive ? WEB_VAD_KEEP_RMS_DB : WEB_VAD_ACTIVATE_RMS_DB
        let peakTh = currentlyActive ? WEB_VAD_KEEP_PEAK_DB : WEB_VAD_ACTIVATE_PEAK_DB

        var active = false
        samples.withUnsafeBufferPointer { ptr in
            for w in 0..<WEB_VAD_SUB_WINDOWS {
                let s = w * per
                let e = (w == WEB_VAD_SUB_WINDOWS - 1) ? n : min(s + per, n)
                if e <= s { continue }
                var sumSq: Double = 0
                var pk: Float = 0
                for i in s..<e {
                    let v = ptr[i]
                    let a = abs(v)
                    if a > pk { pk = a }
                    sumSq += Double(v) * Double(v)
                }
                let rms = sqrt(sumSq / Double(e - s))
                let rmsDb = Float(20.0 * log10(max(rms, 1e-9)))
                let peakDb = Float(20.0 * log10(max(Double(pk), 1e-9)))
                if rmsDb > rmsTh || peakDb > peakTh { active = true }
            }
        }
        return active
    }

    // MARK: - 视频分析（与 VideoProcessVC 同构，只是帧来自 engine.captureFrame160）

    private func performVideoAnalysis() {
        guard let frame160 = engine.captureFrame160() else { return }

        frameBuffer.append(frame160)
        if frameBuffer.count > FRAME_BUFFER_SIZE {
            frameBuffer.removeFirst(frameBuffer.count - FRAME_BUFFER_SIZE)
        }
        if frameBuffer.count < FRAME_BUFFER_SIZE { return }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if nowMs - lastVideoInferenceMs < VIDEO_INFER_STEP_MS { return }
        lastVideoInferenceMs = nowMs

        guard let result = videoClassifier.predict(frames: frameBuffer) else { return }
        let action: String
        let confidence: Float
        if result.index < 0 {
            action = ""; confidence = 0
        } else if result.confidence < VIDEO_CONF_TH {
            action = ""; confidence = 0
        } else if result.index == 0 {
            action = "Noise"; confidence = result.confidence
        } else {
            action = "do"; confidence = result.confidence
        }

        analysisResults.videoResult = (action, confidence, Date().timeIntervalSince1970 * 1000)
        DispatchQueue.main.async {
            self.tvVideoAction.text = action.isEmpty
                ? "V: (unclear)"
                : String(format: "V: %@ (%.2f)", action, confidence)
        }
    }

    // MARK: - 音频分析

    private func performAudioAnalysis() {
        let curMs = Int64(Date().timeIntervalSince1970 * 1000)
        if curMs - audioStartTimeMs < 4000 { return }
        if let segment = pcmBuffer.readWindowRelaxed(currentTimeMs: curMs, sampleCount: 32000) {
            let (index, confidence) = audioHelper.predict(audioBuffer: segment)
            let action: String
            let outConf: Float
            if index < 0 {
                action = ""; outConf = 0
            } else if index == 2 {
                if confidence >= AUDIO_TH_NOISE { action = "Noise"; outConf = confidence }
                else { action = ""; outConf = 0 }
            } else {
                if confidence >= AUDIO_TH_ACTION { action = "do"; outConf = confidence }
                else { action = ""; outConf = 0 }
            }
            analysisResults.audioResult = (action, outConf, Date().timeIntervalSince1970 * 1000)
            DispatchQueue.main.async {
                self.tvAudioAction.text = action.isEmpty
                    ? "A: (unclear)"
                    : String(format: "A: %@ (%.2f)", action, outConf)
            }
        }
        // 响度档位
        if let last05s = pcmBuffer.readWindowRelaxed(currentTimeMs: curMs, sampleCount: 8000) {
            audioLoudnessEstimator.push(pcm: last05s)
            let lr = audioLoudnessEstimator.estimate(nowMs: Int64(Date().timeIntervalSince1970 * 1000))
            analysisResults.audioLoudnessLevel = (level: lr.level, conf: lr.confidence,
                                                  tsMs: lr.timestampMs, valid: lr.valid)
        }
    }

    // MARK: - 融合（与 OnlineAnalysisViewController 完全一致）

    private func performFusion() {
        let vRes = analysisResults.videoResult
        let aRes = analysisResults.audioResult
        let loud = analysisResults.audioLoudnessLevel
        let now = Date().timeIntervalSince1970 * 1000
        let MAX_AGE = 2000.0

        let vAge = vRes.timestamp > 0 ? now - vRes.timestamp : Double.greatestFiniteMagnitude
        let aAge = aRes.timestamp > 0 ? now - aRes.timestamp : Double.greatestFiniteMagnitude
        let loudAge = loud.tsMs > 0 ? now - Double(loud.tsMs) : Double.greatestFiniteMagnitude

        let vAction = vAge < MAX_AGE ? vRes.action : ""
        let aAction = aAge < MAX_AGE ? aRes.action : ""
        let vConf   = vAge < MAX_AGE ? vRes.confidence : 0
        let aConf   = aAge < MAX_AGE ? aRes.confidence : 0
        let aLevel: Float = (loud.valid && loudAge < MAX_AGE) ? Float(loud.level) : .nan
        let aLConf: Float = (loud.valid && loudAge < MAX_AGE) ? loud.conf : 0

        let finalFreq = computeFinalFreq(audioHz: aLevel, audioConf: aLConf, videoHz: .nan, videoConf: 0)
        let finalAction = smoothedFusion(videoAction: vAction, audioAction: aAction,
                                          videoConf: vConf, audioConf: aConf)
        if !finalAction.isEmpty { updateBluetoothState(finalAction, finalFreq) }
        tvOverlay.text = latestBluetoothAction.isEmpty
            ? "Final: 等待识别..."
            : "Final: \(latestBluetoothAction) | freq: \(finalFreq)"
    }

    // MARK: - 计算最终节律档位

    private func computeFinalFreq(audioHz: Float, audioConf: Float,
                                  videoHz: Float, videoConf: Float) -> Int {
        var finalFreq = clampLevelFromLoudness(audioHz)
        let CONF_IGNORE: Float = 0.10
        let CONF_UP: Float = 0.10
        let CONF_DOWN: Float = 0.10
        let curLevel = self.currentLevel
        let candidateLevel = finalFreq
        if audioHz.isNaN || audioConf < CONF_IGNORE { return curLevel }
        if candidateLevel > curLevel && audioConf < CONF_UP { finalFreq = curLevel }
        else if candidateLevel < curLevel && audioConf < CONF_DOWN { finalFreq = curLevel }
        return finalFreq
    }

    private func clampLevelFromLoudness(_ x: Float) -> Int {
        if x.isNaN { return 0 }
        var lv = Int(x.rounded())
        if lv < 0 { lv = 0 }
        if lv > 8 { lv = 8 }
        return lv
    }

    // MARK: - 平滑融合（搬自 OnlineAnalysisViewController）

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
                scores[rec.videoAction, default: 0] += rec.videoConfidence * w * 0.8
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

    // MARK: - 蓝牙更新（搬自 OnlineAnalysisViewController，与 VideoProcessVC 一致）

    @inline(__always) private func upThreshold(_ cur: Int) -> Int   { return min(8, cur + 1) }
    @inline(__always) private func downThreshold(_ cur: Int) -> Int { return max(0, cur - 1) }
    private func isSexAction(_ action: String) -> Bool {
        let lower = action.lowercased()
        return lower.hasPrefix("do") || lower.hasPrefix("oral")
    }

    private func updateBluetoothState(_ newAction: String, _ finalFreq: Int) {
        let currentTime = Date().timeIntervalSince1970 * 1000
        if BluetoothManager.shared.isPausedByLocal { return }

        let supportsLevel = isSexAction(newAction)
        if supportsLevel {
            var latestLevel = finalFreq
            if latestLevel < 0 { latestLevel = 0 }
            if latestLevel > 8 { latestLevel = 8 }
            let worthHandling = latestLevel >= upThreshold(currentLevel)
                || latestLevel <= downThreshold(currentLevel)
            if worthHandling {
                if LEVEL_STABLE_MS <= 0 && (currentTime - currentLevelSinceMs >= LEVEL_MIN_DUR_MS) {
                    currentLevel = latestLevel
                    currentLevelSinceMs = currentTime
                    pendingLevel = nil; pendingLevelSinceMs = 0
                } else {
                    if pendingLevel == nil || pendingLevel! != latestLevel {
                        pendingLevel = latestLevel
                        pendingLevelSinceMs = currentTime
                    } else {
                        let dwell = currentTime - pendingLevelSinceMs
                        let stableOk = dwell >= LEVEL_STABLE_MS
                        let minDurOk = currentTime - currentLevelSinceMs >= LEVEL_MIN_DUR_MS
                        if stableOk && minDurOk {
                            currentLevel = pendingLevel!
                            currentLevelSinceMs = currentTime
                            pendingLevel = nil; pendingLevelSinceMs = 0
                        }
                    }
                }
            } else {
                pendingLevel = nil; pendingLevelSinceMs = 0
            }
        } else {
            pendingLevel = nil; pendingLevelSinceMs = 0
        }

        if newAction != pendingBluetoothState {
            pendingBluetoothState = newAction
            pendingStateStartTime = currentTime
        }
        var actionStableMs: TimeInterval = 0
        if isSexAction(currentBluetoothState) && newAction == "Noise" { actionStableMs = 1000 }
        let actionStableOk = pendingBluetoothState == newAction
            && (currentTime - pendingStateStartTime) >= actionStableMs
        if !actionStableOk { return }

        // 动作变化分支
        if pendingBluetoothState != currentBluetoothState {
            let minDurationOk = currentBluetoothState.isEmpty
                || (currentTime - currentStateStartTime) >= BLUETOOTH_MIN_DURATION
            if !minDurationOk { return }
            let gapOk = (currentTime - lastBluetoothSendTime) >= BLUETOOTH_SEND_INTERVAL
            if !gapOk { return }
            let levelToSend = isSexAction(pendingBluetoothState) ? currentLevel : 0
            latestBluetoothAction = pendingBluetoothState
            if BluetoothManager.shared.isConnected {
                BluetoothManager.shared.sendAction(pendingBluetoothState, levelToSend)
            }
            currentBluetoothState = pendingBluetoothState
            currentStateStartTime = currentTime
            lastBluetoothSendTime = currentTime
            if isSexAction(currentBluetoothState) {
                currentLevel = levelToSend; currentLevelSinceMs = currentTime; lastSentLevel = levelToSend
            } else {
                lastSentLevel = 0
            }
            return
        }

        // 动作未变，档位变了
        let levelChanged = supportsLevel && (currentLevel != lastSentLevel)
        let gapOk = (currentTime - lastBluetoothSendTime) >= BLUETOOTH_SEND_INTERVAL
        if levelChanged && gapOk {
            let levelToSend = currentLevel
            if BluetoothManager.shared.isConnected {
                BluetoothManager.shared.sendAction(currentBluetoothState, levelToSend)
            }
            lastSentLevel = levelToSend
            lastBluetoothSendTime = currentTime
        }
    }

    // MARK: - 暂停/恢复（VAD 触发）

    private func pauseAnalysis(reason: String) {
        isAnalysisPaused = true
        if !currentBluetoothState.isEmpty && currentBluetoothState != "Noise" {
            suspendedBluetoothState = currentBluetoothState
            suspendedLevel = currentLevel
        }
        if BluetoothManager.shared.isConnected && !BluetoothManager.shared.isPausedByLocal {
            BluetoothManager.shared.sendAction("Noise", 0)
        }
        print("⏸️ [WebVideo分析] 暂停 (\(reason))")
    }

    private func resumeAnalysis(reason: String) {
        isAnalysisPaused = false
        if !suspendedBluetoothState.isEmpty {
            currentBluetoothState = suspendedBluetoothState
            currentLevel = suspendedLevel
            currentStateStartTime = Date().timeIntervalSince1970 * 1000
            currentLevelSinceMs = Date().timeIntervalSince1970 * 1000
            if BluetoothManager.shared.isConnected && !BluetoothManager.shared.isPausedByLocal {
                BluetoothManager.shared.sendAction(suspendedBluetoothState, suspendedLevel)
                lastBluetoothSendTime = Date().timeIntervalSince1970 * 1000
                lastSentLevel = suspendedLevel
            }
            suspendedBluetoothState = ""
            suspendedLevel = 0
        }
        print("▶️ [WebVideo分析] 恢复 (\(reason))")
    }

    // MARK: - Seek 清理

    private func handleSeekCleanup(toMs ms: Int64) {
        print("🟡 [WebVideo分析] 检测到 seek 到 \(ms)ms，清理状态")

        videoAnalysisQueue.async { [weak self] in
            self?.frameBuffer.removeAll()
            self?.lastVideoInferenceMs = 0
            self?.historyLock.lock()
            self?.actionHistory.removeAll()
            self?.historyLock.unlock()
            self?.pendingBluetoothState = ""
            self?.currentBluetoothState = ""
            self?.pendingStateStartTime = 0
            self?.currentStateStartTime = 0
        }
        audioAnalysisQueue.async { [weak self] in
            self?.pcmBuffer.reset()
            self?.audioLoudnessEstimator.reset()
        }
        analysisResults.resetRhythm()

        currentLevel = 1
        currentLevelSinceMs = 0
        pendingLevel = nil
        pendingLevelSinceMs = 0
        lastSentLevel = 0
        suspendedBluetoothState = ""
        suspendedLevel = 0

        // 重置 VAD：让"buffer 启动需 4s"再次生效（wall-clock）
        audioStartTimeMs = Int64(Date().timeIntervalSince1970 * 1000)
        webVadActive = false
        webVadSilentTicks = 0
        if !isAnalysisPaused { pauseAnalysis(reason: "after seek") }
        DispatchQueue.main.async { self.statusLabel.text = "等待声音..." }
    }

    // MARK: - 控件回调

    @objc private func onPlayPauseTapped() {
        if engine.isPlaying { engine.pause() } else { engine.play() }
    }

    @objc private func onCloseTapped() {
        cleanup()
        dismiss(animated: true)
    }

    private var isUserSeeking = false
    @objc private func sliderTouchDown() {
        isUserSeeking = true
        engine.pause()
    }
    @objc private func sliderValueChanged() {
        currentTimeLabel.text = Self.formatTime(Double(progressSlider.value))
    }
    @objc private func sliderTouchUp() {
        isUserSeeking = false
        let target = Int64(Double(progressSlider.value) * 1000)
        engine.seek(toMs: target)
        engine.play()
    }

    // MARK: - 进度条 UI 定时器

    private var uiProgressTimer: Timer?
    private func startUIProgressTimer() {
        uiProgressTimer?.invalidate()
        uiProgressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard !self.isUserSeeking else { return }
            let pos = self.engine.lastKnownPositionMs
            let secs = Double(pos) / 1000.0
            if self.engine.durationMs > 0 {
                self.progressSlider.value = Float(secs)
            }
            self.currentTimeLabel.text = Self.formatTime(secs)
        }
    }

    private static func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN, !seconds.isInfinite else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    // MARK: - Cleanup

    private func cleanup() {
        videoLoopItem?.cancel()
        audioLoopItem?.cancel()
        fusionLoopItem?.cancel()
        uiProgressTimer?.invalidate()
        uiProgressTimer = nil
        if BluetoothManager.shared.isConnected {
            BluetoothManager.shared.sendAction("Noise", 0)
        }
        engine?.stop()
    }
}
