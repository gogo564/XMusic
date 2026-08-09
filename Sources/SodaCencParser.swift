import Foundation

/// 汽水加密 m4a（cenc-aes-ctr）容器解析。
/// 结构：ftyp + moov(含 senc/saiz/saio 加密 box) + mdat(加密样本)
/// 参考 qishui-api src/audioDecryptor.js 的解密算法移植。
struct SodaCencParser {
    struct Box {
        let offset: Int
        let size: Int
        let type: String
        var dataOffset: Int { offset + 8 }
        var endOffset: Int { offset + size }
    }

    struct Sample {
        let size: Int
        let iv: [UInt8]
    }

    let fileData: Data

    init(_ data: Data) {
        self.fileData = data
    }

    private func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return data.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
    }

    private func asciiType(_ data: Data, _ offset: Int) -> String {
        guard offset + 4 <= data.count else { return "" }
        return String(data: data.subdata(in: offset..<(offset + 4)), encoding: .ascii) ?? ""
    }

    func findBox(_ type: String, from: Int = 0, to: Int? = nil) -> Box? {
        let end = to ?? fileData.count
        var pos = from
        while pos + 8 <= end {
            let size = Int(readUInt32(fileData, pos))
            if size < 8 || pos + size > end { break }
            let t = asciiType(fileData, pos + 4)
            if t == type { return Box(offset: pos, size: size, type: t) }
            pos += size
        }
        return nil
    }

    func childBoxes(of parent: Box) -> [Box] {
        var result: [Box] = []
        var pos = parent.offset + 8
        let end = parent.endOffset
        while pos + 8 <= end {
            let size = Int(readUInt32(fileData, pos))
            if size < 8 || pos + size > end { break }
            result.append(Box(offset: pos, size: size, type: asciiType(fileData, pos + 4)))
            pos += size
        }
        return result
    }

    func findDeepBox(_ type: String, in root: Box) -> Box? {
        if root.type == type { return root }
        for child in childBoxes(of: root) {
            if let found = findDeepBox(type, in: child) { return found }
        }
        return nil
    }

    struct Parsed {
        let ftyp: Box?
        let mdat: Box
        let samples: [Sample]
        /// 解密后各 chunk 在 mdat 数据区的起始偏移（相对解密文件 mdat 数据起点）
        let chunkOffsets: [Int]
        /// 加密文件里 mdat 数据起始
        let encryptedMdatDataOffset: Int
        /// 解密后 mdat 数据总长
        let decryptedPayloadSize: Int
        let keyBytes: [UInt8]
    }

    func parse(keyHex: String) throws -> Parsed {
        let keyBytes = hexToBytes(keyHex)
        guard let moov = findBox("moov") else { throw SodaCencError.missingBox("moov") }
        guard let mdat = findBox("mdat") else { throw SodaCencError.missingBox("mdat") }
        guard let trak = findDeepBox("trak", in: moov) else { throw SodaCencError.missingBox("trak") }
        guard let mdia = findDeepBox("mdia", in: trak) else { throw SodaCencError.missingBox("mdia") }
        guard let minf = findDeepBox("minf", in: mdia) else { throw SodaCencError.missingBox("minf") }
        guard let stbl = findDeepBox("stbl", in: minf) else { throw SodaCencError.missingBox("stbl") }
        guard let stsz = findDeepBox("stsz", in: stbl) else { throw SodaCencError.missingBox("stsz") }
        guard let stsc = findDeepBox("stsc", in: stbl) else { throw SodaCencError.missingBox("stsc") }
        guard let stco = findDeepBox("stco", in: stbl) else { throw SodaCencError.missingBox("stco") }
        guard let senc = findDeepBox("senc", in: stbl) ?? findDeepBox("senc", in: moov) else {
            throw SodaCencError.missingBox("senc")
        }

        let stszData = fileData.subdata(in: stsz.dataOffset..<stsz.endOffset)
        let stscData = fileData.subdata(in: stsc.dataOffset..<stsc.endOffset)
        let stcoData = fileData.subdata(in: stco.dataOffset..<stco.endOffset)
        let sencData = fileData.subdata(in: senc.dataOffset..<senc.endOffset)

        let sampleSizes = parseStsz(stszData)
        let stscEntries = parseStsc(stscData)
        let chunkCount = Int(readUInt32(stcoData, 4))
        let ivs = parseSenc(sencData)
        guard ivs.count >= sampleSizes.count else { throw SodaCencError.invalidStructure("senc IV 数量不足") }

        // 计算 chunk 偏移（相对解密后 mdat 数据起点，从 0 起算）
        var chunkOffsets: [Int] = []
        var current = 0
        var sampleIndex = 0
        for chunkIndex in 1...chunkCount {
            chunkOffsets.append(current)
            let samplesPerChunk = samplesPerChunk(for: chunkIndex, entries: stscEntries)
            for _ in 0..<samplesPerChunk {
                if sampleIndex < sampleSizes.count { current += sampleSizes[sampleIndex] }
                sampleIndex += 1
            }
        }

        let samples = zip(sampleSizes, ivs).map { Sample(size: $0, iv: $1) }
        let ftyp = findBox("ftyp")
        return Parsed(
            ftyp: ftyp,
            mdat: mdat,
            samples: samples,
            chunkOffsets: chunkOffsets,
            encryptedMdatDataOffset: mdat.offset + 8,
            decryptedPayloadSize: sampleSizes.reduce(0, +),
            keyBytes: keyBytes
        )
    }

    func hexToBytes(_ hex: String) -> [UInt8] {
        let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard clean.count == 32 else { return [] }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let next = clean.index(idx, offsetBy: 2)
            if let byte = UInt8(String(clean[idx..<next]), radix: 16) { bytes.append(byte) }
            idx = next
        }
        return bytes
    }

    private func parseStsz(_ data: Data) -> [Int] {
        let fixedSize = Int(readUInt32(data, 4))
        let count = Int(readUInt32(data, 8))
        if fixedSize != 0 { return Array(repeating: fixedSize, count: count) }
        var sizes: [Int] = []
        for i in 0..<count {
            sizes.append(Int(readUInt32(data, 12 + i * 4)))
        }
        return sizes
    }

    private struct StscEntry {
        let firstChunk: Int
        let samplesPerChunk: Int
    }

    private func parseStsc(_ data: Data) -> [StscEntry] {
        let count = Int(readUInt32(data, 4))
        var entries: [StscEntry] = []
        for i in 0..<count {
            entries.append(StscEntry(
                firstChunk: Int(readUInt32(data, 8 + i * 12)),
                samplesPerChunk: Int(readUInt32(data, 12 + i * 12))
            ))
        }
        return entries
    }

    private func samplesPerChunk(for chunkIndex: Int, entries: [StscEntry]) -> Int {
        for (i, entry) in entries.enumerated() {
            let next: StscEntry? = entries.indices.contains(i + 1) ? entries[i + 1] : nil
            if chunkIndex >= entry.firstChunk && (next == nil || chunkIndex < next!.firstChunk) {
                return entry.samplesPerChunk
            }
        }
        return 0
    }

    private func parseSenc(_ data: Data) -> [[UInt8]] {
        let count = Int(readUInt32(data, 4))
        var ivs: [[UInt8]] = []
        var pos = 8
        for _ in 0..<count {
            var iv = [UInt8](repeating: 0, count: 16)
            let avail = min(8, data.count - pos)
            if avail > 0 {
                for j in 0..<avail { iv[j] = data[pos + j] }
            }
            ivs.append(iv)
            pos += 8
        }
        return ivs
    }

    // MARK: - cleanMoov 构建（参考 JS processBoxTree）

    private let encryptedBoxTypes: Set<String> = ["senc", "saio", "saiz", "sinf", "schi", "tenc", "schm", "frma"]
    private let containerBoxTypes: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "stsd"]

    /// 构建解密版文件：ftyp + cleanMoov + mdat(解密后)
    func buildDecryptedFile(parsed: Parsed, decryptedMdat: Data) throws -> Data {
        let ftypSize = parsed.ftyp?.size ?? 0
        // 第一步：dummy（stco 用偏移 0）求 cleanMoov inner 长度
        let dummyInner = try processBoxTree(root: findBox("moov")!, newMdatOffset: 0, parsed: parsed)
        // 新文件布局 ftyp + [8字节moov头 + cleanInner] + [8字节mdat头 + payload]
        // mdat 数据起点 = ftypSize + dummyInner.count + 8 + 8
        let newMdatOffset = ftypSize + dummyInner.count + 16
        // 第二步：真实 stco 偏移
        let cleanMoovInner = try processBoxTree(root: findBox("moov")!, newMdatOffset: newMdatOffset, parsed: parsed)

        var output = Data()
        if let ftyp = parsed.ftyp {
            output.append(fileData.subdata(in: ftyp.offset..<ftyp.endOffset))
        }
        output.append(boxHeader("moov", innerSize: cleanMoovInner.count))
        output.append(cleanMoovInner)
        output.append(boxHeader("mdat", innerSize: decryptedMdat.count))
        output.append(decryptedMdat)
        return output
    }

    func boxHeader(_ type: String, innerSize: Int) -> Data {
        var size = UInt32(innerSize + 8).bigEndian
        var data = Data(type.utf8)
        data.insert(contentsOf: Swift.withUnsafeBytes(of: &size) { Array($0) }, at: 0)
        return data
    }

    func processBoxTreeForHeader(root: Box, newMdatOffset: Int, parsed: Parsed) throws -> Data {
        return try processBoxTree(root: root, newMdatOffset: newMdatOffset, parsed: parsed)
    }

    private func processBoxTree(root: Box, newMdatOffset: Int, parsed: Parsed) throws -> Data {
        var parts = Data()
        var pos = root.offset + 8
        let end = root.endOffset
        while pos < end {
            if pos + 8 > end {
                parts.append(fileData.subdata(in: pos..<end))
                break
            }
            let size = Int(readUInt32(fileData, pos))
            if size < 8 || size > end - pos {
                parts.append(fileData.subdata(in: pos..<end))
                break
            }
            let type = asciiType(fileData, pos + 4)
            let box = Box(offset: pos, size: size, type: type)

            if encryptedBoxTypes.contains(type) {
                pos += size
                continue
            }

            if type == "enca" {
                let inner = try processBoxTree(root: box, newMdatOffset: newMdatOffset, parsed: parsed)
                parts.append(boxHeader("mp4a", innerSize: inner.count))
                parts.append(inner)
                pos += size
                continue
            }

            if type == "stco" {
                let subdata = fileData.subdata(in: (pos + 8)..<(pos + size))
                let chunkCount = Int(readUInt32(subdata, 4))
                var body = Data(subdata.prefix(8))
                for offset in parsed.chunkOffsets.prefix(chunkCount) {
                    var v = UInt32(newMdatOffset + offset).bigEndian
                    body.append(contentsOf: Swift.withUnsafeBytes(of: &v) { Array($0) })
                }
                parts.append(boxHeader("stco", innerSize: body.count))
                parts.append(body)
                pos += size
                continue
            }

            if containerBoxTypes.contains(type) {
                let inner = try processBoxTree(root: box, newMdatOffset: newMdatOffset, parsed: parsed)
                parts.append(boxHeader(type, innerSize: inner.count))
                parts.append(inner)
                pos += size
                continue
            }

            parts.append(fileData.subdata(in: pos..<(pos + size)))
            pos += size
        }
        return parts
    }
}

enum SodaCencError: Error, LocalizedError {
    case missingBox(String)
    case invalidStructure(String)

    var errorDescription: String? {
        switch self {
        case .missingBox(let name): return "音频容器缺少 \(name) box"
        case .invalidStructure(let message): return "音频容器结构无效：\(message)"
        }
    }
}
