//
//  VideoProcessViewController.swift
//  Xcup
//
//  Created by tingfu on 2025/4/20.
//

import UIKit
import AVFoundation
import CoreML
import CoreBluetooth
import TensorFlowLite

// MARK: - 线程安全的分析结果存储
class ThreadSafeAnalysisResults {
    private let queue = DispatchQueue(label: "com.xcup.analysisResults", attributes: .concurrent)
    
    private var _videoAction: String = ""
    private var _videoConfidence: Float = 0.0
    private var _audioAction: String = ""
    private var _audioConfidence: Float = 0.0
    private var _videoTimestamp: TimeInterval = 0  // 🆕 视频结果时间戳
    private var _audioTimestamp: TimeInterval = 0  // 🆕 音频结果时间戳
    
    // ===== 🆕 新增：音频节奏器结果 =====
    /*
    private var _audioRhythmHz: Float = .nan        // 音频节奏频率(Hz)
    private var _audioRhythmConf: Float = 0.0       // 音频节奏置信度
    private var _audioRhythmTsMs: Int64 = 0         // 音频节奏时间戳(毫秒)
    private var _audioRhythmValid: Bool = false     // 音频节奏是否有效
    */
    // ===== 🆕 新增：音频响度档位结果（替代音频节奏器） =====
    private var _audioLoudLevel: Int = 0
    private var _audioLoudConf: Float = 0.0
    private var _audioLoudTsMs: Int64 = 0
    private var _audioLoudValid: Bool = false

    // ===== 🆕 新增：音频响度档位访问器 =====
    var audioLoudnessLevel: (level: Int, conf: Float, tsMs: Int64, valid: Bool) {
        get { queue.sync { (_audioLoudLevel, _audioLoudConf, _audioLoudTsMs, _audioLoudValid) } }
        set {
            queue.async(flags: .barrier) {
                self._audioLoudLevel = newValue.level
                self._audioLoudConf = newValue.conf
                self._audioLoudTsMs = newValue.tsMs
                self._audioLoudValid = newValue.valid
            }
        }
    }

        
    // ===== 🆕 新增：视频节奏器结果 =====
    private var _videoFreqHz: Float = .nan          // 视频节奏频率(Hz)
    private var _videoFreqConf: Float = 0.0         // 视频节奏置信度
    private var _videoFreqTsMs: Int64 = 0           // 视频节奏时间戳(毫秒)
    
    var videoResult: (action: String, confidence: Float, timestamp: TimeInterval) {
        get {
            queue.sync { (_videoAction, _videoConfidence, _videoTimestamp) }
        }
        set {
            queue.async(flags: .barrier) {
                self._videoAction = newValue.action
                self._videoConfidence = newValue.confidence
                self._videoTimestamp = newValue.timestamp
            }
        }
    }
    
    var audioResult: (action: String, confidence: Float, timestamp: TimeInterval) {
        get {
            queue.sync { (_audioAction, _audioConfidence, _audioTimestamp) }
        }
        set {
            queue.async(flags: .barrier) {
                self._audioAction = newValue.action
                self._audioConfidence = newValue.confidence
                self._audioTimestamp = newValue.timestamp
            }
        }
    }
    
    /*
    // ===== 🆕 新增：音频节奏器访问器 =====
    var audioRhythm: (hz: Float, conf: Float, tsMs: Int64, valid: Bool) {
        get {
            queue.sync {
                (_audioRhythmHz, _audioRhythmConf, _audioRhythmTsMs, _audioRhythmValid)
            }
        }
        set {
            queue.async(flags: .barrier) {
                self._audioRhythmHz = newValue.hz
                self._audioRhythmConf = newValue.conf
                self._audioRhythmTsMs = newValue.tsMs
                self._audioRhythmValid = newValue.valid
            }
        }
    }
    */
    
    // ===== 🆕 新增：视频节奏器访问器 =====
    var videoFreq: (hz: Float, conf: Float, tsMs: Int64) {
        get {
            queue.sync {
                (_videoFreqHz, _videoFreqConf, _videoFreqTsMs)
            }
        }
        set {
            queue.async(flags: .barrier) {
                self._videoFreqHz = newValue.hz
                self._videoFreqConf = newValue.conf
                self._videoFreqTsMs = newValue.tsMs
            }
        }
    }
    
    // ===== 🆕 新增：重置方法 =====
    func resetRhythm() {
        queue.async(flags: .barrier) {
            // 重置音频节奏
            /*
            self._audioRhythmHz = .nan
            self._audioRhythmConf = 0.0
            self._audioRhythmTsMs = 0
            self._audioRhythmValid = false
            */
            // 重置音频响度档位
            self._audioLoudLevel = 0
            self._audioLoudConf = 0.0
            self._audioLoudTsMs = 0
            self._audioLoudValid = false
                
            // 重置视频节奏
            self._videoFreqHz = .nan
            self._videoFreqConf = 0.0
            self._videoFreqTsMs = 0
        }
    }
}

// 🆕 MARK: - 动作记录结构体
struct ActionRecord {
    let videoAction: String
    let audioAction: String
    let videoConfidence: Float
    let audioConfidence: Float
    let timestamp: TimeInterval
}

class VideoProcessViewController: UIViewController {

    // MARK: - UI 元素
    let videoView = UIView()// 使用 AVPlayerLayer 嵌入
    let tvOverlay = UILabel()//最终的动作类型
    let tvVideoAction = UILabel()//视频分析的动作类型
    let tvAudioAction = UILabel()//音频分析的动作类型
    let btnFullscreen = UIButton(type: .system)
    let btnPlayPause = UIButton(type: .system) // 播放/暂停按钮
    // 添加时间显示Label
    let currentTimeLabel = UILabel()
    let totalTimeLabel = UILabel()
    
    // MARK: - 传入视频路径
    var videoURL: URL!

    // MARK: - 推理和蓝牙
    var inferenceHelper: InferenceHelper!
    var audioHelper: AudioInferenceHelper!
    
    // MARK: - 🆕 音频节奏器
    // private var audioRhythmEstimator: AudioRhythmEstimator!
    // 音频响度档位估计器（替代音频节奏器）
    private var audioLoudnessEstimator: AudioLoudnessLevelEstimator!

    
    // MARK: - 🆕 视频节奏器（基于 ROI 块运动 + PCA 主方向 + 自相关）
    private var videoRhythmEstimator: VideoMotionWaveEstimator!
    
    // MARK: - 抽帧
    var videoFrameExtractor: VideoFrameExtractor!

    // MARK: - 视频播放和同步
    var player: AVPlayer!
    var playerItem: AVPlayerItem!
    var playerLayer: AVPlayerLayer!
    var playerObserver: Any?

    // MARK: - 线程相关
    private let videoAnalysisQueue = DispatchQueue(label: "com.xcup.videoAnalysis", qos: .userInitiated)
    private let audioAnalysisQueue = DispatchQueue(label: "com.xcup.audioAnalysis", qos: .userInitiated)
    private let analysisResults = ThreadSafeAnalysisResults()
    
    // MARK: - 分析定时器
    private var videoAnalysisTimer: DispatchSourceTimer?
    private var audioAnalysisTimer: DispatchSourceTimer?
    private var fusionTimer: Timer?
    
    // ===================== [12.14] 自调度循环（替代 repeating timer） =====================
    private let VIDEO_INTERVAL_MS: Int64 = 100           // 视频 100ms
    private let AUDIO_INTERVAL_MS: Int64 = 1000          // 音频 1s
    private let FUSION_INTERVAL_MS: Int64 = 800          // 融合 800ms（与 0.8s 对齐）

    private var videoLoopWorkItem: DispatchWorkItem?
    private var audioLoopWorkItem: DispatchWorkItem?
    private var fusionLoopWorkItem: DispatchWorkItem?
    
    var poseWindow: [PoseFrame] = []
    let WINDOW_SIZE = 32
    
    // MARK: - 二分类相关参数
    var poseWindow8: [PoseFrame] = []  // 8帧二分类窗口
    let BINARY_WINDOW = 8             // 二分类窗口大小
    let BINARY_TH: Float = 0.3        // 二分类阈值
    let MULTI_STEP = 8                // 多分类步长
    var framesSinceLastMulti = 0      // 多分类帧计数器
    
