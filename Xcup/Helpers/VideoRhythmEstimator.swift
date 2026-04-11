import Foundation

/**
 * VideoRhythmEstimator
 * 目标：在视频线程侧，从每帧关键点生成一维"位移标量"序列，基于滑动窗做周期性检测，输出 (videoFreqHz, videoFreqConf)。
 * 频率范围：0.5–6 Hz，窗口建议 32–64 样本（适配你的视频线程 ~100ms/帧）。
 *
 * 使用方式（最小改动）：
 *  1) 在 VideoProcessActivity/InferenceHelper 的 ML Kit 姿态回调里，拿到 17x3 关键点（已做与你训练一致的 PreNormalize2D 后），调用 onPoseFrame(kps, ptsMs)。
 *  2) 周期性（例如每隔 ~300ms）内部自动触发 estimate()，并将结果写入 latestVideoFreqHz / latestVideoFreqConf（原子引用）。
 *  3) 主融合线程暂不使用该值；先仅做缓存。
 *
 * 关键步骤：
 *  A. 关键点可见性判定（≥40% 关键点 conf>0.4，否则跳过该帧）
 *  B. 计算位移标量 s_t ：mid-hip 与 mid-shoulder 的欧氏距离（在已 PreNormalize2D 坐标系下）
 *  C. 写入滑动窗（ring buffer），并轻量带通（高通去趋势 + 低通 EMA）
 *  D. 自相关主峰/频谱主峰（此处默认自相关） → 主频 f_v 与置信度 c_v（峰显著度、可见度、一致性）
 *  E. 轻量时序平滑：EMA 限幅 + 异常跳变抑制
 */
class VideoRhythmEstimator {
    
    // ==== 可调参数（移动端友好，尽量保守） ====
    struct Params {
        // 频率范围（Hz）
        var fMin: Float = 0.5
        var fMax: Float = 6.0
        
        // 滑动窗样本数（视频线程每 ~100ms 一次；64 ≈ 6.4s）
        var windowSize: Int = 64
        
        // 估计步长（每多少帧尝试估计一次；3≈每300ms）
        var estimateEveryNFrames: Int = 3
        
        // 可见度门槛（与现有一致：≥40% 关键点 conf>0.4）
        var minKpConf: Float = 0.4
        var minVisibleRatio: Float = 0.40
        
        // 带通：高通（去趋势）+ 低通 EMA 的系数（越小越平滑）
        var hpAlpha: Float = 0.95    // 高通用简单去均值 + 轻微泄漏
        var lpAlpha: Float = 0.20    // 低通 EMA 系数（0.1~0.3 较稳）
        
        // 频率 EMA 平滑（对最终 f_v 做一点点时间平滑）
        var freqEma: Float = 0.30
        
        // 异常跳变抑制阈值（Hz）
        var maxJumpHz: Float = 2.0
        
        // 置信度加权：峰显著度、关键点覆盖度、一致性
        var wPeak: Float = 0.60
        var wVis: Float = 0.25
        var wCons: Float = 0.15
        
        // 一致性窗口（最近几次估计落在±10%内的占比）
        var consistencyWindow: Int = 5
        var consistencyTol: Float = 0.10 // ±10%
    }
    
    private let P: Params
    
    // === 对外可读（原子） ===
    private let queue = DispatchQueue(label: "VideoRhythmEstimator.queue")
    private var _latestFreqHz: Float = .nan
    private var _latestConf: Float = 0
    private var _latestTsMs: Int64 = 0
    
    var latestFreqHz: Float {
        queue.sync { _latestFreqHz }
    }
    var latestConf: Float {
        queue.sync { _latestConf }
    }
    var latestTsMs: Int64 {
        queue.sync { _latestTsMs }
    }
    
    // === 内部缓冲 ===
    private var ring: [Float]     // 原始位移标量 s_t
    private var proc: [Float]     // 处理后的序列（去趋势/带通后）
    private var writeIdx = 0
    private var filled = 0
    private var frameSinceLastEst = 0
    
    // 频率平滑
    private var haveFreq = false
    private var emaFreq: Float = .nan
    
    // 一致性缓存
    private var recentFreqs: [Float]
    private var recentIdx = 0
    private var recentCount = 0
    
    // 预处理状态
    private var runningMean: Float = 0
    private var lpPrev: Float = 0
    private var lastVisibility: Float = 0
    
    convenience init() {
        self.init(params: Params())
    }
    
    init(params: Params) {
        self.P = params
        self.ring = [Float](repeating: 0, count: P.windowSize)
        self.proc = [Float](repeating: 0, count: P.windowSize)
        self.recentFreqs = [Float](repeating: .nan, count: max(3, P.consistencyWindow))
    }
    
