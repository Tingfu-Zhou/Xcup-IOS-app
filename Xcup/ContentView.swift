//
//  ContentView.swift
//  Xcup
//
//  Created by tingfu on 2025/4/20.
//

// 使用了三级加载策略
//方法1: 尝试直接获取文件 URL（最快，无需转码）
//方法2: 通过 PHAsset 获取原始视频（避免转码）
//方法3: 备用方案使用 Data（可能会转码，但确保兼容性）


import SwiftUI
import PhotosUI
import Photos
import AVFoundation

struct ContentView: View {
    @State private var selectedItem: PhotosPickerItem?
    @State private var selectedVideoURL: URL?
    @State private var showVideoProcessView = false
    @State private var showOnlineAnalysis   = false   // [新增] 在线模式开关
    // [已删除] @State private var showBluetoothView = false
    @State private var isLoadingVideo = false
    @State private var errorMessage: String?
    
    // [新增] 蓝牙连接状态
    @State private var isBluetoothConnected = false
    @State private var isBluetoothScanning = false
    @State private var isBluetoothPaused = false
    @State private var bluetoothStatusText = "未连接"
    
    // NEW: 更新提示所需状态
    @State private var optionalUpdateInfo: UpdateInfo? = nil       // 可更新
    @State private var showOptionalAlert: Bool = false             // 可更新弹窗
    @State private var requiredUpdateInfo: UpdateInfo? = nil       // 强更
    @State private var showRequiredGate: Bool = false              // 强更"拦截页"
    
    // NEW: 监听前后台，回到前台时触发检查
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationView {
            VStack(spacing: 40) {
                Spacer()

                // 1️⃣ 选择本地视频
                PhotosPicker(selection: $selectedItem,
                             matching: .videos,
                             photoLibrary: .shared()) {
                    Label("选择本地视频", systemImage: "film")
                        .font(.title2)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.purple)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                        .padding(.horizontal)
                }
                .disabled(isLoadingVideo)
                .onChange(of: selectedItem) { newItem in
                    guard let item = newItem else { return }
                    
                    Task {
                        await loadVideoURL(from: item)
                    }
                }
                
                // 显示加载状态
                if isLoadingVideo {
                    ProgressView("正在加载视频...")
                        .padding()
                }
                
                // 显示错误信息
                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .padding()
                }
                
