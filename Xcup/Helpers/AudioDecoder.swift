//
//  AudioDecoder.swift
//  Xcup
//
//  Created by tingfu on 2025/4/20.
//


//  对应 Android Java: AudioDecoder.java
//

import Foundation
import AVFoundation

/// 音频解码器：从视频中解码音频 PCM，并写入 CircularBuffer
class AudioDecoder {

    private let asset: AVAsset
    private let pcmBuffer: PcmCircularBuffer
    private let videoPositionProvider: () -> Int // 视频播放位置获取器（单位：ms）

    private var isDecoding = false
    private var decodingThread: Thread?
    private var onCompleteListener: (() -> Void)?
    private var seekToPositionMs: Int? = nil
    private var lastSeekRealTime: TimeInterval = 0
    
    // *** 新增：seek后宽限期相关常量和变量 ***
    private let SEEK_GRACE_PERIOD: Int64 = 2000 // seek后的宽限期2秒
    private let MAX_ADVANCE_NORMAL: Int64 = 3000 // 正常情况下提前3秒
    private let MAX_ADVANCE_AFTER_SEEK: Int64 = 3000 // seek后允许提前3秒
    private var lastSeekTimeInDecoder: TimeInterval = 0 // 记录解码器中的seek时间（毫秒）

    init(asset: AVAsset, buffer: PcmCircularBuffer, positionProvider: @escaping () -> Int) {
        self.asset = asset
        self.pcmBuffer = buffer
        self.videoPositionProvider = positionProvider
    }

    /// 设置音频分析完成后的回调
    func setOnCompleteListener(_ listener: @escaping () -> Void) {
        self.onCompleteListener = listener
    }

    /// 外部请求 seek 到某个时间点（单位：ms）
    func seekTo(_ ms: Int) {
        let now = Date().timeIntervalSince1970 * 1000
        if now - lastSeekRealTime < 1000 {
            print("⚠️ seekTo 频率过快，跳过")
            return
        }
        lastSeekRealTime = now
        
        // *** 新增：记录seek时间，供解码线程使用 ***
        lastSeekTimeInDecoder = now
        
        print("🔄 AudioDecoder.seekTo(", ms, ")")
        stop()
        self.seekToPositionMs = max(ms, 0) // 直接seek到当前位置，让限速机制自然控制播放量
        startDecoding()
    }

    /// 开始解码任务
    func startDecoding() {
        isDecoding = true
        decodingThread = Thread {
            self.decodeLoop()
        }
        decodingThread?.start()
    }

    /// 停止解码任务
    func stop() {
        print("🛑 AudioDecoder: 请求停止解码线程")
        isDecoding = false
    }

    /// 主解码逻辑
    private func decodeLoop() {
        let readerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: false,   // 改为false
            AVLinearPCMBitDepthKey: 16,     // 改为16位
        ]

        guard let track = asset.tracks(withMediaType: .audio).first else {
            print("❌ 未找到音频轨道")
            return
        }

        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput

        do {
            reader = try AVAssetReader(asset: asset)
            output = AVAssetReaderTrackOutput(track: track, outputSettings: readerSettings)
            reader.add(output)

            if let seekMs = seekToPositionMs {
                let time = CMTimeMake(value: Int64(seekMs), timescale: 1000)
                reader.timeRange = CMTimeRangeMake(start: time, duration: asset.duration)
                print("🔄 解码器 Seek 到: \(seekMs)ms")
            }

            reader.startReading()
        } catch {
            print("❌ 创建 AVAssetReader 失败: \(error)")
            return
        }


        
        // 🔴 关键修复1：正确获取音频采样率
        let assetTrack = track as AVAssetTrack
        var sampleRate = 48000  // 默认值
            
