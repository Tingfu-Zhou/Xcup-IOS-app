//
//  VideoMotionWaveEstimator.swift
//  Xcup
//
//  从 Android 端 VideoMotionWaveEstimator.java 移植。
//
//  管线:
//      关键点 → 仅 hip 路径 ROI → 64x64 灰度 → 8x8 块匹配（dx/dy）
//      → 跨帧 EMA 累积 2 阶矩 → 2x2 PCA 主方向 → median(投影) → 泄漏积分
//      → 自相关主频 + 5 因子置信度
//
//  说明:
//      - 输入关键点必须已归一化到 [0,1]，置信度保持原值
//      - frame == nil 或 keypoints == nil 都按场景切换语义处理
//      - 骨盆置信度门控失败直接发布 NaN，不做 bbox fallback
//
//  替换 VideoRhythmEstimator 的同名调用：
//      onPoseFrame(kps, ptsMs)            → pushFrame(timestampMs, frame, keypoints)
//      getLatestFreqHz/Conf/TsMs()        → getLatestResult().freqHz/confidence/timestampMs
//      reset()                            → reset()
//

import Foundation
import UIKit
import CoreGraphics

final class VideoMotionWaveEstimator {

    // MARK: - 默认参数（与 Android 端一致）
    struct Params {
        // ROI
        var roiAlpha: Float = 0.30
        var roiWidthFactor: Float = 1.6
        var roiHeightFactor: Float = 1.6
        var roiVerticalShift: Float = 0.20
        var roiAspectMin: Float = 0.50
        var roiAspectMax: Float = 2.40
        var roiMinFracW: Float = 0.10
        var roiMinFracH: Float = 0.12
        var roiMaxFracW: Float = 0.85
        var roiMaxFracH: Float = 0.85
        var kpConfTh: Float = 0.30
        var pelvisKpConfTh: Float = 0.30

        // Gray ROI
        var grayW: Int = 64
        var grayH: Int = 64

        // Block matching
        var gridX: Int = 8
        var gridY: Int = 8
        var searchRadius: Int = 4
        var texVarTh: Float = 25.0
        var outlierMadK: Float = 2.5

        // 主运动方向
        var enableMotionDirection: Bool = true
        var motionDirAlpha: Float = 0.10
        var motionDirMinEnergy: Float = 0.50

        // 泄漏积分 / 滑窗
        var leak: Float = 0.95
        var windowSize: Int = 60
        var minWarmSamples: Int = 30
        var estimateEveryNFrames: Int = 3

        // 频率搜索范围
        var minFreqHz: Float = 0.95
        var maxFreqHz: Float = 1.85

        // 置信度
        var minMotionEnergyZero: Float = 0.05
        var minMotionEnergyFull: Float = 0.50
        var minValidBlockRatio: Float = 0.30
        var maxFreqJumpHz: Float = 0.40

        // 位置归一化
        var posNormWindow: Int = 20
        var pos01SmoothAlpha: Float = 0.40

        // 生命周期
        var maxConsecutiveLostBeforeReset: Int = 4
    }

    // MARK: - COCO 关键点索引
    private static let LSHO = 5
    private static let RSHO = 6
    private static let LHIP = 11
    private static let RHIP = 12
    private static let LKNEE = 13
    private static let RKNEE = 14

    // MARK: - 状态
    private let P: Params

    // 串行化所有 public 方法
    private let lock = NSLock()

    // 最新结果（由 lock 保护）
    private var latest: VideoWaveResult = VideoWaveResult.empty()

    // ROI EMA（pixel）
    private var roiInitialized: Bool = false
    private var roiCx: Float = 0
    private var roiCy: Float = 0
    private var roiW: Float = 0
    private var roiH: Float = 0

    // 灰度 ROI
    private var prevGray: [UInt8]? = nil
    private var currGray: [UInt8]? = nil
    private var pixelBuf: [UInt32]? = nil   // ARGB 像素缓冲，按需扩容

    // position 滑窗（环形）
    private var posWindow: [Float]
    private var posTsWindow: [Int64]
    private var posCount: Int = 0
    private var posWriteIdx: Int = 0
    private var rawPosition: Float = 0

    // 估计调度
    private var framesSinceEst: Int = 0
    private var lastFreqHz: Float = .nan
    private var lastPos01: Float = 0.5
    private var roiLost: Bool = true
    private var consecutiveLost: Int = 0

    // 主方向：2 阶矩矩阵 EMA + 主特征向量
    private var dirMxx: Float = 0
    private var dirMxy: Float = 0
    private var dirMyy: Float = 0
    private var dirInitialized: Bool = false
    private var mainDirX: Float = 0
    private var mainDirY: Float = 1

    // 块匹配复用缓冲
    private var dxsBuf: [Int]
    private var dysBuf: [Int]
    private var validBuf: [Bool]
    private var projBuf: [Float]
    private var absDevBuf: [Float]

