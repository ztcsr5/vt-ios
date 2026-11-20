//
//  VTProxy.swift
//  在 App 内起一个本地 HTTP 代理（支持 CONNECT 隧道 + 普通 HTTP 转发）。
//  小火箭 / 系统 Wi-Fi 代理都指向 127.0.0.1:18890 即可，
//  这样 VT 隧道完全跑在 App 里，不需要 NetworkExtension、不需要付费开发者账号。
//

import Foundation
import Network

final class VTProxy {

    struct Stats {
        var attempts = 0
        var ok = 0
        var failed = 0
        var upBytes = 0
        var downBytes = 0
        var liveConns = 0
        var lastError: String = ""
    }

    private let queue = DispatchQueue(label: "vt.proxy", attributes: .concurrent)
    private let stateQueue = DispatchQueue(label: "vt.proxy.state")
    /// 字节计数走轻量锁，不走 stateQueue.sync。
    /// 每收一个 TCP 包就 sync 一次串行队列 = 一次上下文切换，
    /// 满速下载时这条路径每秒被调用上万次，是实测吞吐的首要瓶颈。
    private let counterLock = NSLock()
    private var _upBytes = 0
    private var _downBytes = 0
    private var listener: NWListener?
    private let port: UInt16

    /// 中继池：按顺序尝试，成功用哪一个就记住（软粘滞）。
    private let relays: [(String, UInt16)]
    private var preferredRelay = 0
    /// 每个中继的冷却截止时间（时间戳）。连着失败就进冷却，
    /// 免得同一条死线路在一轮 18 次尝试里被反复撞 5 遍 —— 那是"越连越慢"的主因。
    private var cooldownUntil: [TimeInterval] = []
    private var consecutiveFails: [Int] = []

    private var _stats = Stats()
    var stats: Stats {
        var s = stateQueue.sync { _stats }
        counterLock.lock()
        s.upBytes = _upBytes
        s.downBytes = _downBytes
        counterLock.unlock()
        return s
    }
    var onLog: ((String) -> Void)?
    var onStats: ((Stats) -> Void)?

    private func addUp(_ n: Int) {
        counterLock.lock(); _upBytes += n; counterLock.unlock()
    }

    private func addDown(_ n: Int) {
        counterLock.lock(); _downBytes += n; counterLock.unlock()
    }

    private(set) var running = false

    init(port: UInt16 = 18890, relays: [(String, UInt16)]) {
        self.port = port
        self.relays = relays
        self.cooldownUntil = Array(repeating: 0, count: relays.count)
        self.consecutiveFails = Array(repeating: 0, count: relays.count)
    }

    // MARK: - 生命周期

