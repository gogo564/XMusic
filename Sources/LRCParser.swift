import Foundation

struct LRCLine: Identifiable, Equatable {
    let id: Int
    let time: TimeInterval
    let text: String
}

struct LRC {
    let lines: [LRCLine]
    let translatedLines: [LRCLine]

    static func parse(_ content: String?, translation: String? = nil) -> LRC {
        var lines = parseContent(content)
        let translationMap = parseTranslation(translation)
        if !translationMap.isEmpty {
            lines = lines.map { line in
                if let trans = translationMap[line.time] {
                    return LRCLine(id: line.id, time: line.time, text: line.text + "\n" + trans)
                }
                return line
            }
        }
        return LRC(lines: lines, translatedLines: [])
    }

    /// True when the lyric content contains at least one timestamped line.
    static func hasTimestamps(_ content: String?) -> Bool {
        guard let content = content, !content.isEmpty else { return false }
        return content.contains("[") && content.range(of: #"\[\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?\]"#, options: .regularExpression) != nil
    }

    /// 网易/腾讯逐字歌词 (lxlyric): `[mm:ss.xxx]<offset,dur>字<...>` → 还原为普通带时间戳行。
    static func parseLxlyric(_ content: String?) -> [LRCLine] {
        guard let content = content, !content.isEmpty else { return [] }
        var result: [LRCLine] = []
        var idx = 0
        let pattern = #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        for rawLine in content.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let ns = line as NSString
            guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let time = timeFrom(match: m, line: line)
            var text = ""
            let lastEnd = m.range.location + m.range.length
            if lastEnd < ns.length {
                text = ns.substring(from: lastEnd)
            }
            // strip per-char timing tags <offset,duration>
            text = text.replacingOccurrences(of: #"<\d+,\d+>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            let existing = result.contains { abs($0.time - time) < 0.001 }
            if !existing {
                result.append(LRCLine(id: idx, time: time, text: text))
                idx += 1
            }
        }
        result.sort { $0.time < $1.time }
        result = result.enumerated().map { LRCLine(id: $0.offset, time: $0.element.time, text: $0.element.text) }
        return result
    }

    private static func timeFrom(match m: NSTextCheckingResult, line: String) -> TimeInterval {
        func group(_ i: Int) -> String? {
            guard m.numberOfRanges > i, m.range(at: i).location != NSNotFound,
                  let r = Range(m.range(at: i), in: line) else { return nil }
            return String(line[r])
        }
        let minute = Double(group(1) ?? "0") ?? 0
        let second = Double(group(2) ?? "0") ?? 0
        var millis = 0.0
        if let s = group(3) {
            switch s.count {
            case 1: millis = (Double(s) ?? 0) * 100
            case 2: millis = (Double(s) ?? 0) * 10
            default: millis = (Double(s) ?? 0)
            }
        }
        return minute * 60 + second + millis / 1000
    }

    private static func parseTranslation(_ content: String?) -> [TimeInterval: String] {
        guard let content = content, !content.isEmpty else { return [:] }
        var map: [TimeInterval: String] = [:]
        for line in parseContent(content) {
            if map[line.time] == nil {
                map[line.time] = line.text
            }
        }
        return map
    }

    private static func parseContent(_ content: String?) -> [LRCLine] {
        guard let content = content, !content.isEmpty else { return [] }
        var result: [LRCLine] = []
        var idx = 0

        let pattern = #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let isMetadata = { (s: String) -> Bool in
            s.hasPrefix("[ar:") || s.hasPrefix("[ti:") || s.hasPrefix("[al:")
                || s.hasPrefix("[by:") || s.hasPrefix("[offset:") || s.hasPrefix("[total:")
        }

        for rawLine in content.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if isMetadata(line) { continue }

            let ns = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }

            let lastEnd = (matches.last?.range.location ?? 0) + (matches.last?.range.length ?? 0)
            var text = ""
            if lastEnd < ns.length {
                text = ns.substring(from: lastEnd).trimmingCharacters(in: .whitespaces)
            }

            for m in matches {
                let time = timeFrom(match: m, line: line)
                let existing = result.contains { abs($0.time - time) < 0.001 }
                if !existing {
                    result.append(LRCLine(id: idx, time: time, text: text.isEmpty ? "..." : text))
                    idx += 1
                }
            }
        }

        result.sort { $0.time < $1.time }
        result = result.enumerated().map { LRCLine(id: $0.offset, time: $0.element.time, text: $0.element.text) }
        return result
    }

    func line(at time: TimeInterval) -> LRCLine? {
        var current: LRCLine?
        for line in lines where line.time <= time + 0.2 {
            current = line
        }
        return current
    }
}