    // MARK: - 构造
    convenience init() {
        self.init(params: Params())
    }

    init(params: Params) {
        self.P = params
        self.posWindow = [Float](repeating: 0, count: params.windowSize)
        self.posTsWindow = [Int64](repeating: 0, count: params.windowSize)
        let total = params.gridX * params.gridY
        self.dxsBuf = [Int](repeating: 0, count: total)
        self.dysBuf = [Int](repeating: 0, count: total)
        self.validBuf = [Bool](repeating: false, count: total)
        self.projBuf = [Float](repeating: 0, count: total)
        self.absDevBuf = [Float](repeating: 0, count: total)
    }

    // MARK: - 公共接口

    func reset() {
        lock.lock(); defer { lock.unlock() }
        roiInitialized = false
        roiCx = 0; roiCy = 0; roiW = 0; roiH = 0
        prevGray = nil
        currGray = nil
        // pixelBuf 可保留以避免重复分配
        for i in 0..<posWindow.count { posWindow[i] = 0; posTsWindow[i] = 0 }
        posCount = 0
        posWriteIdx = 0
        rawPosition = 0
        framesSinceEst = 0
        lastFreqHz = .nan
        lastPos01 = 0.5
        roiLost = true
        consecutiveLost = 0
        dirMxx = 0; dirMxy = 0; dirMyy = 0
        dirInitialized = false
        mainDirX = 0
        mainDirY = 1
        latest = VideoWaveResult.empty()
    }

