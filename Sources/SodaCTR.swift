import Foundation
import CommonCrypto

/// AES-128-CTR 解密（基于 CommonCrypto 的 ECB 原语实现 CTR 模式）。
/// 与 Node.js crypto aes-128-ctr 兼容：keystream_i = AES_ECB(key, IV + i)，明文 = 密文 XOR keystream。
struct SodaCTR {
    private let key: [UInt8]

    init(key: [UInt8]) {
        self.key = key
    }

    /// 对一个加密样本解密（每个样本独立 IV，IV 为 16 字节，counter 从 IV 起递增）
    func decrypt(sample: Data, iv: [UInt8]) -> Data {
        guard sample.count > 0 else { return sample }
        var counter = [UInt8](iv)
        if counter.count < 16 { counter.append(contentsOf: [UInt8](repeating: 0, count: 16 - counter.count)) }
        let output = sample.withUnsafeBytes { (srcPtr: UnsafeRawBufferPointer) -> Data in
            var result = Data(count: sample.count)
            result.withUnsafeMutableBytes { (dstPtr: UnsafeMutableRawBufferPointer) in
                let src = srcPtr.bindMemory(to: UInt8.self)
                let dst = dstPtr.bindMemory(to: UInt8.self)
                var consumed = 0
                while consumed < sample.count {
                    let keystream = ecbEncryptBlock(key: key, counter: counter)
                    let blockLen = min(16, sample.count - consumed)
                    for j in 0..<blockLen {
                        dst[consumed + j] = src[consumed + j] ^ keystream[j]
                    }
                    consumed += blockLen
                    incrementCounter(&counter)
                }
            }
            return result
        }
        return output
    }

    /// 解密一段跨越多个样本的加密数据。
    /// samples: 样本表；encryptedData: 待解密的加密字节（需覆盖从 startSample 起）
    func decryptRange(samples: [SodaCencParser.Sample], encryptedData: Data, startSample: Int, endSample: Int) throws -> Data {
        guard !samples.isEmpty, startSample < samples.count else { return Data() }
        let end = min(endSample, samples.count)
        var result = Data()
        var cursor = 0
        for i in 0..<startSample { cursor += samples[i].size }
        for i in startSample..<end {
            let sample = samples[i]
            guard cursor + sample.size <= encryptedData.count else { throw SodaCencError.invalidStructure("加密数据不完整") }
            let chunk = encryptedData.subdata(in: cursor..<(cursor + sample.size))
            result.append(decrypt(sample: chunk, iv: sample.iv))
            cursor += sample.size
        }
        return result
    }

    private func ecbEncryptBlock(key: [UInt8], counter: [UInt8]) -> [UInt8] {
        var outputBytes = [UInt8](repeating: 0, count: 16)
        key.withUnsafeBytes { keyPtr in
            counter.withUnsafeBytes { counterPtr in
                outputBytes.withUnsafeMutableBytes { outPtr in
                    _ = CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyPtr.baseAddress, key.count,
                        nil,
                        counterPtr.baseAddress, counter.count,
                        outPtr.baseAddress, outputBytes.count,
                        nil
                    )
                }
            }
        }
        return outputBytes
    }

    private func incrementCounter(_ counter: inout [UInt8]) {
        // 大端 +1（counter block 递增）
        for i in stride(from: counter.count - 1, through: 0, by: -1) {
            counter[i] &+= 1
            if counter[i] != 0 { break }
        }
    }
}
