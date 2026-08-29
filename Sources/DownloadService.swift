import Foundation
import Combine

struct DownloadedSong: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let singer: String
    let source: String
    let songmid: String
    let quality: String
    let fileURL: String
    let createdAt: Date
    let localFile: String
    let rawJSON: String?

    init(id: String, name: String, singer: String, source: String, songmid: String,
         quality: String, fileURL: String, createdAt: Date, localFile: String, rawJSON: String? = nil) {
        self.id = id
        self.name = name
        self.singer = singer
        self.source = source
        self.songmid = songmid
        self.quality = quality
        self.fileURL = fileURL
        self.createdAt = createdAt
        self.localFile = localFile
        self.rawJSON = rawJSON
    }

    enum CodingKeys: String, CodingKey {
        case id, name, singer, source, songmid, quality, fileURL, createdAt, localFile, rawJSON
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        singer = try c.decode(String.self, forKey: .singer)
        source = try c.decode(String.self, forKey: .source)
        songmid = try c.decodeIfPresent(String.self, forKey: .songmid) ?? ""
        quality = try c.decodeIfPresent(String.self, forKey: .quality) ?? ""
        fileURL = try c.decodeIfPresent(String.self, forKey: .fileURL) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        localFile = try c.decodeIfPresent(String.self, forKey: .localFile) ?? ""
        rawJSON = try c.decodeIfPresent(String.self, forKey: .rawJSON)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(singer, forKey: .singer)
        try c.encode(source, forKey: .source)
        try c.encode(songmid, forKey: .songmid)
        try c.encode(quality, forKey: .quality)
        try c.encode(fileURL, forKey: .fileURL)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(localFile, forKey: .localFile)
        try c.encode(rawJSON, forKey: .rawJSON)
    }
}

final class DownloadService: NSObject, ObservableObject {
    static let shared = DownloadService()

    @Published private(set) var downloadsDir: URL
    @Published private(set) var downloadedSongs: [DownloadedSong] = []
    @Published var activeTasks: [String: Double] = [:] // id -> progress 0-1
    @Published var activeSongs: [String: LXSong] = [:] // id -> song metadata

    private var session: URLSession!
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private let queue = DispatchQueue(label: "download.service")

