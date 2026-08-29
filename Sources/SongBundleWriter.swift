import Foundation

/// 统一的"歌曲本地资源打包"写盘器：在音频文件所在目录的 meta/ 子目录里，
/// 存下封面（{id}_cover.jpg）与歌词（{id}.lrc），让缓存与下载共用同一套写盘逻辑，
/// 播放/显示时优先读本地（离线可用）。
///
/// 关键约束：必须放在 meta/ 子目录而非音频平铺目录。MusicCacheManager 的
/// isCached/anyQualityCachedURL 用 "\(id)_" / "\(id)." 前缀判定音频缓存，若把封面/歌词
/// 平铺进 MusicCache 会被误判为音频缓存（从而被当坏文件清掉或命中误报）。
/// meta/ 是缓存索引的平面扫描不会递归进入的子目录，天然隔离。
enum SongBundleWriter {

    // MARK: - 目录定位
    private static func docsDir() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }
    static var cacheDir: URL? { docsDir()?.appendingPathComponent("MusicCache") }
    static var downloadsDir: URL? { docsDir()?.appendingPathComponent("Downloads") }

    static func metaDir(under dir: URL) -> URL {
        dir.appendingPathComponent("meta", isDirectory: true)
    }
    static func coverURL(for song: LXSong, in dir: URL) -> URL {
        metaDir(under: dir).appendingPathComponent(song.id + "_cover.jpg")
    }
    static func lyricURL(for song: LXSong, in dir: URL) -> URL {
        metaDir(under: dir).appendingPathComponent(song.id + ".lrc")
    }

    // MARK: - 写盘
    /// 在 audioURL 所在目录的 meta/ 下写入封面与歌词。全部非致命：任一步失败只记日志，
    /// 不影响音频主流程；已存在的同名文件跳过（幂等，避免每次播放重复下载封面歌词）。
    /// - Parameters:
    ///   - song: 歌曲元数据（取 imageURL 下载封面）
    ///   - audioURL: 已落盘的本地音频文件（其父目录决定 meta/ 归属）
    ///   - lyricProvider: 按音源取歌词文本（Soda 走 qishui /lyric，其余走 LX /api/music/lyric 等）
    static func bundle(song: LXSong, audioURL: URL, lyricProvider: (LXSong) async -> String) async {
        let dir = audioURL.deletingLastPathComponent()
        let meta = metaDir(under: dir)
        do {
            try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        } catch {
            Log.write("❌ [Bundle] 创建 meta 目录失败 \(dir.path): \(error.localizedDescription)")
            return
        }

        // 封面：仅当本地尚无且 imageURL 有效时才网络拉取
        let cover = coverURL(for: song, in: dir)
        if !song.imageURL.isEmpty, !FileManager.default.fileExists(atPath: cover.path),
           let url = URL(string: song.imageURL) {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty {
                    try fsyncWrite(data, to: cover)
                    Log.write("🖼️ [Bundle] 封面已存 \(cover.lastPathComponent) (\(data.count/1024)KB)")
                }
            } catch {
                // 封面拉取偶发失败不阻塞主流程，也不写日志（保持健康日志干净，留待下次重试）
            }
        }

        // 歌词：仅当本地尚无且能取到非空文本时才写
        let lyricURL = lyricURL(for: song, in: dir)
        if !FileManager.default.fileExists(atPath: lyricURL.path) {
            let text = await lyricProvider(song)
            if !text.isEmpty, let data = text.data(using: .utf8) {
                try? fsyncWrite(data, to: lyricURL)
                Log.write("📝 [Bundle] 歌词已存 \(lyricURL.lastPathComponent)")
            }
        }
    }

    /// 用 FileHandle 写入并同步落盘，避免"写完即被读"读到未落盘/截断内容（与缓存 m4a 同款做法）
    private static func fsyncWrite(_ data: Data, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let fh = try FileHandle(forWritingTo: url)
        try fh.write(contentsOf: data)
        try fh.synchronizeFile()
        try fh.close()
    }

    // MARK: - 读取（本地优先，下载目录优先于缓存目录）
    static func localCover(for song: LXSong) -> URL? {
        for dir in [downloadsDir, cacheDir] {
            guard let dir else { continue }
            let u = coverURL(for: song, in: dir)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    static func localLyric(for song: LXSong) -> String? {
        for dir in [downloadsDir, cacheDir] {
            guard let dir else { continue }
            let u = lyricURL(for: song, in: dir)
            if let data = try? Data(contentsOf: u), let s = String(data: data, encoding: .utf8), !s.isEmpty {
                return s
            }
        }
        return nil
    }
}