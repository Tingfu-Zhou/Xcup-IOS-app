//
//  WebVideoView.swift
//  Xcup
//
//  SwiftUI 包装层 — 把 WebVideoViewController（UIKit）嵌入 SwiftUI 导航体系。
//

import SwiftUI
import UIKit

struct WebVideoView: UIViewControllerRepresentable {

    @Binding var isPresented: Bool

    func makeUIViewController(context: Context) -> WebVideoViewController {
        let vc = WebVideoViewController()
        vc.onDismiss = { isPresented = false }
        return vc
    }

    func updateUIViewController(_ uiViewController: WebVideoViewController, context: Context) {}
}
