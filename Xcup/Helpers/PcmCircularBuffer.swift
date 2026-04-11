//
//  PcmCircularBuffer.swift
//  Xcup
//
//  Created by tingfu on 2025/4/20.
//


//  对应 Android Java: PcmCircularBuffer.java
//

import Foundation

/// PCM 音频缓冲区，支持时间戳对齐和基于点的回溯采样
class PcmCircularBuffer {
    private let capacity: Int                     // 缓冲区最大容量（采样点）
    private var buffer: [Float]                   // PCM 音频数据
    private var timestamps: [Int64]               // 每个采样点对应的时间戳（单位：ms）
    private var writeIndex = 0
    private var isFull = false
    private var lastWriteStart: Int64 = -1
    private var lastWriteEnd: Int64 = -1
    
    // 添加线程同步机制
    private let queue = DispatchQueue(label: "com.app.pcmBuffer", attributes: .concurrent)
    
    /// 初始化缓冲区
    /// - Parameters:
    ///   - sampleRate: 采样率（如 16000）
    ///   - maxSeconds: 最大缓冲秒数（如 10）
    init(sampleRate: Int, capacityInSeconds maxSeconds: Int) {
        self.capacity = sampleRate * maxSeconds
        self.buffer = [Float](repeating: 0.0, count: capacity)
        self.timestamps = [Int64](repeating: 0, count: capacity)
    }
    
    /// 写入一段音频数据
    /// - Parameters:
    ///   - data: PCM 音频 float 数组
    ///   - startTimestampMs: 起始时间戳（毫秒）
    ///   - sampleRate: 采样率（如 16000）
    func write(_ data: [Float], startTimestampMs: Int64, sampleRate: Int) {
        queue.async(flags: .barrier) {
            for i in 0..<data.count {
                let index = (self.writeIndex + i) % self.capacity
                self.buffer[index] = data[i]
                self.timestamps[index] = startTimestampMs + Int64(i * 1000 / sampleRate)
            }
            
            self.writeIndex = (self.writeIndex + data.count) % self.capacity
            if data.count >= self.capacity {
                self.isFull = true
            }
            
            self.lastWriteStart = startTimestampMs
            self.lastWriteEnd = startTimestampMs + Int64(data.count * 1000 / sampleRate)
        }
    }
    
    /// 回溯读取一段音频窗口，基于时间戳，按点回溯
    /// - Parameters:
    ///   - currentTimeMs: 当前参考时间点（毫秒）
    ///   - sampleCount: 希望读取的采样点数（例如 32000）
    /// - Returns: 可选 float 数组（样本数量不足时返回 nil）
    func readWindowRelaxed(currentTimeMs: Int64, sampleCount: Int) -> [Float]? {
        var result: [Float]?
        
        queue.sync {
            var buffer = [Float](repeating: 0.0, count: sampleCount)
            var count = 0
            
            for i in 0..<self.capacity where count < sampleCount {
                let index = (self.writeIndex - 1 - i + self.capacity) % self.capacity
                let ts = self.timestamps[index]
                
                if ts > 0 && ts <= currentTimeMs {
                    buffer[sampleCount - count - 1] = self.buffer[index]
                    count += 1
                }
            }
            
            if count < Int(Float(sampleCount) * 0.9) {
                print("🚫 readWindowRelaxed: 样本太少，本轮放弃分析")
                result = nil
            } else {
                if count < sampleCount {
                    print("🔁 readWindowRelaxed: 样本不足，仅获取到 \(count) 个，将补零")
                }
                result = buffer
            }
        }
        
        return result
    }
    
    /// 清空整个 PCM 缓冲区
    func reset() {
        queue.async(flags: .barrier) {
            print("🧹 清空 PCM 缓冲区...")
            self.buffer = [Float](repeating: 0.0, count: self.capacity)
            self.timestamps = [Int64](repeating: 0, count: self.capacity)
            self.writeIndex = 0
            self.isFull = false
            self.lastWriteStart = -1
            self.lastWriteEnd = -1
        }
    }
}
