//
//  OnlineAnalysisView.swift
//  Xcup
//
//  SwiftUI 包装层，对应 VideoProcessView.swift
//  将 OnlineAnalysisViewController（UIKit）嵌入 SwiftUI 导航体系
//

import SwiftUI
import UIKit

struct OnlineAnalysisView: UIViewControllerRepresentable {

    func makeUIViewController(context: Context) -> OnlineAnalysisViewController {
        OnlineAnalysisViewController()
    }

    func updateUIViewController(_ uiViewController: OnlineAnalysisViewController, context: Context) {}
}