        // 从音频格式描述中获取采样率
        if let formatDescriptions = assetTrack.formatDescriptions as? [CMFormatDescription],
            let formatDescription = formatDescriptions.first {
            if let streamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) {
                sampleRate = Int(streamBasicDescription.pointee.mSampleRate)
                print("🎵 音频采样率: \(sampleRate) Hz")
            }
        }
        
        
        
        let windowSize = sampleRate * 2
        let targetSampleRate = 16000  // 目标采样率
        let targetWindowSize = targetSampleRate * 2  // 16kHz的2秒 = 32000样本
        var buffer: [Float] = []
        var segmentStartMs: Int64 = -1  // 🔴 [FIX] 新增：记录段首时间戳
        var lastPtsMs: Int64 = -1

        while isDecoding, reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                print("❌ 无法获取下一个样本缓冲区")
                break
            }
            
            // 🔴 修改：正确获取音频数据
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                print("❌ 无法获取数据缓冲区")
                continue
            }

            let pts = Int64(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds * 1000)
            
            // 🔴 新增：检查PTS是否倒退
            if lastPtsMs >= 0 && pts < lastPtsMs {
                print("⚠️ 解码输出帧 pts 倒退，当前: \(pts)ms, 上一帧: \(lastPtsMs)ms，跳过此帧")
                    
                // 防止死循环
                if pts == 0 && pts < lastPtsMs {
                    print("🛑 视频播放结束")
                    break
                }
                continue
            }
            lastPtsMs = pts
            
            
            let playbackMs = videoPositionProvider()
            
            // *** 修改：改进的限速逻辑 ***
            // 计算当前时间（毫秒）
            let currentTimeMs = Int64(Date().timeIntervalSince1970 * 1000)
                        
            // *** 新增：计算自上次seek以来的时间 ***
            let timeSinceSeek = currentTimeMs - Int64(lastSeekTimeInDecoder)
                        
            // *** 新增：根据是否刚seek过来决定允许的最大提前量 ***
            let maxAdvance: Int64
            if timeSinceSeek < SEEK_GRACE_PERIOD && lastSeekTimeInDecoder > 0 {
                maxAdvance = MAX_ADVANCE_AFTER_SEEK // seek后2秒内允许提前6秒
                //print(String(format: "🚀 Seek宽限期内，允许提前%d秒 (已过%dms)",maxAdvance/1000, timeSinceSeek))
            } else {
                maxAdvance = MAX_ADVANCE_NORMAL // 正常情况提前3秒
            }
            
            let delta = pts - Int64(playbackMs)
            
            // *** 修改：使用动态的maxAdvance ***
            //print(String(format: "🔎 写入 PCM：pts=%d, 当前播放=%d, 提前 %.2f 秒, 限制=%.1f秒",pts, playbackMs, Double(delta) / 1000.0, Double(maxAdvance) / 1000.0))
            
            var d = delta
            while d > maxAdvance {                   // ⏸ 等待播放追上
                Thread.sleep(forTimeInterval: 0.05)
                d = pts - Int64(videoPositionProvider())
            }
            // 接下来正常把 sampleBuffer 写入 buffer

            
            // 🔴 关键修改：正确的数据转换
            let length = CMBlockBufferGetDataLength(blockBuffer)
            var data = Data(count: length)
            let result = data.withUnsafeMutableBytes { ptr in
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: ptr.baseAddress!)
            }
                    
            if result != kCMBlockBufferNoErr {
                print("❌ 复制音频数据失败")
                continue
            }
                    
            // 🔴 新的转换方法：Int16 -> Float
            let samples = data.withUnsafeBytes { bytes in
                let int16Pointer = bytes.bindMemory(to: Int16.self)
                return int16Pointer.map { Float($0) / 32768.0 }
            }
            
            // 🔴 [FIX] 记录段首时间戳（在buffer为空时记录，即窗口的第一帧）
            if buffer.isEmpty {
                segmentStartMs = pts
                //print("📌 [FIX] 记录窗口起始时间戳: \(segmentStartMs)ms")
            }
                    
            buffer.append(contentsOf: samples)
                    
            // 添加调试日志
            //print("📊 读取音频数据: \(samples.count) 样本, buffer总计: \(buffer.count)")

            if buffer.count >= windowSize {
                let segment = Array(buffer.prefix(windowSize))

                // 🔴 [FIX] 使用记录的段首时间戳，而不是计算得到的
                let segmentStartPts = segmentStartMs
                //print("📤 [FIX] 使用窗口起始时间戳: \(segmentStartPts)ms")
                
                // 重采样处理
                if sampleRate != targetSampleRate {
                    let resampledSegment = resample(
                        input: segment,
                        fromSampleRate: sampleRate,
                        toSampleRate: targetSampleRate,
                        targetSize: targetWindowSize
                    )
                    pcmBuffer.write(resampledSegment,
                                        startTimestampMs: segmentStartPts,
                                        sampleRate: targetSampleRate)
                    //print("📤 重采样后写入: \(targetWindowSize)样本 @ 16kHz")
                } else {
                    pcmBuffer.write(segment,
                                        startTimestampMs: segmentStartPts,
                                        sampleRate: sampleRate)
                    //print("📤 直接写入: \(segment.count)样本 @ \(sampleRate)Hz")
                }
                buffer.removeFirst(windowSize)
                segmentStartMs = -1  // 🔴 [FIX] 重置，准备下一个窗口
            }
        }

        print("✅ 解码结束，调用 onCompleteListener")
        onCompleteListener?()
    }
}

// 🔴 新增：重采样函数
private func resample(input: [Float], fromSampleRate: Int, toSampleRate: Int, targetSize: Int) -> [Float] {
    var output = [Float](repeating: 0.0, count: targetSize)
    
    // 创建时间轴
    let originalTime = (0..<input.count).map { Float($0) / Float(fromSampleRate) }
    let targetTime = (0..<targetSize).map { Float($0) / Float(toSampleRate) }
    
    // 线性插值
    var j = 0
    for i in 0..<targetSize {
        while j < input.count - 1 && originalTime[j + 1] < targetTime[i] {
            j += 1
        }
        
        if j < input.count - 1 {
            let t1 = originalTime[j]
            let t2 = originalTime[j + 1]
            let v1 = input[j]
            let v2 = input[j + 1]
            let ratio = (targetTime[i] - t1) / (t2 - t1)
            output[i] = v1 + ratio * (v2 - v1)
        } else {
            output[i] = input[j]
        }
    }
    
    return output
}
