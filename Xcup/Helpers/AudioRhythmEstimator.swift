import Foundation

// =============================================================
// 文件: AudioRhythmEstimator.swift
// 用途: 4秒滑动窗口音频节奏估计器 (0.5-6 Hz)
//      设计用于插入到您现有的音频线程中。
//      每个音频线程节拍推送约1秒的16 kHz PCM数据。
//      当内部缓冲区达到4秒时，估计器
//      输出(频率Hz, 置信度, 时间戳Ms)。
//
// 为什么先简单实现:
//   - 使用宽带短时能量包络(下采样到100 Hz)
//     以避免繁重的DSP依赖。
//   - 在延迟范围[17..200]个bin内进行自相关(≈6-0.5 Hz，包络采样率100 Hz)。
//   - 置信度来自归一化自相关峰值和能量合理性检查。
//
// 下一步迭代(保留TODO标记):
//   - 多频带包络(80-250 / 250-800 / 800-3000 Hz)，使用简单的IIR带通滤波器。
//   - 当音乐/语音占主导时，可选的HPSS或VAD门控。
//   - 用1极点低通滤波器@10 Hz替换移动平均平滑处理包络。
// =============================================================

final class AudioRhythmEstimator {
    struct Result {
        let valid: Bool          // 当我们有>=4秒缓冲并有可用估计时为true
        let frequencyHz: Float   // 估计的节奏频率(Hz)
        let confidence: Float    // [0,1]
        let timestampMs: Int64   // 产生时的系统时间(由调用者提供)
        
        private init(valid: Bool, frequencyHz: Float, confidence: Float, timestampMs: Int64) {
            self.valid = valid
            self.frequencyHz = frequencyHz
            self.confidence = confidence
            self.timestampMs = timestampMs
        }
        
        static func invalid(_ ts: Int64) -> Result {
            return Result(valid: false, frequencyHz: 0, confidence: 0, timestampMs: ts)
        }
        
        static func of(_ f: Float, _ c: Float, _ ts: Int64) -> Result {
            return Result(valid: true, frequencyHz: f, confidence: c, timestampMs: ts)
        }
    }
    
    // ======== 配置 ========
    private let sr: Int                 // 采样率(预期16000)
    private let secondsWindow = 4       // 4秒节奏窗口
    private let capacity: Int           // sr * secondsWindow
    
    // 包络参数
    private let envFs = 100                        // 包络采样率(每秒的bin数)
    private let envHop: Int                        // sr / envFs = 16000/100 = 160 采样/bin
    private let minLagBins = 54                    // ≈ 100/1.85 Hz = 54
    private let maxLagBins = 106                   // ≈ 100/0.95 Hz = 106
    private let maSmooth = 5                       // 移动平均长度(~50毫秒)
    
    // ======== 状态(4秒滑动窗口) ========
    private var ring: [Float]
    private var writeIdx = 0          // 写入游标(对容量取模)
    private var filled = 0            // 当前缓冲的有效采样数
    
    init(sampleRateHz: Int) {
        self.sr = sampleRateHz
        self.capacity = sampleRateHz * secondsWindow // 16 kHz时为64000
        self.ring = [Float](repeating: 0, count: capacity)
        self.envHop = max(1, sampleRateHz / envFs)
    }
    
    /** 重置内部缓冲区和状态(在跳转/停止时调用)。 */
    func reset() {
        ring = [Float](repeating: 0, count: capacity)
        writeIdx = 0
        filled = 0
    }
    
    /**
     * 推送一块最新的单声道PCM采样(float值在[-1,1]范围内)。
     * 推荐块大小: ~1秒(sr个采样)。允许更短或更长。
     */
    func push(_ mono16k: [Float]) {
        push(mono16k, off: 0, len: mono16k.count)
    }
    
    func push(_ mono16k: [Float], off: Int, len: Int) {
        var i = 0
        while i < len {
            let spaceToEnd = capacity - writeIdx
            let cp = min(spaceToEnd, len - i)
            
            // 复制数据到ring buffer
            for j in 0..<cp {
                ring[writeIdx + j] = mono16k[off + i + j]
            }
            
            writeIdx = (writeIdx + cp) % capacity
            i += cp
            filled = min(capacity, filled + cp)
        }
    }
    
    /** 当我们至少缓冲了4秒的音频并可以估计节奏时返回true。 */
    func isWarm() -> Bool {
        return filled >= capacity
    }
    
