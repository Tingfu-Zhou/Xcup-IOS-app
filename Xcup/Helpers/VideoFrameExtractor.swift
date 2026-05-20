//
//  VideoFrameExtractor.swift
//  Xcup
//
//  Created by tingfu on 2025/4/20.
//


//  Android 替代：VideoFrameExtractor.java + EGLRenderer.java
//

import Foundation
import AVFoundation
import CoreImage
import UIKit

/// 高性能视频帧提取器（基于 AVAssetReader + CIImage）
/// 高性能视频帧提取器（单例 ImageGenerator，支持容忍区间）
final class VideoFrameExtractor {

    private let asset: AVAsset
    private let imageGenerator: AVAssetImageGenerator
    private let context = CIContext()          // 如需后处理可复用

    // 目标尺寸：与 MobileNetV3Small 视频分类器输入对齐（160×160）。
    // 注意：maximumSize 只是上限（保持宽高比），最终精确的 160×160 缩放在 VideoClassifierHelper / 控制器层完成。
    private let targetSize = CGSize(width: 160, height: 160)
    
    init?(url: URL) {
        self.asset = AVURLAsset(url: url)

        // ✅ 使用同步判断方式
        guard asset.isPlayable,
              asset.tracks(withMediaType: .video).first != nil else {
            print("❌ 无可播放视频轨道")
            return nil
        }
        
        // 仅保留 ImageGenerator，删除 AVAssetReader
        imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = targetSize
        // **关键：放宽容忍区间**（或直接不设置，使用默认值 ±0.1 s）
        imageGenerator.requestedTimeToleranceBefore = .positiveInfinity
        imageGenerator.requestedTimeToleranceAfter  = .positiveInfinity
    }


    /// 返回最接近 timeUs 的视频帧
    func frame(at timeUs: Int64) -> UIImage? {
        let requested = CMTime(value: timeUs, timescale: 1_000_000) // μs ➜ CMTime
        var actual    = CMTime.zero

        do {
            let cg = try imageGenerator.copyCGImage(at: requested,
                                                    actualTime: &actual)
            return UIImage(cgImage: cg)
        } catch {
            // 调试信息：打印请求/实际时间差
            print("❌ 抽帧失败 Δt = \((actual - requested).seconds) s : \(error)")
            return nil
        }
    }
}