    func start() throws {
        let p = NWParameters.tcp
        p.allowLocalEndpointReuse = true
        p.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let l = try NWListener(using: p)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            if case .ready = st {
                self.running = true
                self.log("代理已监听 127.0.0.1:\(self.port)")
            } else if case .failed(let e) = st {
                self.running = false
                self.log("监听失败: \(e.localizedDescription)")
            }
        }
        listener = l
        l.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        running = false
        stateQueue.sync { _stats.liveConns = 0 }
        log("代理已停止")
    }

    // MARK: - 单连接

    private func accept(_ c: NWConnection) {
        stateQueue.sync {
            _stats.attempts += 1
            _stats.liveConns += 1
        }
        pushStats()
        c.start(queue: queue)
        readRequestHead(c, buffer: Data())
    }

    /// 读 HTTP 请求头（代理协议只需头，body 由隧道原样透传）。
    private func readRequestHead(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isDone, err in
            guard let self else { return }
            if err != nil || isDone {
                self.finish(c, nil); return
            }
            var buf = buffer
            if let data { buf.append(data) }
            guard let idx = buf.range(of: Data("\r\n\r\n".utf8)) else {
                if buf.count > 32768 { self.finish(c, "请求头超长") } else {
                    self.readRequestHead(c, buffer: buf)
                }
                return
            }
            let headText = String(data: buf[..<idx.lowerBound], encoding: .isoLatin1) ?? ""
            let leftover = Data(buf[idx.upperBound...])
            self.handleRequest(c, headText: headText, leftover: leftover)
        }
    }

    private func handleRequest(_ c: NWConnection, headText: String, leftover: Data) {
        let lines = headText.components(separatedBy: "\r\n")
        guard let first = lines.first else { finish(c, "空请求"); return }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { finish(c, "请求行异常: \(first)"); return }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])

        if method == "CONNECT" {
            // CONNECT host:port
            guard let (h, p) = splitHostPort(target) else {
                finish(c, "CONNECT 目标异常: \(target)"); return
            }
            openTunnel(for: c, host: h, port: p) { [weak self] tunnel in
                // 先回 200，再把客户端后续字节原样灌进隧道
                let resp = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
                c.send(content: resp, completion: .contentProcessed { _ in
                    if !leftover.isEmpty { tunnel.write(leftover) }
                    self?.pipe(c, to: tunnel)
                })
            }
        } else {
            // 普通 HTTP：从请求行取 host，原样转发（含 body）
            guard let (h, p) = hostFromPlainHTTP(target: target, lines: lines) else {
                finish(c, "无法确定目标主机: \(target)"); return
            }
            openTunnel(for: c, host: h, port: p) { [weak self] tunnel in
                var raw = Data(headText.utf8)
                raw.append(Data("\r\n\r\n".utf8))
                raw.append(leftover)
                tunnel.write(raw)
                self?.pipe(c, to: tunnel)
            }
        }
    }

    /// 打开隧道；失败自动换下一个中继（最多试完整个池两轮）。
    /// 并发握手数受 maxHandshaking 限制：中继对匿名会话有并发上限，
    /// 小火箭一开一页就能并发几十条，全放进去只会集体 phase=head 超时。
    private func openTunnel(for client: NWConnection,
                            host: String, port: UInt16,
                            then: @escaping (VTTunnel) -> Void) {
        acquireSlot { [weak self] in
            guard let self else { return }
            self.tryRelay(index: 0, host: host, port: port) { [weak self] tunnel in
                guard let self else { return }
                self.releaseSlot()
                guard let tunnel else {
                    self.finish(client, "所有中继都失败")
                    return
                }
                self.stateQueue.sync { self._stats.ok += 1 }
                self.pushStats()
                then(tunnel)
                self.trackTunnel(tunnel, client: client)
            }
        }
    }

    // MARK: - 握手并发闸门

    private var handshaking = 0
    private let maxHandshaking = 10
    private var slotWaiters: [() -> Void] = []

    private func acquireSlot(_ body: @escaping () -> Void) {
        var runNow = false
        stateQueue.sync {
            if handshaking < maxHandshaking {
                handshaking += 1
                runNow = true
            } else {
                slotWaiters.append(body)
            }
        }
        if runNow { body() }
    }

    /// 槽位直接转交给下一个等待者，否则才真正释放 —— 保证守恒。
    private func releaseSlot() {
        var next: (() -> Void)?
        stateQueue.sync {
            if !slotWaiters.isEmpty {
                next = slotWaiters.removeFirst()
            } else {
                handshaking = max(0, handshaking - 1)
            }
        }
        next?()
    }

    private func tryRelay(index: Int, host: String, port: UInt16,
                          done: @escaping (VTTunnel?) -> Void) {
        guard !relays.isEmpty else { done(nil); return }
        guard index < relays.count * 2 else { done(nil); return }
        let i = (preferredRelay + index) % relays.count
        // 第一轮跳过冷却中的线路；第二轮（index >= count）不再跳，
        // 否则全池冷却时会直接判定"所有中继都失败"。
        let relaxed = index >= relays.count
        let now = Date().timeIntervalSince1970
        let until = stateQueue.sync { cooldownUntil[i] }
        if !relaxed, until > now {
            log("跳过冷却中的中继 \(relays[i].0):\(relays[i].1)（剩 \(Int(until - now))s）")
            tryRelay(index: index + 1, host: host, port: port, done: done)
            return
        }
        let (rh, rp) = relays[i]
        let t = VTTunnel(relayHost: rh, relayPort: rp)
        var settled = false
        let settle: (Bool, String?) -> Void = { [weak self] success, msg in
            guard !settled else { return }
            settled = true
            guard let self else { return }
            if success {
                self.stateQueue.sync {
                    self.preferredRelay = i
                    self.consecutiveFails[i] = 0
                    self.cooldownUntil[i] = 0
                }
                self.log("隧道建立 ← \(rh):\(rp)  → \(host):\(port)")
                done(t)
            } else {
                self.stateQueue.sync {
                    self._stats.failed += 1
                    self._stats.lastError = msg ?? "未知错误"
                    self.consecutiveFails[i] += 1
                    // 一次就冷却 20s，连续两次 60s —— 死线路不该在一轮里被撞 5 次
                    let n = self.consecutiveFails[i]
                    self.cooldownUntil[i] = Date().timeIntervalSince1970
                        + (n >= 2 ? 60 : 20)
                }
                self.pushStats()
                self.log("中继 \(rh):\(rp) 失败: \(msg ?? "已关闭")")
                self.tryRelay(index: index + 1, host: host, port: port, done: done)
            }
        }
        t.onReady = { settle(true, nil) }
        t.onClose = { msg in settle(false, msg) }
        t.open(host: host, port: port)
    }

    /// 双向泵：客户端字节 → 隧道；隧道明文 → 客户端。
    private func pipe(_ client: NWConnection, to tunnel: VTTunnel) {
        tunnel.onData = { [weak self] data in
            guard let self else { return }
            self.addDown(data.count)
            // 不用 .contentProcessed 回调：满速时每包一个闭包 + 一次队列跳转，
            // .idempotent 让 Network 框架自己排队，省掉这条热路径上的分配。
            client.send(content: data, completion: .idempotent)
        }
        tunnel.onClose = { [weak self] _ in
            guard let self else { client.cancel(); return }
            client.cancel()
            self.stateQueue.sync {
                self._stats.liveConns = max(0, self._stats.liveConns - 1)
            }
            self.pushStats()
        }
        readLoop(client, tunnel: tunnel)
    }

    private func readLoop(_ client: NWConnection, tunnel: VTTunnel) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isDone, err in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.addUp(data.count)
                tunnel.write(data)
            }
            if err != nil || isDone {
                tunnel.close()
                return
            }
            self.readLoop(client, tunnel: tunnel)
        }
    }

    private func trackTunnel(_ tunnel: VTTunnel, client: NWConnection) {
        client.stateUpdateHandler = { st in
            if case .failed = st { tunnel.close() }
            if case .cancelled = st { tunnel.close() }
        }
    }

    // MARK: - 工具

    private func finish(_ c: NWConnection, _ err: String?) {
        if let err {
            stateQueue.sync {
                _stats.failed += 1
                _stats.lastError = err
            }
            log(err)
        }
        c.cancel()
        stateQueue.sync { _stats.liveConns = max(0, _stats.liveConns - 1) }
        pushStats()
    }

    private func splitHostPort(_ s: String) -> (String, UInt16)? {
        // [v6]:port  或  host:port
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return nil }
            let h = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            guard rest.hasPrefix(":"), let p = UInt16(rest.dropFirst()) else { return nil }
            return (h, p)
        }
        guard let colon = s.lastIndex(of: ":") else { return nil }
        let h = String(s[..<colon])
        guard let p = UInt16(s[s.index(after: colon)...]) else { return nil }
        return (h, p)
    }

    private func hostFromPlainHTTP(target: String, lines: [String]) -> (String, UInt16)? {
        // 绝对 URI：GET http://host/path HTTP/1.1
        if let url = URL(string: target), let h = url.host {
            return (h, UInt16(url.port ?? 80))
        }
        // origin-form：靠 Host 头
        for l in lines.dropFirst() where l.lowercased().hasPrefix("host:") {
            let v = l.dropFirst(5).trimmingCharacters(in: .whitespaces)
            return splitHostPort(v.contains(":") ? v : v + ":80")
        }
        return nil
    }

    private func log(_ s: String) { onLog?(s); }
    private func pushStats() { onStats?(stats) }
}
