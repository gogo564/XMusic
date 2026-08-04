import Foundation
import Combine

class MusicCacheManager: ObservableObject {
    static let shared = MusicCacheManager()
    
    private let fileManager = FileManager.default
    private let cacheDirectoryName = "MusicCache"
    
    // Publish cache size for UI updates
    @Published var cacheSizeString: String = "0.0 MB"
    
    private var cancellables = Set<AnyCancellable>()
    private var downloadTasks: [String: URLSessionDownloadTask] = [:]
    
    private var cacheDirectory: URL? {
        guard let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return documentsDirectory.appendingPathComponent(cacheDirectoryName)
    }
    
    private init() {
        createCacheDirectory()
        updateCacheSize()
    }
    
    private func createCacheDirectory() {
        guard let cacheDirectory = cacheDirectory else { return }
        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            do {
                try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true, attributes: nil)
                print("📁 [Cache] Created cache directory: \(cacheDirectory.path)")
            } catch {
                print("❌ [Cache] Failed to create cache directory: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Public API
    
    func isCached(id: String) -> Bool {
        guard let fileURL = getFileURL(for: id) else { return false }
        guard fileManager.fileExists(atPath: fileURL.path) else { return false }
        // Validate the cached file is actually valid audio data
        return isValidAudioFile(at: fileURL)
    }

    func cachedURL(for id: String) -> URL? {
        guard let fileURL = getFileURL(for: id), fileManager.fileExists(atPath: fileURL.path) else { return nil }
        // Validate the cached file is actually valid audio data
        guard isValidAudioFile(at: fileURL) else {
            print("⚠️ [Cache] Cached file is invalid, removing: \(id)")
            try? fileManager.removeItem(at: fileURL)
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

        // Files smaller than 10KB are likely not valid audio
        let sizeKB = fileSize.int64Value / 1024
        guard sizeKB >= 10 else {
            print("⚠️ [Cache] File too small (\(sizeKB)KB) to be valid audio: \(url.lastPathComponent)")
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

        print("⚠️ [Cache] Unknown audio header: \(url.lastPathComponent), bytes: \(String(format: "%02X %02X %02X %02X", headerBytes[0], headerBytes[1], headerBytes[2], headerBytes[3]))")
        return false
    }
    
    func startCaching(url: String, id: String) {
        guard let remoteURL = URL(string: url), !isCached(id: id) else { return }

        // Avoid duplicate downloads
        if downloadTasks[id] != nil { return }

        print("📥 [Cache] Start downloading: \(id)")

        // Use a URLSession with the same headers that AVPlayer uses for this URL
        var request = URLRequest(url: remoteURL)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

        let task = URLSession.shared.downloadTask(with: request) { [weak self] tempURL, response, error in
            guard let self = self else { return }
            self.downloadTasks.removeValue(forKey: id)

            if let error = error {
                print("❌ [Cache] Download failed: \(error.localizedDescription)")
                return
            }

            // Validate response
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                print("❌ [Cache] Bad HTTP status: \(httpResponse.statusCode) for \(id)")
                return
            }

            guard let tempURL = tempURL, let destinationURL = self.getFileURL(for: id) else { return }

            do {
                if self.fileManager.fileExists(atPath: destinationURL.path) {
                    try self.fileManager.removeItem(at: destinationURL)
                }
                try self.fileManager.moveItem(at: tempURL, to: destinationURL)
                print("✅ [Cache] Cached successfully: \(id)")
                DispatchQueue.main.async {
                    self.updateCacheSize()
                }
            } catch {
                print("❌ [Cache] Save file failed: \(error.localizedDescription)")
            }
        }

        downloadTasks[id] = task
        task.resume()
    }
    
    func clearCache() {
        guard let cacheDirectory = cacheDirectory else { return }
        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
            for fileURL in fileURLs {
                try fileManager.removeItem(at: fileURL)
            }
            print("🧹 [Cache] Cleared all cache")
            updateCacheSize()
        } catch {
            print("❌ [Cache] Clear cache failed: \(error.localizedDescription)")
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
                print("⚠️ [Cache] Calculate size failed: \(error.localizedDescription)")
            }
            
            let mbSize = Double(size) / 1024 / 1024
            let formattedSize = String(format: "%.1f MB", mbSize)
            
            DispatchQueue.main.async {
                self.cacheSizeString = formattedSize
            }
        }
    }
    
    // MARK: - Helper
    
    private func getFileURL(for id: String) -> URL? {
        // Use mp3 extension by default, or could parse from URL if needed. 
        // For simplicity, we assume mp3/audio file.
        // To be safe we could just use the id as filename without extension or with a fixed one.
        // AVPlayer works fine with file URLs even without proper extension sometimes, 
        // but let's append .mp3 for clarity or if AVPlayer requires it.
        return cacheDirectory?.appendingPathComponent("\(id).mp3")
    }
}