    // MARK: - 平滑融合相关
    private var actionHistory = [ActionRecord]()  // 动作历史记录
    private let historyLock = NSLock()           // 历史记录锁
    private let SMOOTH_WINDOW_SIZE = 10          // 窗口大小（10帧 = 1秒）
    private var latestBluetoothAction = ""       // 最新的蓝牙发送动作
    
    // MARK: -主线程融合循环间隔（秒）
    private let FUSION_INTERVAL: TimeInterval = 0.8  // 800ms
    
    // MARK: - 蓝牙状态管理相关
    private var pendingBluetoothState = ""           // 待确认的蓝牙状态
    private var currentBluetoothState = ""           // 当前执行的蓝牙状态
    private var pendingStateStartTime: TimeInterval = 0   // 待确认状态开始时间
    private var currentStateStartTime: TimeInterval = 0   // 当前状态开始时间
    private var lastBluetoothSendTime: TimeInterval = 0   // 上次蓝牙发送时间
    private let BLUETOOTH_MIN_DURATION: TimeInterval = 2000  // 最小持续时间（2秒）
    private let BLUETOOTH_SEND_INTERVAL: TimeInterval = 1600  // 发送间隔（1600ms）
    private let BLUETOOTH_STABLE_CONFIRM_MS: TimeInterval = 1600 // 稳定确认时间
    
    // ===================== 频率档位确认与节流 =====================
    // 档位（0..10）确认状态
    private var currentLevel: Int = 1
    private var currentLevelSinceMs: TimeInterval = 0   // 当前生效档位开始时间（ms）
    private var pendingLevel: Int? = nil
    private var pendingLevelSinceMs: TimeInterval = 0   // 待确认档位开始时间（ms})

    // 最近一次“已发送”的档位（用于判断是否需要用同一动作更新档位）
    private var lastSentLevel: Int = 0
    
    // ★ 新增：暂停时挂起的蓝牙动作与档位
    private var suspendedBluetoothState: String = ""
    private var suspendedLevel: Int = 0

    // 档位确认/节流参数（结合你的 800ms 主循环）
    private let LEVEL_STABLE_MS: TimeInterval  = 0    // 新档位短稳确认
    private let LEVEL_MIN_DUR_MS: TimeInterval = 0   // 生效档位的最小驻留
    private let LEVEL_SEND_GAP_MS: TimeInterval = 1600  // 档位更新发送间隔（与动作一致）
    
    // MARK: - 音频缓冲
    var audioStartTime: Int64 = 0
    
    // MARK: - 播放跳动
    var pendingSeekWorkItem: DispatchWorkItem?
    var lastSeekTime: Int64 = 0
    var didUserSeek = false
    
    // MARK: - 视频播放进度条
    let progressSlider = UISlider()
    var isSeekingByUser = false

    // MARK: - 音频处理
    var audioDecoder: AudioDecoder!
    var pcmBuffer: PcmCircularBuffer!

    var lastFinalAction = ""

    // MARK: - 暂停与继续播放
    private let analysisStateLock = NSLock()
    private var _isAnalysisPaused = false
    var isAnalysisPaused: Bool {
        get {
            analysisStateLock.lock()
            defer { analysisStateLock.unlock() }
            return _isAnalysisPaused
        }
        set {
            analysisStateLock.lock()
            defer { analysisStateLock.unlock() }
            _isAnalysisPaused = newValue
        }
    }
    
    var isVideoCompleted = false
    var playStateTimer: Timer?
    var lastIsPlaying = true
    
    // MARK: - 全屏与退出全屏
    var isFullscreen = false
    
    // MARK: - 检测视频播放结束
    var videoDuration: Double = 0.0
    
    // MARK: - 生命周期
    override func viewDidLoad() {
        super.viewDidLoad()
        
        setupLayout()
        setupUI()
        setupInference()
        guard let url = videoURL else {
            print("❌ 未设置 videoURL")
            return
        }
        setupPlayer(with: url)
        setupAudio(with: url)
        startAnalysisThreads()
        startPlaybackObserver()
    }

