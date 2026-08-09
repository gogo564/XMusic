import Foundation
import AVFoundation

/// AVAssetResourceLoader 流式解密：AVPlayer 通过自定义 scheme（sodastream://）加载，
/// 这里拦截请求，从汽水 CDN 顺序下载加密音频，边下边解（moov 一到位就构建 cleanMoov
/// 发给 AVPlayer 秒开，mdat 逐样本解密持续输出），全程不占 NAS 上传带宽。
final class SodaStreamLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let shared = SodaStreamLoader()
    static let scheme = "sodastream"

    private var active: [String: SodaStreamSession] = [:]
    private let lock = NSLock()

    private override init() {}

    static func customURL(trackID: String, quality: String) -> URL {
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = "track"
        comps.path = "/" + trackID
        comps.queryItems = [URLQueryItem(name: "quality", value: quality)]
        return comps.url!
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url, url.scheme == Self.scheme else {
            loadingRequest.finishLoading(with: NSError(domain: "SodaStream", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "非汽水流式地址"]))
            return false
        }
        let key = url.absoluteString
        let session: SodaStreamSession
        lock.lock()
        if let existing = active[key] {
            session = existing
        } else {
            let trackID = url.path.replacingOccurrences(of: "/", with: "")
            let quality = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "quality" })?.value ?? "highest"
            session = SodaStreamSession(trackID: trackID, quality: quality)
            active[key] = session
        }
        lock.unlock()
        session.enqueue(loadingRequest)
        session.startIfNeeded { [weak self] in
            guard let self = self, session.isFinished else { return }
            self.lock.lock()
            self.active.removeValue(forKey: key)
            self.lock.unlock()
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        let key = loadingRequest.request.url?.absoluteString ?? ""
        lock.lock()
        active[key]?.cancel(request: loadingRequest)
        lock.unlock()
    }
}

/// 单个流式播放会话：串起 下载 → 解析 → 解密 → 喂给 AVPlayer。
final class SodaStreamSession: NSObject, URLSessionDataDelegate {
    let trackID: String
    let quality: String

    private(set) var isFinished = false
    private var onFinished: (() -> Void)?

    private let queue = DispatchQueue(label: "soda.stream")
    private var pending: [PendingRequest] = []
    private var downloadTask: URLSessionDataTask?
    private var downloadSession: URLSession?

    // 加密数据累积与消费游标
    private var encrypted = Data()
    private var payloadCursor = 0          // 已解密到的样本所对应的加密数据绝对偏移
    private var nextSample = 0             // 下一个待解密样本索引

    // 解密产物
    private var parser: SodaCencParser?
    private var parsed: SodaCencParser.Parsed?
    private var ctr: SodaCTR?
    private var header: Data?              // ftyp + cleanMoov + mdat 头
    private var decrypted = Data()         // 解密后的 mdat payload
    private var totalLength: Int64 = 0
    private var totalLengthKnown = false

    private var started = false
    private var downloadFinished = false
    private var keyHex: String = ""

    init(trackID: String, quality: String) {
        self.trackID = trackID
        self.quality = quality
        super.init()
    }

    // MARK: - 对外接口

    func enqueue(_ request: AVAssetResourceLoadingRequest) {
        queue.sync {
            if pending.contains(where: { $0.request === request }) { return }
            pending.append(PendingRequest(request: request))
            serveLocked()
        }
    }

    func cancel(request: AVAssetResourceLoadingRequest) {
        queue.sync {
            pending.removeAll { $0.request === request }
            if pending.isEmpty {
                downloadTask?.cancel()
            }
        }
    }

    func startIfNeeded(completion: @escaping () -> Void) {
        queue.sync {
            self.onFinished = completion
            guard !started else { return }
            started = true
            Task { await self.begin() }
        }
    }

    // MARK: - 下载