    override init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Downloads", isDirectory: true)
        downloadsDir = dir
        super.init()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        loadIndex()
    }

    func isDownloaded(_ song: LXSong) -> Bool {
        downloadedSongs.contains { $0.id == song.id }
    }

    func downloadedQuality(for song: LXSong) -> String? {
        downloadedSongs.first(where: { $0.id == song.id })?.quality
    }

    func localURL(for song: LXSong) -> URL? {
        guard let d = downloadedSongs.first(where: { $0.id == song.id }) else { return nil }
        let url = downloadsDir.appendingPathComponent(d.localFile)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func playLocal(_ song: LXSong) {
        guard let url = localURL(for: song) else { return }
        PlayerManager.shared.play(song: song)
    }

    func playDownloaded(_ d: DownloadedSong) {
        let url = downloadsDir.appendingPathComponent(d.localFile)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if let rawJSON = d.rawJSON, let data = rawJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let song = LXSong(obj)
            PlayerManager.shared.play(song: song)
        } else {
            PlayerManager.shared.playLocalFile(url: url, title: d.name, artist: d.singer)
        }
    }

    /// 从已下载列表点播：把整个列表作为播放队列，保证连续播放 / 下一首圈在当前列表内。
    func playDownloaded(_ d: DownloadedSong, in queue: [DownloadedSong]) {
        let url = downloadsDir.appendingPathComponent(d.localFile)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let songs = queue.compactMap { d -> LXSong? in
            guard let rawJSON = d.rawJSON, let data = rawJSON.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { LXSong($0) }
        }
        if let idx = songs.firstIndex(where: { $0.id == d.id }) {
            PlayerManager.shared.play(song: songs[idx], in: songs, index: idx)
        } else {
            playDownloaded(d)
        }
    }

    func download(_ song: LXSong, quality: String) {
        let songID = song.id + "_" + quality
        guard activeTasks[songID] == nil else { return }
        activeTasks[songID] = 0
        activeSongs[songID] = song

        Task {
            do {
                if song.source == "soda" {
                    // 汽水歌：调 qishui-api /song/play 拿解密后的完整音频（会员通道）
                    await startSodaDownload(song: song, quality: quality)
                } else {
                    let resolved = try await LXAPIClient.shared.downloadURL(for: song, quality: quality)
                    await startTask(song: song, quality: quality, resolvedURL: resolved)
                }
            } catch {
                await MainActor.run {
                    self.activeTasks[songID] = nil
                    self.activeSongs[songID] = nil
                }
            }
        }
    }

    /// 汽水歌下载（CDN 直连 + 客户端解密）：
    /// App 调 /song/stream 拿 CDN main_url + 密钥 → 直连汽水 CDN 拉加密字节 → 本地 SodaCTR 解密 →
    /// 落成可播 m4a。音频字节全程不过服务器，服务器只做签名/resolve。
    /// 下载串行门：同一时间只允许一个汽水下载占用 CDN 连接，
    /// 避免与播放的多个流式会话（同主机最多6并发）抢连接被饿死。
    private static let dlGate = AsyncDownloadGate()

    private func startSodaDownload(song: LXSong, quality: String) async {
        let songKey = song.id + "_" + quality
        let trackID = song.songmid ?? ""
        Log.write("📥 [SodaDL] start song=\(song.name) q=\(quality) trackID=\(trackID)")
        guard !trackID.isEmpty else {
            Log.write("❌ [SodaDL] trackID 为空，放弃")
            await clearActive(songKey)
            return
        }
        do {
            // ① 直连 CDN（带 Range/UA，串行+首字节看门狗）
            if let direct = try await tryDirectCDNDownload(song: song, quality: quality, trackID: trackID, songKey: songKey) {
                await finishSodaDownload(song: song, quality: quality, songKey: songKey, data: direct, alreadyDecrypted: false)
                return
            }
            // ② CDN 饿死/失败 → 回退服务器中转：qishui-api /song/play 服务端解密回传明文 m4a
            Log.write("🔁 [SodaDL] 直连CDN不可用，切换服务器中转 /song/play")
            let mapped = mapSodaQuality(quality)
            var comps = URLComponents(string: SodaAPIClient.shared.playbackBaseURL.map { $0 + "/song/play" } ?? "")
            comps?.queryItems = [URLQueryItem(name: "track_id", value: trackID), URLQueryItem(name: "quality", value: mapped)]
            guard let relayURL = comps?.url else {
                Log.write("❌ [SodaDL] 中转 URL 构造失败")
                await clearActive(songKey)
                return
            }
            let data = try await downloadRelay(url: relayURL, songKey: songKey)
            Log.write("📥 [SodaDL] 中转下载完成 \(data.count / 1024)KB")
            await finishSodaDownload(song: song, quality: quality, songKey: songKey, data: data, alreadyDecrypted: true)
        } catch {
            Log.write("❌ [SodaDL] 失败: \(error.localizedDescription)")
            await clearActive(songKey)
        }
    }

    private func mapSodaQuality(_ q: String) -> String {
        switch q {
        case "flac", "lossless": return "lossless"
        case "hi_res", "hires": return "hi_res"
        case "320k", "highest": return "highest"
        case "128k", "medium": return "medium"
        default: return "medium"
        }
    }

    /// 直连 CDN 拉取加密音频。返回 nil 表示应当走服务器中转。
    private func tryDirectCDNDownload(song: LXSong, quality: String, trackID: String, songKey: String) async throws -> Data? {
        let stream = try await SodaAPIClient.shared.songStream(trackID: trackID, quality: mapSodaQuality(quality))
        guard !stream.mainURL.isEmpty, stream.hexKey.count == 32, let url = URL(string: stream.mainURL) else {
            Log.write("⚠️ [SodaDL] stream 信息缺失，直接转中转")
            return nil
        }
        Log.write("📥 [SodaDL] stream ok hexKeyLen=32 cdn=\(url.host ?? "")")

        // 串行进入（避免与播放流式会话抢同主机连接配额）
        await Self.dlGate.wait()
        defer { Self.dlGate.signal() }
        await MainActor.run { self.activeTasks[songKey] = 0.05 }

        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue("bytes=0-", forHTTPHeaderField: "Range")
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 15_2 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        let cdnSession = URLSession(configuration: .default)
        let (bytes, response) = try await cdnSession.bytes(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 || status == 206 else {
            Log.write("⚠️ [SodaDL] CDN HTTP \(status)，转中转")
            return nil
        }
        let total = Int64(response.expectedContentLength)
        Log.write("📥 [SodaDL] CDN 连接 status=\(status) len=\(total <= 0 ? "未知" : "\(total / 1024)KB")")

        // 接收循环放在可取消的 Task 里；看门狗 12s 内未见 ≥64KB 就取消整个循环，
        // 避免被 CDN 冷处理时无限等待。
        final class RecvBox {
            private let l = NSLock()
            private var f = false
            private var c = 0
            func markFirst() { l.lock(); f = true; l.unlock() }
            func update(_ n: Int) { l.lock(); c = n; l.unlock() }
            func snap() -> (Bool, Int) { l.lock(); defer { l.unlock() }; return (f, c) }
        }
        let box = RecvBox()
        let loop = Task { () throws -> Data in
            var acc = Data()
            var lastReportBytes = 0
            for try await chunk in bytes {
                if !box.snap().0 {
                    box.markFirst()
                    Log.write("📥 [SodaDL] 收到首包，开始接收")
                }
                acc.append(chunk)
                box.update(acc.count)
                if acc.count - lastReportBytes >= 512 * 1024 {
                    lastReportBytes = acc.count
                    Log.write("📥 [SodaDL] 已收 \(acc.count / 1024)KB\(total > 0 ? " / \(total / 1024)KB" : "")")
                    await MainActor.run {
                        self.activeTasks[songKey] = total > 0
                            ? min(Double(acc.count) / Double(total), 0.95)
                            : min(0.05 + Double(acc.count) / 2_500_000.0 * 0.9, 0.92)
                    }
                }
                if acc.count > 256 * 1024 * 1024 {
                    throw NSError(domain: "Download", code: -6,
                                  userInfo: [NSLocalizedDescriptionKey: "音频文件过大"])
                }
            }
            return acc
        }
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            let (f, c) = box.snap()
            if !f || c < 64 * 1024 {
                Log.write("⏱️ [SodaDL] CDN 12s 内无有效数据(\(c / 1024)KB)，取消直连")
                loop.cancel()
            }
        }
        var received: Data?
        do {
            received = try await loop.value
        } catch {
            Log.write("⚠️ [SodaDL] CDN 接收中断(\(box.snap().1 / 1024)KB): \(error.localizedDescription)，转中转")
        }
        watchdog.cancel()
        guard let data = received, data.count > 128 * 1024 else {
            return nil
        }
        Log.write("📥 [SodaDL] CDN 下载完成 \(data.count / 1024)KB")
        // 客户端解密
        let finalData = try await Task.detached(priority: .userInitiated) { [self] in
            try decryptForDownload(data, hexKey: stream.hexKey)
        }.value
        Log.write("📥 [SodaDL] 解密完成 \(finalData.count / 1024)KB")
        return finalData
    }

    /// 服务器中转下载（服务端已解密的明文 m4a）
    private func downloadRelay(url: URL, songKey: String) async throws -> Data {
        await Self.dlGate.wait()
        defer { Self.dlGate.signal() }
        await MainActor.run { self.activeTasks[songKey] = max(self.activeTasks[songKey] ?? 0, 0.08) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        let session = URLSession(configuration: .default)
        let (bytes, response) = try await session.bytes(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw NSError(domain: "Download", code: -7,
                          userInfo: [NSLocalizedDescriptionKey: "中转通道 HTTP \(status)"])
        }
        Log.write("📥 [SodaDL] 中转连接 status=\(status)")
        var data = Data()
        var lastReportBytes = 0
        for try await chunk in bytes {
            data.append(chunk)
            if data.count - lastReportBytes >= 512 * 1024 {
                lastReportBytes = data.count
                Log.write("📥 [SodaDL] 中转已收 \(data.count / 1024)KB")
                await MainActor.run { self.activeTasks[songKey] = min(0.1 + Double(data.count) / 3_500_000.0 * 0.85, 0.95) }
            }
            if data.count > 256 * 1024 * 1024 {
                throw NSError(domain: "Download", code: -6,
                              userInfo: [NSLocalizedDescriptionKey: "音频文件过大"])
            }
        }
        return data
    }

    /// 解密产物/明文落盘并登记下载记录
    private func finishSodaDownload(song: LXSong, quality: String, songKey: String, data: Data, alreadyDecrypted: Bool) async {
        let docsDir = downloadsDir
        let idPart = song.songmid ?? song.id
        let destName = "\(Date().timeIntervalSince1970)_\(idPart).m4a"
        let dest = docsDir.appendingPathComponent(destName)
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
            try data.write(to: dest)
            Log.write("✅ [SodaDL] 落盘成功 \(dest.lastPathComponent) (\(data.count / 1024)KB)")
            // 汽水下载落的是裸 m4a，后台静默把封面+歌词打包进同目录 meta/，离线可显示封面/歌词
            let packSong = song
            let packDest = dest
            Task {
                await SongBundleWriter.bundle(song: packSong, audioURL: packDest) { s in
                    (try? await SodaAPIClient.shared.lyric(trackID: s.songmid ?? "")) ?? ""
                }
            }
            let downloaded = DownloadedSong(
                id: song.id,
                name: song.name,
                singer: song.singer,
                source: "soda",
                songmid: idPart,
                quality: quality,
                fileURL: dest.absoluteString,
                createdAt: Date(),
                localFile: destName,
                rawJSON: song.jsonData.flatMap { String(data: $0, encoding: .utf8) }
            )
            await MainActor.run {
                self.downloadedSongs.append(downloaded)
                self.saveIndex()
                self.activeTasks[songKey] = nil
                self.activeSongs[songKey] = nil
            }
        } catch {
            Log.write("❌ [SodaDL] 落盘失败: \(error.localizedDescription)")
            await clearActive(songKey)
        }
    }

    /// 客户端解密 CDN 音频字节 → 可播 m4a。无密钥或非 cenc 时原样返回。
    private func decryptForDownload(_ data: Data, hexKey: String) throws -> Data {
        guard hexKey.count == 32 else { return data }
        do {
            let parser = SodaCencParser(data)
            let parsed = try parser.parse(keyHex: hexKey)
            let ctr = SodaCTR(key: parsed.keyBytes)
            // 与缓存路径一致：decryptRange 的数据必须从 mdat 数据区起点开始，
            // 否则样本整体错位、原头部字节混进产物，下载出的文件无法播放。
            let start = parsed.encryptedMdatDataOffset
            guard data.count > start else { return data }
            let payload = data.subdata(in: start..<data.count)
            let decrypted = try ctr.decryptRange(samples: parsed.samples, encryptedData: payload,
                                                 startSample: 0, endSample: parsed.samples.count)
            return try parser.buildDecryptedFile(parsed: parsed, decryptedMdat: decrypted)
        } catch {
            // 非 cenc（明文直链）→ 原样返回，交由播放器识别
            return data
        }
    }

    @MainActor
    private func clearActive(_ songKey: String) {
        activeTasks[songKey] = nil
        activeSongs[songKey] = nil
    }

    @MainActor
    private func startTask(song: LXSong, quality: String, resolvedURL: String) async {
        let cfg = AppConfigStore.shared.config
        var comps = URLComponents(string: cfg.normalizedBaseURL + "/api/music/download")!
        var fileName = (song.name + " - " + song.singer).replacingOccurrences(of: "/", with: "_")
        let ext = quality == "flac" ? "flac" : "mp3"
        fileName = fileName + "." + ext
        comps.queryItems = [
            URLQueryItem(name: "url", value: resolvedURL),
            URLQueryItem(name: "filename", value: fileName),
            URLQueryItem(name: "tag", value: "1"),
            URLQueryItem(name: "lyric", value: "1"),
            URLQueryItem(name: "name", value: song.name),
            URLQueryItem(name: "singer", value: song.singer),
            URLQueryItem(name: "album", value: song.albumName),
            URLQueryItem(name: "pic", value: song.imageURL),
            URLQueryItem(name: "source", value: song.source),
            URLQueryItem(name: "songmid", value: song.songmid ?? ""),
            URLQueryItem(name: "hash", value: song.hash),
            URLQueryItem(name: "interval", value: song.interval),
        ]
        guard let url = comps.url else {
            activeTasks[song.id + "_" + quality] = nil
            activeSongs[song.id + "_" + quality] = nil
            return
        }
        var request = URLRequest(url: url)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue(AppConfigStore.shared.token ?? "", forHTTPHeaderField: "x-user-token")
        request.setValue(cfg.username, forHTTPHeaderField: "x-user-name")
        request.setValue(cfg.frontendPassword, forHTTPHeaderField: "x-frontend-auth")
        let task = session.downloadTask(with: request)
        tasks[song.id + "_" + quality] = task
        task.resume()
    }

    func cancel(songID: String) {
        if let t = tasks[songID] {
            t.cancel()
            tasks[songID] = nil
        }
        activeTasks[songID] = nil
        activeSongs[songID] = nil
    }

    func delete(_ downloaded: DownloadedSong) {
        let url = downloadsDir.appendingPathComponent(downloaded.localFile)
        try? FileManager.default.removeItem(at: url)
        downloadedSongs.removeAll { $0.id == downloaded.id }
        saveIndex()
    }

    func deleteMany(_ items: [DownloadedSong]) {
        guard !items.isEmpty else { return }
        let ids = Set(items.map { $0.id })
        for d in items {
            let url = downloadsDir.appendingPathComponent(d.localFile)
            try? FileManager.default.removeItem(at: url)
        }
        downloadedSongs.removeAll { ids.contains($0.id) }
        saveIndex()
    }

    private func loadIndex() {
        let url = downloadsDir.appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: url),
              let arr = try? JSONDecoder().decode([DownloadedSong].self, from: data) else { return }
        downloadedSongs = arr
    }

    private func saveIndex() {
        let url = downloadsDir.appendingPathComponent("index.json")
        if let data = try? JSONEncoder().encode(downloadedSongs) {
            try? data.write(to: url)
        }
    }
}