    // MARK: - 核心 UI 布局代码.
    //设置背景为黑色；播放画面自动居中缩放；UILabel 放左上角；UIButton 放右上角。
    func setupLayout() {
        view.backgroundColor = .black

        // 添加 videoView
        videoView.backgroundColor = .black
        videoView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(videoView)

        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            videoView.topAnchor.constraint(equalTo: view.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        
        // 添加进度条
        progressSlider.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progressSlider)

        NSLayoutConstraint.activate([
            progressSlider.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            progressSlider.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            progressSlider.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])
        
        // 🆕 添加当前时间Label
        currentTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        currentTimeLabel.textColor = .white
        currentTimeLabel.font = UIFont.systemFont(ofSize: 12)
        currentTimeLabel.text = "0:00"
        view.addSubview(currentTimeLabel)

        NSLayoutConstraint.activate([
            currentTimeLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            currentTimeLabel.bottomAnchor.constraint(equalTo: progressSlider.topAnchor, constant: -4)
        ])

        // 🆕 添加总时长Label
        totalTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        totalTimeLabel.textColor = .white
        totalTimeLabel.font = UIFont.systemFont(ofSize: 12)
        totalTimeLabel.text = "0:00"
        view.addSubview(totalTimeLabel)

        NSLayoutConstraint.activate([
            totalTimeLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            totalTimeLabel.bottomAnchor.constraint(equalTo: progressSlider.topAnchor, constant: -4)
        ])

        // 视频分析结果 Label
        let labels = [tvVideoAction, tvAudioAction, tvOverlay]
        let labelTitles = ["V: ", "A: ", "Final: "]

        for (i, label) in labels.enumerated() {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.textColor = .white
            label.font = UIFont.systemFont(ofSize: 13)
            label.text = labelTitles[i]
            view.addSubview(label)

            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
                label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: CGFloat(12 + i * 22))
            ])
        }
        
        // 全屏按钮
        btnFullscreen.translatesAutoresizingMaskIntoConstraints = false
        let icon = UIImage(systemName: "arrow.up.left.and.arrow.down.right")
        btnFullscreen.setImage(icon, for: .normal)
        btnFullscreen.tintColor = .white
        view.addSubview(btnFullscreen)

        NSLayoutConstraint.activate([
            btnFullscreen.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            btnFullscreen.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            btnFullscreen.widthAnchor.constraint(equalToConstant: 32),
            btnFullscreen.heightAnchor.constraint(equalToConstant: 32)
        ])

        // 播放/暂停按钮（现在放在 btnFullscreen 之后）
        btnPlayPause.translatesAutoresizingMaskIntoConstraints = false
        let pauseIcon = UIImage(systemName: "pause.fill")
        btnPlayPause.setImage(pauseIcon, for: .normal)
        btnPlayPause.tintColor = .white
        view.addSubview(btnPlayPause)

        NSLayoutConstraint.activate([
            btnPlayPause.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            btnPlayPause.topAnchor.constraint(equalTo: btnFullscreen.bottomAnchor, constant: 12),
            btnPlayPause.widthAnchor.constraint(equalToConstant: 32),
            btnPlayPause.heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    // MARK: - 播放器初始化（保持主要逻辑不变）
    func setupPlayer(with url: URL) {
        print("📼 设置播放器，传入路径: \(url)")

        playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)

        playerLayer = AVPlayerLayer(player: player)
        playerLayer.frame = videoView.bounds
        
        // 让多余区域也为黑色（letter‑box 时不再出现白条）
        playerLayer.backgroundColor = UIColor.black.cgColor
        // 等比缩放，完整显示全部画面
        playerLayer.videoGravity = .resizeAspect

        videoView.layer.insertSublayer(playerLayer, at: 0)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(videoDidEnd),
            name: .AVPlayerItemDidPlayToEndTime,
            object: playerItem
        )

        // 初始化视频帧提取器
        guard let extractor = VideoFrameExtractor(url: url) else {
            print("❌ VideoFrameExtractor 初始化失败")
            return
        }
        videoFrameExtractor = extractor

        player.play()

        // 设置 audioStartTime 为当前播放时间（毫秒）
        audioStartTime = Int64(CMTimeGetSeconds(player.currentTime()) * 1000)
        print("🎬 播放开始，audioStartTime = \(audioStartTime)")
        
        // 添加拖动监听逻辑
        player.addPeriodicTimeObserver(forInterval: CMTimeMake(value: 1, timescale: 2), queue: .main) { [weak self] time in
            guard let self = self else { return }
            
            //在 timeObserver 中更新进度条
            if !self.isSeekingByUser {
                let seconds = time.seconds
                self.progressSlider.value = Float(seconds)
            }
            
            // 🆕 更新当前时间显示
            let currentSeconds = time.seconds
            self.currentTimeLabel.text = self.formatTime(currentSeconds)
            
            // 判断是否是人为 seek（与 lastSeekTime 差距过大）
            if self.didUserSeek {
                self.didUserSeek = false
                self.handleUserSeek(currentMs: Int64(time.seconds * 1000))
            }
        }
        
        // 初始化 slider 配置，即视频播放进度条
        videoDuration = CMTimeGetSeconds(playerItem.asset.duration)
        progressSlider.minimumValue = 0
        progressSlider.maximumValue = Float(videoDuration)
        progressSlider.value = 0
        
        // 🆕 设置总时长显示
        totalTimeLabel.text = formatTime(videoDuration)

        // 监听用户开始拖动
        progressSlider.addTarget(self, action: #selector(sliderTouchDown), for: .touchDown)
        // 拖动中
        progressSlider.addTarget(self, action: #selector(sliderValueChanged), for: .valueChanged)
        // 拖动结束
        progressSlider.addTarget(self, action: #selector(sliderTouchUp), for: [.touchUpInside, .touchUpOutside])
        
        // 添加点击手势识别器
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(sliderTapped(_:)))
        progressSlider.addGestureRecognizer(tapGesture)
    }

    // MARK: - 推理初始化
    func setupInference() {
        inferenceHelper = InferenceHelper()
        inferenceHelper.setupPoseDetector()
        // 🆕 初始化音频节奏器
        // audioRhythmEstimator = AudioRhythmEstimator(sampleRateHz: 16000)
        audioLoudnessEstimator = AudioLoudnessLevelEstimator(sampleRate: 16000)
        // 🆕 初始化视频节奏器（块运动版本）
        videoRhythmEstimator = VideoMotionWaveEstimator()
    }

    // MARK: - 音频初始化
    func setupAudio(with url: URL) {
        pcmBuffer = PcmCircularBuffer(sampleRate: 16000, capacityInSeconds: 20)
        audioHelper = AudioInferenceHelper()

        guard let player = player else {
            print("❌ 播放器未初始化，无法创建 AudioDecoder")
            return
        }

        let asset = AVURLAsset(url: url) // 使用 AVURLAsset 单独构建解码器（避免出现尚未准备好的 player.asset）

        audioDecoder = AudioDecoder(
            asset: asset,
            buffer: pcmBuffer,
            positionProvider: { Int(player.currentTime().seconds * 1000) }
        )

        audioDecoder.startDecoding()
    }

    // MARK: - UI 初始化
    func setupUI() {
        btnFullscreen.addTarget(self, action: #selector(toggleFullscreen), for: .touchUpInside)
        btnPlayPause.addTarget(self, action: #selector(togglePlayPause), for: .touchUpInside)
    }

    // MARK: - 启动分析线程
    func startAnalysisThreads() {
        startVideoLoop()
        startAudioLoop()     //（保留 4s 预热延迟）
        startFusionLoop()
    }
    
    // ===================== [12.14] 视频自调度循环（100ms） =====================
    private func startVideoLoop() {
        videoLoopWorkItem?.cancel()
        scheduleNextVideoTick(afterMs: 0) // 立即启动
    }

    private func scheduleNextVideoTick(afterMs delayMs: Int64) {
        let item = DispatchWorkItem { [weak self] in
            self?.runVideoTick()
        }
        videoLoopWorkItem = item
        videoAnalysisQueue.asyncAfter(deadline: .now() + .milliseconds(Int(delayMs)), execute: item)
    }

    private func runVideoTick() {
        // run() 进入点计时（对齐你 Android 的 t0）
        let t0 = DispatchTime.now() // NEW

        // 业务逻辑（保持原函数不变）
        if !isAnalysisPaused {
            performVideoAnalysis()
        }

        // elapsed / nextDelay
        let elapsedNs = DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds
        let elapsedMs = Int64(elapsedNs / 1_000_000)
        let nextDelay = max(Int64(0), VIDEO_INTERVAL_MS - elapsedMs) // NEW: nextDelay=max(0, interval-elapsed)

        scheduleNextVideoTick(afterMs: nextDelay) // NEW
    }

    
    // ===================== [12.14] 音频自调度循环（1s） =====================
    private func startAudioLoop() {
        audioLoopWorkItem?.cancel()
        scheduleNextAudioTick(afterMs: 0) 
    }

    private func scheduleNextAudioTick(afterMs delayMs: Int64) {
        let item = DispatchWorkItem { [weak self] in
            self?.runAudioTick()
        }
        audioLoopWorkItem = item
        audioAnalysisQueue.asyncAfter(deadline: .now() + .milliseconds(Int(delayMs)), execute: item)
    }

    private func runAudioTick() {
        let t0 = DispatchTime.now() // NEW

        if !isAnalysisPaused {
            performAudioAnalysis()
        }

        let elapsedNs = DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds
        let elapsedMs = Int64(elapsedNs / 1_000_000)
        let nextDelay = max(Int64(0), AUDIO_INTERVAL_MS - elapsedMs) // NEW

        scheduleNextAudioTick(afterMs: nextDelay) // NEW
    }
    
    // ===================== [12.14] 融合自调度循环（800ms，主线程） =====================
    private func startFusionLoop() {
        fusionLoopWorkItem?.cancel()
        scheduleNextFusionTick(afterMs: 0)
    }

    private func scheduleNextFusionTick(afterMs delayMs: Int64) {
        let item = DispatchWorkItem { [weak self] in
            self?.runFusionTick()
        }
        fusionLoopWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(delayMs)), execute: item)
    }

    private func runFusionTick() {
        let t0 = DispatchTime.now() // NEW

        if !isAnalysisPaused {
            performFusion()
        }

        let elapsedNs = DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds
        let elapsedMs = Int64(elapsedNs / 1_000_000)
        let nextDelay = max(Int64(0), FUSION_INTERVAL_MS - elapsedMs) // NEW

        scheduleNextFusionTick(afterMs: nextDelay) // NEW
    }



    // MARK: - 视频分析线程（后台线程）
    func performVideoAnalysis() {
        guard !isAnalysisPaused else { return }
            
        let currentTime = player.currentTime().seconds
            
        if currentTime >= videoDuration {
            DispatchQueue.main.async { [weak self] in
                if !(self?.isVideoCompleted ?? true) {
                    self?.isVideoCompleted = true
                    self?.pauseAnalysis()
                    print("🎞️ 视频播完，暂停分析等待用户操作")
                }
            }
            return
        }
            
        // 1. 抽帧
        let frameExtractionStart = Date()
            
        guard let extractor = videoFrameExtractor,
              let currentFrame = extractor.frame(at: Int64(currentTime * 1_000_000)) else {
            print("未能提取帧")
            return
        }
            
        let frameExtractionTime = Date().timeIntervalSince(frameExtractionStart) * 1000
        //print(String(format: "📸 [视频线程] 抽帧耗时: %.2f ms", frameExtractionTime))
            
        // 2. ML Kit 姿态检测（异步）
        let poseDetectionStart = Date()
            
        inferenceHelper.runPoseModel(on: currentFrame) { [weak self] keypoints in
            guard let self = self else { return }

            let poseDetectionTime = Date().timeIntervalSince(poseDetectionStart) * 1000
            //print(String(format: "🦴 [视频线程] ML Kit Pose Detection 耗时: %.2f ms", poseDetectionTime))

            let framePtsMs = Int64(Date().timeIntervalSince1970 * 1000)

            // 🆕 关键点为 nil（未检测到人）→ 触发节律器场景切换处理；ST-GCN++ 跳过本帧
            guard let keypoints = keypoints else {
                self.videoRhythmEstimator.pushFrame(timestampMs: framePtsMs, frame: nil, keypointsNorm: nil)
                self.analysisResults.videoFreq = (hz: .nan, conf: 0, tsMs: framePtsMs)
                return
            }

            // 🆕 将归一化后的关键点 + 当前帧一并推入视频节律器
            self.videoRhythmEstimator.pushFrame(timestampMs: framePtsMs,
                                                frame: currentFrame,
                                                keypointsNorm: keypoints)
            let vr = self.videoRhythmEstimator.getLatestResult()

            if vr.valid {
                self.analysisResults.videoFreq = (hz: vr.freqHz,
                                                   conf: vr.confidence,
                                                   tsMs: vr.timestampMs)
                print(String(format: "[频率测试] [离线模式] 视频运动波形 - f=%.2fHz, conf=%.2f, per=%.2f, mE=%.3f, dir=(%.2f,%.2f), pos01=%.2f, locked=%@",
                             vr.freqHz, vr.confidence, vr.periodicity, vr.motionEnergy,
                             vr.mainDirX, vr.mainDirY, vr.position01,
                             vr.locked ? "true" : "false"))
                print("[VideoWave] " + vr.debugInfo)
            } else {
                self.analysisResults.videoFreq = (hz: .nan, conf: 0, tsMs: framePtsMs)
            }
                
            // 在视频分析队列中处理
            self.videoAnalysisQueue.async {
                var skipMulti = false
                /*
                 🆕 8帧二分类
                self.poseWindow8.append(keypoints)
                if self.poseWindow8.count > self.BINARY_WINDOW {
                    self.poseWindow8.removeFirst()
                }
                    
                if self.poseWindow8.count == self.BINARY_WINDOW {
                    let binInput = self.poseWindow8.toStgcnInput()
                    let tStgcnStart = Date()
                        
                    if let prob = self.inferenceHelper.runBinary(input: binInput) {
                        let tStgcnEnd = Date()
                        let binaryTime = (tStgcnEnd.timeIntervalSince(tStgcnStart)) * 1000
                        print(String(format: "[计时] [视频线程] 🧠 二分类ST-GCN++ 推理耗时: %.2f ms", binaryTime))
                            
                        // 修改：注释掉二分类判断，让skipMulti始终为false
                        if prob < self.BINARY_TH {
                            print("[视频线程] [同步分析] 二分类判定为Background")
                            // 添加时间戳
                            self.analysisResults.videoResult = ("Background", prob, Date().timeIntervalSince1970 * 1000)
                            skipMulti = true
                        }
                    }
                }
                // 🆕 结束二分类部分
                */
                    
                // 🔴 32帧多分类
                if !skipMulti {
                    self.poseWindow.append(keypoints)
                    if self.poseWindow.count > self.WINDOW_SIZE {
                        self.poseWindow.removeFirst()
                    }
                        
                    self.framesSinceLastMulti += 1  // 🆕 累积帧计数
                        
                    // 🔴 多分类的ST-GCN++ 触发条件：窗口满且已累积 ≥ MULTI_STEP 帧
                    if self.poseWindow.count == self.WINDOW_SIZE && self.framesSinceLastMulti >= self.MULTI_STEP {
                        self.framesSinceLastMulti = 0  // 🆕 归零计数器
                            
                        var input = self.poseWindow.toStgcnInput()
                        let stgcnStart = Date()
                        // [ADD] 对齐 Windows：复刻 MMAction2 PreNormalize2D（align_center=true）
                        input = ActionUtilsSwift.preNormalize2D(input)
                            
                        if let scores = self.inferenceHelper.runStgcnModel(input: input) {
                            let stgcnTime = Date().timeIntervalSince(stgcnStart) * 1000
                            //print(String(format: "[计时] [视频线程] 🏃 ST-GCN++ 推理耗时: %.2f ms", stgcnTime))
                                
                            let probs = scores.softmax()
                                
                            // 合并同类概率
                            let probOral = probs[0] + probs[1] // oral = label 0 + label 1
                            let probDoslow = probs[2] + probs[3] + probs[4] + probs[5] // doslow = label 2 + label 3 + label 4 + label 5
                            // 噪音类分开
                            let probNoiseStand = probs[6]
                            let probNoiseSit = probs[7]
                                
                            let TargetProb = probOral + probDoslow
                            let NoiseProb = probNoiseStand + probNoiseSit
                                
                            // 比例阈值参数
                            let NOISE_RATIO_THRESHOLD: Float = 1.5 // β=1.5，噪声需要比目标类高50%才被认定
                                
                            var actionClass: String
                            var bestScore: Float
                                
                            // 判定逻辑
                            if NoiseProb > TargetProb * NOISE_RATIO_THRESHOLD {
                                // 噪声显著高于目标类
                                if probNoiseStand > probNoiseSit {
                                    actionClass = "Noise"
                                    bestScore = 0.0
                                } else {
                                    actionClass = "Noise"
                                    bestScore = 0.0
                                }
                            } else {
                                // 在目标类中选择
                                if probOral > probDoslow {
                                    actionClass = "oral"
                                    bestScore = probOral
                                } else {
                                    actionClass = "do"
                                    bestScore = probDoslow
                                }
                            }
                                
                            //采用置信度阈值法，若最大概率 < 阈值 T（如0.0），则强制判为"杂音"类别,否则按照原有 argmax 判别类别。
                            let threshold: Float = 0.0
                            if bestScore < threshold {
                                actionClass = "Noise"
                                bestScore = 1.0
                                print(String(format: "📸 视频分析判定为 Noise (最大概率=%.3f < 阈值)", bestScore))
                            } else {
                                print(String(format: "📸 视频识别结果: %@ (p=%.2f)", actionClass, bestScore))
                                //print(String(format: "[视频线程] 概率分布: oral=%.3f, doslow=%.3f, noise_stand=%.3f, noise_sit=%.3f",probOral, probDoslow, probNoiseStand, probNoiseSit))
                            }
                                
                            // 线程安全地存储结果
                            self.analysisResults.videoResult = (actionClass, bestScore, Date().timeIntervalSince1970 * 1000)
                                
                            //print(String(format: "[视频线程] 视频类型 = %@, 概率 = %.3f", actionClass, bestScore))
                        }
                    }
                } else {
                    // 🆕 若被判为 Background，清空窗口 & 重置计数
                    // self.poseWindow.removeAll()
                    // self.framesSinceLastMulti = 0
                }
            }
        }
    }


    // MARK: - 音频分析线程（后台线程）
    func performAudioAnalysis() {
        guard !isAnalysisPaused else { return }
        
        let currentTime = player.currentTime().seconds
        let currentTimeMs = Int64(currentTime * 1000)
        
        if currentTimeMs - audioStartTime < 4000 {
            print("⏳ [音频线程] 等待 PCM 缓冲填充中")
            return
        }
        
        let segment = pcmBuffer.readWindowRelaxed(currentTimeMs: currentTimeMs, sampleCount: 32000)
        if let segment = segment {
            let yamnetStart = Date()
            
            let (index, confidence) = audioHelper.predict(audioBuffer: segment)
            
            let yamnetTime = Date().timeIntervalSince(yamnetStart) * 1000
            //print(String(format: "🎵 [音频线程] YAMNet 音频分析耗时: %.2f ms", yamnetTime))
            
            let audioClasses = ["do", "oral", "Noise"]
            let threshold: Float = 0.0 // 置信度阈值
            
            var finalIndex = index
            var finalConfidence = confidence   // 可变置信度
            
            if finalIndex >= 0 && finalIndex < audioClasses.count {
                // 阈值法：最大概率小于阈值则判为"004"杂音
                if confidence < threshold {
                    finalIndex = audioClasses.count - 1
                    print(String(format: "🎵 音频分析判定为 Noise (最大概率=%.3f < 阈值)", confidence))
                }
                var audioClass = audioClasses[finalIndex]
                // Noise 比例阈值纠偏逻辑 （Android 对齐）
                if audioClass == "Noise" && finalConfidence < 0.6 {
                    audioClass = "do"
                    finalConfidence = 1.0 - finalConfidence
                    NSLog("[同步分析] Noise置信度过低(%.3f)，转换为 do，新置信度=%.3f",confidence, finalConfidence)
                }
                
                // 线程安全地存储结果
                self.analysisResults.audioResult = (audioClass, finalConfidence, Date().timeIntervalSince1970 * 1000)
        
                print(String(format: "✅ 🎵 [音频线程] 音频类型 = %@, 概率 = %.3f", audioClass, confidence))
            } else {
                print("⚠️ [音频线程] 音频分析返回了无效索引: \(index)")
            }
        }
        
        /*
        // ===== 🆕 音频节奏分析 =====
        // 读取最后1秒的数据用于节奏分析
        if let last1s = pcmBuffer.readWindowRelaxed(currentTimeMs: currentTimeMs, sampleCount: 16000) {
            if last1s.count > 0 {
                audioRhythmEstimator.push(last1s)  // 将~1秒追加到4秒内部缓冲区
            }
        }
        // 仅在预热时(累积>=4秒)且每~1秒节拍一次时估计
        if audioRhythmEstimator.isWarm() {
            let currentMs = Int64(Date().timeIntervalSince1970 * 1000)
            let rhythmResult = audioRhythmEstimator.estimate(currentMs)
                
            // 存储到线程安全的结果容器
            self.analysisResults.audioRhythm = (
                hz: rhythmResult.frequencyHz,
                conf: rhythmResult.confidence,
                tsMs: rhythmResult.timestampMs,
                valid: rhythmResult.valid
            )
                
            // 打印调试信息
            print(String(format: "[频率测试] 音频节奏 - 有效:%@, 频率:%.2f Hz, 置信度:%.2f",
                         rhythmResult.valid ? "是" : "否",
                         rhythmResult.frequencyHz,
                         rhythmResult.confidence))
        }
        */
        
        // **************[MOD] 音频 Loudness → 档位分析（替代频率估计）**************
        if let last1s = pcmBuffer.readWindowRelaxed(currentTimeMs: currentTimeMs, sampleCount: 8000),
           !last1s.isEmpty {

            audioLoudnessEstimator.push(pcm: last1s)
            let lr = audioLoudnessEstimator.estimate(nowMs: Int64(Date().timeIntervalSince1970 * 1000))

            // 存储到线程安全结果容器
            analysisResults.audioLoudnessLevel = (
                level: lr.level,
                conf: lr.confidence,
                tsMs: lr.timestampMs,
                valid: lr.valid
            )

            print(String(format: "[响度档位] valid:%@, level:%d, conf:%.2f, db:%.1f",
                         lr.valid ? "是" : "否",
                         lr.level,
                         lr.confidence,
                         lr.db))
        }
        //********************************************************************

    }

    // MARK: - 融合和UI更新（主线程）
    func performFusion() {
        guard !isAnalysisPaused else { return }
            
        let videoResult = analysisResults.videoResult
        let audioResult = analysisResults.audioResult
        // let audioRhythm = analysisResults.audioRhythm
        let loud = analysisResults.audioLoudnessLevel
        let videoFreq = analysisResults.videoFreq
            
        // 🆕 计算结果的新鲜度（毫秒）
        let currentTime = Date().timeIntervalSince1970 * 1000
        let videoAge = videoResult.timestamp > 0 ? currentTime - videoResult.timestamp : Double.greatestFiniteMagnitude
        let audioAge = audioResult.timestamp > 0 ? currentTime - audioResult.timestamp : Double.greatestFiniteMagnitude
        // let audiofreqAge = audioRhythm.tsMs > 0 ? currentTime - Double(audioRhythm.tsMs) : Double.greatestFiniteMagnitude
        let loudAge = loud.tsMs > 0 ? currentTime - Double(loud.tsMs) : Double.greatestFiniteMagnitude
        let videofreqAge = videoFreq.tsMs > 0 ? currentTime - Double(videoFreq.tsMs) : Double.greatestFiniteMagnitude
        
        // var videoFreq: (hz: Float, conf: Float, tsMs: Int64) {
            
        // 🆕 过滤超过2秒的过期数据
        let MAX_AGE: Double = 2000 // 2秒
            
        var filteredVideoAction = videoResult.action
        var filteredVideoConfidence = videoResult.confidence
        var filteredAudioAction = audioResult.action
        var filteredAudioConfidence = audioResult.confidence

        // var audioFreq = audioRhythm.hz
        // var audioFreqConf = audioRhythm.conf
        var audioLevelLike: Float = Float(loud.level)  // 用 level(float) 复用现有 computeFinalFreq 管线
        var audioLevelConf: Float = loud.conf
        
        var VideoFreq = videoFreq.hz
        var VideoFreqConf = videoFreq.conf
        
        /*
        // 如果音频频节奏结果过期或无效，清空它
        if !audioRhythm.valid || audiofreqAge > MAX_AGE {
            audioFreq = .nan
            audioFreqConf = 0.0
        }
        */
        if !loud.valid || loudAge > MAX_AGE {
            audioLevelLike = .nan
            audioLevelConf = 0.0
        }
        
        //如果视频节奏结果过期，清空它
        if videofreqAge > MAX_AGE {
            VideoFreq = .nan
            VideoFreqConf = 0.0
        }
            
        // 如果视频结果过期，清空它
        if videoAge > MAX_AGE {
            filteredVideoAction = ""
            filteredVideoConfidence = 0
            //print(String(format: "[融合] 视频结果过期（%.0fms），已忽略", videoAge))
        }
            
        // 如果音频结果过期，清空它
        if audioAge > MAX_AGE {
            filteredAudioAction = ""
            filteredAudioConfidence = 0
            //print(String(format: "[融合] 音频结果过期（%.0fms），已忽略", audioAge))
        }
        
        if filteredVideoAction == "oral" {
            filteredVideoAction = "do"
            NSLog("[融合] 视频动作类型 oral -> do")
        }

        if filteredAudioAction == "oral" {
            filteredAudioAction = "do"
            NSLog("[融合] 音频动作类型 oral -> do")
        }

        // 临时采用音频节律作为最终节律（但通过 computeFinalFreq 做门控，便于后续扩展）
        // 仍然复用 computeFinalFreq
        var finalfreq = computeFinalFreq(
            audioHz: audioLevelLike, audioConf: audioLevelConf,
            videoHz: VideoFreq, videoConf: VideoFreqConf
        )
            
        // 更新UI
        if !filteredVideoAction.isEmpty {
            tvVideoAction.text = String(format: "V: %@ (p=%.2f)", filteredVideoAction, filteredVideoConfidence)
        }
            
        if !filteredAudioAction.isEmpty {
            tvAudioAction.text = String(format: "A: %@ (p=%.2f)", filteredAudioAction, filteredAudioConfidence)
        }
            
        // 🆕 使用平滑融合逻辑
        let finalAction = smoothedFusion(
            videoAction: filteredVideoAction,
            audioAction: filteredAudioAction,
            videoConf: filteredVideoConfidence,
            audioConf: filteredAudioConfidence
        )
            
        // 🆕 使用稳定的蓝牙发送策略
        if !finalAction.isEmpty {
            updateBluetoothState(finalAction, finalfreq)
            //print(String(format: "[融合] finalAction: %@ (V:%.0fms前, A:%.0fms前)", finalAction, videoAge, audioAge))
        }
            
        // 🆕 更新UI, 显示蓝牙实际发送的动作
        if !latestBluetoothAction.isEmpty {
            tvOverlay.text = "Final: \(latestBluetoothAction) | freq: \(finalfreq)"
        } else {
            tvOverlay.text = "Final: 等待识别..."
        }
    }
    
    // 🆕 MARK: - 马达档位映射
    // === 频率 -> 10 档映射表（index 1..10：对应档位1~10；0为停止）===
    // 说明：1 次抽插 = 马达 3 转；freq = RPM / 180；当前硬件可达范围约 1.0–1.8 Hz
    private let LEVEL_RANGES: [ClosedRange<Float>?] = [
        nil,            // 0 占位（停止）

        0.95...1.12,    // 档1  ≈ 190 RPM  (1.06 Hz)
        1.12...1.27,    // 档2  ≈ 220 RPM  (1.22 Hz)
        1.27...1.40,    // 档3  ≈ 240 RPM  (1.33 Hz)
        1.40...1.53,    // 档4  ≈ 270 RPM  (1.50 Hz)
        1.53...1.58,    // 档5  ≈ 280 RPM  (1.56 Hz)
        1.58...1.63,    // 档6  ≈ 290 RPM  (1.61 Hz)
        1.63...1.66,    // 档7  ≈ 295 RPM  (1.64 Hz)
        1.66...1.70,    // 档8  ≈ 300 RPM  (1.67 Hz)
        1.70...1.75,    // 档9  ≈ 310 RPM  (1.72 Hz)
        1.75...1.85     // 档10 ≈ 320 RPM  (1.78 Hz，上沿留余量)
    ]


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


        
    // 🆕 MARK: - 时间窗口平滑融合方法
    private func smoothedFusion(videoAction: String, audioAction: String, videoConf: Float, audioConf: Float) -> String {
        historyLock.lock()
        defer { historyLock.unlock() }
            
        // 添加当前记录到历史
        let record = ActionRecord(
            videoAction: videoAction,
            audioAction: audioAction,
            videoConfidence: videoConf,
            audioConfidence: audioConf,
            timestamp: Date().timeIntervalSince1970
        )
        actionHistory.append(record)
            
        // 保持窗口大小
        while actionHistory.count > SMOOTH_WINDOW_SIZE {
            actionHistory.removeFirst()
        }
            
        // 如果历史记录太少，使用原始逻辑
        if actionHistory.count < 3 {
            return selectBestAction(
                videoAction: videoAction,
                audioAction: audioAction,
                videoConf: videoConf,
                audioConf: audioConf
            )
        }
            
        // 统计各动作的加权得分
        var actionScores = [String: Float]()
        var actionCounts = [String: Int]()
            
        // 给最近的记录更高的权重
        for (index, record) in actionHistory.enumerated() {
            let weight = Float(index + 1) / Float(actionHistory.count) // 时间权重，越新权重越高
                
            // 处理视频动作
            if !record.videoAction.isEmpty && record.videoAction != "Background" {
                // 包括Noise在内的所有动作都参与评分
                let videoKey = record.videoAction
                var score = actionScores[videoKey] ?? 0
                score += record.videoConfidence * weight * 0.7 // 视频权重稍低
                actionScores[videoKey] = score
                    
                let count = actionCounts[videoKey] ?? 0
                actionCounts[videoKey] = count + 1
            }
                
            // 处理音频动作
            if !record.audioAction.isEmpty {
                // 包括Noise在内的所有动作都参与评分
                let audioKey = record.audioAction
                var score = actionScores[audioKey] ?? 0
                score += record.audioConfidence * weight * 1.3 // 音频权重更高
                actionScores[audioKey] = score
                    
                let count = actionCounts[audioKey] ?? 0
                actionCounts[audioKey] = count + 1
            }
        }
            
        // 选择得分最高的动作
        var bestAction = ""
        var bestScore: Float = 0
            
        for (action, score) in actionScores {
            let count = actionCounts[action] ?? 0
                
            // 需要至少出现3次才考虑（避免偶然噪声）
            if count >= 3 && score > bestScore {
                bestScore = score
                bestAction = action
            }
        }
            
        // 如果没有找到合适的动作，使用最新的高置信度结果
        if bestAction.isEmpty {
            if let latest = actionHistory.last {
                bestAction = selectBestAction(
                    videoAction: latest.videoAction,
                    audioAction: latest.audioAction,
                    videoConf: latest.videoConfidence,
                    audioConf: latest.audioConfidence
                )
            }
        }
            
        // 记录平滑结果
        //print(String(format: "[平滑融合] 窗口大小:%d, 选择动作:%@ (得分:%.2f)",actionHistory.count, bestAction, bestScore))
            
        return bestAction
    }
        
    // 🆕 简单的动作选择逻辑（用于历史记录不足时）
    private func selectBestAction(videoAction: String, audioAction: String, videoConf: Float, audioConf: Float) -> String {
        // 使用置信度来决定，而不是排除Noise
        // 音频优先策略
        if !audioAction.isEmpty {
            // 如果音频是有效动作（非Noise）或音频置信度很高，使用音频
            if audioAction != "Noise" || audioConf > 0.7 {
                return audioAction
            }
        }
        // 视频作为备选
        if !videoAction.isEmpty && videoAction != "Background" {
            // 如果视频是有效动作（非Noise）或视频置信度很高，使用视频
            if videoAction != "Noise" || videoConf > 0.7 {
                return videoAction
            }
        }
        // 如果音视频都是Noise，返回Noise（而不是空字符串）
        if audioAction == "Noise" || videoAction == "Noise" {
            return "Noise"
        }
            
        return ""
    }
    
    
    // MARK: - 更新蓝牙状态 - 二级平滑策略
    private func updateBluetoothState(_ newAction: String, _ finalFreq: Int) {
        let currentTime = Date().timeIntervalSince1970 * 1000  // ms
        
        // 1) [保持] 本地暂停保护
        if BluetoothManager.shared.isPausedByLocal {
            print("[蓝牙] ⚠️ 设备已暂停App控制，忽略动作: \(newAction)")
            return
        }
        
        // ===================== [NEW] 档位确认（迟滞 + 短稳 + 最小驻留） =====================
        let supportsLevel = isSexAction(newAction) && currentStateSupportsSpeed()   // NEW
        if supportsLevel {
            let latestLevel = finalFreq   // 0..10（来自节律映射）                            // NEW
            if latestLevel >= upThreshold(currentLevel) || latestLevel <= downThreshold(currentLevel) {
                if pendingLevel == nil || pendingLevel! != latestLevel {
                    pendingLevel = latestLevel
                    pendingLevelSinceMs = currentTime
                } else {
                    let dwell = currentTime - pendingLevelSinceMs
                    let stableOk = (dwell >= LEVEL_STABLE_MS)                        // NEW: 短稳（≥800ms）
                    if stableOk && (currentTime - currentLevelSinceMs >= LEVEL_MIN_DUR_MS) {
                        // NEW: 切换生效档位
                        currentLevel = pendingLevel!
                        currentLevelSinceMs = currentTime
                        // 可选：pendingLevel 保留或清空均可
                    }
                }
            } else {
                pendingLevel = nil // 未跨阈值，不计作有效变化
            }
        } else {
            pendingLevel = nil     // 非做爱/不支持变速：忽略档位变化
            // 可选：把 currentLevel 置为安全档位（如 0/1）
        }
        // ===================== [/NEW] 档位确认结束 =====================
        
        // 2) [保持] 新动作进入“待确认”
        if newAction != pendingBluetoothState {
            pendingBluetoothState = newAction
            pendingStateStartTime = currentTime
            print(String(format: "[蓝牙] 检测到新动作: %@, 等待确认...", newAction))
        }
        
        // [ADD] 当“当前执行的是目标动作(do/oral)”且“新动作是Noise”时，提高Noise切入确认时间，避免短暂停顿
        let isCurrentTarget = isSexAction(currentBluetoothState)   // do/oral
        let isToNoise = (newAction == "Noise")
        let stableConfirmMs: TimeInterval = (isCurrentTarget && isToNoise) ? 2400 : BLUETOOTH_STABLE_CONFIRM_MS
        
        // 3) [MOD] 动作稳定确认：目标动作 -> Noise 需要更长确认时间，其他仍按默认1600ms
        if pendingBluetoothState == newAction &&
            (currentTime - pendingStateStartTime) >= stableConfirmMs {
            
            // ===== 情况 A：切换到“不同动作” =====
            if pendingBluetoothState != currentBluetoothState {
                
                // [保持] 当前动作最小持续（≥2s）
                if currentBluetoothState.isEmpty ||
                    (currentTime - currentStateStartTime) >= BLUETOOTH_MIN_DURATION {
                    
                    // [保持] 发送节流（≥1600ms）
                    if (currentTime - lastBluetoothSendTime) >= BLUETOOTH_SEND_INTERVAL {
                        
                        // NEW/CHANGED: 发送时携带“已确认档位”，而非原始 finalFreq
                        let levelToSend = supportsLevel ? currentLevel : finalFreq   // CHANGED
                        
                        print(String(format: "[蓝牙] [同步分析] ✅ 发送指令: %@ (已稳定%.0fms, level=%d)",
                                     pendingBluetoothState,
                                     currentTime - pendingStateStartTime,
                                     levelToSend)) // NEW: 打印档位
                        
                        // [保持] 更新 UI 文案
                        latestBluetoothAction = pendingBluetoothState
                        
                        // [保持] 发送动作（同一接口，第二参数为档位）
                        if BluetoothManager.shared.isConnected {
                            BluetoothManager.shared.sendAction(pendingBluetoothState, levelToSend) // CHANGED
                            lastSentLevel = levelToSend                                            // NEW: 记录已发送档位
                        }
                        
                        currentBluetoothState = pendingBluetoothState
                        currentStateStartTime = currentTime
                        lastBluetoothSendTime = currentTime
                    }
                } else {
                    // [保持] 还未达到最小持续时间
                    let remainingTime = BLUETOOTH_MIN_DURATION - (currentTime - currentStateStartTime)
                    print(String(format: "[蓝牙] 当前动作%@需继续保持%.0fms", currentBluetoothState, remainingTime))
                }
            }
            // ===== 情况 B：动作未变，但档位已确认变化 → 重发同一动作来更新档位 =====
            else {
                // NEW: 仅当支持变速、档位确实变化、达到发送间隔时才重发
                let levelChanged = supportsLevel && (currentLevel != lastSentLevel)                  // NEW
                let gapOk = (currentTime - lastBluetoothSendTime) >= LEVEL_SEND_GAP_MS               // NEW
                
                if levelChanged && gapOk {
                    let levelToSend = currentLevel                                                   // NEW
                    print(String(format: "[蓝牙] 同动作更新档位：%@ -> level=%d",
                                 currentBluetoothState, levelToSend))                                 // NEW
                    if BluetoothManager.shared.isConnected {
                        // 协议无“单独速度帧”，故复用相同动作指令携带新档位                       // NEW
                        BluetoothManager.shared.sendAction(currentBluetoothState, levelToSend)        // NEW
                        lastSentLevel = levelToSend                                                  // NEW
                        lastBluetoothSendTime = currentTime                                          // NEW
                    }
                }
            }
        }
    }

    // ===================== 蓝牙更新状态的工具类函数 =====================
    // 迟滞阈值（Schmitt）
    @inline(__always) private func upThreshold(_ cur: Int) -> Int   { min(10, cur + 1) }
    @inline(__always) private func downThreshold(_ cur: Int) -> Int { max(0,  cur - 1) }

    // 门控——当前动作是否属于“做爱大类”
    private func isSexAction(_ action: String) -> Bool {
        // 支持 "do" 与 "oral" 两类动作
        let lower = action.lowercased()
        return lower.hasPrefix("do") || lower.hasPrefix("oral")
    }

    // 门控——当前动作是否允许变速
    private func currentStateSupportsSpeed() -> Bool {
        // 支持 "do" 与 "oral" 状态
        let lower = currentBluetoothState.lowercased()
        return lower.hasPrefix("do") || lower.hasPrefix("oral")
    }


    // MARK: - 处理用户拖动
    func handleUserSeek(currentMs: Int64) {
        print("🟡 检测到用户拖动播放，准备延迟处理")
        
        pendingSeekWorkItem?.cancel()
        
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            
            print("✅ 执行用户拖动后的 seek 处理逻辑，时间点: \(currentMs)ms")
            
            // 在后台线程中清理数据
            self.videoAnalysisQueue.async {
                self.poseWindow.removeAll()
                self.poseWindow8.removeAll()  // 🆕 清空二分类窗口
                self.framesSinceLastMulti = 0  // 🆕 重置帧计数器
                
                // 🆕 重置视频节奏器
                self.videoRhythmEstimator.reset()
                
                // 🆕 清空动作历史
                self.historyLock.lock()
                self.actionHistory.removeAll()
                self.historyLock.unlock()
                
                // 重置蓝牙状态
                self.pendingBluetoothState = ""
                self.currentBluetoothState = ""
                self.pendingStateStartTime = 0
                self.currentStateStartTime = 0
            }
            
            self.audioAnalysisQueue.async {
                self.pcmBuffer.reset()
                self.audioDecoder.seekTo(Int(currentMs))
                self.audioStartTime = currentMs
                // 🆕 重置音频节奏器
                // self.audioRhythmEstimator.reset()
                self.audioLoudnessEstimator.reset()
            }
            // 🆕 重置分析结果中的节奏数据（视频和音频）
            self.analysisResults.resetRhythm()
            
            self.lastFinalAction = ""
            
            // 在 handleUserSeek(...) 的后台线程清理块中追加：
            // 重置档位确认状态
            self.currentLevel = 1
            self.currentLevelSinceMs = 0
            self.pendingLevel = nil
            self.pendingLevelSinceMs = 0
            self.lastSentLevel = 0

            // ★ 新增：清空挂起状态
            self.suspendedBluetoothState = ""
            self.suspendedLevel = 0
            
            // 播放过完片尾后，如果用户 seek 了，撤销“已播完”标记
            if self.isVideoCompleted {
                self.isVideoCompleted = false
                // 只有播放器处于播放状态时才恢复分析
                if self.player.rate != 0 {
                    self.resumeAnalysis()
                }
            }
        }
        
        pendingSeekWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    // MARK: - 播放状态监听
    // ⏱️ 播放状态检测逻辑：每 200ms 检测一次播放器是否暂停
    func startPlaybackObserver() {
        playStateTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            let isCurrentlyPlaying = self.player.rate != 0
            
            if isCurrentlyPlaying != self.lastIsPlaying {
                self.lastIsPlaying = isCurrentlyPlaying
                
                if isCurrentlyPlaying {
                    self.resumeAnalysis()
                } else {
                    self.pauseAnalysis()
                }
            }
        }
    }

    // MARK: - 暂停与恢复
    func pauseAnalysis() {
        isAnalysisPaused = true

        // ★ 新增：挂起当前蓝牙动作并发送停止信号
        if !currentBluetoothState.isEmpty && currentBluetoothState != "Noise" {
            suspendedBluetoothState = currentBluetoothState
            suspendedLevel = currentLevel
            print("[暂停] 挂起动作: \(suspendedBluetoothState), 档位: \(suspendedLevel)")
        }
        if BluetoothManager.shared.isConnected && !BluetoothManager.shared.isPausedByLocal {
            BluetoothManager.shared.sendAction("Noise", 0)
            print("[暂停] 已发送停止信号(Noise)")
        }

        print("⏸️ 分析暂停")
    }

    func resumeAnalysis() {
        isAnalysisPaused = false

        // ★ 新增：恢复挂起的蓝牙动作
        if !suspendedBluetoothState.isEmpty {
            print("[恢复] 恢复动作: \(suspendedBluetoothState), 档位: \(suspendedLevel)")
            currentBluetoothState = suspendedBluetoothState
            currentLevel = suspendedLevel
            currentStateStartTime = Date().timeIntervalSince1970 * 1000
            currentLevelSinceMs = Date().timeIntervalSince1970 * 1000

            if BluetoothManager.shared.isConnected && !BluetoothManager.shared.isPausedByLocal {
                BluetoothManager.shared.sendAction(suspendedBluetoothState, suspendedLevel)
                lastBluetoothSendTime = Date().timeIntervalSince1970 * 1000
                lastSentLevel = suspendedLevel
                print("[恢复] 已发送恢复动作: \(suspendedBluetoothState) 档位: \(suspendedLevel)")
            }

            suspendedBluetoothState = ""
            suspendedLevel = 0
        }

        print("▶️ 分析恢复")
    }

    // MARK: - 视频结束处理
    @objc func videoDidEnd() {
        isVideoCompleted = true
        pauseAnalysis()
        
        // 🆕 重置两个节奏器
        videoRhythmEstimator?.reset()
        // audioRhythmEstimator?.reset()
        self.audioLoudnessEstimator.reset()

        // 重置存储的结果
        analysisResults.resetRhythm()
        
        print("视频播放完成，已暂停分析等待用户操作")
    }

    // MARK: - 其他功能保持不变
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        playerLayer?.frame = videoView.bounds
    }

    // MARK: - 全屏控制，全屏与退出全屏
    // 加一个可变的方向掩码属性
    private var allowedOrientations: UIInterfaceOrientationMask = .portrait

    @objc func toggleFullscreen() {
        isFullscreen.toggle()
        
        allowedOrientations = isFullscreen ? .landscapeRight : .portrait
        
        if #available(iOS 16.0, *) {
            if let windowScene = view.window?.windowScene {
                let prefs = UIWindowScene.GeometryPreferences.iOS(
                    interfaceOrientations: allowedOrientations
                )
                windowScene.requestGeometryUpdate(prefs) { error in
                    if let err = error as? NSError {
                        print("❌ 方向切换失败: \(err.localizedDescription)")
                    }
                }
            }
        } else {
            // ---------------------- iOS 15 兜底 ----------------------
            // 只有 15 或更早系统才会走到这里
            UIDevice.current.setValue(
                allowedOrientations == .landscapeRight
                ? UIInterfaceOrientation.landscapeRight.rawValue
                : UIInterfaceOrientation.portrait.rawValue,
                forKey: "orientation"
            )
            UIViewController.attemptRotationToDeviceOrientation()
        }
        
        // 刷新系统 UI
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfSupportedInterfaceOrientations()
        navigationController?.setNavigationBarHidden(isFullscreen, animated: true)
        
        // 更新按钮图标
        let icon = isFullscreen
          ? "arrow.down.right.and.arrow.up.left"
          : "arrow.up.left.and.arrow.down.right"
        btnFullscreen.setImage(UIImage(systemName: icon), for: .normal)
    }

    // 让控制器返回我们维护的掩码
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        allowedOrientations
    }

    //（可选）如果你想彻底隐藏状态栏
    override var prefersStatusBarHidden: Bool { isFullscreen }

    // MARK: - 播放控制
    @objc func togglePlayPause() {
        if player.rate == 0 {
            // ▶️ 当前是暂停 → 恢复播放 + 分析
            player.play()
            resumeAnalysis()
            let icon = UIImage(systemName: "pause.fill")
            btnPlayPause.setImage(icon, for: .normal)
            print("▶️ 用户点击：恢复播放")
        } else {
            // ⏸️ 当前是播放 → 暂停播放 + 分析
            player.pause()
            pauseAnalysis()
            let icon = UIImage(systemName: "play.fill")
            btnPlayPause.setImage(icon, for: .normal)
            print("⏸️ 用户点击：暂停播放")
        }
    }

    // MARK: - 进度条控制
    @objc func sliderTouchDown() {
        isSeekingByUser = true
        player.pause()
    }

    @objc func sliderValueChanged() {
        let targetTime = CMTime(seconds: Double(progressSlider.value), preferredTimescale: 600)
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
        
        // 🆕 拖动时实时更新当前时间显示
        currentTimeLabel.text = formatTime(Double(progressSlider.value))
    }

    @objc func sliderTouchUp() {
        isSeekingByUser = false
        let targetTime = CMTime(seconds: Double(progressSlider.value), preferredTimescale: 600)
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            if finished {
                self.didUserSeek = true // 设置人为拖动 flag
                print("🎯 用户主动 seek 到 \(self.progressSlider.value) 秒")
            }
        }
        player.play()
    }
    
    // MARK: - 进度条点击处理
    @objc func sliderTapped(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: progressSlider)
        let percentage = location.x / progressSlider.bounds.width
        let value = Float(percentage) * (progressSlider.maximumValue - progressSlider.minimumValue) + progressSlider.minimumValue
        
        // 暂停播放
        player.pause()
        
        // 更新进度条值
        progressSlider.value = value
        
        // 跳转到目标时间
        let targetTime = CMTime(seconds: Double(value), preferredTimescale: 600)
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            if finished {
                self?.didUserSeek = true // 设置人为拖动 flag，触发 handleUserSeek
                print("🎯 用户点击进度条跳转到 \(value) 秒")
            }
        }
        
        // 恢复播放
        player.play()
    }
    
    // MARK: - 🆕 时间格式化
    private func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite else {
            return "0:00"
        }
        
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }

    // MARK: - 清理资源
    // 用户从 SwiftUI 主页面左滑返回时, 结束播放与分析
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        print("🛑 页面将消失，停止播放与分析")
        
        // ★ 新增：退出时发送停止信号
        if BluetoothManager.shared.isConnected {
            BluetoothManager.shared.sendAction("Noise", 0)
            print("[退出] 已发送停止信号(Noise)")
        }
        
        // 🆕 重置两个节奏器
        videoRhythmEstimator?.reset()
        // audioRhythmEstimator?.reset()
        self.audioLoudnessEstimator.reset()
        
        // 停止所有定时器
        videoAnalysisTimer?.cancel()
        audioAnalysisTimer?.cancel()
        fusionTimer?.invalidate()
        playStateTimer?.invalidate()
        // 停止自调度循环
        videoLoopWorkItem?.cancel()
        audioLoopWorkItem?.cancel()
        fusionLoopWorkItem?.cancel()
        
        player.pause()
        audioDecoder?.stop()
    }

    deinit {
        videoAnalysisTimer?.cancel()
        audioAnalysisTimer?.cancel()
        fusionTimer?.invalidate()
        playStateTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        audioDecoder?.stop()
        // 停止自调度循环
        videoLoopWorkItem?.cancel()
        audioLoopWorkItem?.cancel()
        fusionLoopWorkItem?.cancel()

    }
}