    /** 重置（Seek/镜头切换时调用） */
    func reset() {
        queue.sync {
            ring = [Float](repeating: 0, count: P.windowSize)
            proc = [Float](repeating: 0, count: P.windowSize)
            writeIdx = 0
            filled = 0
            frameSinceLastEst = 0
            haveFreq = false
            emaFreq = .nan
            recentFreqs = [Float](repeating: .nan, count: max(3, P.consistencyWindow))
            recentIdx = 0
            recentCount = 0
            _latestFreqHz = .nan
            _latestConf = 0
            _latestTsMs = 0
            runningMean = 0
            lpPrev = 0
        }
    }
    
    // ============== 外部读接口（供你缓存至 AtomicReference） ==============
    func getLatestFreqHz() -> Float { return latestFreqHz }
    func getLatestConf() -> Float { return latestConf }
    func getLatestTsMs() -> Int64 { return latestTsMs }
    
    // ============== 主入口：在 ML Kit 姿态回调中调用 ======================
    /**
     * @param kps    17x3 关键点（x,y,conf），坐标需与你 ST-GCN++ 训练时的 PreNormalize2D 一致（[-1,1]）
     * @param ptsMs  当前帧的展示或编码时间戳
     */
    func onPoseFrame(kps: [[Float]], ptsMs: Int64) {
        queue.sync {
            // A) 关键点可见性检查
            if !isPoseReliable(kps) {
                // 关键点不可靠：不写入新样本，但做置信度衰减（可选，这里简单不更新）
                frameSinceLastEst += 1
                tryEstimateIfReady(ptsMs)
                return
            }
            
            // B) 计算位移标量：mid-hip 与 mid-shoulder 的欧氏距离
            let s = computeDisplacementScalar(kps)
            
            // C) 写入滑动窗
            ring[writeIdx] = s
            // 预处理：去均值 + 轻微高通 + 低通 EMA
            // 为简单起见，先做去均值，再做一次一阶 EMA 低通
            proc[writeIdx] = prefilter(s, writeIdx)
            writeIdx = (writeIdx + 1) % P.windowSize
            if filled < P.windowSize {
                filled += 1
            }
            
            frameSinceLastEst += 1
            tryEstimateIfReady(ptsMs)
        }
    }
    
    // ============== 核心步骤：估计触发与结果写入 ==============
    private func tryEstimateIfReady(_ ptsMs: Int64) {
        if filled < min(32, P.windowSize/2) { return } // 预热
        if frameSinceLastEst < P.estimateEveryNFrames { return }
        frameSinceLastEst = 0
        
        // 复制一份连续序列，避免环形索引复杂性
        let seq = snapshot(proc, filled)
        
        // D) 自相关主峰 → 频率 & 峰显著度
        let est = estimateByAutocorr(seq, samplePeriodSec: 0.1, fMin: P.fMin, fMax: P.fMax)
        
        // 置信度：峰显著度、关键点可见度、一致性
        let vis = lastVisibility // 在 isPoseReliable() 中更新
        let cons = consistencyScore(est.freqHz)
        var conf = clamp01(P.wPeak * est.peakScore + P.wVis * vis + P.wCons * cons)
        
        // E) 频率时间平滑与异常抑制
        var smoothF = est.freqHz
        if haveFreq && !emaFreq.isNaN {
            if abs(est.freqHz - emaFreq) > P.maxJumpHz && conf < 0.5 {
                // 大跳变且置信度不高 → 抑制：沿用旧值并降低 conf
                smoothF = emaFreq
                conf *= 0.6
            } else {
                smoothF = (1 - P.freqEma) * est.freqHz + P.freqEma * emaFreq
            }
        }
        emaFreq = smoothF
        haveFreq = true
        
        // 一致性缓存更新
        recentFreqs[recentIdx] = smoothF
        recentIdx = (recentIdx + 1) % recentFreqs.count
        if recentCount < recentFreqs.count {
            recentCount += 1
        }
        
        // 写原子值（供外部缓存/读取）
        _latestFreqHz = smoothF
        _latestConf = conf
        _latestTsMs = ptsMs
    }
    
    // ============== 可见性与位移标量 ==========================
    private func isPoseReliable(_ kps: [[Float]]) -> Bool {
        var visible = 0
        for i in 0..<kps.count {
            let conf = kps[i][2]
            if conf >= P.minKpConf {
                visible += 1
            }
        }
        let ratio = Float(visible) / Float(max(1, kps.count))
        lastVisibility = ratio // 用作置信度分量
        return ratio >= P.minVisibleRatio
    }
    