extension DownloadService: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0, let songKey = tasks.first(where: { $0.value == downloadTask })?.key else { return }
        let progress = min(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 1.0)
        DispatchQueue.main.async { self.activeTasks[songKey] = progress }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let songKey = tasks.first(where: { $0.value == downloadTask })?.key else { return }
        tasks.removeValue(forKey: songKey)
        guard let song = activeSongs[songKey] else { return }
        let quality = String(songKey.split(separator: "_").last ?? "320k")

        let docsDir = downloadsDir
        let idPart = song.songmid ?? song.id
        let ext = song.source == "soda" ? "m4a" : (quality == "flac" ? "flac" : "mp3")
        let destName = "\(Date().timeIntervalSince1970)_\(idPart).\(ext)"
        let dest = docsDir.appendingPathComponent(destName)
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            let song = DownloadedSong(
                id: song.id,
                name: song.name,
                singer: song.singer,
                source: song.source,
                songmid: idPart,
                quality: quality,
                fileURL: dest.absoluteString,
                createdAt: Date(),
                localFile: destName,
                rawJSON: song.jsonData.flatMap { String(data: $0, encoding: .utf8) }
            )
            DispatchQueue.main.async {
                self.downloadedSongs.append(song)
                self.saveIndex()
                self.activeTasks[songKey] = nil
                self.activeSongs[songKey] = nil
            }
        } catch {
            DispatchQueue.main.async {
                self.activeTasks[songKey] = nil
                self.activeSongs[songKey] = nil
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            DispatchQueue.main.async {
                if let songKey = self.tasks.first(where: { $0.value == task })?.key {
                    self.tasks[songKey] = nil
                    self.activeTasks[songKey] = nil
                    self.activeSongs[songKey] = nil
                }
            }
        }
    }
}

extension URL {
    var queryParameters: [String: String]? {
        guard let comps = URLComponents(url: self, resolvingAgainstBaseURL: false), let items = comps.queryItems else { return nil }
        var dict = [String: String]()
        for item in items { dict[item.name] = item.value }
        return dict
    }
}

/// 简易异步串行门：保证同一时间只有一个汽水下载占用 CDN 连接，
/// 防止与播放的多个流式会话抢同主机连接配额（iOS 每主机默认 6 并发）。
final class AsyncDownloadGate {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var occupied = false

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if !occupied {
                occupied = true
                lock.unlock()
                c.resume()
            } else {
                waiters.append(c)
                lock.unlock()
            }
        }
    }

    func signal() {
        lock.lock()
        if let next = waiters.first {
            waiters.removeFirst()
            lock.unlock()
            next.resume()
        } else {
            occupied = false
            lock.unlock()
        }
    }
}
