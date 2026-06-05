//
//  WebVideoPlayerEngine.swift
//  Xcup
//
//  AVPlayer 封装：负责播放网页嗅探来的视频流（mp4 / m3u8），
//  并同时输出到屏幕（AVPlayerLayer）+ 抽帧（AVPlayerItemVideoOutput）+ 抓音频（WebVideoAudioTap）。
//
//  对应 Android: ExoPlayerEngine.java
//
//  设计点：
//   - 播放器 position 必须主线程读，否则部分 API 不稳定。
//     用一个 50ms 主线程 timer 把当前 position 缓存到 volatile-ish 的 lastKnownPositionMs，
//     后台线程读它，不直接碰 AVPlayer 实例。
//   - Headers 通过 AVURLAsset 的 AVURLAssetHTTPHeaderFieldsKey（私有 key，但事实上可用）传入。
//   - seek 完成回调：用 periodicTimeObserver 检测时间跳变，差 > 1s 视作 seek。
//

import Foundation
import AVFoundation
import UIKit

final class WebVideoPlayerEngine: NSObject {

    // MARK: - Public

    /// 屏幕上展示用的图层。外部插到 videoView.layer 上。
    let playerLayer = AVPlayerLayer()

    /// 是否在播放（由 KVO rate 触发）
    var onPlayPauseChanged: ((Bool) -> Void)?

    /// 用户 seek 后的回调（参数：seek 后的位置 ms）。**主线程**调用。
    var onUserSeek: ((Int64) -> Void)?

    /// 播放到结尾。
    var onEnded: (() -> Void)?

    /// 准备好（item.status = .readyToPlay）。主线程。
    var onReady: (() -> Void)?

    /// 缓存的当前播放位置（毫秒）。**线程安全读**。
    /// 后台线程（帧/音频分析、PCM tap）只读这个；不要直接读 player.currentTime。
    private(set) var lastKnownPositionMs: Int64 = 0

    /// 总时长（毫秒）。直播流为 0 或 .nan，按 0 处理。
    private(set) var durationMs: Int64 = 0

    /// PCM 时间戳源（毫秒）。默认 = lastKnownPositionMs，但调用方可改成 wall-clock（兼容直播）。
    var audioTimestampProvider: (() -> Int64)? {
        didSet {
            if let p = audioTimestampProvider {
                audioTap?.positionProvider = p
            }
        }
    }

    /// PCM 缓冲（外部传入，与分析层共享）
    let pcmBuffer: PcmCircularBuffer

    // MARK: - Private

    private(set) var player: AVPlayer!
    private(set) var playerItem: AVPlayerItem!
    private var videoOutput: AVPlayerItemVideoOutput!
    private var audioTap: WebVideoAudioTap!

    private var lastObservedTimeForSeekMs: Int64 = -1
    private var periodicObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?

    private var pendingStartMs: Int64 = 0

    // MARK: - Init

    /// - Parameters:
    ///   - videoURL: 视频流地址（.mp4 / .m3u8）
    ///   - headers: 透传给 AVURLAsset 的 HTTP 头（Referer / User-Agent / Cookie）
    ///   - startMs: 起播位置（毫秒，可为 0）
    ///   - pcmBuffer: 共享的 PCM 缓冲
    init(videoURL: URL, headers: [String: String], startMs: Int64, pcmBuffer: PcmCircularBuffer) {
        self.pcmBuffer = pcmBuffer
        super.init()
        self.pendingStartMs = startMs

        // 1) Asset + headers
        // AVURLAssetHTTPHeaderFieldsKey 是私有 key 但实际可用，许多大厂 App 都这样做。
        // App Store 审核如要更稳，可改用 AVAssetResourceLoaderDelegate。
        let options: [String: Any] = [
            "AVURLAssetHTTPHeaderFieldsKey": headers
        ]
        let asset = AVURLAsset(url: videoURL, options: options)

        // 2) PlayerItem
        let item = AVPlayerItem(asset: asset)
        self.playerItem = item

        // 3) Video frame tap: BGRA32 输出，便于后续 CIImage 缩放
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let vOut = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        item.add(vOut)
        self.videoOutput = vOut

        // 4) Audio tap → PCM 缓冲（推迟到 readyToPlay 才挂，HLS 的 audio track 在那之后才可见）
        let tap = WebVideoAudioTap(pcmBuffer: pcmBuffer)
        tap.positionProvider = { [weak self] in self?.lastKnownPositionMs ?? 0 }
        self.audioTap = tap

        // 5) Player + Layer
        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = true
        self.player = p
        playerLayer.player = p
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = UIColor.black.cgColor

        // 6) KVO: item.status
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                switch item.status {
                case .readyToPlay:
                    let secs = CMTimeGetSeconds(item.duration)
                    self.durationMs = (secs.isFinite && secs > 0) ? Int64(secs * 1000) : 0
                    // tap 必须在 readyToPlay 之后挂（HLS 的 audio track 这时才可见）
                    if item.audioMix == nil {
                        self.audioTap.attach(to: item)
                    }
                    self.onReady?()
                    if self.pendingStartMs > 0 {
                        let target = self.pendingStartMs
                        self.pendingStartMs = 0
                        let cmt = CMTime(value: target, timescale: 1000)
                        self.player.seek(to: cmt, toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                case .failed:
                    print("❌ [WebVideoPlayerEngine] playerItem failed: \(String(describing: item.error))")
                default: break
                }
            }
        }

        // 7) KVO: player.rate (播放/暂停)
        rateObservation = p.observe(\.rate, options: [.new]) { [weak self] player, _ in
            DispatchQueue.main.async { self?.onPlayPauseChanged?(player.rate != 0) }
        }

        // 8) End-of-item
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.onEnded?()
        }