                // [修改] 蓝牙连接按钮 - 改为一键扫描连接
                Button(action: {
                    handleBluetoothConnection()
                }) {
                    HStack {
                        if isBluetoothScanning {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: isBluetoothConnected ? "checkmark.circle.fill" : "dot.radiowaves.left.and.right")
                        }
                        Text(isBluetoothConnected ? "已连接设备" : (isBluetoothScanning ? "扫描中..." : "连接蓝牙设备"))
                    }
                    .font(.title2)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(isBluetoothConnected ? Color.green : Color.purple)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                    .padding(.horizontal)
                }
                .disabled(isBluetoothScanning)
                
                // [新增] 蓝牙连接状态显示
                Text("蓝牙状态: \(bluetoothStatusText)")
                    .font(.caption)
                    .foregroundColor(.gray)
                
                // [新增] 恢复控制按钮
                Button(action: {
                    handleResumeControl()
                }) {
                    Text("已暂停app操作，点击恢复")
                        .font(.title3)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(isBluetoothPaused ? Color.orange : Color.gray)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                        .padding(.horizontal)
                }
                .disabled(!isBluetoothPaused)
                .opacity(isBluetoothPaused ? 1.0 : 0.5)

                // [修改] 在线模式按钮（使用 ReplayKit 采集屏幕与系统音频，类似腾讯会议共享屏幕方式）
                Button(action: {
                    showOnlineAnalysis = true
                }) {
                    Label("在线模式", systemImage: "record.circle")
                        .font(.title2)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.red.opacity(0.85))
                        .foregroundColor(.white)
                        .cornerRadius(12)
                        .padding(.horizontal)
                }
                .padding(.top, 6)
                .fullScreenCover(isPresented: $showOnlineAnalysis) {
                    OnlineAnalysisView()
                        .ignoresSafeArea()
                }

                Spacer()

                // 2️⃣ 隐形 NavigationLink（带 onDisappear 手动复位）
                NavigationLink(
                    destination: Group {
                        if let url = selectedVideoURL {
                            VideoProcessView(videoURL: url)
                                .ignoresSafeArea()
                                .onDisappear {
                                    showVideoProcessView = false
                                    // 清理临时文件
                                    cleanupTempFile(at: url)
                                }
                        } else {
                            EmptyView()
                        }
                    },
                    isActive: $showVideoProcessView,
                    label: { EmptyView() }
                )
            }
            .navigationBarHidden(true)
            .onAppear {
                checkForUpdate()
                // [新增] 设置蓝牙代理
                setupBluetoothDelegate()
            }
            // NEW: 回到前台再次检查
            .onChange(of: scenePhase) { phase in
                if phase == .active { checkForUpdate() }
            }
            // NEW: 可更新弹窗（可取消）
            .alert(isPresented: $showOptionalAlert) {
                let info = optionalUpdateInfo
                return Alert(
                    title: Text("发现新版本 \(info?.latest ?? "")"),
                    message: Text(info?.notes ?? "为获得更佳体验，建议更新。"),
                    primaryButton: .default(Text("前往 App Store")) {
                        if let urlStr = info?.appStoreUrl, let url = URL(string: urlStr) {
                            UIApplication.shared.open(url)
                        }
                    },
                    secondaryButton: .cancel(Text("稍后"))
                )
            }
            // NEW: 强制更新拦截页（不可下滑关闭）
            .fullScreenCover(isPresented: $showRequiredGate) {
                RequiredUpdateView(
                    info: requiredUpdateInfo,
                    onGo: { urlStr in
                        if let u = URL(string: urlStr) { UIApplication.shared.open(u) }
                    }
                )
                .interactiveDismissDisabled(true) // 关键：禁止下拉关闭
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
    
    // [新增] 设置蓝牙代理
    private func setupBluetoothDelegate() {
        // 使用 StateObserver 替代直接的代理模式
        // 注意：SwiftUI的struct不需要weak self，SwiftUI会自动管理生命周期
        BluetoothManager.shared.stateObserver = BluetoothStateObserver(
            onConnect: {
                self.isBluetoothConnected = true
                self.isBluetoothScanning = false
                self.bluetoothStatusText = "已连接"
            },
            onDisconnect: {
                self.isBluetoothConnected = false
                self.isBluetoothPaused = false
                self.bluetoothStatusText = "未连接"
            },
            onPause: {
                self.isBluetoothPaused = true
            },
            onResume: {
                self.isBluetoothPaused = false
            }
        )
    }
    
    // [新增] 处理蓝牙连接
    private func handleBluetoothConnection() {
        if isBluetoothConnected {
            // 已连接，点击断开
            BluetoothManager.shared.disconnect()
            bluetoothStatusText = "未连接"
        } else {
            // 未连接，开始扫描
            isBluetoothScanning = true
            bluetoothStatusText = "扫描中..."
            BluetoothManager.shared.startScanAndConnect()
            
            // 20秒超时
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                if !self.isBluetoothConnected {
                    self.isBluetoothScanning = false
                    self.bluetoothStatusText = "扫描超时"
                }
            }
        }
    }
    
    // [新增] 处理恢复控制
    private func handleResumeControl() {
        BluetoothManager.shared.resumeAppControl()
    }
    
    // NEW: 统一的更新检查入口（静默失败）
    private func checkForUpdate() {
        UpdateService.shared.check { result in
            switch result {
            case .none:
                break
            case .optional(let info):
                self.optionalUpdateInfo = info
                self.showOptionalAlert = true
            case .required(let info):
                self.requiredUpdateInfo = info
                self.showRequiredGate = true
            }
        }
    }
    
    // MARK: - 优化的视频加载方法
    private func loadVideoURL(from item: PhotosPickerItem) async {
        isLoadingVideo = true
        errorMessage = nil
        
        do {
            // 方法1: 尝试直接获取文件 URL (对于本地视频最快)
            if let url = try await loadAsFileURL(from: item) {
                await MainActor.run {
                    self.selectedItem = nil
                    self.showVideoProcessView = false
                    self.selectedVideoURL = url
                    self.isLoadingVideo = false
                    DispatchQueue.main.async {
                        self.showVideoProcessView = true
                    }
                }
                print("✅ 方法1成功: 直接获取文件 URL")
                return
            }
            
            // 方法2: 从相册导出视频 (避免转码)
            if let asset = try await loadPHAsset(from: item) {
                let url = try await exportVideo(from: asset)
                await MainActor.run {
                    self.selectedItem = nil
                    self.showVideoProcessView = false
                    self.selectedVideoURL = url
                    self.isLoadingVideo = false
                    DispatchQueue.main.async {
                        self.showVideoProcessView = true
                    }
                }
                print("✅ 方法2成功: 从 PHAsset 导出")
                return
            }
            
            // 方法3: 最后的备用方案 - 使用 Data (可能会转码)
            let url = try await loadAsData(from: item)
            await MainActor.run {
                self.selectedItem = nil
                self.showVideoProcessView = false
                self.selectedVideoURL = url
                self.isLoadingVideo = false
                DispatchQueue.main.async {
                    self.showVideoProcessView = true
                }
            }
            print("⚠️ 方法3: 使用 Data 方式加载（可能较慢）")
            
        } catch {
            await MainActor.run {
                self.errorMessage = "视频加载失败: \(error.localizedDescription)"
                self.isLoadingVideo = false
                self.selectedItem = nil
            }
            print("❌ 视频加载失败: \(error)")
        }
    }
    
    // 方法1: 尝试直接获取文件 URL
    private func loadAsFileURL(from item: PhotosPickerItem) async throws -> URL? {
        // 尝试作为文件 URL 加载
        return try await item.loadTransferable(type: URL.self)
    }
    
    // 方法2: 获取 PHAsset
    private func loadPHAsset(from item: PhotosPickerItem) async throws -> PHAsset? {
        guard let identifier = item.itemIdentifier else { return nil }
        
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        return fetchResult.firstObject
    }
    
    // 从 PHAsset 导出视频（避免转码）
    private func exportVideo(from asset: PHAsset) async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.version = .original  // 请求原始版本
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true  // 允许从 iCloud 下载
            
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                guard let urlAsset = avAsset as? AVURLAsset else {
                    // 如果不是 URL Asset，则导出到临时文件
                    if let avAsset = avAsset {
                        Task {
                            do {
                                let url = try await self.exportAVAsset(avAsset)
                                continuation.resume(returning: url)
                            } catch {
                                continuation.resume(throwing: error)
                            }
                        }
                    } else {
                        continuation.resume(throwing: NSError(domain: "VideoLoad", code: -1,
                                                            userInfo: [NSLocalizedDescriptionKey: "无法获取视频资源"]))
                    }
                    return
                }
                
                // 直接使用原始 URL
                let originalURL = urlAsset.url
                
                // 复制到临时目录（避免权限问题）
                let tmpURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + ".mp4")
                
                do {
                    try FileManager.default.copyItem(at: originalURL, to: tmpURL)
                    continuation.resume(returning: tmpURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // 导出 AVAsset 到文件
    private func exportAVAsset(_ asset: AVAsset) async throws -> URL {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mp4")
        
        // 使用 passthrough 预设避免重新编码
        guard let exportSession = AVAssetExportSession(asset: asset,
                                                      presetName: AVAssetExportPresetPassthrough) else {
            throw NSError(domain: "VideoExport", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "无法创建导出会话"])
        }
        
        exportSession.outputURL = tmpURL
        exportSession.outputFileType = .mp4
        
        await exportSession.export()
        
        if exportSession.status == .completed {
            return tmpURL
        } else {
            throw exportSession.error ?? NSError(domain: "VideoExport", code: -1,
                                               userInfo: [NSLocalizedDescriptionKey: "导出失败"])
        }
    }
    
    // 方法3: 备用方案 - 使用 Data
    private func loadAsData(from item: PhotosPickerItem) async throws -> URL {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mp4")
        
        if let data = try await item.loadTransferable(type: Data.self) {
            try data.write(to: tmpURL, options: .atomic)
            return tmpURL
        } else {
            throw NSError(domain: "VideoLoad", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "无法加载视频数据"])
        }
    }
    
    // 清理临时文件
    private func cleanupTempFile(at url: URL) {
        if url.path.contains(NSTemporaryDirectory()) {
            try? FileManager.default.removeItem(at: url)
            print("🗑️ 已清理临时文件: \(url.lastPathComponent)")
        }
    }
}

// NEW: 强制更新拦截视图（全屏）
private struct RequiredUpdateView: View {
    let info: UpdateInfo?
    let onGo: (String) -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.9).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundColor(.white)
                Text("必须更新以继续使用")
                    .font(.title2).bold().foregroundColor(.white)
                Text(info?.notes ?? "为保证兼容性与稳定性，请更新到最新版。")
                    .foregroundColor(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button(action: {
                    if let urlStr = info?.appStoreUrl { onGo(urlStr) }
                }) {
                    Text("前往 App Store 更新")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.white)
                        .foregroundColor(.black)
                        .cornerRadius(12)
                        .padding(.horizontal, 24)
                }
                Text("当前版本已不再受支持。")
                    .foregroundColor(.white.opacity(0.7))
                    .font(.footnote)
                    .padding(.top, 8)
            }
        }
    }
}