    /// 推一帧。
    /// - Parameters:
    ///   - timestampMs: 帧时间戳
    ///   - frame: 当前帧；nil 表示未拿到图像
    ///   - keypointsNorm: 17×3 数组，x/y∈[0,1]，conf 原值；nil 表示未检测到人
    func pushFrame(timestampMs: Int64, frame: UIImage?, keypointsNorm: [[Float]]?) {
        lock.lock(); defer { lock.unlock() }

        // (a) keypoints == nil → 场景切换语义
        guard let kps = keypointsNorm else {
            consecutiveLost += 1
            if consecutiveLost >= P.maxConsecutiveLostBeforeReset {
                resetUnsafe()
            } else {
                roiLost = true
                decayConfidence(timestampMs: timestampMs, reason: "no-keypoints")
            }
            return
        }

        // (a') frame == nil
        guard let frame = frame else {
            consecutiveLost += 1
            roiLost = true
            decayConfidence(timestampMs: timestampMs, reason: "no-frame")
            return
        }

        // (a.1) Pelvis 置信度门控
        if kps.count < 17 {
            consecutiveLost += 1
            roiLost = true
            if consecutiveLost >= P.maxConsecutiveLostBeforeReset {
                resetUnsafe()
            } else {
                publishNaN(timestampMs: timestampMs, reason: String(format: "kps too short n=%d", kps.count))
            }
            return
        }
        let lhipConf = kps[VideoMotionWaveEstimator.LHIP][2]
        let rhipConf = kps[VideoMotionWaveEstimator.RHIP][2]
        if lhipConf < P.pelvisKpConfTh || rhipConf < P.pelvisKpConfTh {
            consecutiveLost += 1
            roiLost = true
            if consecutiveLost >= P.maxConsecutiveLostBeforeReset {
                resetUnsafe()
            } else {
                let reason = String(format: "low-pelvis-conf Lhip=%.2f Rhip=%.2f th=%.2f",
                                    lhipConf, rhipConf, P.pelvisKpConfTh)
                publishNaN(timestampMs: timestampMs, reason: reason)
            }
            return
        }
        consecutiveLost = 0

        // 帧尺寸：与 InferenceHelper 中的归一化分母对齐（image.size，scale=1.0 时即像素维度）
        let frameW = Int(frame.size.width.rounded())
        let frameH = Int(frame.size.height.rounded())
        if frameW < 16 || frameH < 16 {
            roiLost = true
            decayConfidence(timestampMs: timestampMs, reason: "frame-too-small")
            return
        }

        // (b) 计算目标 ROI
        guard let newRoi = computeRoi(kp: kps, frameW: frameW, frameH: frameH) else {
            roiLost = true
            decayConfidence(timestampMs: timestampMs, reason: "no-roi")
            return
        }

        // (c) ROI EMA
        if !roiInitialized {
            roiCx = newRoi.cx; roiCy = newRoi.cy; roiW = newRoi.w; roiH = newRoi.h
            roiInitialized = true
            roiLost = true
        } else {
            let a = P.roiAlpha
            roiCx = a * newRoi.cx + (1 - a) * roiCx
            roiCy = a * newRoi.cy + (1 - a) * roiCy
            roiW  = a * newRoi.w  + (1 - a) * roiW
            roiH  = a * newRoi.h  + (1 - a) * roiH
        }

        // (d) Crop ROI → 灰度 64x64
        let rx = max(0, Int((roiCx - roiW / 2).rounded()))
        let ry = max(0, Int((roiCy - roiH / 2).rounded()))
        let rwTarget = Int(roiW.rounded())
        let rhTarget = Int(roiH.rounded())
        let rw = min(frameW - rx, rwTarget)
        let rh = min(frameH - ry, rhTarget)
        if rw < 16 || rh < 16 {
            roiLost = true
            decayConfidence(timestampMs: timestampMs, reason: "roi-too-small")
            return
        }

        // 确保灰度缓冲存在
        let grayCount = P.grayW * P.grayH
        if currGray == nil || currGray!.count != grayCount {
            currGray = [UInt8](repeating: 0, count: grayCount)
        }
        let cropOK = cropToGrayBuffer(image: frame, rx: rx, ry: ry, rw: rw, rh: rh)
        if !cropOK {
            roiLost = true
            decayConfidence(timestampMs: timestampMs, reason: "crop-failed")
            return
        }

        // (e) Block matching
        let haveMatch = (prevGray != nil) && !roiLost
        var signedMotion: Float = 0
        var motionEnergy: Float = 0
        var validBlocks: Int = 0
        let totalBlocks = P.gridX * P.gridY
        if haveMatch {
            let res = blockMatch()
            signedMotion = res.signedMotion
            motionEnergy = res.energy
            validBlocks = res.validBlocks
        }
        roiLost = false
        // swap prevGray <-> currGray
        let tmp = prevGray
        prevGray = currGray
        currGray = tmp
        if currGray == nil {
            currGray = [UInt8](repeating: 0, count: grayCount)
        }

        // (f) 泄漏积分
        let minBlocks = max(4, Int((Float(totalBlocks) * P.minValidBlockRatio).rounded()))
        if haveMatch && validBlocks >= minBlocks {
            rawPosition = P.leak * rawPosition + signedMotion
        } else {
            rawPosition = P.leak * rawPosition
        }

        // (g) 推入 position 滑窗
        posWindow[posWriteIdx] = rawPosition
        posTsWindow[posWriteIdx] = timestampMs
        posWriteIdx = (posWriteIdx + 1) % P.windowSize
        if posCount < P.windowSize { posCount += 1 }
        framesSinceEst += 1

        // (h) 周期性触发主频估计
        if posCount >= P.minWarmSamples && framesSinceEst >= P.estimateEveryNFrames {
            framesSinceEst = 0
            let result = doEstimate(timestampMs: timestampMs,
                                    rx: rx, ry: ry, rw: rw, rh: rh,
                                    signedMotion: signedMotion,
                                    motionEnergy: motionEnergy,
                                    validBlocks: validBlocks,
                                    totalBlocks: totalBlocks)
            latest = result
        } else {
            // 预热期：复制上次结果，刷新部分字段
            let prev = latest
            let upd = prev.copy()
            upd.timestampMs = timestampMs
            upd.rawPosition = rawPosition
            upd.motionEnergy = motionEnergy
            upd.roiX = rx; upd.roiY = ry; upd.roiW = rw; upd.roiH = rh
            upd.mainDirX = mainDirX
            upd.mainDirY = mainDirY
            let dirAngleDeg = atan2(mainDirY, mainDirX) * 180.0 / Float.pi
            upd.debugInfo = String(format: "[warm] posCount=%d/%d roi=(%d,%d,%d,%d) sM=%.2f rawP=%.2f mE=%.3f dir=(%.2f,%.2f,%.0f°)",
                                   posCount, P.minWarmSamples, rx, ry, rw, rh,
                                   signedMotion, rawPosition, motionEnergy,
                                   mainDirX, mainDirY, dirAngleDeg)
            latest = upd
        }
    }

    func getLatestResult() -> VideoWaveResult {
        lock.lock(); defer { lock.unlock() }
        return latest.copy()
    }

    // MARK: - Reset 内部版本（已持锁）
    private func resetUnsafe() {
        roiInitialized = false
        roiCx = 0; roiCy = 0; roiW = 0; roiH = 0
        prevGray = nil
        currGray = nil
        for i in 0..<posWindow.count { posWindow[i] = 0; posTsWindow[i] = 0 }
        posCount = 0
        posWriteIdx = 0
        rawPosition = 0
        framesSinceEst = 0
        lastFreqHz = .nan
        lastPos01 = 0.5
        roiLost = true
        consecutiveLost = 0
        dirMxx = 0; dirMxy = 0; dirMyy = 0
        dirInitialized = false
        mainDirX = 0
        mainDirY = 1
        latest = VideoWaveResult.empty()
    }

    // MARK: - 计算 ROI (仅 hip 路径，无 bbox fallback)
    private struct RoiPx { let cx: Float; let cy: Float; let w: Float; let h: Float }

