//
//  InferenceHelper.swift
//  Xcup
//
//  Created by tingfu on 2025/4/20.
//


//  对应 Android Java: InferenceHelper.java
//

import Foundation
import CoreML
import Vision
import UIKit
import MLKitPoseDetectionAccurate
import MLKitVision


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
                config.computeUnits = .all // 自动使用 ANE / GPU / CPU

                print("📦 Bundle 路径: \(Bundle.main.bundlePath)")

                // ✅ 加载多分类模型
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
                // ---------- DEBUG: 打印模型 I/O ----------
                //if let model = self.stgcnModel {
                    //let io = model.modelDescription
                    //print("🔍 ST-GCN++ 输入键: \(io.inputDescriptionsByName.keys)")
                    //print("🔍 ST-GCN++ 输出键: \(io.outputDescriptionsByName.keys)")
                //}
                
                // ✅ 加载二分类模型
                //if let binaryModelURL = Bundle.main.url(forResource: "stgcnpp_binary", withExtension: "mlmodelc") {
                    //print("📦 二分类模型路径: \(binaryModelURL.path)")
                    
                    //if FileManager.default.fileExists(atPath: binaryModelURL.path) {
                        //print("✅ 二分类文件存在！准备加载模型")
                        //self.stgcnBinaryModel = try MLModel(contentsOf: binaryModelURL, configuration: config)
                        //print("✅ ST-GCN++ 二分类模型加载成功")
                    //} else {
                        //print("⚠️ 找到了二分类模型路径，但文件不存在！")
                    //}
                //} else {
                    //print("⚠️ 未找到 stgcnpp_binary.mlmodelc 文件")
                //}

            } catch {
                print("❌ ST-GCN++ 模型加载失败: \(error)")
            }
        }


    
    // MARK: - 姿态检测模型
    // Accurate pose detector on static images, when depending on the
    // PoseDetectionAccurate SDK
    func setupPoseDetector() {
            let options = AccuratePoseDetectorOptions()
            options.detectorMode = .singleImage
            self.poseDetector = PoseDetector.poseDetector(options: options)
        }

    // MARK: - 姿态检测（ML Kit iOS）
    // ✅ 示例方法：将 UIImage 图像输入姿态模型，提取 COCO17 关键点（返回 [1,1,17,3] 的 COCO 关键点数组。每个点格式为 [x, y, confidence]。
    //   ML Kit Pose Detection 返回的是 33 点式全身骨架，需要映射成 COCO 17
    func runPoseModel(on image: UIImage, completion: @escaping (_ keypoints: PoseFrame?) -> Void) {
        guard let poseDetector = self.poseDetector else {
            print("❌ poseDetector 未初始化")
            completion(nil)
            return
        }

        // 置信度阈值常量
        let pointConfThres: Float   = 0.4         // 单点置信度阈值
        let framePassRatio: Float   = 0.4         // 帧级通过比例 (40%)
        let cocoKptNum: Int         = 17          // COCO 关键点数量
        let framePassCnt: Int       = Int(roundf(Float(cocoKptNum) * framePassRatio)) // 7

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
            
            var validCount = 0 // [新增] 满足单点阈值的关键点计数
            
            for (i, type) in cocoToMLKit.enumerated() {
                let landmark = pose.landmark(ofType: type)
                
                // ✅ 使用与训练时相同的归一化方式（PreNormalize2D）
                // [MOD] 对齐 Windows：先归一化到 [0,1]，再在 32 帧窗口上做 bbox 归一化（PreNormalize2D）
                keypoints[i][0] = Float(landmark.position.x) / max(frameWidth,  1e-6)
                keypoints[i][1] = Float(landmark.position.y) / max(frameHeight, 1e-6)
                keypoints[i][2] = landmark.inFrameLikelihood               // 置信度无需归一化
                
                // 统计超阈值关键点
                if landmark.inFrameLikelihood > pointConfThres {
                    validCount += 1
                }
            }

            // 帧级置信度过滤
            if validCount < framePassCnt {
                print("⚠️ 关键点置信度不足 (\(validCount)/\(cocoKptNum))，跳过该帧")
                completion(nil)
                return
            }

            completion(keypoints)
        }
    }


    // MARK: - 多分类 ST-GCN++ 推理
    /*
     * ST-GCN++ 多分类器
     * @param poseWindow [T=32][V=17][C=3]
     * @return 当前窗口样本的预测结果
     * - 模型实际输出 shape = [1, N]，即 batch size = 1，类别数 = N
     * - CoreML MLMultiArray 拉平成一维数组后，result[i] 就是第 i 个类别的 logit（未归一化分数）
     * - 本质上与 Android 端 outputArray[0] 完全一致
     * 每个值代表对应动作类别的未归一化分数（logit）
     * 注意：ST-GCN++模型输出的是 logits（未归一化分数），不是概率
     */

    func runStgcnModel(input poseWindow: [[[Float]]]) -> [Float]? {
        
        // ---------- DEBUG: 检查窗口尺寸 ----------
        //print("🧩 poseWindow.count = \(poseWindow.count)  // 期望 TIME")
        //print("🧩 poseWindow[0].count = \(poseWindow.first?.count ?? -1)  // 期望 TIME")
        // -----------------------------------------
        
        // ✅ 格式转换：shape [1, 3, TIME, 17, 1] -> 转换为 MLMultiArray
        let shape = [BATCH, CHANNEL, TIME, VERTEX, M].map { NSNumber(value: $0) }
        let totalCount = BATCH * CHANNEL * TIME * VERTEX * M
        //let idx = ((((0 * CHANNEL + c) * TIME + t) * VERTEX) + v) * M + 0，这里M=1, 所以目前的不同修改

        guard let inputArray = try? MLMultiArray(shape: shape, dataType: .float32) else {
            print("❌ 创建 MLMultiArray 失败")
            return nil
        }

        for c in 0..<CHANNEL {
            for t in 0..<TIME {
                for v in 0..<VERTEX {
                    let index = c * TIME * VERTEX + t * VERTEX + v
                    let value = poseWindow[t][v][c] // ⚠️ 需保证维度一致
                    inputArray[index] = NSNumber(value: value)
                }
            }
        }

        // ✅ 构造模型输入
        let input = try? MLDictionaryFeatureProvider(dictionary: ["input": inputArray])
        guard let prediction = try? stgcnModel?.prediction(from: input!) else {
            print("❌ 视频推理失败")
            return nil
        }
        
        // ---------- DEBUG: 查看可用输出 ----------
        //print("🔍 prediction.featureNames = \(prediction.featureNames)")
        // -----------------------------------------
        
        /// ① 取“唯一”输出键（测试模型打印为 ["var_608"]）
        guard let outKey = prediction.featureNames.first,
              let outArr = prediction.featureValue(for: outKey)?.multiArrayValue else {
            print("❌ 找不到输出特征")
            return nil
        }
        /// ② 打印 shape 便于确认类别数
        //print("🔍 输出 shape = \(outArr.shape)") // 形如 [1, num_classes]
        /// ③ 转为 [Float] 返回
        let result = (0..<outArr.count).map { i in
            Float(truncating: outArr[i])
        }
        // debug
        //print("ST-GCN++ 原始输出: \(result)")
        return result

    }
    // MARK: - ST-GCN++ 推理（二分类）
    /*
    // ✅ 新增：二分类模型推理，返回目标动作(label 0)的概率
    func runBinary(input poseWindow: [[[Float]]]) -> Float? {
        guard let binaryModel = stgcnBinaryModel else {
            print("❌ 二分类模型未加载")
            return nil
        }
            
        // ✅ 格式转换：shape [1, 3, BIN_TIME, 17, 1] -> 转换为 MLMultiArray
        let shape = [BATCH, CHANNEL, BIN_TIME, VERTEX, M].map { NSNumber(value: $0) }
            
        guard let inputArray = try? MLMultiArray(shape: shape, dataType: .float32) else {
            print("❌ 创建 MLMultiArray 失败")
            return nil
        }
            
        for c in 0..<CHANNEL {
            for t in 0..<BIN_TIME {
                for v in 0..<VERTEX {
                    let index = c * BIN_TIME * VERTEX + t * VERTEX + v
                    let value = poseWindow[t][v][c]
                    inputArray[index] = NSNumber(value: value)
                }
            }
        }
            
        // ✅ 构造模型输入
        let input = try? MLDictionaryFeatureProvider(dictionary: ["input": inputArray])
        guard let prediction = try? binaryModel.prediction(from: input!) else {
            print("❌ 二分类推理失败")
            return nil
        }
            
        // ✅ 获取输出
        guard let outKey = prediction.featureNames.first,
                let outArr = prediction.featureValue(for: outKey)?.multiArrayValue else {
            print("❌ 找不到二分类输出特征")
            return nil
        }
            
        // ✅ 转换为 logits
        let logits = (0..<outArr.count).map { i in
            Float(truncating: outArr[i])
        }
            
        //print("二分类 logits: \(logits)")
            
        // ✅ 应用 softmax 获得概率
        let probabilities = softmax(logits)
        //print("二分类概率: \(probabilities)")
            
        // ✅ 返回目标动作(label 0)的概率
        return probabilities.first
    }
     */
        
    // MARK: - Softmax 函数
    private func softmax(_ logits: [Float]) -> [Float] {
        // 防止数值溢出，减去最大值
        let maxLogit = logits.max() ?? 0
        let expValues = logits.map { exp($0 - maxLogit) }
        let sumExp = expValues.reduce(0, +)
        return expValues.map { $0 / sumExp }
    }
    
    // MARK: - 清理方法
    func close() {
        // CoreML 不需要手动释放资源，留空
    }
}

// MARK: - PoseFrame 类型定义
// ✅ 模拟 [1, 1, 17, 3] 格式关键点
// Swift 中推荐使用类型别名或 struct

typealias PoseFrame = [[Float]] // 17 x 3 数组：[[x,y,score], ...]（每一帧）
