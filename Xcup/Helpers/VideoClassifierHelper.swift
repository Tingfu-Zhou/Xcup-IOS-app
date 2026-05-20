//
//  VideoClassifierHelper.swift
//  Xcup
//
//  对应 Android Java: VideoClassifierHelper.java
//
//  MobileNetV3Small + Temporal Average Pooling + 3分类 视频动作识别器
//  模型文件：mobilenetv3small_tap_3class_float32.tflite
//
//  输入 [1, 12, 160, 160, 3] float32（NHWC，t→h→w→c）
//    - 原始像素值 0–255，不归一化（模型内含 Rescaling 层）
//    - RGB 顺序
//  输出 [1, 3] softmax 概率
//    - 索引 0 = normal_plot
//    - 索引 1 = oral
//    - 索引 2 = sex
//

import Foundation
import UIKit
import CoreGraphics
import TensorFlowLite

final class VideoClassifierHelper {

    // MARK: - 模型常量
    static let TIME: Int = 12
    static let SIZE: Int = 160
    static let CHANNELS: Int = 3
    static let NUM_CLASSES: Int = 3

    private var interpreter: Interpreter?

    init() {
        do {
            guard let path = Bundle.main.path(
                forResource: "mobilenetv3small_tap_3class_float32",
                ofType: "tflite"
            ) else {
                print("❌ mobilenetv3small_tap_3class_float32.tflite 未找到")
                return
            }

            var options = Interpreter.Options()
            options.threadCount = 4

            interpreter = try Interpreter(modelPath: path, options: options)
            try interpreter?.allocateTensors()
            print("✅ VideoClassifier 加载成功（MobileNetV3Small + TAP + 3class）")
        } catch {
            print("❌ VideoClassifier 初始化失败: \(error)")
        }
    }

    /// 将任意尺寸的 UIImage 缩放到 160×160（RGB 像素）
    /// - Note: 调用者应在帧缓冲入队前完成一次缩放，避免缓存大图。
    static func resizeTo160(_ image: UIImage) -> UIImage? {
        let target = CGSize(width: SIZE, height: SIZE)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// 推理 12 帧 → 三分类
    /// - Parameter frames: 长度为 12 的 UIImage 数组（建议已是 160×160）
    /// - Returns: (argmax 索引, 最大概率, [normal_plot, oral, sex])
    func predict(frames: [UIImage]) -> (index: Int, confidence: Float, probs: [Float])? {
        guard let interpreter = interpreter else {
            print("❌ VideoClassifier 未初始化")
            return nil
        }
        guard frames.count == Self.TIME else {
            print("❌ 帧数错误：期望 \(Self.TIME)，实际 \(frames.count)")
            return nil
        }

        // 构造输入缓冲：[1, 12, 160, 160, 3] float32
        // 顺序：t → h → w → c（与 Android 端一致）
        let perFrameCount = Self.SIZE * Self.SIZE * Self.CHANNELS
        let totalFloats = Self.TIME * perFrameCount
        var inputBuffer = [Float](repeating: 0, count: totalFloats)

        for (t, image) in frames.enumerated() {
            guard let cg = image.cgImage else {
                print("❌ 第 \(t) 帧缺少 CGImage")
                return nil
            }

            // 用 CGContext 绘制成固定的 RGBA32（byteOrder32Big + premultipliedLast = R,G,B,A）
            // 这样无论原图是 BGRA / CVPixelBuffer 还是其它格式都强制变成 RGB 通道顺序
            let w = Self.SIZE
            let h = Self.SIZE
            let bytesPerRow = w * 4
            var pixelBytes = [UInt8](repeating: 0, count: w * h * 4)

            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue

            guard let ctx = pixelBytes.withUnsafeMutableBytes({ rawBuf -> CGContext? in
                guard let base = rawBuf.baseAddress else { return nil }
                return CGContext(
                    data: base,
                    width: w,
                    height: h,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                )
            }) else {
                print("❌ 创建 CGContext 失败")
                return nil
            }

            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

            // 拷贝 RGBA -> RGB float（丢弃 A，保持 0..255 原值）
            let frameOffset = t * perFrameCount
            for i in 0..<(w * h) {
                let base = i * 4
                inputBuffer[frameOffset + i * 3 + 0] = Float(pixelBytes[base + 0]) // R
                inputBuffer[frameOffset + i * 3 + 1] = Float(pixelBytes[base + 1]) // G
                inputBuffer[frameOffset + i * 3 + 2] = Float(pixelBytes[base + 2]) // B
            }
        }

        do {
            let data = inputBuffer.withUnsafeBufferPointer { Data(buffer: $0) }
            try interpreter.copy(data, toInputAt: 0)
            try interpreter.invoke()

            let outTensor = try interpreter.output(at: 0)
            let raw = outTensor.data.toArray(type: Float32.self)
            let probs = Array(raw.prefix(Self.NUM_CLASSES))

            var maxIdx = 0
            var maxP = probs[0]
            for i in 1..<probs.count {
                if probs[i] > maxP {
                    maxP = probs[i]
                    maxIdx = i
                }
            }
            return (maxIdx, maxP, probs)
        } catch {
            print("❌ VideoClassifier 推理失败: \(error)")
            return nil
        }
    }

    func close() {
        interpreter = nil
    }
}
