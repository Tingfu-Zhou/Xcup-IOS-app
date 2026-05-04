//
//  VideoWaveResult.swift
//  Xcup
//
//  跨平台 DTO，承载 VideoMotionWaveEstimator 的最新输出。
//  与 Android 端 VideoWaveResult.java 字段保持一一对应。
//

import Foundation

final class VideoWaveResult {
    var timestampMs: Int64
    var freqHz: Float
    var confidence: Float
    var position01: Float
    var rawPosition: Float
    var motionEnergy: Float
    var periodicity: Float
    var roiX: Int
    var roiY: Int
    var roiW: Int
    var roiH: Int
    var mainDirX: Float
    var mainDirY: Float
    var locked: Bool
    var valid: Bool
    var debugInfo: String

    init(timestampMs: Int64,
         freqHz: Float,
         confidence: Float,
         position01: Float,
         rawPosition: Float,
         motionEnergy: Float,
         periodicity: Float,
         roiX: Int, roiY: Int, roiW: Int, roiH: Int,
         mainDirX: Float, mainDirY: Float,
         locked: Bool,
         valid: Bool,
         debugInfo: String) {
        self.timestampMs = timestampMs
        self.freqHz = freqHz
        self.confidence = confidence
        self.position01 = position01
        self.rawPosition = rawPosition
        self.motionEnergy = motionEnergy
        self.periodicity = periodicity
        self.roiX = roiX; self.roiY = roiY; self.roiW = roiW; self.roiH = roiH
        self.mainDirX = mainDirX; self.mainDirY = mainDirY
        self.locked = locked
        self.valid = valid
        self.debugInfo = debugInfo
    }

    static func empty() -> VideoWaveResult {
        return VideoWaveResult(
            timestampMs: 0,
            freqHz: .nan,
            confidence: 0,
            position01: 0.5,
            rawPosition: 0,
            motionEnergy: 0,
            periodicity: 0,
            roiX: 0, roiY: 0, roiW: 0, roiH: 0,
            mainDirX: 0, mainDirY: 1,
            locked: false,
            valid: false,
            debugInfo: "empty"
        )
    }

    func copy() -> VideoWaveResult {
        return VideoWaveResult(
            timestampMs: timestampMs,
            freqHz: freqHz,
            confidence: confidence,
            position01: position01,
            rawPosition: rawPosition,
            motionEnergy: motionEnergy,
            periodicity: periodicity,
            roiX: roiX, roiY: roiY, roiW: roiW, roiH: roiH,
            mainDirX: mainDirX, mainDirY: mainDirY,
            locked: locked,
            valid: valid,
            debugInfo: debugInfo
        )
    }
}
