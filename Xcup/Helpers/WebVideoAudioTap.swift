//
//  WebVideoAudioTap.swift
//  Xcup
//
//  AVPlayerItem 的 MTAudioProcessingTap 包装。
//  从播放器渲染链 tap 出 PCM（透传给扬声器 + 复制一份给我们分析），
//  做 mono mixdown + 线性重采样到 16kHz Float32，写入 PcmCircularBuffer。
//
//  对应 Android: PcmCaptureAudioProcessor.java
//

import Foundation
import AVFoundation
import CoreMedia
import MediaToolbox

final class WebVideoAudioTap {

    // MARK: - Public
    /// 调用方提供的位置回调（用于给 PCM 加时间戳，毫秒）
    var positionProvider: () -> Int64 = { 0 }

    /// 目标采样率（用于喂 YAMNet）
    private let targetSampleRate: Int = 16000

    /// 输出 AudioMix。挂到 playerItem.audioMix 上。
    private(set) var audioMix: AVAudioMix?

    // MARK: - Private
    private weak var pcmBuffer: PcmCircularBuffer?
    private var tap: MTAudioProcessingTap?

    // tap 内部状态（仅在 audio thread 访问）
    fileprivate var sourceSampleRate: Double = 16000
    fileprivate var sourceChannels: Int = 1
    fileprivate var monoScratch: [Float] = []
    fileprivate var resampleScratch: [Float] = []
    fileprivate var lastSourceTail: Float = 0
    fileprivate var hasLastTail: Bool = false

    init(pcmBuffer: PcmCircularBuffer) {
        self.pcmBuffer = pcmBuffer
    }

    /// 把 tap 挂到 playerItem.audioMix 上。需要 playerItem.asset 已加载完音频轨道。
    func attach(to playerItem: AVPlayerItem) {
        guard let audioTrack = playerItem.asset.tracks(withMediaType: .audio).first else {
            print("❌ [WebVideoAudioTap] 未找到音频轨道")
            return
        }

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque()),
            init: webvideo_tap_init,
            finalize: webvideo_tap_finalize,
            prepare: webvideo_tap_prepare,
            unprepare: webvideo_tap_unprepare,
            process: webvideo_tap_process
        )

        var tapRef: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &tapRef
        )
        guard status == noErr, let createdTap = tapRef else {
            print("❌ [WebVideoAudioTap] MTAudioProcessingTapCreate 失败: \(status)")
            return
        }
        self.tap = createdTap

        let params = AVMutableAudioMixInputParameters(track: audioTrack)
        params.audioTapProcessor = createdTap

        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        playerItem.audioMix = mix
        self.audioMix = mix

        print("✅ [WebVideoAudioTap] 挂载成功")
    }

    /// 从 audio 线程喂数据。已经是单声道 Float32 且目标采样率 16000。
    fileprivate func deliverResampled(_ data: UnsafePointer<Float>, frameCount: Int) {
        if frameCount <= 0 { return }
        let ts = self.positionProvider()
        var arr = [Float](repeating: 0, count: frameCount)
        arr.withUnsafeMutableBufferPointer { dst in
            dst.baseAddress!.update(from: data, count: frameCount)
        }
        pcmBuffer?.write(arr, startTimestampMs: ts, sampleRate: targetSampleRate)
    }
}

// MARK: - C callbacks (real-time audio thread)

private func webvideo_tap_init(
    _ tap: MTAudioProcessingTap,
    _ clientInfo: UnsafeMutableRawPointer?,
    _ tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>
) {
    // clientInfo 是 passRetained(self) 的指针；存到 tap storage 里
    tapStorageOut.pointee = clientInfo
}

private func webvideo_tap_finalize(_ tap: MTAudioProcessingTap) {
    let storage = MTAudioProcessingTapGetStorage(tap)
    Unmanaged<WebVideoAudioTap>.fromOpaque(storage).release()
}

private func webvideo_tap_prepare(
    _ tap: MTAudioProcessingTap,
    _ maxFrames: CMItemCount,
    _ format: UnsafePointer<AudioStreamBasicDescription>
) {
    let storage = MTAudioProcessingTapGetStorage(tap)
    let me = Unmanaged<WebVideoAudioTap>.fromOpaque(storage).takeUnretainedValue()
    me.sourceSampleRate = format.pointee.mSampleRate > 0 ? format.pointee.mSampleRate : 16000
    me.sourceChannels = max(1, Int(format.pointee.mChannelsPerFrame))
    // 预分配 scratch
    me.monoScratch = [Float](repeating: 0, count: Int(maxFrames))
    // 重采样输出最多约 maxFrames * (16000/source)；按 16000/最低源采样率(8000) 估个 2 倍上限即可
    let resampledMax = max(Int(maxFrames), Int(Double(maxFrames) * 16000.0 / max(1.0, me.sourceSampleRate)) + 16)
    me.resampleScratch = [Float](repeating: 0, count: resampledMax * 2)
    me.hasLastTail = false
    print("✅ [WebVideoAudioTap] prepare: sr=\(me.sourceSampleRate) ch=\(me.sourceChannels) maxFrames=\(maxFrames)")
}

private func webvideo_tap_unprepare(_ tap: MTAudioProcessingTap) {
    // no-op
}

