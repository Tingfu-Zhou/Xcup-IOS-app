//
//  BroadcastSampleHandler.swift
//  XcupBroadcast  ← 仅属于 Broadcast Upload Extension target
//
//  自包含版本：所有写端代码（AudioRingWriter、VideoFrameWriter、常量）直接内嵌，
//  不依赖任何外部共享文件，彻底避免跨 target 编译问题。
//

import ReplayKit
import AVFoundation
import AudioToolbox
import UIKit
import Foundation
import Darwin

// MARK: - 常量（与主 App 端 BroadcastBridge.swift 保持一致）

private let kAppGroupID    = "group.com.aibei.Xcup"
private let kAudioFile     = "xcup_audio_ring.bin"
private let kVideoFile     = "xcup_video_frame.jpg"
private let kVideoTsFile   = "xcup_video_ts.bin"
private let kNotifyAudio    = "com.aibei.xcup.audio"           as CFString
private let kNotifyVideo    = "com.aibei.xcup.video"           as CFString
private let kNotifyStop     = "com.aibei.xcup.stop"            as CFString
private let kNotifyStart    = "com.aibei.xcup.broadcastStart"  as CFString
private let kNotifyAudioRaw = "com.aibei.xcup.audioRaw"        as CFString   // 诊断：audioApp 原始到达

// 诊断 key（写入 App Groups UserDefaults，绕过 <private> 日志限制）
private let kDiagAudioFmt   = "xcup_diag_audio_fmt"    // 扩展收到的音频格式
private let kDiagAudioConv  = "xcup_diag_audio_conv"   // 转换结果
private let kDiagAudioRaw   = "xcup_diag_audio_raw"    // 是否收到 .audioApp

// MARK: - 环形缓冲布局

private enum Ring {
    static let sampleRate  = 16000
    static let capacity    = sampleRate * 20          // 20 秒
    static let headerBytes = 16
    static let dataBytes   = capacity * MemoryLayout<Float>.size
    static let fileBytes   = headerBytes + dataBytes  // ≈ 1.22 MB
}

// MARK: - 音频写端

private final class AudioWriter {
    private var fd: Int32 = -1
    private var base: UnsafeMutableRawPointer?
    private var cursor: Int = 0
    private var seq: UInt32 = 0

    init?() {
        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: kAppGroupID)?
            .appendingPathComponent(kAudioFile) else {
            print("[XcupBroadcast] ⚠️ AudioWriter: App Groups 容器路径获取失败")
            return nil
        }

        // 用 O_CREAT|O_RDWR 直接创建或打开，避免在扩展进程内存中分配 1.22MB Data 对象
        fd = open(url.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR | S_IRGRP | S_IWGRP)
        guard fd >= 0 else {
            print("[XcupBroadcast] ⚠️ AudioWriter: open 失败 errno=\(errno)")
            return nil
        }

        // ftruncate 将文件扩展到所需大小（不占用扩展进程的大块内存）
        guard ftruncate(fd, off_t(Ring.fileBytes)) == 0 else {
            print("[XcupBroadcast] ⚠️ AudioWriter: ftruncate 失败 errno=\(errno)")
            close(fd); fd = -1; return nil
        }

        base = mmap(nil, Ring.fileBytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        if base == MAP_FAILED {
            print("[XcupBroadcast] ⚠️ AudioWriter: mmap 失败 errno=\(errno)")
            base = nil; close(fd); fd = -1; return nil
        }

        store(UInt32(0), at: 0); store(UInt32(0), at: 4)
        store(UInt32(Ring.sampleRate), at: 8); store(UInt32(0), at: 12)
        print("[XcupBroadcast] ✅ AudioWriter: 初始化成功，文件=\(url.lastPathComponent)")
    }

    deinit {
        if let b = base { munmap(b, Ring.fileBytes) }
        if fd >= 0 { close(fd) }
    }

    func write(_ samples: [Float]) {
        guard let b = base, !samples.isEmpty else { return }
        let data = b.advanced(by: Ring.headerBytes).assumingMemoryBound(to: Float.self)
        let cap = Ring.capacity
        for s in samples { data[cursor % cap] = s; cursor += 1 }
        seq &+= 1
        store(UInt32(cursor % cap), at: 0)
        store(seq, at: 4)
        notify(kNotifyAudio)
    }

    private func store(_ v: UInt32, at offset: Int) {
        base!.storeBytes(of: v, toByteOffset: offset, as: UInt32.self)
    }
}

// MARK: - 视频写端

private final class VideoWriter {
    private let jpegURL: URL?
    private let tsURL:   URL?

