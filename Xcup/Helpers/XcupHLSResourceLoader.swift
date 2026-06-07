//
//  XcupHLSResourceLoader.swift
//  Xcup
//
//  AVAssetResourceLoaderDelegate：用自己的 URLSession 处理所有视频 HTTP 请求，
//  保证 Referer / Origin / User-Agent / Cookie 真正被发到 **每一个**子请求上
//  （manifest / variant playlist / segment / encryption key），
//  避免 missav / Pornhub 这类 CDN 在 segment 请求上 403。
//
//  对应 Android：ExoPlayer 的 DefaultDataSource.Factory().setDefaultRequestProperties(headers)。
//
//  工作原理：
//   1) 把 videoURL 的 scheme 从 https 改成自定义 scheme "xcup-https"
//   2) AVPlayer 不认识这个 scheme → 走 resourceLoader 委托问我们
//   3) 我们用 URLSession 把 scheme 还原回 https，注入所有 headers 后请求真实资源
//   4) **关键**：拿到 .m3u8 manifest 后，把里面所有 segment / 子 playlist / key URL
//      也改成 xcup-https://，这样 AVPlayer 再次走 resourceLoader 时，
//      就还是我们注入 headers。否则只有第一个请求带 headers，segment 全裸奔。
//

import Foundation
import AVFoundation

final class XcupHLSResourceLoader: NSObject, AVAssetResourceLoaderDelegate {

    // 自定义 scheme：AVPlayer 不识别，强制走 resourceLoader 委托
    static let customSchemeHTTPS = "xcup-https"
    static let customSchemeHTTP  = "xcup-http"

    private let headers: [String: String]
    private let session: URLSession
    private let pendingQueue = DispatchQueue(label: "com.xcup.hlsLoader.pending")
    private var pending: [ObjectIdentifier: URLSessionDataTask] = [:]

    init(headers: [String: String]) {
        self.headers = headers
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 120
        cfg.httpShouldSetCookies = false       // 我们用自己的 Cookie header
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpAdditionalHeaders = nil
        self.session = URLSession(configuration: cfg)
        super.init()
    }

    // MARK: - 工厂方法

    /// 用给定的 URL + headers 造一个 AVURLAsset。Asset 的 resourceLoader 已经挂好。
    /// **必须**用返回的 loader 保留强引用，否则 delegate 是 weak 持有。
    static func makeAsset(originalURL: URL, headers: [String: String]) -> (asset: AVURLAsset, loader: XcupHLSResourceLoader) {
        let loader = XcupHLSResourceLoader(headers: headers)
        let customURL = loader.toCustomScheme(originalURL) ?? originalURL
        let asset = AVURLAsset(url: customURL)
        let delegateQueue = DispatchQueue(label: "com.xcup.hlsLoader.delegate")
        asset.resourceLoader.setDelegate(loader, queue: delegateQueue)
        return (asset, loader)
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let customURL = loadingRequest.request.url else {
            loadingRequest.finishLoading(with: NSError(domain: "Xcup.HLS", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "no url"]))
            return true
        }
        let realURL = restoreScheme(customURL)
        var req = URLRequest(url: realURL)
        req.httpMethod = "GET"
        // 注入用户传入的 headers（Referer / Cookie / User-Agent / Origin 等）
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        // 补一些浏览器请求 .m3u8 时的常见 header，提升 CDN 接受率
        if req.value(forHTTPHeaderField: "Accept") == nil {
            req.setValue("*/*", forHTTPHeaderField: "Accept")
        }
        if req.value(forHTTPHeaderField: "Accept-Language") == nil {
            req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        }
        // 转发 AVPlayer 自带的 Range header（如果有）
        if let dataRequest = loadingRequest.dataRequest {
            let offset = dataRequest.requestedOffset
            let length = dataRequest.requestedLength
            // currentOffset > 0 表示这是续传
            let from = max(offset, dataRequest.currentOffset)
            if from > 0 || (length > 0 && length < Int.max) {
                let end = from + Int64(length) - 1
                req.setValue("bytes=\(from)-\(end)", forHTTPHeaderField: "Range")
            }
        }

        // === 诊断日志：完整列出我们发出去的 header ===
        let dump = (req.allHTTPHeaderFields ?? [:])
            .map { "    \($0.key): \($0.value)" }
            .sorted()
            .joined(separator: "\n")
        print("➡️ [XcupHLS] GET \(realURL.absoluteString)\n\(dump)")