    private func computeRoi(kp: [[Float]], frameW: Int, frameH: Int) -> RoiPx? {
        if kp.count < 17 { return nil }
        let LHIP = VideoMotionWaveEstimator.LHIP
        let RHIP = VideoMotionWaveEstimator.RHIP
        let LSHO = VideoMotionWaveEstimator.LSHO
        let RSHO = VideoMotionWaveEstimator.RSHO
        let LKNEE = VideoMotionWaveEstimator.LKNEE
        let RKNEE = VideoMotionWaveEstimator.RKNEE

        if kp[LHIP][2] < P.pelvisKpConfTh || kp[RHIP][2] < P.pelvisKpConfTh {
            return nil
        }

        let lkneeOK = kp[LKNEE][2] >= P.kpConfTh
        let rkneeOK = kp[RKNEE][2] >= P.kpConfTh
        let lshoOK  = kp[LSHO][2]  >= P.kpConfTh
        let rshoOK  = kp[RSHO][2]  >= P.kpConfTh

        let hipCx = (kp[LHIP][0] + kp[RHIP][0]) * 0.5
        let hipCy = (kp[LHIP][1] + kp[RHIP][1]) * 0.5
        let hipDx = kp[RHIP][0] - kp[LHIP][0]
        let hipDy = kp[RHIP][1] - kp[LHIP][1]
        let hipDist = sqrt(hipDx * hipDx + hipDy * hipDy)

        var refSize = hipDist
        if refSize < 0.04 && lshoOK && rshoOK {
            let sdx = kp[RSHO][0] - kp[LSHO][0]
            let sdy = kp[RSHO][1] - kp[LSHO][1]
            refSize = sqrt(sdx * sdx + sdy * sdy)
        }
        if refSize < 0.03 { refSize = 0.03 }

        var vert = refSize * 1.6
        if lkneeOK || rkneeOK {
            var kneeY: Float = 0
            var n: Float = 0
            if lkneeOK { kneeY += kp[LKNEE][1]; n += 1 }
            if rkneeOK { kneeY += kp[RKNEE][1]; n += 1 }
            kneeY /= n
            let v = abs(kneeY - hipCy)
            if v > vert * 0.5 { vert = v * 1.4 }
        }

        var cx = hipCx
        var cy = hipCy + P.roiVerticalShift * vert
        var w  = refSize * P.roiWidthFactor
        var h  = vert    * P.roiHeightFactor

        let fW = Float(frameW)
        let fH = Float(frameH)
        cx *= fW; cy *= fH
        w  *= fW; h  *= fH

        // min/max 尺寸
        let wMin = P.roiMinFracW * fW
        let wMax = P.roiMaxFracW * fW
        let hMin = P.roiMinFracH * fH
        let hMax = P.roiMaxFracH * fH
        if w < wMin { w = wMin }
        if w > wMax { w = wMax }
        if h < hMin { h = hMin }
        if h > hMax { h = hMax }

        // aspect
        if w > 1 {
            if h / w < P.roiAspectMin { h = w * P.roiAspectMin }
            if h / w > P.roiAspectMax { h = w * P.roiAspectMax }
        }

        // 中心 clamp 到帧内
        if cx - w / 2 < 0 { cx = w / 2 }
        if cy - h / 2 < 0 { cy = h / 2 }
        if cx + w / 2 > fW { cx = fW - w / 2 }
        if cy + h / 2 > fH { cy = fH - h / 2 }

        if w < P.roiMinFracW * fW * 0.5 || h < P.roiMinFracH * fH * 0.5 {
            return nil
        }
        return RoiPx(cx: cx, cy: cy, w: w, h: h)
    }

    // MARK: - 抠图 + 灰度 (iOS 平台特定部分)
    /// 将 image 在 (rx, ry, rw, rh) 区域抠出并降采样为 grayW * grayH 灰度。
    /// 写入 self.currGray，返回是否成功。
    ///
    /// 实现说明:
    ///   先用 CGImage.cropping(to:) 在图像空间内（左上原点）切出 ROI 子图，
    ///   再 draw 到一个 rw*rh 的 BGRA 缓冲。CGContext 默认左下原点 → draw 出来
    ///   的 BGRA 缓冲在 Y 方向上下翻转，但 prev/curr 帧处理方式一致，块匹配的
    ///   运动向量在自身坐标系下仍然正确（PCA 主方向 + 符号稳定能自动适配）。
    private func cropToGrayBuffer(image: UIImage, rx: Int, ry: Int, rw: Int, rh: Int) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        // CGImage.cropping 使用图像空间坐标（左上原点），与 rx/ry 一致
        let cropRect = CGRect(x: rx, y: ry, width: rw, height: rh)
        guard let cropped = cgImage.cropping(to: cropRect) else { return false }

