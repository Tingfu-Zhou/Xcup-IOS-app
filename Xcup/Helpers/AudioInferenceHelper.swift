//
//  AudioInferenceHelper.swift
//  Xcup
//
//  Created by tingfu on 2025/4/20.
//


import Foundation
import TensorFlowLite

class AudioInferenceHelper {

    // MARK: - 模型参数
    private let SAMPLE_RATE = 16000
    private let INPUT_LENGTH = 32000 // 输入 2 秒音频数据
    private let EMBEDDING_SIZE = 1024

    private var yamnetInterpreter: Interpreter!
    private var classifierInterpreter: Interpreter!

    init() {
        do {
            guard let yamnetPath = Bundle.main.path(forResource: "yamnet", ofType: "tflite"),
                  let classifierPath = Bundle.main.path(forResource: "yamnet_finetuned", ofType: "tflite") else {
                print("❌ 模型文件未找到")
                return
            }

            var options = Interpreter.Options()
            options.threadCount = 2

            // ① 创建 Interpreter
            yamnetInterpreter      = try Interpreter(modelPath: yamnetPath,      options: options)
            classifierInterpreter  = try Interpreter(modelPath: classifierPath,  options: options)

            // ② 先把可变维度改成我们需要的 [32000]
            try yamnetInterpreter.resizeInput(at: 0, to: [INPUT_LENGTH])

            // ③ 再分配 tensor 内存
            try yamnetInterpreter.allocateTensors()
            try classifierInterpreter.allocateTensors()

            print("✅ 音频模型初始化成功")
        } catch {
            print("❌ 初始化失败: \(error)")
        }
    }


    /// 执行一次音频推理流程：YAMNet → 分类器
    /// - Parameter audioBuffer: 长度为 32000 的 Float 数组（2 秒音频）
    /// - Returns: (类别索引, 置信度, 完整概率数组)
    ///   probs 顺序为 [sex, oral, noise]；无效结果时 index = -1、probs 为空数组
    func predict(audioBuffer: [Float]) -> (index: Int, confidence: Float, probs: [Float]) {
        guard audioBuffer.count == INPUT_LENGTH else {
            print("❌ 音频长度不正确，应为 32000，当前为 \(audioBuffer.count)")
            return (-1, 0, [])
        }

        do {
            let inputShape = try yamnetInterpreter.input(at: 0).shape.dimensions
            //print("🧪 当前 YAMNet 输入 shape = \(inputShape)")   // 应该看到 [32000]
            // 1. YAMNet 推理（输入 shape: [32000]）
            let yamnetInputData = toData(from: audioBuffer)
            //print("🧪 准备推理 YAMNet")
            try yamnetInterpreter.copy(yamnetInputData, toInputAt: 0)
            try yamnetInterpreter.invoke()
            //print("✅ YAMNet 推理完成")
            
            // ✅ 打印所有输出 Tensor 的维度，用于调试
            //for i in 0..<yamnetInterpreter.outputTensorCount {
                //let shape = try yamnetInterpreter.output(at: i).shape.dimensions
                //print("🧪 YAMNet 输出 [\(i)] 维度: \(shape)")
            //}

            // YAMNet 输出 shape 为 [num_frames, 1024]
            let outputTensor = try yamnetInterpreter.output(at: 1)
            let outputShape = outputTensor.shape.dimensions
            let outputData = outputTensor.data.toArray(type: Float32.self)
            let numFrames = outputShape[0]

            // 2. 平均输出特征
            var meanEmbedding = [Float](repeating: 0, count: EMBEDDING_SIZE)
            for i in 0..<numFrames {
                for j in 0..<EMBEDDING_SIZE {
                    meanEmbedding[j] += outputData[i * EMBEDDING_SIZE + j]
                }
            }
            for j in 0..<EMBEDDING_SIZE {
                meanEmbedding[j] /= Float(numFrames)
            }
            
            
            // 3. 分类器推理
            //let clsInputShape = try classifierInterpreter.input(at: 0).shape.dimensions
            //print("🧪 分类器输入 shape =", clsInputShape)
            let classifierInputData = toData(from: meanEmbedding)
            try classifierInterpreter.copy(classifierInputData, toInputAt: 0)
            try classifierInterpreter.invoke()

            let classOutput = try classifierInterpreter.output(at: 0)
            let scores = classOutput.data.toArray(type: Float32.self)

            if let maxIndex = scores.argmax() {
                let confidence = scores[maxIndex] // 概率分布中最大值
                //print("✅ 音频推理结果: 类别 \(maxIndex), 置信度 \(confidence)")
                return (maxIndex, confidence, scores)
            } else {
                return (-1, 0, [])
            }

        } catch {
            print("❌ 音频推理失败: \(error)")
            return (-1, 0, [])
        }
    }

    func close() {
        yamnetInterpreter = nil
        classifierInterpreter = nil
    }
}

// MARK: - 输入数据类型
func toData(from array: [Float]) -> Data {
    return array.withUnsafeBufferPointer {
        Data(buffer: $0)
    }
}


// MARK: - Data 解析工具（转为 Float 数组）
extension Data {
    func toArray<T>(type: T.Type) -> [T] {
        return withUnsafeBytes {
            Array($0.bindMemory(to: type))
        }
    }
}

// MARK: - Argmax 工具
extension Array where Element == Float {
    func argmax() -> Int? {
        guard let max = self.max(), let idx = self.firstIndex(of: max) else { return nil }
        return idx
    }
}
