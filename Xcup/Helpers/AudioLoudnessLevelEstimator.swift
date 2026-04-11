//
//  AudioLoudnessLevelEstimator.swift
//  Xcup
//
//  Created by tingfu on 2025/12/31.
//

import Foundation

final class AudioLoudnessLevelEstimator {

    final class Result {
        let valid: Bool
        let level: Int           // 0..9
        let confidence: Float    // 0..1
        let rms: Float           // linear RMS
        let db: Float            // dBFS (<=0)
        let timestampMs: Int64

        init(valid: Bool, level: Int, confidence: Float, rms: Float, db: Float, ts: Int64) {
            self.valid = valid
            self.level = level
            self.confidence = confidence
            self.rms = rms
            self.db = db
            self.timestampMs = ts
        }
    }

    private let sampleRate: Int

    // --- 与 Java 对齐的参数 ---
    private static let EPS: Float = 1e-8

    // RMS → dBFS 后做 EMA 平滑
    private static let EMA_ALPHA: Float = 0.35

    // 自适应噪声底/峰值的更新速度
    private static let NOISE_ADAPT: Float = 0.03
    private static let PEAK_ADAPT: Float  = 0.03

    private static let HARD_SILENCE_DB: Float = -50.0
    private static let MIN_DYNAMIC_RANGE_DB: Float = 10.0
    private static let GAMMA: Float = 1.15  // 这里保留（当前分段映射主要依赖阈值）

    // 分段阈值：norm ∈ [0,1] → 0..9 档
    private static let NORM_THRESH: [Float] = [
        0.10, // >=0.10 -> 1档（低于此视为0档）
        0.20, // -> 2
        0.30, // -> 3
        0.40, // -> 4
        0.50, // -> 5
        0.60, // -> 6  （1..6：转速档，覆盖0.10~0.60）
        0.75, // -> 7  （7..9：强度档，需要更强响度）
        0.88, // -> 8
        0.96  // -> 9
    ]

    // --- 状态 ---
    private var inited: Bool = false
    private var warmCount: Int = 0

    private var emaDb: Float = AudioLoudnessLevelEstimator.HARD_SILENCE_DB
    private var noiseFloorDb: Float = -45.0
    private var peakDb: Float = -12.0

    // 保持“构造函数名/语义”对齐：Java 是 AudioLoudnessLevelEstimator(int sampleRate)
    init(sampleRate: Int) {
        self.sampleRate = sampleRate
    }

    // ===== 要求：函数名不改变 =====
    func reset() {
        inited = false
        warmCount = 0
        emaDb = AudioLoudnessLevelEstimator.HARD_SILENCE_DB
        noiseFloorDb = -45.0
        peakDb = -12.0
    }

    // ===== 要求：函数名不改变（Swift 需要参数标签，这里按语义保留） =====
    func push(pcm: [Float]) {
        guard !pcm.isEmpty else { return }

        let rms = Self.computeRms(pcm)
        let db = 20.0 * log10f(rms + Self.EPS) // dBFS

        if !inited {
            emaDb = db
            noiseFloorDb = min(db, noiseFloorDb)
            peakDb = max(db, peakDb)
            inited = true
        } else {
            emaDb = Self.EMA_ALPHA * db + (1.0 - Self.EMA_ALPHA) * emaDb

            // 噪声底：安静时更新更积极
            if emaDb < noiseFloorDb + 3.0 {
                noiseFloorDb = Self.NOISE_ADAPT * emaDb + (1.0 - Self.NOISE_ADAPT) * noiseFloorDb
            } else {
                noiseFloorDb = (Self.NOISE_ADAPT * 0.2) * emaDb + (1.0 - Self.NOISE_ADAPT * 0.2) * noiseFloorDb
            }

            // 峰值：变大时快更新，变小时慢回落
            if emaDb > peakDb {
                peakDb = Self.PEAK_ADAPT * emaDb + (1.0 - Self.PEAK_ADAPT) * peakDb
            } else {
                peakDb = (Self.PEAK_ADAPT * 0.15) * emaDb + (1.0 - Self.PEAK_ADAPT * 0.15) * peakDb
            }
        }

        warmCount += 1
    }

    // ===== 要求：函数名不改变 =====
    func estimate(nowMs: Int64) -> Result {
        guard inited, warmCount >= 2 else {
            return Result(valid: false, level: 0, confidence: 0.0, rms: 0.0, db: emaDb, ts: nowMs)
        }

        if emaDb < Self.HARD_SILENCE_DB {
            return Result(valid: true, level: 0, confidence: 0.0, rms: Self.dbToRms(emaDb), db: emaDb, ts: nowMs)
        }

        var dyn = peakDb - noiseFloorDb
        if dyn < 1.0 { dyn = 1.0 }

        var norm = (emaDb - noiseFloorDb) / dyn
        norm = Self.clamp01(norm)

        // 分段/非线性映射：0..9
        let level = Self.mapNormToLevel(norm)

        // confidence：norm + 动态范围惩罚
        var conf = norm
        if dyn < Self.MIN_DYNAMIC_RANGE_DB {
            let penalty = dyn / Self.MIN_DYNAMIC_RANGE_DB
            conf *= Self.clamp01(penalty)
        }
        if emaDb < noiseFloorDb + 2.0 {
            conf *= 0.3
        }
        conf = Self.clamp01(conf)

        let valid = (level > 0) && (conf >= 0.10)
        return Result(valid: valid, level: level, confidence: conf, rms: Self.dbToRms(emaDb), db: emaDb, ts: nowMs)
    }

    // --- 对齐 Java 的 mapNormToLevel ---
    private static func mapNormToLevel(_ norm: Float) -> Int {
        if norm < NORM_THRESH[0] { return 0 }
        for i in 0..<(NORM_THRESH.count - 1) {
            if norm < NORM_THRESH[i + 1] { return i + 1 } // i=0 -> 1档
        }
        return 9
    }

    private static func computeRms(_ x: [Float]) -> Float {
        var s: Double = 0.0
        for v in x { s += Double(v) * Double(v) }
        return Float(sqrt(s / Double(max(1, x.count))))
    }

    private static func dbToRms(_ db: Float) -> Float {
        return powf(10.0, db / 20.0)
    }

    private static func clamp01(_ v: Float) -> Float {
        return v < 0 ? 0 : (v > 1 ? 1 : v)
    }
}
