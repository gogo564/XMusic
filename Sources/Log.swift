import Foundation

/// 简易文件日志：print 的同时追加到 Documents/xmusic.log，方便无 Console 环境（巨魔）查看。
enum Log {
    private static let lock = NSLock()
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static var fileURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("xmusic.log")
    }

    static func write(_ message: String) {
        let line = "[\(dateFormatter.string(from: Date()))] \(message)\n"
        print(message)
        lock.lock()
        defer { lock.unlock() }
        guard let url = fileURL else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            if let data = line.data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
        } else {
            try? line.data(using: .utf8)?.write(to: url)
        }
    }

    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        if let url = fileURL {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