        let key = ObjectIdentifier(loadingRequest)
        let task = session.dataTask(with: req) { [weak self] data, response, error in
            guard let self = self else { return }
            self.pendingQueue.async { self.pending.removeValue(forKey: key) }
            self.handleResponse(loadingRequest: loadingRequest,
                                 realURL: realURL,
                                 data: data,
                                 response: response,
                                 error: error)
        }
        pendingQueue.async { self.pending[key] = task }
        task.resume()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        let key = ObjectIdentifier(loadingRequest)
        pendingQueue.async {
            if let t = self.pending.removeValue(forKey: key) {
                t.cancel()
            }
        }
    }

    // MARK: - URLSession 完成回调

    private func handleResponse(loadingRequest: AVAssetResourceLoadingRequest,
                                 realURL: URL,
                                 data: Data?,
                                 response: URLResponse?,
                                 error: Error?) {
        if let error = error {
            print("❌ [XcupHLS] \(realURL.lastPathComponent) 失败: \(error.localizedDescription)")
            loadingRequest.finishLoading(with: error)
            return
        }
        guard let http = response as? HTTPURLResponse, let data = data else {
            loadingRequest.finishLoading(with: NSError(domain: "Xcup.HLS", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "no response"]))
            return
        }
        if http.statusCode >= 400 {
            let msg = "HTTP \(http.statusCode): \(realURL.absoluteString)"
            print("❌ [XcupHLS] \(msg)")
            // === 诊断：打印响应 headers + 响应体前 512 字节，方便排查 CDN 拒绝原因 ===
            let respHeadersDump = http.allHeaderFields
                .map { "    \($0.key): \($0.value)" }
                .sorted()
                .joined(separator: "\n")
            print("⬅️ [XcupHLS] resp headers:\n\(respHeadersDump)")
            if let body = String(data: data.prefix(512), encoding: .utf8), !body.isEmpty {
                print("⬅️ [XcupHLS] resp body[<=512B]: \(body)")
            }
            loadingRequest.finishLoading(with: NSError(domain: "Xcup.HLS", code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: msg]))
            return
        }

        // 判断是 manifest 还是 segment
        let urlLowerFull = realURL.absoluteString.lowercased()
        let mime = (http.mimeType ?? "").lowercased()
        let isManifest = mime.contains("mpegurl") || mime.contains("dash+xml")
            || urlLowerFull.contains(".m3u8") || urlLowerFull.contains(".m3u")
            || urlLowerFull.contains(".mpd")

        // 成功日志（方便看 segment 拿到的实际 content-type / 大小）
        print("✅ [XcupHLS] \(http.statusCode) \(realURL.lastPathComponent) (\(data.count)B, type=\(http.mimeType ?? "?"))")

        // 设置 contentInformation（如果 AVPlayer 问）
        if let info = loadingRequest.contentInformationRequest {
            print("ℹ️ [XcupHLS] contentInfoRequest SET for \(realURL.lastPathComponent)")
            if isManifest {
                info.contentType = http.mimeType?.isEmpty == false
                    ? http.mimeType
                    : "application/vnd.apple.mpegurl"
            } else {
                // **关键**：HLS segment 即使被服务端伪装成 image/jpeg 也强制 video/MP2T
                // （missav 这类站把 .ts 分片改名成 video0.jpeg、Content-Type: image/jpeg
                //  绕开 ISP DPI 过滤；ExoPlayer 不看 type 直接 demux 能用，
                //  AVPlayer 严格校验 type，看到 image/jpeg 会 -12881 直接拒）
                info.contentType = "video/MP2T"
            }
            info.contentLength = http.expectedContentLength
            let ranges = (http.value(forHTTPHeaderField: "Accept-Ranges") ?? "").lowercased()
            info.isByteRangeAccessSupported = ranges.contains("bytes")
        } else {
            print("ℹ️ [XcupHLS] contentInfoRequest NOT set for \(realURL.lastPathComponent)")
        }

        // 非 manifest 资源 → 打 16 字节 hex，判断是不是真 TS（0x47 sync byte）
        if !isManifest, !data.isEmpty {
            let n = min(data.count, 16)
            let hex = data.prefix(n).map { String(format: "%02X", $0) }.joined(separator: " ")
            print("⬇️ [XcupHLS] segment 前 \(n)B (hex): \(hex)")
        }

        // 如果是 m3u8 / mpd manifest，重写里面的 URL 让 segment 也走我们
        var payload = data
        if isManifest, let text = String(data: data, encoding: .utf8) {
            let rewritten = rewriteManifest(text, baseURL: realURL)
            // 诊断：原始 + 重写后内容（各取前 400B），方便确认 .ts 别名生效
            print("⬇️ [XcupHLS] manifest 原始 前 400B:\n\(text.prefix(400))")
            print("⬇️ [XcupHLS] manifest 重写 前 400B:\n\(rewritten.prefix(400))")
            payload = rewritten.data(using: .utf8) ?? data
        }

        loadingRequest.dataRequest?.respond(with: payload)
        loadingRequest.finishLoading()
    }

    // MARK: - Manifest 重写

    /// 把 manifest 里所有 URL（绝对 / 相对）改成自定义 scheme，
    /// 这样 AVPlayer 之后请求 segment / 子 playlist / key 时还会走我们。
    private func rewriteManifest(_ content: String, baseURL: URL) -> String {
        // 兼容 \r\n
        let separator: String = content.contains("\r\n") ? "\r\n" : "\n"
        let lines = content.components(separatedBy: separator)
        var out: [String] = []
        out.reserveCapacity(lines.count)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                out.append(line)
                continue
            }
            if trimmed.hasPrefix("#") {
                // 标签：里面可能有 URI="..."（EXT-X-KEY / EXT-X-MEDIA / EXT-X-MAP / EXT-X-I-FRAME-STREAM-INF）
                if trimmed.contains("URI=\"") {
                    out.append(rewriteUriAttribute(line, baseURL: baseURL))
                } else {
                    out.append(line)
                }
            } else {
                // URL 行（segment 或 variant playlist）
                if let abs = absoluteURL(from: trimmed, baseURL: baseURL),
                   let custom = toCustomScheme(abs) {
                    // 给伪装成图片的 segment URL 加 .ts 别名，避免 AVPlayer 看 URL 后缀
                    // 直接把它当图片 short-circuit。restoreScheme 会把 .ts 后缀脱掉再请求。
                    let aliased = appendSegmentTsAliasIfNeeded(custom)
                    out.append(aliased.absoluteString)
                } else {
                    out.append(line)
                }
            }
        }
        return out.joined(separator: separator)
    }

    /// 如果 URL 后缀是 image 类（伪装成图片的 segment），追加 ".ts"
    /// e.g. xcup-https://.../video0.jpeg → xcup-https://.../video0.jpeg.ts
    /// AVPlayer 这样看后缀就是 .ts，按 MPEG-TS demuxer 解，不会因为 .jpeg 直接拒。
    private func appendSegmentTsAliasIfNeeded(_ url: URL) -> URL {
        let path = url.path.lowercased()
        let imageExts = [".jpeg", ".jpg", ".png", ".webp", ".bmp", ".gif"]
        for ext in imageExts where path.hasSuffix(ext) {
            // 拼接 .ts。URLComponents 安全可控。
            guard var comp = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
            comp.path = comp.path + ".ts"
            return comp.url ?? url
        }
        return url
    }

    /// 替换 EXT-X-KEY 这类标签里的 URI="..."
    private func rewriteUriAttribute(_ line: String, baseURL: URL) -> String {
        // 简单状态机：找 URI=" 到下一个非转义 "
        let marker = "URI=\""
        guard let start = line.range(of: marker) else { return line }
        let afterStart = start.upperBound
        guard let end = line.range(of: "\"", range: afterStart..<line.endIndex) else { return line }
        let inner = String(line[afterStart..<end.lowerBound])
        guard let abs = absoluteURL(from: inner, baseURL: baseURL),
              let custom = toCustomScheme(abs) else {
            return line
        }
        var rewritten = String(line[line.startIndex..<afterStart])
        rewritten.append(custom.absoluteString)
        rewritten.append(String(line[end.lowerBound..<line.endIndex]))
        return rewritten
    }

    // MARK: - URL scheme 转换

    private func absoluteURL(from urlString: String, baseURL: URL) -> URL? {
        let lower = urlString.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://")
            || lower.hasPrefix("\(Self.customSchemeHTTP)://") || lower.hasPrefix("\(Self.customSchemeHTTPS)://") {
            return URL(string: urlString)
        }
        return URL(string: urlString, relativeTo: baseURL)?.absoluteURL
    }

    /// https://x → xcup-https://x ；http://x → xcup-http://x ；其它不变
    private func toCustomScheme(_ url: URL) -> URL? {
        guard var comp = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        switch (comp.scheme ?? "").lowercased() {
        case "https": comp.scheme = Self.customSchemeHTTPS
        case "http":  comp.scheme = Self.customSchemeHTTP
        case Self.customSchemeHTTPS, Self.customSchemeHTTP: break
        default: return nil
        }
        return comp.url
    }

    /// xcup-https://x → https://x （反过来）
    /// 同时脱掉 appendSegmentTsAliasIfNeeded 给图片伪装 segment 加的 .ts 后缀
    private func restoreScheme(_ url: URL) -> URL {
        guard var comp = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        switch (comp.scheme ?? "").lowercased() {
        case Self.customSchemeHTTPS: comp.scheme = "https"
        case Self.customSchemeHTTP:  comp.scheme = "http"
        default: break
        }
        // 脱 .ts 后缀（如果它是我们贴上去的 image alias）
        let lower = comp.path.lowercased()
        let imageExts = [".jpeg.ts", ".jpg.ts", ".png.ts", ".webp.ts", ".bmp.ts", ".gif.ts"]
        for ext in imageExts where lower.hasSuffix(ext) {
            comp.path = String(comp.path.dropLast(3))  // 移除尾部的 ".ts"
            break
        }
        return comp.url ?? url
    }
}