// MARK: - 工具扩展（保持不变）
extension Array where Element == PoseFrame {
    func toStgcnInput() -> [[[Float]]] {
        // 将滑动窗口 Pose 数据转换为 ST-GCN++ 输入
        return self
    }
}

extension Array where Element == Float {
    func argmax() -> Int {
        guard let maxVal = self.max(), let idx = self.firstIndex(of: maxVal) else { return 0 }
        return idx
    }
    
    func softmax() -> [Float] { // 置信度阈值法, 加 softmax 归一化后再判断
        let expVals = self.map { expf($0) }
        let sumExp = expVals.reduce(0, +)
        return expVals.map { $0 / sumExp }
    }
}

struct Math {
    static func argmax(_ array: [Float]) -> Int {
        guard let maxVal = array.max(), let idx = array.firstIndex(of: maxVal) else { return 0 }
        return idx
    }
}

// [ADD] 直接放在 VideoProcessViewController.swift 底部（工具扩展附近）
// 复刻 Windows ActionUtils.preNormalize2D / MMAction2 PreNormalize2D(align_center=true)
enum ActionUtilsSwift {
    static func preNormalize2D(_ window: [[[Float]]]) -> [[[Float]]] {
        guard !window.isEmpty, !window[0].isEmpty else { return window }

        var xMin = Float.greatestFiniteMagnitude
        var yMin = Float.greatestFiniteMagnitude
        var xMax = -Float.greatestFiniteMagnitude
        var yMax = -Float.greatestFiniteMagnitude

        for frame in window {
            for kp in frame {
                if kp.count < 3 { continue }
                if kp[2] <= 0 { continue }
                xMin = min(xMin, kp[0])
                yMin = min(yMin, kp[1])
                xMax = max(xMax, kp[0])
                yMax = max(yMax, kp[1])
            }
        }

        // 没有人体点：给一个默认 bbox，保持与 Java 版一致的兜底行为
        if xMax < xMin {
            xMin = 0; yMin = 0; xMax = 1; yMax = 1
        }

        let cx = 0.5 * (xMin + xMax)
        let cy = 0.5 * (yMin + yMax)
        var scale = max(xMax - xMin, yMax - yMin)
        if scale < 1e-6 { scale = 1e-6 }

        var out = window
        for t in 0..<out.count {
            for v in 0..<out[t].count {
                out[t][v][0] = (out[t][v][0] - cx) / scale
                out[t][v][1] = (out[t][v][1] - cy) / scale
                // out[t][v][2] = out[t][v][2] // conf 原样保留
            }
        }
        return out
    }
}

