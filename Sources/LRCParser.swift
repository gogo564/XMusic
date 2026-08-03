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
                var minute = 0.0, second = 0.0, millis = 0.0
                if let r = Range(m.range(at: 1), in: line) { minute = Double(line[r]) ?? 0 }
                if let r = Range(m.range(at: 2), in: line) { second = Double(line[r]) ?? 0 }
                if m.numberOfRanges > 3, m.range(at: 3).location != NSNotFound, let r = Range(m.range(at: 3), in: line) {
                    let s = line[r]
                    switch s.count {
                    case 1: millis = (Double(s) ?? 0) * 100
                    case 2: millis = (Double(s) ?? 0) * 10
                    default: millis = (Double(s) ?? 0) / 10
                    }
                }
                let time = minute * 60 + second + millis / 1000
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