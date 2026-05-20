//
//  InferenceHelper.swift
//  Xcup
//
//  Created by tingfu on 2025/4/20.
//
//  ⚠️ 已弃用（保留文件以避免破坏现有引用）。
//  视频分析模块已从「ML Kit 姿态检测 + ST-GCN++ 推理」迁移为
//  「MobileNetV3Small + Temporal Average Pooling + 3分类」，
//  新逻辑见 VideoClassifierHelper.swift。
//
//  本文件内的 MLKit 与 ST-GCN++ 相关代码已注释。
//  保留 `typealias PoseFrame` 仅为兼容历史代码中的注释/弃用引用。
//


import Foundation
import CoreML
// import Vision
import UIKit
// import MLKitPoseDetectionAccurate
// import MLKitVision


/* ============================================================
   ===== 以下整段是旧版 ML Kit + ST-GCN++ 实现，已弃用 =====
   ============================================================

// ✅ 替代 OnnxRuntime：使用 CoreML 加载 ST-GCN++ .mlpackage 模型
// ✅ 替代 MLKit PoseDetection：后续用户将替换为 iOS 端的姿态识别 API（如 MediaPipe iOS / Apple Vision）

class InferenceHelper {

    // MARK: - 模型参数（与 ST-GCN++ 一致）
    let BATCH = 1, CHANNEL = 3, TIME = 32, VERTEX = 17, M = 1, BIN_TIME = 8

    // MARK: - 模型实例
    var stgcnModel: MLModel?
    var stgcnBinaryModel: MLModel? // ✅ 二分类模型
    private var poseDetector: PoseDetector? // ✅ 声明 poseDetector 实例

    init() {
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all

            print("📦 Bundle 路径: \(Bundle.main.bundlePath)")

            guard let modelURL = Bundle.main.url(forResource: "stgcnpp", withExtension: "mlmodelc") else {
                print("❌ 未找到 stgcnpp.mlmodelc 文件")
                return
            }

            print("📦 模型路径: \(modelURL.path)")

            if FileManager.default.fileExists(atPath: modelURL.path) {
                print("✅ 文件存在！准备加载模型")
            } else {
                print("❌ 找到了路径，但文件不存在！")
            }

            self.stgcnModel = try MLModel(contentsOf: modelURL, configuration: config)
            print("✅ ST-GCN++ 多分类模型加载成功")
        } catch {
            print("❌ ST-GCN++ 模型加载失败: \(error)")
        }
    }

    // MARK: - 姿态检测模型（ML Kit Accurate）
    func setupPoseDetector() {
        let options = AccuratePoseDetectorOptions()
        options.detectorMode = .singleImage
        self.poseDetector = PoseDetector.poseDetector(options: options)
    }

    // MARK: - 姿态检测（ML Kit iOS）
    func runPoseModel(on image: UIImage, completion: @escaping (_ keypoints: PoseFrame?) -> Void) {
        guard let poseDetector = self.poseDetector else {
            print("❌ poseDetector 未初始化")
            completion(nil)
            return
        }

        let pointConfThres: Float   = 0.4
        let framePassRatio: Float   = 0.4
        let cocoKptNum: Int         = 17
        let framePassCnt: Int       = Int(roundf(Float(cocoKptNum) * framePassRatio))

        let visionImage = VisionImage(image: image)
        visionImage.orientation = image.imageOrientation

        poseDetector.process(visionImage) { poses, error in
            if let error = error {
                print("❌ 姿态检测出错: \(error)")
                completion(nil)
                return
            }

            guard let poses = poses,
                  let pose  = poses.first,
                  !pose.landmarks.isEmpty else {
                print("⚠️ 当前帧未检测到人体")
                completion(nil)
                return
            }

            var keypoints: PoseFrame = Array(repeating: [0, 0, 0], count: 17)

            let cocoToMLKit: [PoseLandmarkType] = [
                .nose, .leftEye, .rightEye,
                .leftEar, .rightEar,
                .leftShoulder, .rightShoulder,
                .leftElbow, .rightElbow,
                .leftWrist, .rightWrist,
                .leftHip, .rightHip,
                .leftKnee, .rightKnee,
                .leftAnkle, .rightAnkle
            ]

            let frameWidth:  Float = Float(image.size.width)
            let frameHeight: Float = Float(image.size.height)

            var validCount = 0

            for (i, type) in cocoToMLKit.enumerated() {
                let landmark = pose.landmark(ofType: type)
                keypoints[i][0] = Float(landmark.position.x) / max(frameWidth,  1e-6)
                keypoints[i][1] = Float(landmark.position.y) / max(frameHeight, 1e-6)
                keypoints[i][2] = landmark.inFrameLikelihood
                if landmark.inFrameLikelihood > pointConfThres {
                    validCount += 1
                }
            }

            if validCount < framePassCnt {
                print("⚠️ 关键点置信度不足 (\(validCount)/\(cocoKptNum))，跳过该帧")
                completion(nil)
                return
            }

            completion(keypoints)
        }
    }

    func runStgcnModel(input poseWindow: [[[Float]]]) -> [Float]? {
        let shape = [BATCH, CHANNEL, TIME, VERTEX, M].map { NSNumber(value: $0) }

        guard let inputArray = try? MLMultiArray(shape: shape, dataType: .float32) else {
            print("❌ 创建 MLMultiArray 失败")
            return nil
        }

        for c in 0..<CHANNEL {
            for t in 0..<TIME {
                for v in 0..<VERTEX {
                    let index = c * TIME * VERTEX + t * VERTEX + v
                    let value = poseWindow[t][v][c]
                    inputArray[index] = NSNumber(value: value)
                }
            }
        }

        let input = try? MLDictionaryFeatureProvider(dictionary: ["input": inputArray])
        guard let prediction = try? stgcnModel?.prediction(from: input!) else {
            print("❌ 视频推理失败")
            return nil
        }

        guard let outKey = prediction.featureNames.first,
              let outArr = prediction.featureValue(for: outKey)?.multiArrayValue else {
            print("❌ 找不到输出特征")
            return nil
        }

        let result = (0..<outArr.count).map { i in
            Float(truncating: outArr[i])
        }
        return result
    }

    private func softmax(_ logits: [Float]) -> [Float] {
        let maxLogit = logits.max() ?? 0
        let expValues = logits.map { exp($0 - maxLogit) }
        let sumExp = expValues.reduce(0, +)
        return expValues.map { $0 / sumExp }
    }

    func close() { }
}

============================================================ */


// MARK: - PoseFrame 类型定义（保留以兼容历史代码引用）
// 17 x 3 数组：[[x,y,score], ...]（每一帧）
typealias PoseFrame = [[Float]]
