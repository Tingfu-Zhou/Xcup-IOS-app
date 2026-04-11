//
//  BroadcastBridge.swift  ── 主 App 端（读端）
//  Xcup target 专用，只包含主 App 需要的读端代码
//
//  Extension 端的写端代码在 XcupBroadcast/BroadcastBridge.swift
//

import Foundation
import Darwin

// MARK: - 共享常量

let kBroadcastAppGroupID = "group.com.aibei.Xcup"
let kAudioRingFile       = "xcup_audio_ring.bin"
let kVideoFrameFile      = "xcup_video_frame.jpg"
let kVideoTsFile         = "xcup_video_ts.bin"

let kDarwinStart    = "com.aibei.xcup.broadcastStart" as CFString
let kDarwinAudio    = "com.aibei.xcup.audio"          as CFString
let kDarwinVideo    = "com.aibei.xcup.video"          as CFString
let kDarwinStop     = "com.aibei.xcup.stop"           as CFString
let kDarwinAudioRaw = "com.aibei.xcup.audioRaw"       as CFString   // 诊断：.audioApp 原始到达

// 诊断 UserDefaults key（与扩展侧保持一致）
let kDiagAudioFmt  = "xcup_diag_audio_fmt"
let kDiagAudioConv = "xcup_diag_audio_conv"
let kDiagAudioRaw  = "xcup_diag_audio_raw"

// MARK: - 环形缓冲布局

enum AudioRing {
    static let sampleRate  = 16000
    static let capSec      = 20
    static let capacity    = sampleRate * capSec
    static let headerBytes = 16
    static let dataBytes   = capacity * MemoryLayout<Float>.size
    static let fileBytes   = headerBytes + dataBytes
}

// MARK: - 音频读端

final class AudioRingReader {
    private var fd: Int32 = -1
    private var base: UnsafeRawPointer?

    init?(groupID: String = kBroadcastAppGroupID) {
        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent(kAudioRingFile),
              FileManager.default.fileExists(atPath: url.path) else { return nil }

        fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }

        let raw = mmap(nil, AudioRing.fileBytes, PROT_READ, MAP_SHARED, fd, 0)
        if raw == MAP_FAILED { close(fd); fd = -1; return nil }
        base = UnsafeRawPointer(raw)
    }

    deinit {
        if let b = base { munmap(UnsafeMutableRawPointer(mutating: b), AudioRing.fileBytes) }
        if fd >= 0 { close(fd) }
    }

    func readLatest(count: Int) -> [Float]? {
        guard let b = base else { return nil }
        let writeCursor = Int(b.load(fromByteOffset: 0, as: UInt32.self))
        let data = b.advanced(by: AudioRing.headerBytes).assumingMemoryBound(to: Float.self)
        let cap  = AudioRing.capacity
        let n    = min(count, cap)
        var out  = [Float](repeating: 0, count: n)
        let start = ((writeCursor - n) % cap + cap) % cap
        for i in 0..<n { out[i] = data[(start + i) % cap] }
        return out
    }
}

// MARK: - 视频读端

final class VideoFrameReader {
    private let jpegURL: URL?

    init(groupID: String = kBroadcastAppGroupID) {
        jpegURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent(kVideoFrameFile)
    }

    func readLatestJpeg() -> Data? {
        guard let url = jpegURL else { return nil }
        return try? Data(contentsOf: url)
    }
}

// MARK: - Darwin 通知注册（主 App 用）

typealias DarwinCallback = () -> Void

func registerDarwinObserver(name: CFString, callback: @escaping DarwinCallback) -> AnyObject {
    let box = CallbackBox(callback)
    let ptr = Unmanaged.passRetained(box).toOpaque()
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        ptr,
        { _, observer, _, _, _ in
            guard let obs = observer else { return }
            Unmanaged<CallbackBox>.fromOpaque(obs).takeUnretainedValue().callback()
        },
        name, nil, .deliverImmediately)
    return box
}

func unregisterDarwinObserver(_ token: AnyObject) {
    let ptr = Unmanaged.passRetained(token as AnyObject).toOpaque()
    CFNotificationCenterRemoveObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), ptr, nil, nil)
    _ = Unmanaged<AnyObject>.fromOpaque(ptr).takeRetainedValue()
}

private final class CallbackBox {
    let callback: DarwinCallback
    init(_ cb: @escaping DarwinCallback) { callback = cb }
}
