import Foundation
import Combine

class MusicCacheManager: ObservableObject {
    static let shared = MusicCacheManager()
    
    private let fileManager = FileManager.default
    private let cacheDirectoryName = "MusicCache"
    private let maxCacheBytes: Int64 = 2 * 1024 * 1024 * 1024 // 2GB
    
    // Publish cache size for UI updates
    @Published var cacheSizeString: String = "0.0 MB"
    
    private var cancellables = Set<AnyCancellable>()
    private var downloadTasks: [String: URLSessionDownloadTask] = [:]
    
    // 缓存文件内存索引（仅文件名，避免列表滚动时每次渲染做目录扫描）。
    // 线程安全：读写都在 cachedFilesLock 下进行。
    private var cachedFiles = Set<String>()
    private let cachedFilesLock = NSLock()

    /// 汽水整首缓存的任务指纹集合（防重复入队）。读写受 sodaCacheLock 保护。
    private var sodaCacheTasks = Set<String>()
    private let sodaCacheLock = NSLock()

    /// 音频校验记忆化：path → (mtime, size, 是否有效)。
    /// 校验要读 32KB 头，m4a 还要扫 1MB 找加密 box；同一次点播 isCached/cachedURL
    /// 会连续调用两遍，列表渲染也会频繁查询——按文件大小+修改时间缓存结果避免重扫。
    private var validationMemo: [String: (mtime: Date, size: Int64, ok: Bool)] = [:]
    private let validationMemoLock = NSLock()
    
    private var cacheDirectory: URL? {
        guard let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return documentsDirectory.appendingPathComponent(cacheDirectoryName)
    }
    
    private init() {
        createCacheDirectory()
        updateCacheSize()
        refreshCacheIndex()
    }
    