    init() {
        let base = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: kAppGroupID)
        jpegURL = base?.appendingPathComponent(kVideoFile)
        tsURL   = base?.appendingPathComponent(kVideoTsFile)
    }

    func write(jpeg: Data, timestampMs: Int64) {
        guard let ju = jpegURL, let tu = tsURL else { return }
        try? jpeg.write(to: ju, options: .atomic)
        var ts = timestampMs
        try? Data(bytes: &ts, count: 8).write(to: tu, options: .atomic)
        notify(kNotifyVideo)
    }
}

// MARK: - Darwin 通知工具

private func notify(_ name: CFString) {
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFNotificationName(name), nil, nil, true)
}

// MARK: - BroadcastSampleHandler

// MARK: - 共享诊断工具（绕过 <private> 日志限制）

private func writeDiag(_ value: String, forKey key: String) {
    UserDefaults(suiteName: kAppGroupID)?.set(value, forKey: key)
}

// MARK: - BroadcastSampleHandler

class BroadcastSampleHandler: RPBroadcastSampleHandler {

    private var audioWriter: AudioWriter?
    private let videoWriter = VideoWriter()

    // 不再使用 AVAudioConverter，改为离线模式相同的手动提取 + 重采样
    private var lastVideoTime: TimeInterval = 0
    private let VIDEO_INTERVAL: TimeInterval = 0.2
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // 诊断：记录首条音频样本（.audioApp 或 .audioMic），只发一次通知
    private var audioRawDiagSent = false
    // 优先使用麦克风：若 .audioMic 已到达，忽略 .audioApp（避免双路叠加）
    private var hasMicAudio = false

