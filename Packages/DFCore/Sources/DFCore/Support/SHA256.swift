import Foundation

/// 纯 Swift SHA-256 实现。
/// 之所以不直接用 CryptoKit：附件校验需要在 Linux CI 上跑单测，
/// 而 CryptoKit 不提供 Linux 实现。本实现已用 NIST 标准向量测试。
public enum SHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    private static func rotateRight(_ value: UInt32, _ bits: UInt32) -> UInt32 {
        (value >> bits) | (value << (32 - bits))
    }

    public static func hash(_ data: Data) -> String {
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8

        message.append(0x80)
        while message.count % 64 != 56 {
            message.append(0x00)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
        }

        var state: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
        ]

        var w = [UInt32](repeating: 0, count: 64)
        var offset = 0
        while offset < message.count {
            for i in 0..<16 {
                let base = offset + i * 4
                w[i] = (UInt32(message[base]) << 24)
                    | (UInt32(message[base + 1]) << 16)
                    | (UInt32(message[base + 2]) << 8)
                    | UInt32(message[base + 3])
            }
            for i in 16..<64 {
                let s0 = rotateRight(w[i - 15], 7) ^ rotateRight(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotateRight(w[i - 2], 17) ^ rotateRight(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }

            var a = state[0], b = state[1], c = state[2], d = state[3]
            var e = state[4], f = state[5], g = state[6], h = state[7]

            for i in 0..<64 {
                let s1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = h &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj

                h = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }

            state[0] = state[0] &+ a
            state[1] = state[1] &+ b
            state[2] = state[2] &+ c
            state[3] = state[3] &+ d
            state[4] = state[4] &+ e
            state[5] = state[5] &+ f
            state[6] = state[6] &+ g
            state[7] = state[7] &+ h

            offset += 64
        }

        return state.map { String(format: "%08x", $0) }.joined()
    }

    public static func hash(_ string: String) -> String {
        hash(Data(string.utf8))
    }

    /// 增量哈希：大文件（本地模型）必须边读边算，不能整个读进内存。
    /// 用法：`var hasher = SHA256.Hasher(); hasher.update(chunk); hasher.finalize()`
    public struct Hasher: Sendable {
        private var state: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
        ]
        private var buffer: [UInt8] = []
        private var totalBytes: UInt64 = 0
        private var finalized = false

        public init() {}

        public mutating func update(_ data: Data) {
            update([UInt8](data))
        }

        public mutating func update(_ bytes: [UInt8]) {
            precondition(!finalized, "SHA256.Hasher 已完成，不能继续写入")
            guard !bytes.isEmpty else { return }
            totalBytes &+= UInt64(bytes.count)
            var rest = bytes

            if !buffer.isEmpty {
                let need = 64 - buffer.count
                if rest.count >= need {
                    buffer.append(contentsOf: rest.prefix(need))
                    compress(buffer)
                    buffer.removeAll(keepingCapacity: true)
                    rest.removeFirst(need)
                } else {
                    buffer.append(contentsOf: rest)
                    return
                }
            }

            var index = 0
            while index + 64 <= rest.count {
                compress(Array(rest[index..<(index + 64)]))
                index += 64
            }
            if index < rest.count {
                buffer = Array(rest[index...])
            }
        }

        /// 收尾并返回 64 位十六进制摘要；只能调用一次。
        public mutating func finalize() -> String {
            precondition(!finalized, "SHA256.Hasher.finalize 只能调用一次")
            finalized = true

            let bitLength = totalBytes &* 8
            var tail = buffer
            tail.append(0x80)
            while tail.count % 64 != 56 {
                tail.append(0x00)
            }
            for shift in stride(from: 56, through: 0, by: -8) {
                tail.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
            }
            var index = 0
            while index + 64 <= tail.count {
                compress(Array(tail[index..<(index + 64)]))
                index += 64
            }
            buffer.removeAll()
            return state.map { String(format: "%08x", $0) }.joined()
        }

        private mutating func compress(_ block: [UInt8]) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let base = i * 4
                w[i] = (UInt32(block[base]) << 24)
                    | (UInt32(block[base + 1]) << 16)
                    | (UInt32(block[base + 2]) << 8)
                    | UInt32(block[base + 3])
            }
            for i in 16..<64 {
                let s0 = SHA256.rotateRight(w[i - 15], 7) ^ SHA256.rotateRight(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = SHA256.rotateRight(w[i - 2], 17) ^ SHA256.rotateRight(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }

            var a = state[0], b = state[1], c = state[2], d = state[3]
            var e = state[4], f = state[5], g = state[6], h = state[7]

            for i in 0..<64 {
                let s1 = SHA256.rotateRight(e, 6) ^ SHA256.rotateRight(e, 11) ^ SHA256.rotateRight(e, 25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = h &+ s1 &+ ch &+ SHA256.k[i] &+ w[i]
                let s0 = SHA256.rotateRight(a, 2) ^ SHA256.rotateRight(a, 13) ^ SHA256.rotateRight(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj

                h = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }

            state[0] = state[0] &+ a
            state[1] = state[1] &+ b
            state[2] = state[2] &+ c
            state[3] = state[3] &+ d
            state[4] = state[4] &+ e
            state[5] = state[5] &+ f
            state[6] = state[6] &+ g
            state[7] = state[7] &+ h
        }
    }
}
