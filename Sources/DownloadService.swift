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

    func localURL(for song: LXSong) -> URL? {
        guard let d = downloadedSongs.first(where: { $0.id == song.id }) else { return nil }
        let url = downloadsDir.appendingPathComponent(d.localFile)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func playLocal(_ song: LXSong) {
        guard let url = localURL(for: song) else { return }
        PlayerManager.shared.playLocalFile(url: url, title: song.name, artist: song.singer)
    }

    func download(_ song: LXSong, quality: String) {
        let songID = song.id + "_" + quality
        guard activeTasks[songID] == nil else { return }
        activeTasks[songID] = 0
        activeSongs[songID] = song

        Task {
            do {
                let resolved = try await LXAPIClient.shared.downloadURL(for: song, quality: quality)
                await startTask(song: song, quality: quality, resolvedURL: resolved)
            } catch {
                await MainActor.run {
                    self.activeTasks[songID] = nil
                    self.activeSongs[songID] = nil
                }
            }
        }
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
        let destName = "\(Date().timeIntervalSince1970)_\(idPart).\(quality == "flac" ? "flac" : "mp3")"
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
                localFile: destName
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
