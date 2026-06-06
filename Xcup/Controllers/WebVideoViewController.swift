//
//  WebVideoViewController.swift
//  Xcup
//
//  网页视频模式：内置 WKWebView 浏览视频网站，嗅探视频流（.mp4 / .m3u8），
//  用户点"开始分析"后跳转到 WebVideoAnalysisViewController 用 AVPlayer 重放 + 本地分析。
//
//  对应 Android: WebVideoActivity.java
//
//  WKWebView 几个不可少的处理（详见任务备忘）：
//   1) WKUIDelegate.createWebViewWith → 蜜罐 WKWebView，拦截 window.open 广告弹窗
//   2) WKNavigationDelegate.decidePolicyFor → 拦截跨站主窗口跳转
//   3) WKContentRuleList → 屏蔽广告域名
//   4) JS 注入（documentStart）→ monkey-patch fetch / XHR / HTMLMediaElement.src，
//      把视频 URL + UA + Referer 通过 messageHandler 送回 native
//   5) 起播位置：JS 读 document.querySelector('video').currentTime
//

import UIKit
import WebKit
import AVFoundation

class WebVideoViewController: UIViewController {

    // MARK: - 由 SwiftUI 包装层注入：关闭整页（fullScreenCover）
    var onDismiss: (() -> Void)?

    // MARK: - UI
    private let urlBar = UITextField()
    private let goButton = UIButton(type: .system)
    private let backButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let analyzeButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private var webView: WKWebView!

    // MARK: - 嗅探状态
    private var sniffedVideoURL: URL?
    private var sniffedReferer: String?
    private var sniffedUserAgent: String?
    private var lastPageURL: URL?
    private var pageRootHost: String?

    // 评分覆盖判定：相同分数不允许互相覆盖（"真视频先到先得"）。
    // 同一个 <video> 元素的 src 变化（typical: 广告→真视频）走 sameElement 特例，
    // 不受 score 比较约束。
    // 网络层 / 元素层捕获兜底分 = 1；后面如需引入更强的来源分（manifest > variant 等）
    // 直接调整 scoreForSource() 即可。
    private var currentBestElementId: String?
    private var currentBestScore: Int = 0

    // 蜜罐 WebViews + 它们的代理（防止被释放）
    private var honeypotEntries: [(view: WKWebView, delegate: HoneypotNavDelegate)] = []

    // JS 轮询 <video>.src / currentTime 的 timer
    private var jsPollTimer: Timer?

    // 用户在地址栏主动输入时，下一次 navigation 跳过跨站检查
    private var allowNextNavigation = false

    // 已经标记过"嗅到了，按钮可点"的状态

    // 桌面 Chrome UA（很多视频站会按 UA 区分）
    private let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Safari/605.1.15"

    // 空状态提示视图（未加载任何页面时显示在 WebView 区域）
    private let emptyHintView = UIView()

