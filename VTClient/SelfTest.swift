//
//  SelfTest.swift
//  把 _gen_vectors.js 生成的固定向量烧进 App，点一下就知道 Swift 端和 proto.js 是否对得上。
//  这比 XCTest 更直接：不需要 Mac、不需要跑 CI，装到手机上即可自证。
//

import Foundation

enum SelfTest {

    struct Case {
        let name: String
        let pass: Bool
        let detail: String
    }

    private static func h(_ d: Data) -> String {
        d.map { String(format: "%02x", $0) }.joined()
    }
    private static func unhex(_ s: String) -> Data {
        var d = Data(); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            d.append(UInt8(s[i..<j], radix: 16) ?? 0)
            i = j
        }
        return d
    }

    private static func check(_ name: String, _ got: String, _ want: String) -> Case {
        Case(name: name, pass: got == want,
             detail: got == want ? "ok" : "got \(got.prefix(24))… want \(want.prefix(24))…")
    }

    static func run() -> [Case] {
        var out: [Case] = []

        out.append(check("masterKey",
                         h(VTProto.masterKey),
                         "5f4dcc3b5aa765d61d8327deb882cf992b95990a9151374abd8ff8c5a7a0fe08"))

        let salt1 = Data(repeating: 0x01, count: 32)
        out.append(check("subkey(salt=0x01×32)",
                         h(VTProto.subkey(salt: salt1)),
                         "c2986bbd7be2f46876a0346839cb544c9687bc424470ab8ce628068d45a9e865"))

        let salt2 = unhex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        out.append(check("subkey(salt=0..31)",
                         h(VTProto.subkey(salt: salt2)),
                         "ee187aed3f87574907a39db98606f60a526114831288097cac66054b33a9464f"))

        let sealer = VTSealer(key: VTProto.subkey(salt: salt1))
        out.append(check("frame(\"abc\")",
                         h(sealer.frame(Data("abc".utf8))),
                         "527d8fbdbcd1a80e9b8115d612d309b490a752395dd82d257ade9fc6430510900363bc9bc4"))
        out.append(check("frame(\"hello world\") 第二帧 nonce 推进",
                         h(sealer.frame(Data("hello world".utf8))),
                         "d1916aa2dd153b14115b58f9812dd8863dfe9d6c7064cf73032c95a9bf2bb7fc4bf8c4c8c53075889721134b68"))

        // 闭环：加密→解密必须还原
        let k = VTProto.subkey(salt: salt1)
        let s2 = VTSealer(key: k)
        let r = VTFrameReader(key: k)
        r.push(s2.frame(Data("abc".utf8)) + s2.frame(Data("hello world".utf8)))
        let a = r.next().flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let b = r.next().flatMap { String(data: $0, encoding: .utf8) } ?? ""
        out.append(Case(name: "FrameReader 闭环",
                        pass: a == "abc" && b == "hello world" && !r.isFailed,
                        detail: "\(a) / \(b)"))

        out.append(check("auth(60B)",
                         h(VTAuth.build(token: "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6")),
                         "41ce623243336434453566364737683849396a304b316c324d336e344f3570363a"
                       + "48494a4b4c4d4e4f505152535455565758595a4142434445464748"))

        out.append(check("addr(example.com:443)",
                         h(VTAddress.encode(host: "example.com", port: 443)),
                         "030b6578616d706c652e636f6d01bb"))
        out.append(check("addr(1.2.3.4:8080)",
                         h(VTAddress.encode(host: "1.2.3.4", port: 8080)),
                         "01010203041f90"))
        out.append(check("addr([2001:db8::1]:53)",
                         h(VTAddress.encode(host: "2001:db8::1", port: 53)),
                         "0420010db80000000000000000000000010035"))

        out.append(check("invertFirst 只翻首字节",
                         h(VTProto.invertFirst(salt2)),
                         "ff0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"))

        // 切片边界：16384 字节 → 两帧。每片线上 = 18(加密长度头) + 明文 + 16(tag)
        //   片1 明文 16383 → 18 + 16399 = 16417
        //   片2 明文     1 → 18 +    17 =    35
        //   合计 16452（与桌面 proto.js 实测一致；原断言写成 16420 是把 tag 漏算了）
        let s3 = VTSealer(key: k)
        let n = s3.frame(Data(repeating: 0x5a, count: VTProto.maxWriteFrame + 1)).count
        out.append(Case(name: "16384 切两帧 = 16452B", pass: n == 16452, detail: "\(n)"))

        return out
    }
}
