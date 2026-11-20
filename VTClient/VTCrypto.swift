//
//  VTCrypto.swift
//  VT 协议的密码学层 —— 与 D:\suyou\vt-client\proto.js 逐字节对齐
//
//  设计要点（血泪教训，别改）:
//   1. masterKey 是 EVP_BytesToKey("password")，不是 PBKDF，也不是 SHA256。
//   2. subkey 用 HKDF-SHA1(master, salt, "ss-subkey", 32)。CryptoKit 不暴露 HKDF-SHA1，
//      所以手写（HMAC-SHA1 20 字节，正好是标准 HMAC 块长以内的输出）。
//   3. 上线用的 salt 只取反【首字节】，不是整个 salt，也不是第二个字节。
//   4. nonce 是小端、从 0 开始、每帧 +1（长度帧与数据帧各占一个 nonce）。
//   5. AEAD = ChaCha20-Poly1305，tag 16 字节附加在密文尾部（iOS 的 API 是分开给的）。
//

import Foundation
import CryptoKit

enum VTProto {
    static let password = "password"
    static let hkdfInfo = Data("ss-subkey".utf8)
    static let keyLen = 32
    static let saltLen = 32
    static let authLen = 60
    static let nonceLen = 12
    static let tagLen = 16
    static let maxWriteFrame = 16383
    static let maxReadFrame = 16384

    /// EVP_BytesToKey(MD5, 无 salt, 1 轮) —— OpenSSL 历史行为，SS 生态沿用至今。
    static let masterKey: Data = {
        let pw = Data(password.utf8)
        let d1 = Insecure.MD5.hash(data: pw)
        let d2 = Insecure.MD5.hash(data: Data(d1) + pw)
        return Data(d1) + Data(d2)          // 16 + 16 = 32
    }()

    /// HKDF-SHA1(masterKey, salt, "ss-subkey", 32)
    ///
    /// extract 的参数顺序是 RFC 5869 里最容易写反的地方，写反了不会报错、
    /// 只会得到一串"看起来像但完全不对"的 subkey —— 表现为握手成功但对端静默。
    ///   RFC 5869:  PRK = HMAC-Hash(key = salt, data = IKM)
    ///   Node 侧:   crypto.hkdfSync('sha1', ikm = masterKey, salt, info, 32)
    /// 所以 key 必须是 salt、data 必须是 masterKey（2026-11-20 修：原来写反了）。
    static func subkey(salt: Data) -> Data {
        precondition(salt.count == saltLen, "salt 必须 32 字节")
        let prk = hmacSHA1(key: salt, data: masterKey)   // extract（20 字节）
        return hmacSHA1Expand(prk: prk, info: hkdfInfo, len: keyLen)
    }

    static func hmacSHA1(key: Data, data: Data) -> Data {
        let k = SymmetricKey(data: key)
        return Data(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: k))
    }

    /// HKDF 第 2 步（expand），单块即可（32 > 20 时会走两块，这里必须循环）。
    static func hmacSHA1Expand(prk: Data, info: Data, len: Int) -> Data {
        var out = Data()
        var t = Data()
        var counter: UInt8 = 1
        while out.count < len {
            var input = t
            input.append(info)
            input.append(counter)
            t = hmacSHA1(key: prk, data: input)
            out.append(t)
            counter = counter &+ 1
        }
        return out.prefix(len)
    }

    /// 只取反首字节。
    static func invertFirst(_ b: Data) -> Data {
        var c = b
        c[0] = ~c[0]
        return c
    }

    /// 小端递增：从字节 0 起进位。
    static func incrementNonce(_ n: inout [UInt8]) {
        for i in 0..<n.count {
            n[i] = n[i] &+ 1
            if n[i] != 0 { return }
        }
    }

    static func nonceData(_ n: [UInt8]) -> ChaChaPoly.Nonce {
        // ChaChaPoly.Nonce(data:) 要求 12 字节
        try! ChaChaPoly.Nonce(data: Data(n))
    }
}

/// 加密方向：每帧 = E(2B 大端明文长度) + E(payload)
final class VTSealer {
    private let key: SymmetricKey
    private var nonce = [UInt8](repeating: 0, count: VTProto.nonceLen)

    init(key: Data) { self.key = SymmetricKey(data: key) }

    private func sealOne(_ plain: Data) -> Data {
        let box = try! ChaChaPoly.seal(plain, using: key, nonce: VTProto.nonceData(nonce))
        VTProto.incrementNonce(&nonce)
        return box.ciphertext + box.tag
    }

    /// 一帧或多帧（>16383 自动切片）。返回可直接写 socket 的字节。
    func frame(_ payload: Data) -> Data {
        // 与 proto.js 对齐：空 payload 不产生任何字节（不是产生一个 0 长度帧）
        guard !payload.isEmpty else { return Data() }
        var out = Data()
        var offset = 0
        repeat {
            let end = min(offset + VTProto.maxWriteFrame, payload.count)
            let part = payload[offset..<end]
            var lenBE = UInt16(part.count).bigEndian
            let lenData = withUnsafeBytes(of: &lenBE) { Data($0) }
            out.append(sealOne(lenData))
            out.append(sealOne(Data(part)))
            offset = end
        } while offset < payload.count
        return out
    }
}

