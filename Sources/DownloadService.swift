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
    private func startSodaDownload(song: LXSong, quality: String) async {
        let songKey = song.id + "_" + quality
        let trackID = song.songmid ?? ""
        guard !trackID.isEmpty else {
            await clearActive(songKey)
            return
        }
        do {
            let stream = try await SodaAPIClient.shared.songStream(trackID: trackID, quality: quality)
            guard !stream.mainURL.isEmpty, let url = URL(string: stream.mainURL) else {
                await clearActive(songKey)
                return
            }
            await MainActor.run { self.activeTasks[songKey] = 0.05 }

            // 直连 CDN 顺序拉取加密音频（流式累加，按已收字节报进度）
            let cdnSession = URLSession(configuration: .default)
            let (bytes, response) = try await cdnSession.bytes(from: url)
            let total = Int64(response.expectedContentLength)
            var data = Data()
            for try await chunk in bytes {
                data.append(chunk)
                if total > 0 {
                    let p = min(Double(data.count) / Double(total), 0.9)
                    await MainActor.run { self.activeTasks[songKey] = p }
                }
                if data.count > 256 * 1024 * 1024 {
                    throw NSError(domain: "Download", code: -6,
                                  userInfo: [NSLocalizedDescriptionKey: "音频文件过大"])
                }
            }

            // 客户端解密（复用流式解密组件），后台执行，落成可播 m4a
            let finalData = try await Task.detached(priority: .userInitiated) {
                try self.decryptForDownload(data, hexKey: stream.hexKey)
            }.value

            let docsDir = self.downloadsDir
            let idPart = song.songmid ?? song.id
            let destName = "\(Date().timeIntervalSince1970)_\(idPart).m4a"
            let dest = docsDir.appendingPathComponent(destName)
            try? FileManager.default.removeItem(at: dest)
            try finalData.write(to: dest)
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
            DispatchQueue.main.async {
                self.downloadedSongs.append(downloaded)
                self.saveIndex()
                self.activeTasks[songKey] = nil
                self.activeSongs[songKey] = nil
            }
        } catch {
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
            let decrypted = try ctr.decryptRange(samples: parsed.samples, encryptedData: data,
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