        let bytesPerPixel = 4
        let bytesPerRow = rw * bytesPerPixel
        let neededPx = rw * rh
        if pixelBuf == nil || pixelBuf!.count < neededPx {
            pixelBuf = [UInt32](repeating: 0, count: neededPx)
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        // byteOrder32Little + premultipliedFirst → 内存中字节顺序 B,G,R,A
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let success: Bool = pixelBuf!.withUnsafeMutableBufferPointer { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            guard let ctx = CGContext(data: base,
                                      width: rw,
                                      height: rh,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: cs,
                                      bitmapInfo: bitmapInfo) else { return false }
            ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: rw, height: rh))
            return true
        }
        if !success { return false }

        // 降采样为 grayW * grayH
        let gW = P.grayW
        let gH = P.grayH
        if currGray == nil || currGray!.count != gW * gH {
            currGray = [UInt8](repeating: 0, count: gW * gH)
        }
        currGray!.withUnsafeMutableBufferPointer { gOut in
            pixelBuf!.withUnsafeBufferPointer { pIn in
                guard let gp = gOut.baseAddress, let pp = pIn.baseAddress else { return }
                // pixelBuf 为 BGRA：内存中字节序 B@0, G@1, R@2, A@3
                let pBytes = UnsafeRawPointer(pp).assumingMemoryBound(to: UInt8.self)
                for gy in 0..<gH {
                    let srcY = (gy * rh) / gH
                    let rowOff = srcY * rw * 4
                    for gx in 0..<gW {
                        let srcX = (gx * rw) / gW
                        let off = rowOff + srcX * 4
                        let b = Int(pBytes[off + 0])
                        let g = Int(pBytes[off + 1])
                        let r = Int(pBytes[off + 2])
                        let y = (r * 30 + g * 59 + b * 11) / 100
                        gp[gy * gW + gx] = UInt8(truncatingIfNeeded: y)
                    }
                }
            }
        }
        return true
    }

    // MARK: - 块匹配
    private struct BlockMatchResult {
        let signedMotion: Float
        let energy: Float
        let validBlocks: Int
    }

    private func blockMatch() -> BlockMatchResult {
        guard let prev = prevGray, let curr = currGray else {
            return BlockMatchResult(signedMotion: 0, energy: 0, validBlocks: 0)
        }
        let W = P.grayW
        let H = P.grayH
        let gx = P.gridX
        let gy = P.gridY
        let bw = W / gx
        let bh = H / gy
        let R = P.searchRadius

        // 复用 buffer
        for i in 0..<dxsBuf.count { dxsBuf[i] = 0; dysBuf[i] = 0; validBuf[i] = false }
        var validCount = 0
        var Sxx: Float = 0, Sxy: Float = 0, Syy: Float = 0

        prev.withUnsafeBufferPointer { pPrev in
            curr.withUnsafeBufferPointer { pCurr in
                let prevPtr = pPrev.baseAddress!
                let currPtr = pCurr.baseAddress!
                for byi in 0..<gy {
                    let y0 = byi * bh
                    if y0 < R || y0 + bh + R > H { continue }
                    for bxi in 0..<gx {
                        let x0 = bxi * bw
                        if x0 < R || x0 + bw + R > W { continue }
                        let idx = byi * gx + bxi

                        // 1) 块方差
                        var sum: Int = 0
                        var sum2: Int = 0
                        for yy in 0..<bh {
                            let rowOff = (y0 + yy) * W + x0
                            for xx in 0..<bw {
                                let v = Int(prevPtr[rowOff + xx])
                                sum += v
                                sum2 += v * v
                            }
                        }
                        let npx = bw * bh
                        let mean = sum / npx
                        let varv = sum2 / npx - mean * mean
                        if Float(varv) < P.texVarTh { continue }

                        // 2) ±R 范围 SAD 搜索
                        var bestSAD = Int.max
                        var bestDx = 0
                        var bestDy = 0
                        for dy in -R...R {
                            for dx in -R...R {
                                var sad = 0
                                for yy in 0..<bh {
                                    let prevOff = (y0 + yy) * W + x0
                                    let currOff = (y0 + yy + dy) * W + x0 + dx
                                    for xx in 0..<bw {
                                        let diff = Int(prevPtr[prevOff + xx]) - Int(currPtr[currOff + xx])
                                        sad += diff < 0 ? -diff : diff
                                    }
                                    if sad >= bestSAD { break }
                                }
                                if sad < bestSAD {
                                    bestSAD = sad
                                    bestDx = dx
                                    bestDy = dy
                                }
                            }
                        }

                        dxsBuf[idx] = bestDx
                        dysBuf[idx] = bestDy
                        validBuf[idx] = true
                        validCount += 1
                        let fx = Float(bestDx)
                        let fy = Float(bestDy)
                        Sxx += fx * fx
                        Sxy += fx * fy
                        Syy += fy * fy
                    }
                }
            }
        }

        if validCount == 0 {
            return BlockMatchResult(signedMotion: 0, energy: 0, validBlocks: 0)
        }

        // 3) 更新主方向
        updateMainDirection(Sxx: Sxx, Sxy: Sxy, Syy: Syy, validBlocks: validCount)

        // 4) 投影到主方向
        var n = 0
        var energySum: Float = 0
        for i in 0..<dxsBuf.count where validBuf[i] {
            let proj = Float(dxsBuf[i]) * mainDirX + Float(dysBuf[i]) * mainDirY
            projBuf[n] = proj
            n += 1
            energySum += proj < 0 ? -proj : proj
        }

        // 5) 中位数
        let medSlice = Array(projBuf[0..<n]).sorted()
        let median = medSlice[n / 2]

        // 6) MAD 异常剔除后再算一次中位数
        for i in 0..<n {
            let d = medSlice[i] - median
            absDevBuf[i] = d < 0 ? -d : d
        }
        let madSorted = Array(absDevBuf[0..<n]).sorted()
        let mad = madSorted[n / 2]
        let thresh = max(Float(1.0), P.outlierMadK * mad)

        var filtered: [Float] = []
        filtered.reserveCapacity(n)
        for i in 0..<n {
            let d = medSlice[i] - median
            let a = d < 0 ? -d : d
            if a <= thresh { filtered.append(medSlice[i]) }
        }
        var signedMotion: Float
        if filtered.isEmpty {
            signedMotion = median
        } else {
            filtered.sort()
            signedMotion = filtered[filtered.count / 2]
        }

        let energy = energySum / Float(max(1, n))
        return BlockMatchResult(signedMotion: signedMotion, energy: energy, validBlocks: validCount)
    }

    // MARK: - 主方向估计
    private func updateMainDirection(Sxx: Float, Sxy: Float, Syy: Float, validBlocks: Int) {
        if !P.enableMotionDirection {
            mainDirX = 0
            mainDirY = 1
            return
        }
        let frameEnergy = sqrt(Sxx + Syy)
        let minBlocks = max(4, Int((Float(P.gridX * P.gridY) * P.minValidBlockRatio).rounded()))
        if validBlocks < minBlocks || frameEnergy < P.motionDirMinEnergy {
            return
        }
        if !dirInitialized {
            dirMxx = Sxx; dirMxy = Sxy; dirMyy = Syy
            dirInitialized = true
        } else {
            let a = P.motionDirAlpha
            dirMxx = (1 - a) * dirMxx + a * Sxx
            dirMxy = (1 - a) * dirMxy + a * Sxy
            dirMyy = (1 - a) * dirMyy + a * Syy
        }
        let (newUxRaw, newUyRaw) = principalEigenvector2x2(a: dirMxx, b: dirMxy, d: dirMyy)
        var newUx = newUxRaw
        var newUy = newUyRaw
        // 符号稳定
        if newUx * mainDirX + newUy * mainDirY < 0 {
            newUx = -newUx
            newUy = -newUy
        }
        mainDirX = newUx
        mainDirY = newUy
    }

    private func principalEigenvector2x2(a: Float, b: Float, d: Float) -> (Float, Float) {
        let half = (a - d) * 0.5
        let disc = sqrt(half * half + b * b)
        let lambda1 = (a + d) * 0.5 + disc
        var ex: Float
        var ey: Float
        if abs(b) < 1e-9 {
            if a >= d { ex = 1; ey = 0 }
            else      { ex = 0; ey = 1 }
        } else {
            ex = b
            ey = lambda1 - a
        }
        let norm = sqrt(ex * ex + ey * ey)
        if norm < 1e-9 { return (0, 1) }
        return (ex / norm, ey / norm)
    }

    // MARK: - 主频估计
    private struct AutocorrResult { let freqHz: Float; let periodicity: Float }

    private func estimateByAutocorr(seq: [Float], dt: Float) -> AutocorrResult {
        let n = seq.count
        if n < 16 || dt <= 0 { return AutocorrResult(freqHz: .nan, periodicity: 0) }

        // 1) 去趋势
        let x = detrend(seq)

        // 2) 总能量
        var r0: Float = 0
        for v in x { r0 += v * v }
        if r0 < 1e-9 { return AutocorrResult(freqHz: .nan, periodicity: 0) }

        // 3) 自相关搜索范围
        let kMin = max(1, Int(floor(1.0 / (P.maxFreqHz * dt))))
        let kMax = min(n - 2, Int(ceil(1.0 / (P.minFreqHz * dt))))
        if kMax <= kMin { return AutocorrResult(freqHz: .nan, periodicity: 0) }

        // 4) 计算 R[k]，k 范围扩到 ±1
        let lo = max(1, kMin - 1)
        let hi = min(n - 1, kMax + 1)
        var R = [Float](repeating: 0, count: hi + 2)
        for k in lo...hi {
            var s: Float = 0
            let upper = n - k
            for i in 0..<upper {
                s += x[i] * x[i + k]
            }
            R[k] = s
        }

        // 5) 在 [kMin, kMax] 内取最大
        var bestK = -1
        var bestVal: Float = -.greatestFiniteMagnitude
        for k in kMin...kMax {
            if R[k] > bestVal { bestVal = R[k]; bestK = k }
        }
        if bestK < 0 { return AutocorrResult(freqHz: .nan, periodicity: 0) }

        // 6) 抛物线插值
        var refK = Float(bestK)
        if bestK - 1 >= lo && bestK + 1 <= hi {
            let a = R[bestK - 1]
            let b = R[bestK]
            let c = R[bestK + 1]
            let denom = a - 2 * b + c
            if abs(denom) > 1e-9 {
                var delta = 0.5 * (a - c) / denom
                if delta < -0.5 { delta = -0.5 }
                if delta > 0.5  { delta =  0.5 }
                refK = Float(bestK) + delta
            }
        }
        let tau = refK * dt
        if tau < 1e-6 { return AutocorrResult(freqHz: .nan, periodicity: 0) }
        let freqHz = 1.0 / tau
        var periodicity = R[bestK] / r0
        if periodicity < 0 { periodicity = 0 }
        if periodicity > 1 { periodicity = 1 }

        // 7) 频带越界 → NaN
        if freqHz < P.minFreqHz * 0.9 || freqHz > P.maxFreqHz * 1.1 {
            return AutocorrResult(freqHz: .nan, periodicity: 0)
        }
        return AutocorrResult(freqHz: freqHz, periodicity: periodicity)
    }

    private func detrend(_ seq: [Float]) -> [Float] {
        let n = seq.count
        var sumX: Double = 0
        var sumY: Double = 0
        var sumXY: Double = 0
        var sumX2: Double = 0
        for i in 0..<n {
            let xi = Double(i)
            let yi = Double(seq[i])
            sumX  += xi
            sumY  += yi
            sumXY += xi * yi
            sumX2 += xi * xi
        }
        let nd = Double(n)
        let meanX = sumX / nd
        let meanY = sumY / nd
        let varX = sumX2 / nd - meanX * meanX
        let slope = varX > 1e-12 ? (sumXY / nd - meanX * meanY) / varX : 0
        let intercept = meanY - slope * meanX
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let pred = slope * Double(i) + intercept
            out[i] = Float(Double(seq[i]) - pred)
        }
        return out
    }

    // MARK: - doEstimate
    private func doEstimate(timestampMs: Int64,
                            rx: Int, ry: Int, rw: Int, rh: Int,
                            signedMotion: Float,
                            motionEnergy: Float,
                            validBlocks: Int,
                            totalBlocks: Int) -> VideoWaveResult {
        let seq = snapshotPosWindow()
        let dt = estimateAvgDt()
        let auto = estimateByAutocorr(seq: seq, dt: dt)
        let freqHz = auto.freqHz
        let periodicity = auto.periodicity

        // 5 个置信度因子
        var periodicityFactor = periodicity
        if periodicityFactor < 0 { periodicityFactor = 0 }
        if periodicityFactor > 1 { periodicityFactor = 1 }

        var meFactor: Float
        if motionEnergy <= P.minMotionEnergyZero {
            meFactor = 0
        } else if motionEnergy >= P.minMotionEnergyFull {
            meFactor = 1
        } else {
            meFactor = (motionEnergy - P.minMotionEnergyZero) /
                       (P.minMotionEnergyFull - P.minMotionEnergyZero)
        }

        let blockRatio = totalBlocks > 0 ? Float(validBlocks) / Float(totalBlocks) : 0
        var blockFactor: Float
        if blockRatio <= P.minValidBlockRatio {
            blockFactor = 0
        } else if blockRatio >= 0.7 {
            blockFactor = 1
        } else {
            blockFactor = (blockRatio - P.minValidBlockRatio) /
                          (0.7 - P.minValidBlockRatio)
        }

        var roiLockFactor: Float
        if consecutiveLost == 0 && posCount >= P.minWarmSamples {
            roiLockFactor = 1
        } else if posCount < P.minWarmSamples {
            roiLockFactor = Float(posCount) / Float(max(1, P.minWarmSamples))
        } else {
            roiLockFactor = 0.5
        }

        var freqStability: Float
        if lastFreqHz.isNaN || freqHz.isNaN {
            freqStability = 0.7
        } else {
            let jump = abs(freqHz - lastFreqHz)
            var stab = 1 - jump / P.maxFreqJumpHz
            if stab < 0 { stab = 0 }
            if stab > 1 { stab = 1 }
            if stab < 0.3 { stab = 0.3 }
            freqStability = stab
        }

        var confidence = periodicityFactor * meFactor * blockFactor *
                         roiLockFactor * freqStability
        if confidence < 0 { confidence = 0 }
        if confidence > 1 { confidence = 1 }
        if freqHz.isNaN { confidence = 0 }

        let pos01 = computePosition01(motionEnergy: motionEnergy)

        let dirAngleDeg = atan2(mainDirY, mainDirX) * 180.0 / Float.pi
        let blkRatePct = totalBlocks > 0 ? Int((Float(validBlocks) / Float(totalBlocks) * 100).rounded()) : 0
        let dtMs = dt * 1000.0
        let debug = String(
            format: "roi=(%d,%d,%d,%d) blk=%d/%d (%d%%) sM=%.2f rawP=%.2f f=%.2fHz per=%.2f mE=%.3f conf=%.2f dir=(%.2f,%.2f,%.0f°) [me=%.2f blk=%.2f lock=%.2f stab=%.2f] dt=%.0fms",
            rx, ry, rw, rh,
            validBlocks, totalBlocks, blkRatePct,
            signedMotion, rawPosition,
            freqHz, periodicityFactor, motionEnergy, confidence,
            mainDirX, mainDirY, dirAngleDeg,
            meFactor, blockFactor, roiLockFactor, freqStability,
            dtMs
        )

        let r = VideoWaveResult(
            timestampMs: timestampMs,
            freqHz: freqHz,
            confidence: confidence,
            position01: pos01,
            rawPosition: rawPosition,
            motionEnergy: motionEnergy,
            periodicity: periodicityFactor,
            roiX: rx, roiY: ry, roiW: rw, roiH: rh,
            mainDirX: mainDirX, mainDirY: mainDirY,
            locked: (consecutiveLost == 0 && posCount >= P.minWarmSamples),
            valid: !freqHz.isNaN && posCount >= P.minWarmSamples,
            debugInfo: debug
        )

        if !freqHz.isNaN { lastFreqHz = freqHz }
        return r
    }

    // MARK: - computePosition01
    private func computePosition01(motionEnergy: Float) -> Float {
        if motionEnergy < P.minMotionEnergyZero {
            lastPos01 = 0.95 * lastPos01 + 0.05 * 0.5
            return lastPos01
        }
        let n = min(P.posNormWindow, posCount)
        if n < 5 { return lastPos01 }

        var minV: Float = .greatestFiniteMagnitude
        var maxV: Float = -.greatestFiniteMagnitude
        for i in 0..<n {
            let idx = (posWriteIdx - 1 - i + P.windowSize) % P.windowSize
            let v = posWindow[idx]
            if v < minV { minV = v }
            if v > maxV { maxV = v }
        }
        let range = maxV - minV
        if range < 1e-3 { return lastPos01 }

        var v01 = (rawPosition - minV) / range
        if v01 < 0 { v01 = 0 }
        if v01 > 1 { v01 = 1 }
        lastPos01 = (1 - P.pos01SmoothAlpha) * lastPos01 + P.pos01SmoothAlpha * v01
        return lastPos01
    }

    // MARK: - 辅助
    private func publishNaN(timestampMs: Int64, reason: String) {
        let r = VideoWaveResult(
            timestampMs: timestampMs,
            freqHz: .nan,
            confidence: 0,
            position01: lastPos01,
            rawPosition: rawPosition,
            motionEnergy: 0,
            periodicity: 0,
            roiX: 0, roiY: 0, roiW: 0, roiH: 0,
            mainDirX: mainDirX, mainDirY: mainDirY,
            locked: false,
            valid: false,
            debugInfo: "[NaN] " + reason
        )
        latest = r
    }

    private func decayConfidence(timestampMs: Int64, reason: String) {
        let prev = latest
        let upd = prev.copy()
        upd.timestampMs = timestampMs
        upd.confidence *= 0.6
        upd.locked = false
        upd.debugInfo = "[decay] reason=" + reason + " prev=" + prev.debugInfo
        latest = upd
    }

    private func snapshotPosWindow() -> [Float] {
        let n = posCount
        if n == 0 { return [] }
        var out = [Float](repeating: 0, count: n)
        let start = (posWriteIdx - n + P.windowSize) % P.windowSize
        for i in 0..<n {
            out[i] = posWindow[(start + i) % P.windowSize]
        }
        return out
    }

    private func estimateAvgDt() -> Float {
        if posCount < 2 { return 0.1 }
        let t0 = posTsWindow[(posWriteIdx - posCount + P.windowSize) % P.windowSize]
        let t1 = posTsWindow[(posWriteIdx - 1 + P.windowSize) % P.windowSize]
        if t1 <= t0 { return 0.1 }
        let dt = Float(t1 - t0) / 1000.0 / Float(max(1, posCount - 1))
        if dt < 0.02 || dt > 0.5 { return 0.1 }
        return dt
    }
}