/// 解密方向：靠 pending 记住"已解出的长度、但数据还没到齐"，绝不重复解密。
/// 重复解密会让 nonce 多推进，后续全部错位 —— 这是 proto.js 里踩过的坑。
final class VTFrameReader {
    private let key: SymmetricKey
    private var nonce = [UInt8](repeating: 0, count: VTProto.nonceLen)
    private var buf = Data()
    private var pending: Int? = nil
    private var failed = false

    init(key: Data) { self.key = SymmetricKey(data: key) }

    func push(_ chunk: Data) { buf.append(chunk) }

    /// 解密失败后流已不可恢复，调用方必须断开而不是继续等数据。
    var isFailed: Bool { failed }
    /// 还有多少已收但未消费的字节（调试用）。
    var bufferedCount: Int { buf.count }

    private func open(_ cipherAndTag: Data) -> Data? {
        guard cipherAndTag.count >= VTProto.tagLen else { return nil }
        let ct = cipherAndTag.prefix(cipherAndTag.count - VTProto.tagLen)
        let tag = cipherAndTag.suffix(VTProto.tagLen)
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: VTProto.nonceData(nonce),
                ciphertext: ct,
                tag: tag)
            let pt = try ChaChaPoly.open(box, using: key)
            VTProto.incrementNonce(&nonce)
            return pt
        } catch {
            failed = true
            return nil
        }
    }

    /// 取下一帧明文；数据不足返回 nil（不消耗 nonce）。
    func next() -> Data? {
        if failed { return nil }
        if pending == nil {
            let headLen = 2 + VTProto.tagLen            // 18
            guard buf.count >= headLen else { return nil }
            let head = buf.prefix(headLen)
            guard let lenPt = open(Data(head)) else { return nil }
            buf.removeFirst(headLen)
            guard lenPt.count == 2 else { failed = true; return nil }
            let n = (Int(lenPt[lenPt.startIndex]) << 8) | Int(lenPt[lenPt.startIndex + 1])
            if n > VTProto.maxReadFrame { failed = true; return nil }
            pending = n
        }
        guard let n = pending else { return nil }
        let need = n + VTProto.tagLen
        guard buf.count >= need else { return nil }
        let body = buf.prefix(need)
        guard let pt = open(Data(body)) else { return nil }
        buf.removeFirst(need)
        pending = nil
        return pt
    }
}

enum VTAddress {
    /// 域名优先 ATYP 3（与 proto.js encodeAddress 一致），末尾 2 字节大端端口。
    static func encode(host: String, port: UInt16) -> Data {
        var out = Data()
        if isIPv4(host) {
            out.append(0x01)
            for seg in host.split(separator: ".") {
                out.append(UInt8(seg) ?? 0)
            }
        } else if isIPv6(host) {
            out.append(0x04)
            var addr = in6_addr()
            inet_pton(AF_INET6, host, &addr)
            out.append(withUnsafeBytes(of: &addr) { Data($0) })
        } else {
            let name = Data(host.utf8)
            out.append(0x03)
            out.append(UInt8(name.count))
            out.append(name)
        }
        var p = port.bigEndian
        out.append(withUnsafeBytes(of: &p) { Data($0) })
        return out
    }

    static func isIPv4(_ s: String) -> Bool {
        var a = in_addr()
        return inet_pton(AF_INET, s, &a) == 1
    }
    static func isIPv6(_ s: String) -> Bool {
        var a = in6_addr()
        return inet_pton(AF_INET6, s, &a) == 1
    }
}

enum VTAuth {
    /// 60 字节：先铺 0x41 + (i % 26)，写入 token，第 n 位放 ':'，再把第 2 字节取反。
    /// 服务端只认 ':' 之前的 token，且空 token 会被拒 —— 必须给 32 位随机串。
    static func build(token: String) -> Data {
        var a = [UInt8](repeating: 0, count: VTProto.authLen)
        for i in 0..<VTProto.authLen { a[i] = UInt8(0x41 + (i % 26)) }
        let t = Array(token.utf8)
        let n = min(VTProto.authLen - 1, t.count)
        for i in 0..<n { a[i] = t[i] }
        a[n] = 0x3a
        a[1] = ~a[1]
        return Data(a)
    }

    /// 32 位小写字母数字随机串（服务端靠它做会话标识）。
    static func randomToken() -> String {
        let cs = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<32).map { _ in cs[Int.random(in: 0..<cs.count)] })
    }
}

/// 诊断输出的全局出口。ContentView 把它接到日志面板上。
enum VTDiag {
    private static let lock = NSLock()
    private static var _sink: ((String) -> Void)?

    static var sink: ((String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _sink }
        set { lock.lock(); _sink = newValue; lock.unlock() }
    }

    static func emit(_ s: String) {
        if let f = sink { f(s) } else { print("VT> " + s) }
    }
}