    private func computeDisplacementScalar(_ kps: [[Float]]) -> Float {
        // mid-hip = (Lhip + Rhip)/2 ; mid-shoulder = (Lsho + Rsho)/2
        let L_HIP = 11, R_HIP = 12, L_SHO = 5, R_SHO = 6 // COCO 索引（按你项目使用的顺序调整）
        
        let lx = kps[L_HIP][0], ly = kps[L_HIP][1]
        let rx = kps[R_HIP][0], ry = kps[R_HIP][1]
        let mx = 0.5 * (lx + rx)
        let my = 0.5 * (ly + ry)
        
        let lsx = kps[L_SHO][0], lsy = kps[L_SHO][1]
        let rsx = kps[R_SHO][0], rsy = kps[R_SHO][1]
        let sx = 0.5 * (lsx + rsx)
        let sy = 0.5 * (lsy + rsy)
        
        let dx = mx - sx, dy = my - sy
        var dist = sqrt(dx*dx + dy*dy)
        
        // 可选：除以肩宽做自适应归一化（提升镜头推拉稳健性）
        let shoulderDx = rsx - lsx, shoulderDy = rsy - lsy
        let shoulder = sqrt(shoulderDx*shoulderDx + shoulderDy*shoulderDy)
        if shoulder > 1e-6 {
            dist /= shoulder
        }
        return dist
    }
    
    // ============== 预处理（去均值/带通的轻量近似） ==================
    // 这里采用：去均值 + 简单低通 EMA。为避免存整窗均值，这里做一个渐进均值/泄漏式高通近似。
    private func prefilter(_ s: Float, _ idx: Int) -> Float {
        // 去均值（渐进）
        runningMean = 0.99 * runningMean + 0.01 * s
        let highpassed = s - runningMean      // 简易高通（去趋势）
        
        // 低通 EMA
        let lp = (1 - P.lpAlpha) * highpassed + P.lpAlpha * lpPrev
        lpPrev = lp
        
        return lp
    }
    
    // ============== 自相关主频估计 ==============================
    private struct EstResult {
        var freqHz: Float
        var peakScore: Float // 0..1
    }
    
    /**
     * @param seq  连续数组（长度 = filled）
     * @param dt   采样周期（秒），视频线程 ~100ms → 0.1
     * @param fMin/fMax  搜索频率范围
     */
    private func estimateByAutocorr(_ seq: [Float], samplePeriodSec dt: Float, fMin: Float, fMax: Float) -> EstResult {
        var r = EstResult(freqHz: .nan, peakScore: 0)
        let n = seq.count
        if n < 16 { return r }
        
        // 计算自相关 R[k]（中心化后）
        var mean: Float = 0
        for v in seq { mean += v }
        mean /= Float(n)
        var variance: Float = 0
        var x = [Float](repeating: 0, count: n)
        for i in 0..<n {
            x[i] = seq[i] - mean
            variance += x[i] * x[i]
        }
        if variance < 1e-12 { return r }
        
        let kMin = max(1, Int(floor(1.0/(fMax*dt)))) // 对应最大频率的最小滞后
        let kMax = min(n-1, Int(ceil(1.0/(fMin*dt)))) // 对应最小频率的最大滞后
        
        var bestVal: Float = -Float.greatestFiniteMagnitude
        var bestK = -1
        for k in kMin...kMax {
            var s: Float = 0
            for i in 0..<(n-k) {
                s += x[i] * x[i+k]
            }
            if s > bestVal {
                bestVal = s
                bestK = k
            }
        }
        if bestK <= 0 { return r }
        
        let r0 = variance // k=0 的自相关值
        let norm = bestVal / (r0 + 1e-12)
        
        // 估计频率
        let tau = Float(bestK) * dt
        let f = 1.0 / max(tau, 1e-6)
        
        // 峰显著度（与相邻滞后比较）
        var neighbor: Float = 0
        if bestK-1 >= kMin && bestK+1 <= kMax {
            var sm1: Float = 0, sp1: Float = 0
            for i in 0..<(n-(bestK-1)) {
                sm1 += x[i] * x[i+bestK-1]
            }
            for i in 0..<(n-(bestK+1)) {
                sp1 += x[i] * x[i+bestK+1]
            }
            neighbor = max(sm1, sp1) / (r0 + 1e-12)
        }
        let peakScore = clamp01((norm - neighbor) * 2.0) // 简易突出度 0..1
        
        r.freqHz = f
        r.peakScore = peakScore
        return r
    }
    
    // ============== 一致性评分（最近几次在 ±10% 内的占比） ===========
    private func consistencyScore(_ fNow: Float) -> Float {
        if fNow.isNaN || recentCount == 0 { return 0 }
        var ok = 0
        for i in 0..<recentCount {
            let v = recentFreqs[i]
            if v.isNaN { continue }
            let tol = max(P.consistencyTol * v, 0.1)
            if abs(fNow - v) <= tol {
                ok += 1
            }
        }
        return clamp01(Float(ok) / Float(max(1, recentCount)))
    }
    
    // ============== 工具函数 ============================
    private func clamp01(_ v: Float) -> Float {
        return max(0, min(1, v))
    }
    
    private func snapshot(_ buf: [Float], _ len: Int) -> [Float] {
        // 将环形缓冲的"filled"段按时间顺序拷贝出来（最近的在末尾）
        var out = [Float](repeating: 0, count: len)
        let start = (writeIdx - len + P.windowSize) % P.windowSize
        for i in 0..<len {
            out[i] = buf[(start + i) % P.windowSize]
        }
        return out
    }
}