    // 广告域名（含子域）— 与 Android 端一致
    private let adHosts: [String] = [
        "ero-labs.top",
        "trafficstars.com",
        "tsyndicate.com",
        "juicyads.com",
        "exoclick.com",
        "exosrv.com",
        "adsterra.net",
        "adsterra.com",
        "popads.net",
        "revcontent.com",
        "doubleclick.net",
        "googlesyndication.com"
    ]

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupUI()
        setupWebView()
        setupEmptyHint()
        startJsPollLoop()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        jsPollTimer?.invalidate()
        jsPollTimer = nil
    }

    deinit {
        jsPollTimer?.invalidate()
        // 移除所有 message handler 避免循环引用
        let ucc = webView?.configuration.userContentController
        ucc?.removeScriptMessageHandler(forName: "videoSniff")
    }

    // MARK: - UI

    private func setupUI() {
        view.backgroundColor = UIColor(white: 0.08, alpha: 1.0)

        // 顶部地址栏容器
        let topBar = UIView()
        topBar.backgroundColor = UIColor(white: 0.12, alpha: 1.0)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        urlBar.translatesAutoresizingMaskIntoConstraints = false
        urlBar.backgroundColor = UIColor(white: 0.22, alpha: 1.0)
        urlBar.textColor = .white
        urlBar.tintColor = .white
        urlBar.font = .systemFont(ofSize: 14)
        urlBar.attributedPlaceholder = NSAttributedString(
            string: "粘贴视频网页链接 (https://...)",
            attributes: [.foregroundColor: UIColor(white: 1, alpha: 0.5)]
        )
        urlBar.borderStyle = .roundedRect
        urlBar.keyboardType = .URL
        urlBar.returnKeyType = .go
        urlBar.autocapitalizationType = .none
        urlBar.autocorrectionType = .no
        urlBar.clearButtonMode = .whileEditing
        urlBar.delegate = self
        topBar.addSubview(urlBar)

        configureBarButton(closeButton, systemName: "xmark", action: #selector(onCloseTapped))
        configureBarButton(backButton, systemName: "chevron.backward", action: #selector(onBackTapped))
        configureBarButton(forwardButton, systemName: "chevron.forward", action: #selector(onForwardTapped))
        topBar.addSubview(closeButton)
        topBar.addSubview(backButton)
        topBar.addSubview(forwardButton)

        goButton.translatesAutoresizingMaskIntoConstraints = false
        goButton.setTitle("打开", for: .normal)
        goButton.setTitleColor(.white, for: .normal)
        goButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        goButton.addTarget(self, action: #selector(onGoTapped), for: .touchUpInside)
        topBar.addSubview(goButton)

        // 状态条
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.text = "尚未嗅到视频流"
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        statusLabel.textAlignment = .center
        view.addSubview(statusLabel)

        // 开始分析按钮（底部）
        analyzeButton.translatesAutoresizingMaskIntoConstraints = false
        analyzeButton.setTitle("开始分析（尚未嗅到视频）", for: .normal)
        analyzeButton.setTitleColor(.white, for: .normal)
        analyzeButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        analyzeButton.backgroundColor = UIColor.gray
        analyzeButton.layer.cornerRadius = 24
        analyzeButton.layer.masksToBounds = true
        analyzeButton.isEnabled = false
        analyzeButton.addTarget(self, action: #selector(onAnalyzeTapped), for: .touchUpInside)
        view.addSubview(analyzeButton)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 48),

            closeButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 8),
            closeButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),

            backButton.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 4),
            backButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 32),
            backButton.heightAnchor.constraint(equalToConstant: 32),

            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 4),
            forwardButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            forwardButton.widthAnchor.constraint(equalToConstant: 32),
            forwardButton.heightAnchor.constraint(equalToConstant: 32),

            urlBar.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: 8),
            urlBar.trailingAnchor.constraint(equalTo: goButton.leadingAnchor, constant: -8),
            urlBar.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            urlBar.heightAnchor.constraint(equalToConstant: 32),

            goButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -8),
            goButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            goButton.widthAnchor.constraint(equalToConstant: 44),

            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            statusLabel.heightAnchor.constraint(equalToConstant: 22),

            analyzeButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            analyzeButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            analyzeButton.widthAnchor.constraint(equalToConstant: 280),
            analyzeButton.heightAnchor.constraint(equalToConstant: 48)
        ])
    }

    private func configureBarButton(_ button: UIButton, systemName: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: systemName), for: .normal)
        button.tintColor = .white
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    // MARK: - WebView 设置

    private func setupWebView() {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []  // 自动播放，便于嗅探

        // 1) JS 注入：document_start 时机 monkey-patch fetch / XHR / HTMLMediaElement.src
        let ucc = WKUserContentController()
        let userScript = WKUserScript(
            source: Self.sniffJSSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false   // 子 frame 也注入
        )
        ucc.addUserScript(userScript)
        ucc.add(self, name: "videoSniff")
        cfg.userContentController = ucc

        // 2) WKContentRuleList：广告域名屏蔽
        compileAdBlockRuleList { [weak self] list in
            guard let self = self, let list = list else { return }
            DispatchQueue.main.async {
                self.webView?.configuration.userContentController.add(list)
            }
        }

        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = desktopUA

        view.addSubview(webView)
        view.sendSubviewToBack(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: analyzeButton.topAnchor, constant: -8)
        ])
    }

    // MARK: - 空状态提示

    private func setupEmptyHint() {
        emptyHintView.translatesAutoresizingMaskIntoConstraints = false
        emptyHintView.backgroundColor = UIColor(white: 0.08, alpha: 1.0)
        view.addSubview(emptyHintView)
        view.bringSubviewToFront(emptyHintView)

        let icon = UIImageView(image: UIImage(systemName: "link.badge.plus",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 48, weight: .regular)))
        icon.tintColor = UIColor(white: 1, alpha: 0.55)
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = UILabel()
        title.text = "尚未打开任何网页"
        title.font = .systemFont(ofSize: 17, weight: .medium)
        title.textColor = UIColor(white: 1, alpha: 0.9)
        title.textAlignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false

        let desc = UILabel()
        desc.text = "请在上方地址栏粘贴或输入视频网页链接（https://…），\n按回车或点击「打开」开始浏览。"
        desc.font = .systemFont(ofSize: 13, weight: .regular)
        desc.textColor = UIColor(white: 1, alpha: 0.6)
        desc.textAlignment = .center
        desc.numberOfLines = 0
        desc.translatesAutoresizingMaskIntoConstraints = false

        [icon, title, desc].forEach { emptyHintView.addSubview($0) }

        NSLayoutConstraint.activate([
            emptyHintView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor),
            emptyHintView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyHintView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyHintView.bottomAnchor.constraint(equalTo: analyzeButton.topAnchor, constant: -8),

            icon.centerXAnchor.constraint(equalTo: emptyHintView.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: emptyHintView.centerYAnchor, constant: -36),
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),

            title.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12),
            title.centerXAnchor.constraint(equalTo: emptyHintView.centerXAnchor),

            desc.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            desc.leadingAnchor.constraint(equalTo: emptyHintView.leadingAnchor, constant: 24),
            desc.trailingAnchor.constraint(equalTo: emptyHintView.trailingAnchor, constant: -24),
        ])
    }

    private func setEmptyHintVisible(_ visible: Bool) {
        emptyHintView.isHidden = !visible
    }

    // MARK: - 顶部按钮 / 地址栏

    @objc private func onCloseTapped() {
        onDismiss?()
    }
    @objc private func onGoTapped() {
        loadFromUrlBar()
    }
    @objc private func onBackTapped() {
        if webView.canGoBack { webView.goBack() }
    }
    @objc private func onForwardTapped() {
        if webView.canGoForward { webView.goForward() }
    }
    private func loadFromUrlBar() {
        urlBar.resignFirstResponder()
        var text = (urlBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "https://" + text
        }
        guard let url = URL(string: text) else { return }
        allowNextNavigation = true   // 用户主动输入，跳过跨站检查
        webView.load(URLRequest(url: url))
    }

    // MARK: - 开始分析

    @objc private func onAnalyzeTapped() {
        guard let videoURL = sniffedVideoURL else { return }

        // 先取 currentTime 作为起播位置
        webView.evaluateJavaScript("(function(){var v=document.querySelector('video');return v?v.currentTime:0;})();") { [weak self] result, _ in
            guard let self = self else { return }
            let startSec = (result as? Double) ?? Double((result as? NSNumber)?.doubleValue ?? 0)
            let startMs = Int64(max(0, startSec) * 1000)

            // 再拿 Cookie
            self.collectCookies(for: videoURL) { cookies in
                var headers: [String: String] = [:]
                if let ua = self.sniffedUserAgent { headers["User-Agent"] = ua } else { headers["User-Agent"] = self.desktopUA }
                if let ref = self.sniffedReferer ?? self.lastPageURL?.absoluteString { headers["Referer"] = ref }
                if !cookies.isEmpty { headers["Cookie"] = cookies }

                self.presentAnalysisVC(videoURL: videoURL, headers: headers, startMs: startMs)
            }
        }
    }

    private func presentAnalysisVC(videoURL: URL, headers: [String: String], startMs: Int64) {
        let vc = WebVideoAnalysisViewController()
        vc.videoURL = videoURL
        vc.requestHeaders = headers
        vc.startMs = startMs
        vc.modalPresentationStyle = .fullScreen
        present(vc, animated: true)
    }

    // MARK: - Cookie 收集（按 host 过滤）

    private func collectCookies(for url: URL, completion: @escaping (String) -> Void) {
        guard let host = url.host else { completion(""); return }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        store.getAllCookies { cookies in
            let pairs = cookies
                .filter { Self.cookieMatchesHost($0, host: host) }
                .map { "\($0.name)=\($0.value)" }
            completion(pairs.joined(separator: "; "))
        }
    }

    private static func cookieMatchesHost(_ c: HTTPCookie, host: String) -> Bool {
        // 简化匹配：cookie.domain 是 host 后缀
        var d = c.domain
        if d.hasPrefix(".") { d.removeFirst() }
        return host == d || host.hasSuffix("." + d)
    }

    // MARK: - 嗅探入口（来自 JS / shouldStartLoad / JS poll）
    //
    // 覆盖判定规则（"真视频先到先得"）：
    //   1) looksLikeVideoURL：严格后缀白名单 + 分片/字幕黑名单 + fMP4 分片识别
    //   2) looksLikePreviewUrl：trickplay / sprite / 缩略图条排除
    //   3) 同 URL 去重（不刷 UI 也不打日志）
    //   4) **核心**：
    //        - 首次 → 接受
    //        - elementId == currentBestElementId （同 <video> 元素 src 变化）→ 接受
    //          （典型例：Pornhub 主播放器从广告 src 切到真视频 src）
    //        - score > currentBestScore（严格大于！）→ 接受
    //        - 其它 → 拒绝（同分不允许互相覆盖，防止 missav 推荐位顶掉真视频）

    private func handleSniffedURL(_ urlString: String,
                                  source: String,
                                  ua: String? = nil,
                                  referer: String? = nil,
                                  elementId: String? = nil) {
        // 第一道：是不是"看起来可播放的视频" URL
        guard isLikelyVideoURL(urlString) else { return }
        // 第二道：是不是 trickplay / 预览 / 缩略图条
        if looksLikePreviewUrl(urlString) {
            print("⏭️ [WebVideo] 跳过预览/trickplay: \(urlString)")
            return
        }
        // 同 URL 去重：不刷 UI 也不打日志
        if let cur = sniffedVideoURL, cur.absoluteString == urlString { return }

        // 兜底来源分；后续要引入更强的来源分（manifest > variant > network）改这里
        let score = scoreForSource(source)

        // 覆盖判定
        let acceptReason: String
        if sniffedVideoURL == nil {
            acceptReason = "first"
        } else if let eid = elementId, !eid.isEmpty, eid == currentBestElementId {
            // 同元素 src 变化：典型 Pornhub 广告→真视频，绕过 score 比较
            acceptReason = "sameElement(\(eid))"
        } else if score > currentBestScore {
            // 严格大于：相同分数不允许互相覆盖
            acceptReason = "higherScore(\(currentBestScore)→\(score))"
        } else {
            print("⏭️ [WebVideo] 同分不覆盖（src=\(source), eid=\(elementId ?? "-")）: \(urlString)")
            return
        }

        guard let url = URL(string: urlString) else { return }

        sniffedVideoURL = url
        currentBestScore = score
        if let eid = elementId, !eid.isEmpty { currentBestElementId = eid }
        if let ua = ua, !ua.isEmpty { sniffedUserAgent = ua }
        if let r = referer, !r.isEmpty { sniffedReferer = r }
        if sniffedReferer == nil { sniffedReferer = lastPageURL?.absoluteString }
        if sniffedUserAgent == nil { sniffedUserAgent = desktopUA }

        DispatchQueue.main.async {
            self.statusLabel.text = "已嗅到视频流（\(source)）"
            self.analyzeButton.isEnabled = true
            self.analyzeButton.backgroundColor = UIColor.systemBlue
            self.analyzeButton.setTitle("开始分析", for: .normal)
        }
        print("✅ [WebVideo] 嗅到（\(acceptReason)）src=\(source) eid=\(elementId ?? "-"): \(urlString)")
    }

    /// 不同捕获来源的兜底分数。当前都是 1（够用），
    /// 后续如需细分（master playlist > variant > 单 mp4）可以在这里加权。
    private func scoreForSource(_ source: String) -> Int {
        return 1
    }

    /// 严格判断：是不是一个完整容器 / playlist 的 URL。
    /// **必须严格 endsWith**，不能用 `contains(".mp4/")` 这种子串匹配 ——
    /// CDN 经常把 `.mp4/` 当作目录段复用在 HLS `.ts` 分片 URL 里
    /// (e.g. `.../720P_4000K_xxxxx.mp4/seg-6-v1-a1.ts?...`)
    private func isLikelyVideoURL(_ s: String) -> Bool {
        let lower = s.lowercased()
        if lower.hasPrefix("blob:") { return false }
        // 去掉 query / fragment
        var path = lower
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        if let h = path.firstIndex(of: "#") { path = String(path[..<h]) }
        // HLS / DASH 分片 + 字幕：明确排除（即便后缀像 mp4 也不行）
        if path.hasSuffix(".ts") || path.hasSuffix(".m4s")
            || path.hasSuffix(".m4a") || path.hasSuffix(".aac")
            || path.hasSuffix(".vtt") {
            return false
        }
        // 完整容器 / playlist 白名单
        let okSuffix = path.hasSuffix(".mp4")
            || path.hasSuffix(".m3u8")
            || path.hasSuffix(".m3u")
            || path.hasSuffix(".webm")
            || path.hasSuffix(".mpd")
        if !okSuffix { return false }
        // 新增（仅对 .mp4 后缀生效）：识别带 .mp4 后缀的 fMP4 / HLS-CMAF 分片
        // missav 用这种分片，单独喂给 AVPlayer 会报错 -11828 / -12865 之类
        if looksLikeHlsFragment(s) {
            print("⏭️ [WebVideo] 跳过 fMP4 分片: \(s)")
            return false
        }
        return true
    }

    /// 带 `.mp4` 后缀但其实是 fMP4 / HLS-CMAF 分片（init 段或媒体分片）。
    /// missav 用 `..._h264_589_<token>_<ts>.mp4` 这种命名，必须排除。
    /// 注意 Pornhub 的完整 mp4 `720P_4000K_50855065.mp4` 不会被这三条命中。
    private func looksLikeHlsFragment(_ s: String) -> Bool {
        let lower = s.lowercased()
        // 去 query / fragment
        var path = lower
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        if let h = path.firstIndex(of: "#") { path = String(path[..<h]) }
        guard path.hasSuffix(".mp4") else { return false }

        // 取文件名（最后一个 / 之后）
        let filename: String
        if let slashIdx = path.lastIndex(of: "/") {
            filename = String(path[path.index(after: slashIdx)...])
        } else {
            filename = path
        }

        // 1) init 段
        let initKeys = ["init.mp4", "_init_", "-init-", "_init.", "-init.", "initialization"]
        for k in initKeys where filename.contains(k) { return true }
        if filename.hasPrefix("init.") || filename.hasPrefix("init-") || filename.hasPrefix("init_") {
            return true
        }

        // 2) codec 标记 + 数字序号的分片
        //    _(h264|h265|hevc|avc|vp9|av1|av01|aac)_\d+[._\-].*\.mp4
        if Self.codecFragRegex.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)) != nil {
            return true
        }

        // 3) 通用编号分片
        //    (^|[_\-/])(seg|segment|chunk|frag|fragment)[_\-]?\d+.*\.mp4
        if Self.namedFragRegex.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)) != nil {
            return true
        }

        return false
    }

    // 提前编译好的正则；运行期失败的话退化成"不命中"，让 URL 走白名单
    private static let codecFragRegex: NSRegularExpression = {
        return (try? NSRegularExpression(pattern: "_(h264|h265|hevc|avc|vp9|av1|av01|aac)_\\d+[._\\-].*\\.mp4"))
            ?? (try! NSRegularExpression(pattern: "$^"))  // never matches
    }()
    private static let namedFragRegex: NSRegularExpression = {
        return (try? NSRegularExpression(pattern: "(^|[_\\-/])(seg|segment|chunk|frag|fragment)[_\\-]?\\d+.*\\.mp4"))
            ?? (try! NSRegularExpression(pattern: "$^"))
    }()

    /// trickplay / sprite / poster / 缩略图条 URL —— 这些是页面预拉的"用于 seek 悬停预览"
    /// 的迷你视频，会被嗅探器最早抓到，必须排除。
    private func looksLikePreviewUrl(_ s: String) -> Bool {
        let lower = s.lowercased()

        // 1) 路径关键词
        let pathKeys = [
            "/vts:", "/vts/", "/preview/", "/thumb/", "/thumbnail/",
            "/sprite/", "/storyboard/", "/poster/", "/trickplay/", "/seek-thumb/",
            "?type=preview", "&type=preview"
        ]
        for k in pathKeys where lower.contains(k) { return true }

        // 2) Pornhub 风格 `vts:数字`
        if let r = lower.range(of: "vts:"),
           r.upperBound < lower.endIndex,
           lower[r.upperBound].isNumber {
            return true
        }

        // 3) 子域名前缀
        if let host = URL(string: s)?.host?.lowercased() {
            let subPrefixes = ["pix-", "thumb-", "sprite-", "preview-", "trickplay-"]
            for p in subPrefixes where host.hasPrefix(p) { return true }
        }

        // 4) `rs:fit:W:H` 且 W*H < 240_000（约 600×400 以下）
        if let regex = try? NSRegularExpression(pattern: "rs:fit:(\\d+):(\\d+)"),
           let m = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
           m.numberOfRanges >= 3,
           let wRange = Range(m.range(at: 1), in: lower),
           let hRange = Range(m.range(at: 2), in: lower),
           let w = Int(lower[wRange]), let h = Int(lower[hRange]),
           w * h > 0, w * h < 240_000 {
            return true
        }

        return false
    }

    // MARK: - JS 轮询（拿 <video>.src + currentTime）

    private func startJsPollLoop() {
        jsPollTimer?.invalidate()
        jsPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollVideoSrc()
        }
    }

    private func pollVideoSrc() {
        // 不再 short-circuit —— 持续轮询，handleSniffedURL 内部会做去重 / 覆盖判定
        guard webView != nil else { return }
        // 返回 {url, elementId} 以便 Swift 端识别"同元素 src 切换"
        let js = """
        (function(){
          var v = document.querySelector('video');
          if (!v) return null;
          var u = v.currentSrc || v.src || '';
          if (!u) return null;
          try {
            if (!v.__sniffId) {
              window.__sniffN = (window.__sniffN || 0) + 1;
              v.__sniffId = 'v' + window.__sniffN;
            }
          } catch(e){}
          return { url: u, elementId: v.__sniffId || '' };
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self = self else { return }
            guard let dict = result as? [String: Any],
                  let u = dict["url"] as? String, !u.isEmpty else { return }
            let eid = dict["elementId"] as? String
            self.handleSniffedURL(u, source: "JS轮询", elementId: eid)
        }
    }

    // MARK: - 重置嗅探状态

    private func resetSniffState(pageURL: URL?) {
        sniffedVideoURL = nil
        sniffedReferer = nil
        sniffedUserAgent = nil
        currentBestElementId = nil
        currentBestScore = 0
        lastPageURL = pageURL
        pageRootHost = pageURL.flatMap { Self.extractRootDomain($0.host) }
        DispatchQueue.main.async {
            self.statusLabel.text = "尚未嗅到视频流"
            self.analyzeButton.isEnabled = false
            self.analyzeButton.backgroundColor = UIColor.gray
            self.analyzeButton.setTitle("开始分析（尚未嗅到视频）", for: .normal)
        }
    }

    // host = "www.missav.ws" → "missav.ws"
    private static func extractRootDomain(_ host: String?) -> String? {
        guard let host = host else { return nil }
        let parts = host.split(separator: ".")
        if parts.count <= 2 { return host }
        return parts.suffix(2).joined(separator: ".")
    }

    // MARK: - WKContentRuleList 编译（广告域名屏蔽）

    private func compileAdBlockRuleList(completion: @escaping (WKContentRuleList?) -> Void) {
        var rules: [[String: Any]] = []
        for host in adHosts {
            let esc = NSRegularExpression.escapedPattern(for: host)
            rules.append([
                "trigger": ["url-filter": ".*" + esc + ".*"],
                "action": ["type": "block"]
            ])
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8) else {
            completion(nil); return
        }
        WKContentRuleListStore.default()?.compileContentRuleList(
            forIdentifier: "XcupAdBlockRules",
            encodedContentRuleList: json
        ) { list, err in
            if let err = err {
                print("⚠️ [WebVideo] AdBlock RuleList 编译失败: \(err)")
            }
            completion(list)
        }
    }

    // MARK: - JS 源（嗅探 fetch / XHR / video.src）

    private static let sniffJSSource: String = """
    (function(){
      if (window.__xcupSniffInstalled) return;
      window.__xcupSniffInstalled = true;
      var send = function(payload){
        try { window.webkit.messageHandlers.videoSniff.postMessage(payload); } catch(e){}
      };
      // 给每个 <video> 元素分配一个稳定 id，用于 Swift 端识别"同元素 src 切换"
      // （典型例：Pornhub 主播放器 src=广告 → src=真视频，相同 element）。
      // 不抛错，失败就 fallback 到空 id。
      var sniffId = function(el){
        if (!el) return '';
        try {
          if (!el.__sniffId) {
            window.__sniffN = (window.__sniffN || 0) + 1;
            el.__sniffId = 'v' + window.__sniffN;
          }
          return el.__sniffId;
        } catch(e) { return ''; }
      };
      // 与 Swift 端 isLikelyVideoURL 保持一致：严格 endsWith 白名单 + 分片黑名单。
      // 切勿用 contains('.mp4') —— CDN 会把 .mp4/ 当目录名复用在 .ts 分片 URL 里。
      var looksVideo = function(u){
        if (!u || typeof u !== 'string') return false;
        if (u.indexOf('blob:') === 0) return false;
        var lower = u.toLowerCase();
        var qIdx = lower.indexOf('?');
        var path = qIdx >= 0 ? lower.substring(0, qIdx) : lower;
        var hIdx = path.indexOf('#');
        if (hIdx >= 0) path = path.substring(0, hIdx);
        if (path.endsWith('.ts') || path.endsWith('.m4s')
            || path.endsWith('.m4a') || path.endsWith('.aac')
            || path.endsWith('.vtt')) return false;
        return path.endsWith('.mp4') || path.endsWith('.m3u8')
            || path.endsWith('.m3u') || path.endsWith('.webm')
            || path.endsWith('.mpd');
      };

      // 1) fetch（网络层捕获，没有所属 video 元素 → elementId 为空）
      var origFetch = window.fetch;
      if (origFetch) {
        window.fetch = function(input, init){
          try {
            var u = (typeof input === 'string') ? input : (input && input.url);
            if (looksVideo(u)) {
              send({src: 'fetch', url: u, elementId: '', ua: navigator.userAgent, referer: location.href});
            }
          } catch(e){}
          return origFetch.apply(this, arguments);
        };
      }

      // 2) XHR（同上，没有所属 video 元素）
      var XOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, url){
        try {
          if (looksVideo(url)) {
            send({src: 'xhr', url: url, elementId: '', ua: navigator.userAgent, referer: location.href});
          }
        } catch(e){}
        return XOpen.apply(this, arguments);
      };

      // 3) HTMLMediaElement.src setter（this 即为被设置的 <video> 元素 → 分配 elementId）
      try {
        var proto = HTMLMediaElement.prototype;
        var desc = Object.getOwnPropertyDescriptor(proto, 'src') ||
                   Object.getOwnPropertyDescriptor(HTMLVideoElement.prototype, 'src');
        if (desc && desc.set) {
          var origSet = desc.set;
          Object.defineProperty(proto, 'src', {
            set: function(v) {
              try {
                if (looksVideo(v)) {
                  send({src: 'media-src', url: v, elementId: sniffId(this), ua: navigator.userAgent, referer: location.href});
                }
              } catch(e){}
              return origSet.call(this, v);
            },
            get: desc.get
          });
        }
      } catch(e){}

      // 4) 兜底：document_end 后扫描一次所有 <video>（每个元素带 id）
      var scan = function(){
        try {
          var vs = document.querySelectorAll('video');
          vs.forEach(function(v){
            var u = v.currentSrc || v.src || '';
            if (looksVideo(u)) {
              send({src: 'dom-scan', url: u, elementId: sniffId(v), ua: navigator.userAgent, referer: location.href});
            }
          });
        } catch(e){}
      };
      if (document.readyState === 'complete' || document.readyState === 'interactive') {
        setTimeout(scan, 500);
      } else {
        document.addEventListener('DOMContentLoaded', function(){ setTimeout(scan, 500); });
      }
    })();
    """
}

// MARK: - WKScriptMessageHandler

extension WebVideoViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                                didReceive message: WKScriptMessage) {
        guard message.name == "videoSniff",
              let dict = message.body as? [String: Any] else { return }
        let url = dict["url"] as? String ?? ""
        let src = dict["src"] as? String ?? "?"
        let ua = dict["ua"] as? String
        let ref = dict["referer"] as? String
        let eid = dict["elementId"] as? String
        if !url.isEmpty {
            handleSniffedURL(url, source: src, ua: ua, referer: ref, elementId: eid)
        }
    }
}

// MARK: - WKNavigationDelegate

extension WebVideoViewController: WKNavigationDelegate {

    // 拦跨站主窗口跳转 + 拦广告域 + 主动嗅 .mp4 / .m3u8
    func webView(_ webView: WKWebView,
                  decidePolicyFor navigationAction: WKNavigationAction,
                  decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }

        // 广告域名拦截（保险层，与 RuleList 互为兜底）
        if let host = url.host?.lowercased() {
            for ad in adHosts {
                if host == ad || host.hasSuffix("." + ad) {
                    decisionHandler(.cancel); return
                }
            }
        }

        // 嗅探：URL 直接看起来像视频流
        if isLikelyVideoURL(url.absoluteString) {
            handleSniffedURL(url.absoluteString, source: "navAction")
            // 视频流别让 WebView 自己去打开（避免变成下载页 / 直接播放）
            decisionHandler(.cancel)
            return
        }

        // 仅主窗口跨站时拦（但用户在 URL bar 主动跳转的情况下放行）
        if allowNextNavigation {
            allowNextNavigation = false
        } else if navigationAction.targetFrame?.isMainFrame == true,
                  let reqHost = url.host?.lowercased(),
                  let pageRoot = pageRootHost?.lowercased(),
                  !pageRoot.isEmpty,
                  !reqHost.hasSuffix(pageRoot) {
            // 自动跳转才拦：点击链接 / location.href = X / window.open（已被 UIDelegate 拦走）
            if navigationAction.navigationType == .other ||
               navigationAction.navigationType == .linkActivated {
                print("[WebVideo] 拦截跨站主窗口跳转: \(url) (page root=\(pageRoot))")
                decisionHandler(.cancel)
                return
            }
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if let url = webView.url, navigation != nil {
            resetSniffState(pageURL: url)
            DispatchQueue.main.async {
                self.urlBar.text = url.absoluteString
                self.setEmptyHintVisible(false)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url {
            lastPageURL = url
            if pageRootHost == nil { pageRootHost = Self.extractRootDomain(url.host) }
        }
    }
}

// MARK: - WKUIDelegate（蜜罐 popup）

extension WebVideoViewController: WKUIDelegate {

    func webView(_ webView: WKWebView,
                  createWebViewWith configuration: WKWebViewConfiguration,
                  for navigationAction: WKNavigationAction,
                  windowFeatures: WKWindowFeatures) -> WKWebView? {
        // 蜜罐：任何 window.open / target=_blank 弹出都给一个隔离 WebView，立即拦截其所有跳转
        let popup = WKWebView(frame: .zero, configuration: configuration)
        let honeypot = HoneypotNavDelegate()
        popup.navigationDelegate = honeypot
        honeypotEntries.append((popup, honeypot))

        // 1 秒后移除引用 — 避免无限累积
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self, weak popup] in
            guard let self = self, let popup = popup else { return }
            self.honeypotEntries.removeAll { $0.view === popup }
        }
        return popup
    }

    // 屏蔽 JS alert / confirm / prompt 弹窗（防止广告卡死）
    func webView(_ webView: WKWebView,
                  runJavaScriptAlertPanelWithMessage message: String,
                  initiatedByFrame frame: WKFrameInfo,
                  completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

// 蜜罐 popup 的导航代理 — 拦截一切跳转
private final class HoneypotNavDelegate: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                  decidePolicyFor navigationAction: WKNavigationAction,
                  decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(.cancel)
    }
}

// MARK: - UITextFieldDelegate

extension WebVideoViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        loadFromUrlBar()
        return true
    }
}