    private func begin() async {
        do {
            let stream = try await SodaAPIClient.shared.songStream(trackID: trackID, quality: quality)
            guard let url = URL(string: stream.mainURL), stream.hexKey.count == 32 else {
                failAll(error: NSError(domain: "SodaStream", code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "流式信息缺失"]))
                return
            }
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            var req = URLRequest(url: url)
            req.timeoutInterval = 60
            let task = session.dataTask(with: req)
            queue.sync {
                self.keyHex = stream.hexKey
                self.downloadSession = session
                self.downloadTask = task
            }
            Log.write("🎧 [SodaStream] start track=\(trackID) q=\(quality) url=\(url.absoluteString.prefix(50))")
            task.resume()
        } catch {
            failAll(error: error)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        queue.sync {
            encrypted.append(data)
            processLocked()
            serveLocked()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        queue.sync {
            if let error = error {
                if (error as NSError).code != NSURLErrorCancelled {
                    failAll(error: error)
                    return
                }
            }
            downloadFinished = true
            processLocked()
            serveLocked()
            if nextSample >= (parsed?.samples.count ?? Int.max) {
                Log.write("🎧 [SodaStream] done track=\(trackID) samples=\(parsed?.samples.count ?? -1) decrypted=\(decrypted.count) finished")
                finishAll()
            } else {
                Log.write("❌ [SodaStream] incomplete track=\(trackID) nextSample=\(nextSample) total=\(parsed?.samples.count ?? -1) dataLen=\(encrypted.count)")
                failAll(error: NSError(domain: "SodaStream", code: -4,
                    userInfo: [NSLocalizedDescriptionKey: "音频数据下载不完整"]))
            }
        }
    }

    // MARK: - 解析 + 解密

    /// 需在 queue 内调用
    private func processLocked() {
        if parsed == nil {
            // parse 需要在拿到完整 moov + mdat 头后才成功
            let parser = SodaCencParser(encrypted)
            guard let parsed = try? parser.parse(keyHex: keyHex) else { return }
            self.parser = parser
            self.parsed = parsed
            self.ctr = SodaCTR(key: parsed.keyBytes)
            self.payloadCursor = parsed.encryptedMdatDataOffset
            buildHeaderLocked(parser)
            processSamplesLocked()
            return
        }
        processSamplesLocked()
    }

    /// 需在 queue 内调用
    private func buildHeaderLocked(_ parser: SodaCencParser) {
        guard let parsed = self.parsed else { return }
        // 新文件布局 ftyp + [8字节moov头 + cleanInner] + [8字节mdat头 + payload]
        // 两步法：先 dummy 求 cleanInner 长度，再算真实 mdat 偏移
        guard let moov = parser.findBox("moov"),
              let dummyInner = try? parser.processBoxTreeForHeader(root: moov, newMdatOffset: 0, parsed: parsed) else { return }
        let ftypSize = parsed.ftyp?.size ?? 0
        let newMdatOffset = ftypSize + dummyInner.count + 16
        guard let realInner = try? parser.processBoxTreeForHeader(root: moov, newMdatOffset: newMdatOffset, parsed: parsed) else { return }

        var out = Data()
        if let ftyp = parsed.ftyp {
            out.append(encrypted.subdata(in: ftyp.offset..<ftyp.endOffset))
        }
        out.append(parser.boxHeader("moov", innerSize: realInner.count))
        out.append(realInner)
        out.append(parser.boxHeader("mdat", innerSize: parsed.decryptedPayloadSize))
        self.header = out
        self.totalLength = Int64(out.count) + Int64(parsed.decryptedPayloadSize)
        self.totalLengthKnown = true
    }

    /// 需在 queue 内调用：把已就绪的加密样本逐个解密追加到 decrypted
    private func processSamplesLocked() {
        guard let parser = self.parser, let parsed = self.parsed, let ctr = self.ctr else { return }
        while nextSample < parsed.samples.count {
            let sample = parsed.samples[nextSample]
            guard payloadCursor + sample.size <= encrypted.count else { break }
            let chunk = encrypted.subdata(in: payloadCursor..<(payloadCursor + sample.size))
            decrypted.append(ctr.decrypt(sample: chunk, iv: sample.iv))
            payloadCursor += sample.size
            nextSample += 1
        }
    }

    // MARK: - 喂给 AVPlayer

    /// 需在 queue 内调用
    private func serveLocked() {
        guard totalLengthKnown else { return }
        var finishedIndexes: [Int] = []
        for (i, p) in pending.enumerated() {
            let request = p.request
            if let info = request.contentInformationRequest, !p.infoFulfilled {
                info.contentType = "public.mpeg-4"
                info.isByteRangeAccessSupported = true
                info.contentLength = totalLength
                pending[i].infoFulfilled = true
            }
            if let dataReq = request.dataRequest {
                let headerLen = Int64(header?.count ?? 0)
                let decryptedLen = Int64(decrypted.count)
                let available = headerLen + decryptedLen
                let wantOffset = Int64(dataReq.requestedOffset)
                let wantLength = dataReq.requestedLength > 0 ? Int64(dataReq.requestedLength) : totalLength - wantOffset
                let wantEnd = min(wantOffset + wantLength, totalLength)
                if !pending[i].loggedRequest {
                    Log.write("🎧 [SodaStream] request track=\(trackID) off=\(wantOffset) len=\(dataReq.requestedLength) wantEnd=\(wantEnd) total=\(totalLength) avail=\(available) pending=\(pending.count)")
                    pending[i].loggedRequest = true
                }
                // 首次响应的起点 = 请求的 offset；之后从上次响应的终点继续
                if pending[i].served == 0 {
                    pending[i].served = wantOffset
                }
                let canEnd = min(wantEnd, available)
                if canEnd > pending[i].served {
                    let sliceStart = pending[i].served
                    let sliceEnd = canEnd
                    if sliceEnd > sliceStart {
                        dataReq.respond(with: slice(of: sliceStart..<sliceEnd, headerLen: headerLen))
                        pending[i].served = sliceEnd
                    }
                }
                if pending[i].served >= wantEnd || (downloadFinished && pending[i].served >= available) {
                    Log.write("🎧 [SodaStream] finish request track=\(trackID) served=\(pending[i].served) wantEnd=\(wantEnd)")
                    request.finishLoading()
                    finishedIndexes.append(i)
                }
            } else {
                // 仅 contentInformationRequest（或无 dataRequest）→ 元数据已给出即完成
                request.finishLoading()
                finishedIndexes.append(i)
            }
        }
        for idx in finishedIndexes.reversed() { pending.remove(at: idx) }
        if pending.isEmpty, isFinished == false, downloadFinished, nextSample >= (parsed?.samples.count ?? Int.max) {
            finishAll()
        }
    }

    private func slice(of range: Range<Int64>, headerLen: Int64) -> Data {
        let start = range.lowerBound, end = range.upperBound
        var out = Data()
        if start < headerLen {
            let hEnd = min(headerLen, end)
            out.append(header!.subdata(in: Int(start)..<Int(hEnd)))
        }
        if end > headerLen && start < headerLen + Int64(decrypted.count) {
            let dStart = max(Int64(0), start - headerLen)
            let dEnd = min(Int64(decrypted.count), end - headerLen)
            if dEnd > dStart { out.append(decrypted.subdata(in: Int(dStart)..<Int(dEnd))) }
        }
        return out
    }

    // MARK: - 收尾

    private func finishAll() {
        for p in pending { p.request.finishLoading() }
        pending.removeAll()
        downloadTask = nil
        downloadSession = nil
        isFinished = true
        onFinished?()
    }

    private func failAll(error: Error) {
        for p in pending { p.request.finishLoading(with: error) }
        pending.removeAll()
        downloadTask = nil
        downloadSession = nil
        isFinished = true
        onFinished?()
    }
}

private struct PendingRequest {
    let request: AVAssetResourceLoadingRequest
    var served: Int64 = 0
    var infoFulfilled = false
    var loggedRequest = false
}