private func webvideo_tap_process(
    _ tap: MTAudioProcessingTap,
    _ numberFrames: CMItemCount,
    _ flags: MTAudioProcessingTapFlags,
    _ bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
    _ numberFramesOut: UnsafeMutablePointer<CMItemCount>,
    _ flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
) {
    // 1) 先从上游拉取数据。MTAudioProcessingTapGetSourceAudio 会写入 bufferListInOut。
    let status = MTAudioProcessingTapGetSourceAudio(
        tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut
    )
    guard status == noErr else { return }

    let frameCount = numberFramesOut.pointee
    if frameCount <= 0 { return }

    let storage = MTAudioProcessingTapGetStorage(tap)
    let me = Unmanaged<WebVideoAudioTap>.fromOpaque(storage).takeUnretainedValue()

    // 2) 从 AudioBufferList 拿到 Float32 数据 → 下混成 mono
    //    AVPlayer 的 tap 默认是 Float32 非交错（每声道一个 buffer），但保险起见两种都处理。
    let abl = UnsafeMutableAudioBufferListPointer(bufferListInOut)
    let bufferCount = abl.count
    if bufferCount == 0 { return }

    // 确保 scratch 容量够
    if me.monoScratch.count < frameCount {
        me.monoScratch = [Float](repeating: 0, count: frameCount)
    }

    let mono = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
    defer { mono.deallocate() }

    if bufferCount == 1 {
        // 可能是单声道，也可能是交错多声道
        let buf = abl[0]
        let channelsInBuffer = max(1, Int(buf.mNumberChannels))
        if let raw = buf.mData {
            let ptr = raw.bindMemory(to: Float.self, capacity: frameCount * channelsInBuffer)
            if channelsInBuffer == 1 {
                for i in 0..<frameCount { mono[i] = ptr[i] }
            } else {
                // 交错：mono = mean(channel_i)
                let inv = 1.0 / Float(channelsInBuffer)
                for i in 0..<frameCount {
                    var sum: Float = 0
                    let base = i * channelsInBuffer
                    for c in 0..<channelsInBuffer { sum += ptr[base + c] }
                    mono[i] = sum * inv
                }
            }
        } else {
            return
        }
    } else {
        // 非交错：每个 buffer 一个声道，逐帧求平均
        let inv = 1.0 / Float(bufferCount)
        // 第一遍：复制第一个声道
        if let raw0 = abl[0].mData {
            let p0 = raw0.bindMemory(to: Float.self, capacity: frameCount)
            for i in 0..<frameCount { mono[i] = p0[i] * inv }
        } else {
            return
        }
        // 后续声道：累加
        for ch in 1..<bufferCount {
            guard let raw = abl[ch].mData else { continue }
            let p = raw.bindMemory(to: Float.self, capacity: frameCount)
            for i in 0..<frameCount { mono[i] += p[i] * inv }
        }
    }

    // 3) 重采样到 16kHz（线性插值；够 VAD/YAMNet 用了）
    let srcSr = me.sourceSampleRate
    let dstSr: Double = 16000
    if abs(srcSr - dstSr) < 0.5 {
        // 不用重采样
        me.deliverResampled(mono, frameCount: frameCount)
        return
    }

    let ratio = dstSr / srcSr
    // 输出帧数（保守估算）
    let outCountEst = Int(Double(frameCount) * ratio) + 2
    if me.resampleScratch.count < outCountEst {
        me.resampleScratch = [Float](repeating: 0, count: outCountEst * 2)
    }
    let out = UnsafeMutablePointer<Float>.allocate(capacity: outCountEst)
    defer { out.deallocate() }

    // 跨帧连续性：lastSourceTail 是上一批最后一个 mono 样本
    var outIdx = 0
    var srcPosF: Double = 0  // 在 mono[] 中的浮点位置
    let step: Double = srcSr / dstSr  // 每个输出样本前进多少源样本

    // 第一次的特殊处理：如果有上次的 tail，用它做边界
    if me.hasLastTail {
        // 从 lastSourceTail → mono[0] 这一段先采样
        // 用 fractional position 在 [-1, 0] 范围之外的索引（即上次最后一个样本）的方式处理：
        // 即 srcPosF 起始为 -1 + step 直到 < 0，从虚拟数组 [lastSourceTail, mono...]
        srcPosF = -1.0
        while srcPosF < 0 {
            let i0 = Int(floor(srcPosF))
            let i1 = i0 + 1
            let t = Float(srcPosF - Double(i0))
            let v0: Float = (i0 == -1) ? me.lastSourceTail : (i0 >= 0 && i0 < frameCount ? mono[i0] : 0)
            let v1: Float = (i1 == -1) ? me.lastSourceTail : (i1 >= 0 && i1 < frameCount ? mono[i1] : 0)
            out[outIdx] = v0 + (v1 - v0) * t
            outIdx += 1
            srcPosF += step
        }
    }

    // 正常段
    while srcPosF < Double(frameCount - 1) && outIdx < outCountEst {
        let i0 = Int(srcPosF)
        let i1 = i0 + 1
        let t = Float(srcPosF - Double(i0))
        let v0 = mono[i0]
        let v1 = mono[i1]
        out[outIdx] = v0 + (v1 - v0) * t
        outIdx += 1
        srcPosF += step
    }

    // 记录尾巴，留给下次衔接
    me.lastSourceTail = mono[frameCount - 1]
    me.hasLastTail = true

    me.deliverResampled(out, frameCount: outIdx)
}
