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

    /// 待发出的明文（攒批用）
    private var outBuf = Data()
    private var flushScheduled = false

    /// 服务器第一帧（ServerHello）常和 salt 挤在同一个 TCP 包里：
    /// handle() 里 drain() 会立刻拿到明文，但那时 VTProxy 还没把 onData 挂上，
    /// 直接回调就丢了 → 客户端永远等不到 ServerHello → 连接 abort。先缓冲住。
    private var pendingOut = Data()

    /// 硬保护：一条 TCP 上只允许发一次握手。
    /// NWConnection 的 .ready 在某些路径上会重复回调，仅靠 state 判断不够稳；
    /// 一旦发两次，中继会在同一条 TCP 上回两段 128B 响应头（288B = 128+128+32），
    /// 而两次握手用的是两个不同的 salt / token，服务端只认其中一条会话，另一条必被关。
    private var handshakeSent = false

    private(set) var state: State = .idle
    private(set) var lastError: String?

    /// 诊断输出（打到同一个日志面板，前缀 VT>）。
    /// 默认关 —— 每收一个 TCP 包就打一行、还要在主线程刷一屏 UI，
    /// 实测能把吞吐压到十分之一。排查时再打开。
    /// @autoclosure：关着的时候连字符串拼接都不发生。
    static var verbose = false
    private func diag(_ s: @autoclosure () -> String) {
        guard VTTunnel.verbose else { return }
        VTDiag.emit(s())
    }

    var onReady: (() -> Void)?
    var onClose: ((String?) -> Void)?

    var onData: ((Data) -> Void)? {
        didSet { flushPending() }
    }

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
                    // 幂等：NWConnection 在某些网络路径上会把 .ready 报不止一次。
                    // 重发握手会让中继以为又来了一条新隧道，于是在同一条 TCP 上
                    // 再回一段 128B 响应头 —— 这正是 iOS 侧看到「288B = 128+128+32」
                    // 而 Node 探针只看到「160B = 128+32」的原因。
                    // 这里除了看 state 还看 handshakeSent：两条判据都过才发。
                    guard self.state == .connecting, !self.handshakeSent else {
                        self.diag("跳过重复握手（state=\(self.state) sent=\(self.handshakeSent)）")
                        return
                    }
                    self.handshakeSent = true
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

        let addrFrame = s.frame(VTAddress.encode(host: host, port: port))
        var payload = Data()
        payload.append(Data(head.utf8))
        payload.append(VTAuth.build(token: VTAuth.randomToken()))  // 60B，缺了必被关
        payload.append(wireSalt)                                    // 32B
        payload.append(addrFrame)
        diag("握手 →\(payload.count)B  head=\(head.utf8.count) auth=60 salt=32 addr=\(addrFrame.count) 目标=\(host):\(port) relay=\(relayHost):\(relayPort)")
        rawSend(payload)
    }

    /// 隧道就绪后写明文，内部自动分帧。
    /// 攒批：同一轮事件循环里连续多次 write（TLS 一次握手会连发好几个小记录）
    /// 合并成一批再封帧，减少帧数与 conn.send 次数。
    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        io.async {
            guard self.state == .ready, self.sealer != nil else {
                self.diag("丢弃 \(data.count)B（state=\(self.state)）")
                return
            }
            self.outBuf.append(data)
            if self.flushScheduled { return }
            self.flushScheduled = true
            self.io.async { self.flushOut() }
        }
    }

    private func flushOut() {
        flushScheduled = false
        guard !outBuf.isEmpty else { return }
        let batch = outBuf
        outBuf.removeAll(keepingCapacity: true)
        guard state == .ready, let s = sealer else { return }
        rawSend(s.frame(batch))
    }

    func close() {
        io.async {
            guard self.state != .closed else { return }
            self.state = .closed
            self.outBuf.removeAll(keepingCapacity: false)
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
            self.outBuf.removeAll(keepingCapacity: false)
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
            } else if isDone {
                self.diag("对端 EOF（state=\(self.state)）")
            }
            if isDone {
                self.io.async {
                    if self.state == .ready { self.fail("对端已关闭") } else { self.fail("中继提前断开") }
                }
                return
            }
            self.pump()
        }
    }

    private func handle(_ chunk: Data) {
        diag("收到 \(chunk.count)B  phase=\(phase)")
        switch phase {
        case .head:
            acc.append(chunk)
            if VTTunnel.verbose {
                diag("累积 \(acc.count)B  hex=\(acc.prefix(48).map { String(format: "%02x", $0) }.joined())")
            }
            // 中继的响应形状不固定，实测至少两种：
            //   A) 128B 头 + 32B salt               （Node 侧 _raw443.js 5/5 稳定这样）
            //   B) 128B 头 + 128B 头 + 32B salt     （iOS 侧观察到，总量正好 288B）
            // 所以先把开头连续几段 "HTTP/" 响应头全部剥掉（最多 4 段），
            // 再自校准：扫出「哪个偏移开始的 32 字节能解出合法首帧」。
            // 只有真正的服务端 salt 才能解出 2B 长度且 ≤16383，错 key 的 tag 必挂。
            var peeled = 0
            while true {
                guard acc.count >= 5 else { return }
                let isHTTP = acc.prefix(5).elementsEqual(Data("HTTP/".utf8))
                if !isHTTP { break }
                guard let r = acc.range(of: Data("\r\n\r\n".utf8)) else {
                    if acc.count > 16384 { fail("响应头超长") }
                    return
                }
                let segText = String(data: acc[..<r.lowerBound], encoding: .isoLatin1) ?? ""
                let status = segText.split(separator: "\r\n").first.map(String.init) ?? ""
                if peeled == 0 {
                    guard status.contains(" 200") else {
                        fail("中继拒绝: \(status.isEmpty ? "空响应" : status)")
                        return
                    }
                }
                diag("剥响应段#\(peeled + 1) 段长=\(r.upperBound) 状态=\(status)")
                acc = Data(acc[r.upperBound...])
                peeled += 1
                if peeled > 4 { fail("响应段过多"); return }
            }
            guard let hit = VTProto.locateSalt(in: acc) else {
                // 剥完所有响应头后紧跟的一定是服务端 salt（协议规定），
                // 所以拿不到首帧时按偏移 0 直接建 reader —— 否则会死等：
                // write() 有 guard state == .ready，state 不 ready 就发不出应用数据，
                // 服务端没有应用数据就不回帧，locateSalt 于是永远等不到帧头。
                guard acc.count >= VTProto.saltLen else {
                    diag("等 salt（已剥 \(peeled) 段头，余 \(acc.count)B）")
                    return
                }
                let salt0 = acc.subdata(in: acc.startIndex..<(acc.startIndex + VTProto.saltLen))
                let rest0 = Data(acc[(acc.startIndex + VTProto.saltLen)...])
                diag("按协议取偏移0作 salt（剥 \(peeled) 段头后 余 \(acc.count)B）salt=\(salt0.prefix(8).map { String(format: "%02x", $0) }.joined())…  待解=\(rest0.count)B")
                acc = Data()
                reader = VTFrameReader(key: VTProto.subkey(salt: salt0))
                phase = .data
                state = .ready
                if !rest0.isEmpty { reader?.push(rest0) }
                drain()
                let cb0 = onReady; onReady = nil
                queue.async { cb0?() }
                return
            }
            let serverSalt = acc.subdata(in: (acc.startIndex + hit.saltOffset)..<(acc.startIndex + hit.saltOffset + VTProto.saltLen))
            let frameBytes = Data(acc[(acc.startIndex + hit.frameOffset)...])
            diag("自校准成功 salt偏移=\(hit.saltOffset) 帧偏移=\(hit.frameOffset) 余=\(frameBytes.count)B salt=\(serverSalt.prefix(8).map { String(format: "%02x", $0) }.joined())…")
            acc = Data()
            reader = VTFrameReader(key: VTProto.subkey(salt: serverSalt))
            phase = .data
            state = .ready
            if !frameBytes.isEmpty { reader?.push(frameBytes) }
            drain()
            let cb = onReady; onReady = nil
            queue.async { cb?() }

        case .salt:
            // 旧路径，已由 .head 内的自校准取代
            phase = .data
            fallthrough

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
        if !pushed.isEmpty {
            let hex = pushed.prefix(12).map { String(format: "%02x", $0) }.joined()
            diag("解密出 \(pushed.count)B  头部=\(hex)")
        }
        if pushed.isEmpty { return }
        if let cb = onData {
            cb(pushed)
        } else {
            pendingOut.append(pushed)
        }
    }

    private func flushPending() {
        io.async { [weak self] in
            guard let self, let cb = self.onData, !self.pendingOut.isEmpty else { return }
            let d = self.pendingOut
            self.pendingOut.removeAll(keepingCapacity: false)
            cb(d)
        }
    }
}