    /// 重新扫描一次缓存目录，重建内存索引（启动时 / 清空缓存后调用）。
    private func refreshCacheIndex() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self, let cacheDirectory = self.cacheDirectory else { return }
            let names = (try? self.fileManager.contentsOfDirectory(atPath: cacheDirectory.path)) ?? []
            self.cachedFilesLock.lock()
            self.cachedFiles = Set(names)
            self.cachedFilesLock.unlock()
        }
    }
    
    private func createCacheDirectory() {
        guard let cacheDirectory = cacheDirectory else { return }
        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            do {
                try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true, attributes: nil)
        Log.write("📁 [Cache] Created cache directory: \(cacheDirectory.path)")
            } catch {
        Log.write("❌ [Cache] Failed to create cache directory: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Public API
    
    /// 任意音质版本是否已缓存（用于列表展示/离线判断）。走内存索引，不触碰文件系统。
    func isCached(id: String) -> Bool {
        cachedFilesLock.lock()
        defer { cachedFilesLock.unlock() }
        return cachedFiles.contains { $0.hasPrefix(id + "_") || $0.hasPrefix(id + ".") }
    }

    private func removeCachedFile(_ name: String) {
        cachedFilesLock.lock()
        cachedFiles.remove(name)
        cachedFilesLock.unlock()
    }

    private func addCachedFile(_ name: String) {
        cachedFilesLock.lock()
        cachedFiles.insert(name)
        cachedFilesLock.unlock()
    }

    func isCached(id: String, quality: String) -> Bool {
        guard let fileURL = matchedCacheURL(for: id, quality: quality) else { return false }
        // Validate the cached file is actually valid audio data
        return isValidAudioFile(at: fileURL)
    }

    func cachedURL(for id: String, quality: String) -> URL? {
        guard let fileURL = matchedCacheURL(for: id, quality: quality) else { return nil }
        // Validate the cached file is actually valid audio data
        guard isValidAudioFile(at: fileURL) else {
        Log.write("⚠️ [Cache] Cached file is invalid, removing: \(id)_\(quality)")
            try? fileManager.removeItem(at: fileURL)
            removeCachedFile(fileURL.lastPathComponent)
            return nil
        }
        return fileURL
    }

    /// Check if a file contains valid audio data by examining file size and magic bytes
    private func isValidAudioFile(at url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber else {
            return false
        }
        let mtime = (attributes[.modificationDate] as? Date) ?? .distantPast
        validationMemoLock.lock()
        let memo = validationMemo[url.path]
        validationMemoLock.unlock()
        if let memo = memo, memo.size == fileSize.int64Value, memo.mtime == mtime {
            return memo.ok
        }
        let ok = validateAudioFile(at: url, fileSize: fileSize)
        validationMemoLock.lock()
        validationMemo[url.path] = (mtime, fileSize.int64Value, ok)
        validationMemoLock.unlock()
        return ok
    }

    private func validateAudioFile(at url: URL, fileSize: NSNumber) -> Bool {
        // Files smaller than 10KB are likely not valid audio
        let sizeKB = fileSize.int64Value / 1024
        guard sizeKB >= 10 else {
        Log.write("⚠️ [Cache] File too small (\(sizeKB)KB) to be valid audio: \(url.lastPathComponent)")
            return false
        }

        // Check for common audio file headers
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        // Read the start of the file. If it carries an ID3v2 tag, skip past it and
        // validate the actual audio payload (many MP3s start with "ID3", not 0xFF).
        let readLength = 32 * 1024
        var headerData = handle.readData(ofLength: readLength)
        if headerData.count >= 3,
           String(bytes: headerData[0..<3], encoding: .ascii) == "ID3",
           headerData.count >= 10 {
            let tagSize = ((Int(headerData[6]) & 0x7F) << 21) | ((Int(headerData[7]) & 0x7F) << 14) | ((Int(headerData[8]) & 0x7F) << 7) | (Int(headerData[9]) & 0x7F)
            let audioOffset = 10 + tagSize
            if audioOffset < headerData.count {
                headerData = Data(headerData[audioOffset...])
            } else {
                handle.seek(toFileOffset: UInt64(audioOffset))
                headerData = handle.readData(ofLength: readLength)
            }
        }
        guard headerData.count >= 4 else { return false }
        let headerBytes = [UInt8](headerData)

        // MP3: starts with 0xFF 0xFB, 0xFF 0xFA, or 0xFF 0xF3
        if headerBytes[0] == 0xFF && (headerBytes[1] & 0xF0) == 0xF0 {
            return true
        }

        // MP4/M4A: starts with "ftyp" at offset 4
        if headerData.count >= 8 {
            let ftypRange = 4..<min(8, headerData.count)
            if String(bytes: headerData[ftypRange], encoding: .ascii) == "ftyp" {
                // 若容量仍是未被解密的加密文件（moov 数据前含 senc/sinf/tenc 加密 box），
                // 判定无效：这种文件能读到时长但样本为密文，AVPlayer 解码必失败。
                // （历史 bug 可能把未解密的加密字节落盘成 .m4a，需逐出以免误当可播缓存。）
                if containsEncryptionBoxes(at: url) {
        Log.write("⚠️ [Cache] Encrypted (undecrypted) cache, rejecting: \(url.lastPathComponent)")
                    return false
                }
                return true
            }
        }

        // WAV: starts with "RIFF"
        if headerData.count >= 4, String(bytes: headerData[0..<4], encoding: .ascii) == "RIFF" {
            return true
        }

        // OGG: starts with "OggS"
        if headerData.count >= 4, String(bytes: headerData[0..<4], encoding: .ascii) == "OggS" {
            return true
        }

        // FLAC: starts with "fLaC"
        if headerData.count >= 4, String(bytes: headerData[0..<4], encoding: .ascii) == "fLaC" {
            return true
        }

        Log.write("⚠️ [Cache] Unknown audio header: \(url.lastPathComponent), bytes: \(String(format: "%02X %02X %02X %02X", headerBytes[0], headerBytes[1], headerBytes[2], headerBytes[3]))")
        return false
    }

    /// 检测 m4a 是否仍是未解密的加密文件：扫描文件头部区域里的 moov 结构，
    /// 若存在 senc/sinf/tenc/saiz/saio 等 CENC 加密 box 则判定为未解密。
    /// moov 通常位于文件前部且体积远小于音频数据，只读前 1MB 足够覆盖。
    private func containsEncryptionBoxes(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 1024 * 1024)
        guard data.count >= 8 else { return true }
        // 在 moov box 内部扫描加密子 box 类型。直接把整个头部当连续字节搜索，
        // 因为 senc/sinf/tenc/saiz/saio/schm/cenc 这些 ASCII 类型名极不可能出现在音频样本
        // 明文里，误报风险可忽略。
        let candidates = ["senc", "sinf", "tenc", "saiz", "saio"]
        for c in candidates {
            let needle = Data(c.utf8)
            if data.range(of: needle) != nil {
                return true
            }
        }
        return false
    }
    
    func startCaching(url: String, quality: String, id: String) {
        guard let remoteURL = URL(string: url), !isCached(id: id, quality: quality) else { return }
        // 汽水流式（sodastream://）由 AVAssetResourceLoader 直连解密，无需走本地缓存
        if remoteURL.scheme == "sodastream" { return }

        // Avoid duplicate downloads
        let taskKey = id + "_" + quality
        if downloadTasks[taskKey] != nil { return }

        Log.write("📥 [Cache] Start downloading: \(id)_\(quality)")

        // Use a URLSession with the same headers that AVPlayer uses for this URL
        var request = URLRequest(url: remoteURL)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

        let task = URLSession.shared.downloadTask(with: request) { [weak self] tempURL, response, error in
            guard let self = self else { return }
            self.downloadTasks.removeValue(forKey: taskKey)

            if let error = error {
        Log.write("❌ [Cache] Download failed: \(error.localizedDescription)")
                return
            }

            // Validate response
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
        Log.write("❌ [Cache] Bad HTTP status: \(httpResponse.statusCode) for \(id)_\(quality)")
                return
            }

            guard let tempURL = tempURL, let destinationURL = self.getFileURL(for: id, quality: quality) else { return }

            do {
                if self.fileManager.fileExists(atPath: destinationURL.path) {
                    try self.fileManager.removeItem(at: destinationURL)
                }
                // 迁移：清理旧版不带音质的同名缓存（\(id).mp3）
                if let oldURL = self.getLegacyFileURL(for: id), self.fileManager.fileExists(atPath: oldURL.path) {
                    try? self.fileManager.removeItem(at: oldURL)
                    self.removeCachedFile(oldURL.lastPathComponent)
                }
                try self.fileManager.moveItem(at: tempURL, to: destinationURL)
        Log.write("✅ [Cache] Cached successfully: \(id)_\(quality)")
                self.addCachedFile(destinationURL.lastPathComponent)
                self.enforceCacheLimit()
            } catch {
        Log.write("❌ [Cache] Save file failed: \(error.localizedDescription)")
            }
        }

        downloadTasks[taskKey] = task
        task.resume()
    }
    
    /// 汽水加密流整首后台缓存（播放即缓存）：
    /// App 调 /song/stream 拿 CDN main_url + 密钥 → 直连汽水 CDN 拉加密字节 →
    /// 客户端 SodaCTR 本地解密 → 落盘缓存目录（沿用 \(id)_\(quality).mp3 命名，
    /// 使 isCached/cachedURL 命中，下次播放直接读本地文件，不再走 CDN + NAS 签名）。
    /// 音频字节全程不过服务器，服务器只做签名/resolve。
    func cacheSodaTrack(trackID: String, id: String, quality: String) {
        guard !trackID.isEmpty, !isCached(id: id, quality: quality) else { return }
        let taskKey = "soda_" + id + "_" + quality
        sodaCacheLock.lock()
        if sodaCacheTasks.contains(taskKey) {
            sodaCacheLock.unlock()
            return
        }
        sodaCacheTasks.insert(taskKey)
        sodaCacheLock.unlock()
        Log.write("📥 [Cache] Soda whole-song caching start: \(id)_\(quality)")
        let cacheTask = Task(priority: .utility) {
            do {
                let stream = try await SodaAPIClient.shared.songStream(trackID: trackID, quality: quality)
                guard !stream.mainURL.isEmpty, let url = URL(string: stream.mainURL) else {
                    self.finishSodaCache(taskKey)
                    return
                }
                // 直连 CDN 拉取加密音频
                let (bytes, response) = try await URLSession.shared.bytes(from: url)
                let total = Int64(response.expectedContentLength)
                var data = Data()
                for try await chunk in bytes {
                    data.append(chunk)
                    if data.count > 256 * 1024 * 1024 {
                        throw NSError(domain: "Cache", code: -6,
                                      userInfo: [NSLocalizedDescriptionKey: "音频文件过大"])
                    }
                }
                guard total <= 0 || !data.isEmpty else { throw NSError(domain: "Cache", code: -7, userInfo: [:]) }

                // 客户端解密后落盘
                let decrypted = try await Task.detached(priority: .utility) {
                    try self.decryptSodaForCache(data, hexKey: stream.hexKey)
                }.value
                guard let dest = self.getSodaFileURL(for: id, quality: quality) else {
                    self.finishSodaCache(taskKey)
                    return
                }
                if self.fileManager.fileExists(atPath: dest.path) {
                    try self.fileManager.removeItem(at: dest)
                }
                try decrypted.write(to: dest)
                self.addCachedFile(dest.lastPathComponent)
                self.finishSodaCache(taskKey)
                self.enforceCacheLimit()
        Log.write("✅ [Cache] Soda whole-song cached: \(id)_\(quality)")
            } catch {
                self.finishSodaCache(taskKey)
        Log.write("❌ [Cache] Soda whole-song cache failed: \(error.localizedDescription)")
            }
        }
    }

    private func finishSodaCache(_ taskKey: String) {
        sodaCacheLock.lock()
        sodaCacheTasks.remove(taskKey)
        sodaCacheLock.unlock()
    }

    /// 流式会话转存缓存：SodaStreamSession 播放时已经把整首加密数据拉到内存，
    /// 下载完成后直接解密落盘，省掉后台缓存任务对 CDN 的第二份全量下载。
    /// fileKey 为缓存文件名（不含扩展名），由播放侧传入，保证与起播查询的
    /// 音质档完全一致（如 "{songID}_320k"）。
    func writeSodaCacheFromStream(fileKey: String, encrypted: Data, hexKey: String) {
        guard !fileKey.isEmpty, !encrypted.isEmpty else { return }
        let dest = cacheDirectory?.appendingPathComponent(fileKey + ".m4a")
        guard let dest else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let decrypted = try self.decryptSodaForCache(encrypted, hexKey: hexKey)
                if self.fileManager.fileExists(atPath: dest.path) {
                    try self.fileManager.removeItem(at: dest)
                }
                try decrypted.write(to: dest)
                self.addCachedFile(dest.lastPathComponent)
                self.enforceCacheLimit()
                Log.write("✅ [Cache] Soda 流式转存完成: \(fileKey).m4a (\(decrypted.count/1024)KB)")
            } catch {
                Log.write("❌ [Cache] Soda 流式转存失败 \(fileKey): \(error.localizedDescription)")
            }
        }
    }

    /// 客户端解密汽水 CDN 音频字节（cenc-aes-ctr）→ 可播 m4a。
    /// 无密钥（明文直链）原样返回；有密钥但解析/解密失败则抛错（缓存失败），
    /// 绝不把未解密的加密字节落盘——否则会产生「假缓存」：能读到时长但样本仍是
    /// 密文，AVPlayer 解码失败 → item failed / 无进度条 / 点播放无反应。
    private func decryptSodaForCache(_ data: Data, hexKey: String) throws -> Data {
        guard hexKey.count == 32 else { return data }
        let parser = SodaCencParser(data)
        let parsed = try parser.parse(keyHex: hexKey)
        let ctr = SodaCTR(key: parsed.keyBytes)
        let decrypted = try ctr.decryptRange(samples: parsed.samples, encryptedData: data,
                                             startSample: 0, endSample: parsed.samples.count)
        return try parser.buildDecryptedFile(parsed: parsed, decryptedMdat: decrypted)
    }

    func clearCache() {
        guard let cacheDirectory = cacheDirectory else { return }
        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
            for fileURL in fileURLs {
                try fileManager.removeItem(at: fileURL)
            }
        Log.write("🧹 [Cache] Cleared all cache")
            cachedFilesLock.lock()
            cachedFiles.removeAll()
            cachedFilesLock.unlock()
            updateCacheSize()
        } catch {
        Log.write("❌ [Cache] Clear cache failed: \(error.localizedDescription)")
        }
    }

    /// 缓存总量超过上限时，按修改时间从旧到新清理（跳过正在播放的文件），直至不超过 2GB。
    func enforceCacheLimit() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self, let cacheDirectory = self.cacheDirectory else { return }

            var files: [(url: URL, size: Int64, modified: Date)] = []
            var total: Int64 = 0
            do {
                let fileURLs = try self.fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
                for fileURL in fileURLs {
                    let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    let size = Int64(values?.fileSize ?? 0)
                    total += size
                    files.append((fileURL, size, values?.contentModificationDate ?? .distantPast))
                }
            } catch {
                return
            }

            guard total > self.maxCacheBytes else { return }

            files.sort { $0.modified < $1.modified }
            let playingPath = PlayerManager.shared.currentPlaybackURL?.path
            for f in files {
                guard total > self.maxCacheBytes else { break }
                guard f.url.path != playingPath else { continue }
                if (try? self.fileManager.removeItem(at: f.url)) != nil {
                    total -= f.size
                    self.removeCachedFile(f.url.lastPathComponent)
        Log.write("🗑️ [Cache] Evicted (limit): \(f.url.lastPathComponent)")
                }
            }

            DispatchQueue.main.async {
                self.updateCacheSize()
            }
        }
    }
    
    func updateCacheSize() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self, let cacheDirectory = self.cacheDirectory else { return }
            
            var size: Int64 = 0
            do {
                let fileURLs = try self.fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey])
                for fileURL in fileURLs {
                    if let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                       let fileSize = resourceValues.fileSize {
                        size += Int64(fileSize)
                    }
                }
            } catch {
        Log.write("⚠️ [Cache] Calculate size failed: \(error.localizedDescription)")
            }
            
            let mbSize = Double(size) / 1024 / 1024
            let formattedSize = String(format: "%.1f MB", mbSize)
            
            DispatchQueue.main.async {
                self.cacheSizeString = formattedSize
            }
        }
    }
    
    // MARK: - Helper
    
    private func getFileURL(for id: String, quality: String) -> URL? {
        return cacheDirectory?.appendingPathComponent("\(id)_\(quality).mp3")
    }

    /// 汽水缓存落盘用 .m4a：汽水解密后是 m4a 内容，若沿用 .mp3 扩展名，
    /// AVPlayer 会按 MP3 解析 m4a 导致时长错乱/不播放/秒切歌。
    private func getSodaFileURL(for id: String, quality: String) -> URL? {
        return cacheDirectory?.appendingPathComponent("\(id)_\(quality).m4a")
    }

    /// 命中查询：优先 .m4a。若发现旧版误命名的 .mp3 汽水缓存（内容实为 m4a，
    /// 以 ftyp 魔数判断），自动改名为 .m4a 修复，避免 AVPlayer 按 MP3 解析 m4a。
    private func matchedCacheURL(for id: String, quality: String) -> URL? {
        if let sodaURL = getSodaFileURL(for: id, quality: quality), fileManager.fileExists(atPath: sodaURL.path) {
            return sodaURL
        }
        if let mp3URL = getFileURL(for: id, quality: quality), fileManager.fileExists(atPath: mp3URL.path) {
            if isM4AContent(at: mp3URL), let sodaURL = getSodaFileURL(for: id, quality: quality) {
                try? fileManager.moveItem(at: mp3URL, to: sodaURL)
                removeCachedFile(mp3URL.lastPathComponent)
                if fileManager.fileExists(atPath: sodaURL.path) {
                    addCachedFile(sodaURL.lastPathComponent)
                    return sodaURL
                }
            }
            return mp3URL
        }
        return nil
    }

    /// 跨音质命中：返回该歌曲任意音质版本的缓存文件。
    /// 场景：列表"缓存"角标按任意音质判断，而起播原本只精确匹配当前音质档，
    /// 音质设置变过之后永远 miss → 明明有缓存却每次都走网络重新解析。
    /// 本地任意音质秒开都远好于慢网整首拉取，故汽水等场景允许降级/升级命中。
    func anyQualityCachedURL(for id: String) -> URL? {
        var name: String?
        cachedFilesLock.lock()
        // 优先 m4a，其次 mp3
        name = cachedFiles.first { $0.hasPrefix(id + "_") && $0.hasSuffix(".m4a") }
            ?? cachedFiles.first { $0.hasPrefix(id + "_") && $0.hasSuffix(".mp3") }
            ?? cachedFiles.first { $0.hasPrefix(id + ".") }
        cachedFilesLock.unlock()
        guard let fileName = name, let dir = cacheDirectory else { return nil }
        let url = dir.appendingPathComponent(fileName)
        return isValidAudioFile(at: url) ? url : nil
    }

    /// 判断文件内容是否为 m4a/mp4（起始含 ftyp box），用于识别误命名为 .mp3 的汽水缓存。
    private func isM4AContent(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 16)
        guard data.count >= 8 else { return false }
        return String(bytes: data[4..<8], encoding: .ascii) == "ftyp"
    }

    private func getLegacyFileURL(for id: String) -> URL? {
        return cacheDirectory?.appendingPathComponent("\(id).mp3")
    }
}
