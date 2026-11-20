//
//  VTTunnel.swift
//  一条 VT 隧道 = 到中继的 TCP 长连接 + 自定义握手 + AEAD 帧流。
//  与 vt_engine.js 的 connectTunnel 一一对应。
//
//  握手字节序（务必按此顺序，错一个字节服务端就静默关闭）：
//     POST /sync HTTP/1.1 头 + 60B auth + 32B salt(首字节取反) + E(地址帧)
//     响应：HTTP 200 头 + 32B 服务端 salt(不取反) + E(...) 帧流
//

import Foundation
import Network

final class VTTunnel {

    enum State: Equatable { case idle, connecting, handshaking, ready, closed, failed }
    private enum Phase { case head, salt, data }

    private let relayHost: String
    private let relayPort: UInt16
    private let queue = DispatchQueue(label: "vt.tunnel")
    private let io = DispatchQueue(label: "vt.tunnel.io")

    private var conn: NWConnection?
    private var phase: Phase = .head
    private var acc = Data()          // 累积缓冲（头部 / salt 阶段用）

    private var sealer: VTSealer?
    private var reader: VTFrameReader?

    private(set) var state: State = .idle
    private(set) var lastError: String?

    var onReady: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onClose: ((String?) -> Void)?

    init(relayHost: String, relayPort: UInt16) {
        self.relayHost = relayHost
        self.relayPort = relayPort
    }

    // MARK: - 建立

    func open(host: String, port: UInt16, timeout: TimeInterval = 9) {
        io.async { guard self.state == .idle else { return }; self.state = .connecting }

        let p = NWParameters.tcp
        p.allowLocalEndpointReuse = true
        if let tcp = p.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 8
        }
        let ep = NWEndpoint.hostPort(host: NWEndpoint.Host(relayHost),
                                     port: NWEndpoint.Port(rawValue: relayPort) ?? 80)
        let c = NWConnection(to: ep, using: p)
        conn = c

        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.state == .connecting || self.state == .handshaking else { return }
            self.fail("握手超时（phase=\(self.phase)）")
        }

        c.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                self.io.async {
                    self.state = .handshaking
                    self.sendHandshake(host: host, port: port)
                }
            case .failed(let e):
                self.fail("连接失败: \(e.debugDescription)")
            case .cancelled:
                self.fail("连接被取消")
            default: break
            }
        }
        c.start(queue: queue)
        pump()
    }

    private func sendHandshake(host: String, port: UInt16) {
        phase = .head
        acc.removeAll(keepingCapacity: true)

        let salt = Data((0..<VTProto.saltLen).map { _ in UInt8.random(in: 0...255) })
        let wireSalt = VTProto.invertFirst(salt)                  // 上线取反首字节
        let s = VTSealer(key: VTProto.subkey(salt: salt))          // 派生用原值
        sealer = s
        reader = nil

        let head = "POST /sync HTTP/1.1\r\n"
            + "Host: \(relayHost):\(relayPort)\r\n"
            + "Connection: keep-alive\r\n"
            + "Pragma: no-cache\r\n"
            + "Transfer-Encoding: chunked\r\n"
            + "Content-Type: application/octet-stream\r\n\r\n"

        var payload = Data()
        payload.append(Data(head.utf8))
        payload.append(VTAuth.build(token: VTAuth.randomToken()))  // 60B，缺了必被关
        payload.append(wireSalt)                                    // 32B
        payload.append(s.frame(VTAddress.encode(host: host, port: port)))
        rawSend(payload)
    }

    /// 隧道就绪后写明文，内部自动分帧。
    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        io.async {
            guard self.state == .ready, let s = self.sealer else { return }
            self.rawSend(s.frame(data))
        }
    }

    func close() {
        io.async {
            guard self.state != .closed else { return }
            self.state = .closed
            self.conn?.cancel()
            self.conn = nil
        }
    }

    private func rawSend(_ d: Data) {
        conn?.send(content: d, completion: .contentProcessed { _ in })
    }

    private func fail(_ msg: String) {
        io.async {
            guard self.state != .closed, self.state != .failed else { return }
            self.lastError = msg
            self.state = .failed
            self.conn?.cancel()
            self.conn = nil
            let cb = self.onClose
            self.onClose = nil
            self.queue.async { cb?(msg) }
        }
    }

    // MARK: - 收数据

    private func pump() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isDone, err in
            guard let self else { return }
            if err != nil {
                self.fail("读失败: \(err!.debugDescription)")
                return
            }
            if let data, !data.isEmpty {
                self.io.async { self.handle(data) }
            }
            if isDone {
                self.io.async {
                    if self.state == .ready { self.fail(nil) } else { self.fail("中继提前断开") }
                }
                return
            }
            self.pump()
        }
    }

    private func handle(_ chunk: Data) {
        switch phase {
        case .head:
            acc.append(chunk)
            guard let r = acc.range(of: Data("\r\n\r\n".utf8)) else {
                if acc.count > 8192 { fail("响应头超长") }
                return
            }
            let headStr = String(data: acc[..<r.lowerBound], encoding: .isoLatin1) ?? ""
            let status = headStr.split(separator: "\r\n").first.map(String.init) ?? ""
            guard status.contains(" 200") else {
                fail("中继拒绝: \(status.isEmpty ? "空响应" : status)")
                return
            }
            acc = Data(acc[r.upperBound...])
            phase = .salt
            fallthrough

        case .salt:
            guard acc.count >= VTProto.saltLen else { return }   // 等 salt 到齐
            let serverSalt = Data(acc.prefix(VTProto.saltLen))    // 服务端 salt 不取反
            acc = Data(acc.dropFirst(VTProto.saltLen))
            reader = VTFrameReader(key: VTProto.subkey(salt: serverSalt))
            phase = .data
            state = .ready
            if !acc.isEmpty { reader?.push(acc); acc.removeAll(keepingCapacity: false) }
            drain()
            let cb = onReady; onReady = nil
            queue.async { cb?() }

        case .data:
            guard let rd = reader else { fail("reader 丢失"); return }
            rd.push(chunk)
            drain()
        }
    }

    private func drain() {
        guard let rd = reader else { return }
        var pushed = Data()
        while true {
            guard let pt = rd.next() else {
                if rd.isFailed { fail("帧解密失败（key/nonce 错位或中继异常）") }
                break
            }
            pushed.append(pt)
        }
        if !pushed.isEmpty { onData?(pushed) }
    }
}