    /**
     * 对最后4秒窗口执行节奏估计。
     * @param nowMs 用于标记结果的时间戳。
     */
    func estimate(_ nowMs: Int64) -> Result {
        if !isWarm() {
            return Result.invalid(nowMs)
        }
        
        // 1) 按时间顺序提取连续的4秒窗口
        var win = [Float](repeating: 0, count: capacity)
        if writeIdx == 0 {
            win = ring
        } else {
            let tail = capacity - writeIdx
            // 复制ring的后半部分到win的前面
            for i in 0..<tail {
                win[i] = ring[writeIdx + i]
            }
            // 复制ring的前半部分到win的后面
            for i in 0..<writeIdx {
                win[tail + i] = ring[i]
            }
        }
        
        // 2) 预归一化(RMS归一化到~1.0，避免溢出和响度漂移)
        let rms = sqrt(eps + meanSquare(win))
        if rms > 0 {
            let g = 1.0 / rms
            for i in 0..<win.count {
                win[i] *= g
            }
        }
        
        // 3) 构建~100 Hz的能量包络(对envHop求平方和)
        let bins = win.count / envHop // ~64000/160 = 400个bin
        var env = [Float](repeating: 0, count: bins)
        var idx = 0
        for b in 0..<bins {
            var e: Float = 0
            let end = idx + envHop
            while idx < end {
                let s = win[idx]
                idx += 1
                e += s * s
            }
            env[b] = e // 已经≥0
        }
        
        // 4) 移动平均平滑(~50毫秒)
        if maSmooth > 1 {
            env = movingAverage(env, maSmooth)
        }
        
        // 在标准化之前，拷贝一份“未标准化”的包络，用于弱信号判定
        let envRaw = env
        
        // 5) 标准化包络: 减去均值，除以标准差(避免直流偏置)
        standardizeInPlace(&env)
        
        // 6) 在延迟范围[minLagBins..maxLagBins]内进行自相关
        let r0 = autocorrAtLag(env, 0) // 等于方差 * N (因为零均值)
        if r0 <= 1e-6 {
            return Result.invalid(nowMs)
        }
        
        var bestLag = -1
        var bestR: Float = -Float.greatestFiniteMagnitude
        // 可选: 在峰值周围进行小的抛物线插值可以精细化频率。
        for k in minLagBins...min(maxLagBins, env.count - 3) {
            let r = autocorrAtLag(env, k)
            if r > bestR {
                bestR = r
                bestLag = k
            }
        }
        if bestLag < 0 {
            return Result.invalid(nowMs)
        }

        // 次谐波纠错（Subharmonic Correction）
        // 目的：当 bestLag 很小导致频率偏高（如 100/17=5.88Hz）时，
        // 在 2*bestLag 附近寻找“更慢一倍”的候选峰（基础频率），若足够强则替换 bestLag/bestR。
        do {
            let baseFreq = Float(envFs) / Float(bestLag)
            if baseFreq > 2.0 {                         // 只对“明显偏快”的情况尝试纠错（阈值可调：3.3~3.8）
                let searchRadius = 2                    // 在 2*bestLag ±2 bins 内搜索（可调：2~3）
                let cand2 = bestLag * 2
                
                if cand2 <= maxLagBins {
                    var candidateLag = -1
                    var candidateR: Float = -Float.greatestFiniteMagnitude
                    
                    let start = max(minLagBins, cand2 - searchRadius)
                    let end = min(maxLagBins, cand2 + searchRadius)
                    if start <= end {
                        for k in start...min(end, env.count - 3) {
                            let r = autocorrAtLag(env, k)
                            if r > candidateR {
                                candidateR = r
                                candidateLag = k
                            }
                        }
                    }
                    
                    if candidateLag > 0 {
                        let mainNorm = bestR / r0
                        let subNorm  = candidateR / r0
                        
                        // 条件：次谐波峰不能比主峰弱太多，且自身不能太弱（两个阈值都可调）
                        if subNorm >= 0.6 * mainNorm && subNorm >= 0.20 {
                            bestLag = candidateLag
                            bestR = candidateR
                        }
                    }
                }
                
                // 如后续需要，还可加 3*bestLag 的搜索（更强纠错，但更易误触发；建议先不上）
            }
        }
        
        // 7) 将延迟(100 Hz的bin数) -> Hz
        var freq = Float(envFs) / Float(bestLag) // Hz
        
        // 8) 从归一化峰值高度和基本合理性检查计算置信度
        let peakNorm = bestR / r0                     // [0..1] 准周期信号通常 < 0.7
        // 传入 env(标准化后) + envRaw(未标准化)
        var conf = scoreConfidence(peakNorm, env, envRaw, bestLag)
        
        // 9) 将频率限制在[0.95, 1.85] Hz以减少异常值
        if freq < 0.95 || freq > 1.85 {
            // 如果超出范围，视为低置信度，但仍返回限制后的频率
            freq = clamp(freq, 0.95, 1.85)
            conf *= 0.5
        }
        return Result.of(freq, conf, nowMs)
    }
    
