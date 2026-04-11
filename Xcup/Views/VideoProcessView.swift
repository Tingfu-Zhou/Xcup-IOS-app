//
//  VideoProcessView.swift
//  Xcup
//
//  Created by tingfu on 2025/4/20.
//
// VideoProcessView.swift
import SwiftUI
import UIKit

struct VideoProcessView: UIViewControllerRepresentable {
    var videoURL: URL // ✅ 传入用户选中的视频路径

    func makeUIViewController(context: Context) -> VideoProcessViewController {
        let controller = VideoProcessViewController()
        controller.videoURL = videoURL // ✅ 赋值给控制器
        return controller
    }

    func updateUIViewController(_ uiViewController: VideoProcessViewController, context: Context) {}
}