        // 9) Periodic time observer：缓存 position + 检测大跳变 = seek
        periodicObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 20), // 50ms
            queue: .main
        ) { [weak self] time in
            guard let self = self else { return }
            let curMs = Int64(time.seconds.isFinite ? time.seconds * 1000 : 0)
            // 检测 seek：与上次观测差 > 1 秒视为 seek
            if self.lastObservedTimeForSeekMs >= 0 {
                let delta = abs(curMs - self.lastObservedTimeForSeekMs)
                if delta > 1000 {
                    self.onUserSeek?(curMs)
                }
            }
            self.lastObservedTimeForSeekMs = curMs
            self.lastKnownPositionMs = curMs
        }
    }

    // MARK: - Control

    func play() { player?.play() }
    func pause() { player?.pause() }

    var isPlaying: Bool { (player?.rate ?? 0) != 0 }

    func seek(toMs ms: Int64) {
        guard let player = player else { return }
        let t = CMTime(value: max(0, ms), timescale: 1000)
        // 不重置 lastObservedTimeForSeekMs：让 periodicObserver 自然检测跳变并触发 onUserSeek
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Frame extraction

    /// 取当前帧并缩放到 160x160。后台线程调用。返回 UIImage（RGB）。
    /// 内部用 lastKnownPositionMs 对应的 itemTime；如果不可用就用 currentTime。
    func captureFrame160() -> UIImage? {
        guard let videoOutput = videoOutput else { return nil }

        let itemTime = CMTime(value: lastKnownPositionMs, timescale: 1000)
        let queryTime = videoOutput.hasNewPixelBuffer(forItemTime: itemTime)
            ? itemTime
            : playerItem.currentTime()

        var displayTime = CMTime.zero
        guard let pb = videoOutput.copyPixelBuffer(forItemTime: queryTime, itemTimeForDisplay: &displayTime) else {
            return nil
        }
        return Self.pixelBufferTo160(pb)
    }

    /// CVPixelBuffer (BGRA32) → 160x160 UIImage (RGB)
    private static func pixelBufferTo160(_ pb: CVPixelBuffer) -> UIImage? {
        let srcW = CGFloat(CVPixelBufferGetWidth(pb))
        let srcH = CGFloat(CVPixelBufferGetHeight(pb))
        if srcW <= 0 || srcH <= 0 { return nil }

        let ci = CIImage(cvPixelBuffer: pb)
        let target: CGFloat = 160
        let sx = target / srcW
        let sy = target / srcH
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: sx, y: sy))

        // 用一个静态 CIContext 提高效率
        struct Ctx { static let ci = CIContext(options: [.useSoftwareRenderer: false]) }
        let extent = CGRect(x: 0, y: 0, width: target, height: target)
        guard let cg = Ctx.ci.createCGImage(scaled, from: extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: - Cleanup

    func stop() {
        player?.pause()
        if let obs = periodicObserver { player?.removeTimeObserver(obs); periodicObserver = nil }
        if let obs = endObserver { NotificationCenter.default.removeObserver(obs); endObserver = nil }
        statusObservation = nil
        rateObservation = nil
        playerItem?.audioMix = nil
        playerLayer.player = nil
    }

    deinit {
        stop()
    }
}
