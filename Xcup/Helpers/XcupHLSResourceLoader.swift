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
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
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
            loadingRequest.finishLoading(with: NSError(domain: "Xcup.HLS", code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: msg]))
            return
        }

        // 设置 contentInformation（如果 AVPlayer 问）
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = http.mimeType
            info.contentLength = http.expectedContentLength
            let ranges = (http.value(forHTTPHeaderField: "Accept-Ranges") ?? "").lowercased()
            info.isByteRangeAccessSupported = ranges.contains("bytes")
        }

        // 如果是 m3u8 / mpd manifest，重写里面的 URL 让 segment 也走我们
        var payload = data
        let mime = (http.mimeType ?? "").lowercased()
        let isManifest = mime.contains("mpegurl") || mime.contains("dash+xml")
            || realURL.absoluteString.lowercased().contains(".m3u8")
            || realURL.absoluteString.lowercased().contains(".m3u")
            || realURL.absoluteString.lowercased().contains(".mpd")
        if isManifest, let text = String(data: data, encoding: .utf8) {
            let rewritten = rewriteManifest(text, baseURL: realURL)
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
                    out.append(custom.absoluteString)
                } else {
                    out.append(line)
                }
            }
        }
        return out.joined(separator: separator)
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
    private func restoreScheme(_ url: URL) -> URL {
        guard var comp = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        switch (comp.scheme ?? "").lowercased() {
        case Self.customSchemeHTTPS: comp.scheme = "https"
        case Self.customSchemeHTTP:  comp.scheme = "http"
        default: break
        }
        return comp.url ?? url
    }
}