    // ======== 辅助函数 ========
    private let eps: Float = 1e-12
    
    private func meanSquare(_ x: [Float]) -> Float {
        var acc: Double = 0.0
        for v in x {
            acc += Double(v) * Double(v)
        }
        return Float(acc / Double(x.count))
    }
    
    private func movingAverage(_ x: [Float], _ m: Int) -> [Float] {
        let n = x.count
        if m <= 1 || m >= n {
            return x
        }
        var y = [Float](repeating: 0, count: n)
        var acc: Double = 0.0
        for i in 0..<n {
            acc += Double(x[i])
            if i >= m {
                acc -= Double(x[i - m])
            }
            if i >= m - 1 {
                y[i] = Float(acc / Double(m))
            } else {
                y[i] = x[i]
            }
        }
        return y
    }
    
    private func standardizeInPlace(_ x: inout [Float]) {
        var sum: Double = 0.0
        for v in x {
            sum += Double(v)
        }
        let mean = sum / Double(x.count)
        var vacc: Double = 0.0
        for v in x {
            let d = Double(v) - mean
            vacc += d * d
        }
        let std = sqrt(vacc / Double(max(1, x.count - 1)))
        if std < 1e-9 {
            for i in 0..<x.count {
                x[i] = 0
            }
            return
        }
        for i in 0..<x.count {
            x[i] = Float((Double(x[i]) - mean) / std)
        }
    }
    
    private func autocorrAtLag(_ x: [Float], _ lag: Int) -> Float {
        let n = x.count - lag
        if n <= 1 {
            return 0
        }
        var acc: Double = 0.0
        for i in 0..<n {
            acc += Double(x[i]) * Double(x[i + lag])
        }
        return Float(acc / Double(n))
    }
    
    private func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float {
        return max(lo, min(hi, v))
    }
    
    /** 置信度曲线: 基于归一化峰值的线性斜坡，带有轻微惩罚。 */
    // 新增 envRaw 参数：标准化前的包络
    private func scoreConfidence(_ peakNorm: Float, _ envStd: [Float], _ envRaw: [Float], _ bestLag: Int) -> Float {
        // 基于归一化峰值高度的基础值
        var c = (peakNorm - 0.06) / 0.35 // 0.15->0, 0.70->1.0 (可调)
        c = clamp(c, 0, 1)

        // [MOD] 弱信号惩罚：改用“未标准化”的 envRaw（而不是 envStd）
        if !envRaw.isEmpty {
            var energy: Double = 0.0
            var maxVal: Float = -Float.greatestFiniteMagnitude
            var minVal: Float =  Float.greatestFiniteMagnitude

            for v in envRaw {
                energy += Double(v) * Double(v)
                if v > maxVal { maxVal = v }
                if v < minVal { minVal = v }
            }

            let avgEnergy = energy / Double(envRaw.count)
            let dynamicRange = maxVal - minVal

            // 能量过低 → 降低置信度（阈值建议后续结合日志微调）
            if avgEnergy < 1e-4 {      // 建议调参范围：1e-4 ~ 1e-3
                c *= 0.8
            }

            // 动态范围过小（几乎没起伏）→ 再次降低置信度
            if dynamicRange < 1e-3 {   // 建议调参范围：1e-3 ~ 1e-2
                c *= 0.8
            }
        }

        // 可选: 检查bestLag周围的局部一致性(峰值尖锐度) —— 继续使用标准化后的 envStd
        /*
        let k = bestLag
        if k - 2 >= 0 && k + 2 < envStd.count {
            let side = 0.25 * (autocorrAtLag(envStd, k - 2) + autocorrAtLag(envStd, k + 2) +
                               autocorrAtLag(envStd, k - 1) + autocorrAtLag(envStd, k + 1))
            let sharp = peakNorm - side / max(1e-6, autocorrAtLag(envStd, 0))
            if sharp < 0.05 {
                c *= 0.8 // 宽峰 -> 稍低的置信度
            }
        }
        */

        return clamp(c, 0, 1)
    }
}