    // MARK: - 广播生命周期

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        audioWriter = AudioWriter()
        audioRawDiagSent = false
        hasMicAudio = false
        if audioWriter == nil {
            print("[XcupBroadcast] ⚠️ AudioWriter 初始化失败，请检查 App Groups 配置")
        }
        notify(kNotifyStart)
        print("[XcupBroadcast] 广播已启动，AudioWriter=\(audioWriter != nil ? "OK" : "nil")")
    }

    override func broadcastFinished() {
        notify(kNotifyStop)
        print("[XcupBroadcast] 广播已结束")
    }

    override func broadcastPaused()  { print("[XcupBroadcast] 广播暂停") }
    override func broadcastResumed() { print("[XcupBroadcast] 广播恢复") }

    // MARK: - 采样缓冲处理

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with type: RPSampleBufferType) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        switch type {
        case .audioMic:
            // 麦克风音频（优先：适用于动作/语音识别场景，与 Android AudioRecord 等价）
            hasMicAudio = true
            if !audioRawDiagSent {
                audioRawDiagSent = true
                writeDiag("YES(mic)", forKey: kDiagAudioRaw)
                notify(kNotifyAudioRaw)
            }
            processAudio(sampleBuffer)
        case .audioApp:
            // App 音频（仅在没有麦克风数据时使用，避免两路叠加）
            if !hasMicAudio {
                if !audioRawDiagSent {
                    audioRawDiagSent = true
                    writeDiag("YES(app)", forKey: kDiagAudioRaw)
                    notify(kNotifyAudioRaw)
                }
                processAudio(sampleBuffer)
            }
        case .video:
            processVideo(sampleBuffer)
        default:
            break
        }
    }

    // MARK: - 音频处理（离线模式相同思路：直接提取 PCM → 混声 → 手动重采样到 16 kHz）
    //
    // 不使用 AVAudioConverter（黑盒，多个失败点）。
    // 改为：ABL 取原始字节 → 手动 stereo→mono → 线性插值重采样，与 AudioDecoder.swift 逻辑一致。

    private func processAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc) else {
            writeDiag("E1:fmtDesc_nil", forKey: kDiagAudioConv); return
        }
        let asbd      = asbdPtr.pointee
        let srcRate   = Int(asbd.mSampleRate)
        let srcCh     = Int(asbd.mChannelsPerFrame)
        let numFrames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard srcRate > 0, srcCh > 0, numFrames > 0 else {
            writeDiag("E2:rate=\(srcRate) ch=\(srcCh) frames=\(numFrames)", forKey: kDiagAudioConv); return
        }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonI  = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        writeDiag("\(srcRate)Hz \(srcCh)ch float=\(isFloat) nonI=\(isNonI)", forKey: kDiagAudioFmt)

        // ── 1. 两步法获取 ABL：先查询所需大小，再分配并填充（避免 kCMSampleBufferError_ArrayTooSmall）──
        var ablSizeNeeded = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &ablSizeNeeded,
            bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: nil)
        guard ablSizeNeeded > 0 else {
            writeDiag("E3a:ablSize=0", forKey: kDiagAudioConv); return
        }

        let rawAbl = UnsafeMutableRawPointer.allocate(byteCount: ablSizeNeeded, alignment: 16)
        defer { rawAbl.deallocate() }
        let ablListPtr = rawAbl.assumingMemoryBound(to: AudioBufferList.self)
        var blockBuf: CMBlockBuffer?
        let ablStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil,
            bufferListOut: ablListPtr, bufferListSize: ablSizeNeeded,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: &blockBuf)
        guard ablStatus == noErr else {
            writeDiag("E3:abl=\(ablStatus)", forKey: kDiagAudioConv); return
        }

        let ablWrapper = UnsafeMutableAudioBufferListPointer(ablListPtr)

        // ── 2. 直接从 ABL 取原始 PCM，混声为 mono Float32（类比 AudioDecoder 的 Int16→Float 转换）──
        var monoSamples = [Float](repeating: 0, count: numFrames)

        if isFloat && isNonI {
            // 非交错 Float32（每个 AudioBuffer 对应一路声道）
            var validCh = 0
            for ab in ablWrapper {
                guard let data = ab.mData else { continue }
                let floats = data.assumingMemoryBound(to: Float.self)
                for i in 0..<numFrames { monoSamples[i] += floats[i] }
                validCh += 1
            }
            if validCh > 1 {
                let inv = 1.0 / Float(validCh)
                for i in 0..<numFrames { monoSamples[i] *= inv }
            }
        } else if isFloat && !isNonI {
            // 交错 Float32：[L R L R ...]
            guard let data = ablWrapper[0].mData else {
                writeDiag("E4:mData_nil float_interleaved", forKey: kDiagAudioConv); return
            }
            let floats = data.assumingMemoryBound(to: Float.self)
            let inv = srcCh > 1 ? 1.0 / Float(srcCh) : 1.0
            for i in 0..<numFrames {
                var sum: Float = 0
                for ch in 0..<srcCh { sum += floats[i * srcCh + ch] }
                monoSamples[i] = sum * inv
            }
        } else {
            // Int16 交错（同 AudioDecoder：Float($0) / 32768.0），44100Hz 2ch 即此路径
            guard let data = ablWrapper[0].mData else {
                writeDiag("E5:mData_nil int16", forKey: kDiagAudioConv); return
            }
            let bitsPerCh = Int(asbd.mBitsPerChannel)
            if bitsPerCh == 16 || bitsPerCh == 0 {
                let int16s = data.assumingMemoryBound(to: Int16.self)
                let inv = srcCh > 1 ? 1.0 / Float(srcCh) : 1.0
                for i in 0..<numFrames {
                    var sum: Float = 0
                    for ch in 0..<srcCh { sum += Float(int16s[i * srcCh + ch]) / 32768.0 }
                    monoSamples[i] = sum * inv
                }
            } else {
                // Int32 交错
                let int32s = data.assumingMemoryBound(to: Int32.self)
                let inv = srcCh > 1 ? 1.0 / Float(srcCh) : 1.0
                for i in 0..<numFrames {
                    var sum: Float = 0
                    for ch in 0..<srcCh { sum += Float(int32s[i * srcCh + ch]) / 2147483648.0 }
                    monoSamples[i] = sum * inv
                }
            }
        }

        // ── 3. 线性插值重采样到 16 kHz（同 AudioDecoder 的 resample() 函数）──
        let output: [Float]
        if srcRate != 16000 {
            output = resampleLinear(monoSamples, fromRate: srcRate, toRate: 16000)
        } else {
            output = monoSamples
        }

        guard !output.isEmpty else {
            writeDiag("E6:output_empty", forKey: kDiagAudioConv); return
        }
        writeDiag("OK \(srcRate)→16k len=\(output.count)", forKey: kDiagAudioConv)
        audioWriter?.write(output)
    }

    /// 线性插值重采样（与 AudioDecoder.swift 的 resample() 函数逻辑一致）
    private func resampleLinear(_ input: [Float], fromRate: Int, toRate: Int) -> [Float] {
        guard !input.isEmpty, fromRate > 0, toRate > 0 else { return [] }
        let ratio       = Double(fromRate) / Double(toRate)
        let outputCount = max(1, Int(Double(input.count) / ratio))
        var output      = [Float](repeating: 0, count: outputCount)
        for i in 0..<outputCount {
            let srcPos = Double(i) * ratio
            let idx    = Int(srcPos)
            let frac   = Float(srcPos - Double(idx))
            if idx + 1 < input.count {
                output[i] = input[idx] * (1 - frac) + input[idx + 1] * frac
            } else {
                output[i] = idx < input.count ? input[idx] : 0
            }
        }
        return output
    }

    // MARK: - 视频处理（降采样 → JPEG → 共享文件）

    private func processVideo(_ sampleBuffer: CMSampleBuffer) {
        let now = Date().timeIntervalSince1970
        guard now - lastVideoTime >= VIDEO_INTERVAL else { return }
        lastVideoTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        let scale = 480.0 / ciImage.extent.width
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else { return }
        guard let jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.6) else { return }

        videoWriter.write(jpeg: jpeg, timestampMs: Int64(now * 1000))
    }
}
