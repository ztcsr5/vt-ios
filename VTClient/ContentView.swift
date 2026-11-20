//
//  ContentView.swift
//  VT 独立客户端 —— 全部在设备侧完成，不依赖电脑、不依赖服务端账号。
//

import SwiftUI

// MARK: - 节点表

struct VTNode: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let relayHost: String
    let relayPort: UInt16
}

enum VTNodes {
    /// 全部 9 条 /sync 直连节点。实测吞吐（单流 50MB）写在注释里，
    /// 香港 No.1 108~265 Mbps 最稳；日本 No.1 只有 2 Mbps，默认排最后。
    static let all: [VTNode] = [
        .init(name: "香港 No.1 (电信) ●265Mbps", relayHost: "183.61.173.57",  relayPort: 15889),
        .init(name: "香港 No.2 (联通) ●实测可用", relayHost: "112.65.199.137", relayPort: 15889),
        .init(name: "香港 No.3 (联通备用) ●100Mbps", relayHost: "112.65.199.136", relayPort: 15889),
        .init(name: "美国 No.1 (电信) ●133Mbps", relayHost: "183.61.173.57",  relayPort: 3589),
        .init(name: "美国 No.2 (联通)",          relayHost: "112.65.199.134", relayPort: 3589),
        .init(name: "新加坡 No.1 (电信) ●31Mbps", relayHost: "183.61.173.57",  relayPort: 5228),
        .init(name: "新加坡 No.2 (联通)",         relayHost: "112.65.199.134", relayPort: 5228),
        .init(name: "日本 No.2 (联通)",           relayHost: "112.65.199.134", relayPort: 3389),
        .init(name: "日本 No.1 (电信) ○慢",       relayHost: "183.61.173.57",  relayPort: 3389),
    ]
}

// MARK: - 主界面

struct ContentView: View {
    @State private var selectedRelay = 0
    @State private var running = false
    @State private var logs: [String] = []
    @State private var stats = VTProxy.Stats()
    @State private var proxy: VTProxy?
    @State private var showSelfTest = false
    // 静音音频保活：让本 App 在被别的东西盖住、或锁屏后仍能维持监听。
    // 系统在内存吃紧/省电模式下仍可能挂起，此时小火箭的流量会直接断掉，
    // 所以小火箭那边必须配 fallback（见界面底部说明）。
    @State private var keepAlive = KeepAlive()

    private let listenPort: UInt16 = 18890

    var body: some View {
        NavigationStack {
            Form {
                Section("启动节点") {
                    Picker("中继", selection: $selectedRelay) {
                        ForEach(Array(VTNodes.all.enumerated()), id: \.offset) { i, n in
                            Text(n.name).tag(i)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("本地代理") {
                    HStack {
                        Text("HTTP / CONNECT")
                        Spacer()
                        Text("127.0.0.1:\(String(listenPort))")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        running ? stop() : start()
                    } label: {
                        HStack {
                            Spacer()
                            Label(running ? "断开" : "连接",
                                  systemImage: running ? "stop.circle.fill" : "bolt.horizontal.circle.fill")
                                .font(.headline)
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(running ? .red : .accentColor)
                }

                Section("统计") {
                    row("连接尝试", "\(stats.attempts)")
                    row("成功", "\(stats.ok)")
                    row("失败", "\(stats.failed)")
                    row("在线连接", "\(stats.liveConns)")
                    row("上行", bytes(stats.upBytes))
                    row("下行", bytes(stats.downBytes))
                    if !stats.lastError.isEmpty {
                        Text(stats.lastError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section("日志") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(logs.enumerated()), id: \.offset) { _, l in
                                Text(l)
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(minHeight: 160)
                }

                Section {
                    Button {
                        showSelfTest = true
                    } label: {
                        Label("协议自检（12 项字节级比对）", systemImage: "checkmark.seal")
                    }
                } header: {
                    Text("自检")
                } footer: {
                    Text("期望值来自桌面端 proto.js 的真实计算输出，全绿说明本机实现与桌面逐字节一致。")
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("① 本 App 必须一直开着")
                            .font(.footnote.weight(.semibold))
                        Text("它是「服务端」：小火箭把流量交给 127.0.0.1:\(String(listenPort))，"
                             + "这条监听一旦没了，所有流量就无处可去。已自动开启静音音频保活，"
                             + "可以切后台；但省电模式、低电量、长时间没交互仍可能被系统挂起。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("② 小火箭里必须配 fallback")
                            .font(.footnote.weight(.semibold))
                        Text("策略组把本 App 的这个 HTTP 代理和一个 DIRECT 备用项放一起；"
                             + "否则本 App 一旦被挂起，小火箭会连不上出站，表现为整机断网。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("③ 想彻底不用管这件事")
                            .font(.footnote.weight(.semibold))
                        Text("那需要 NetworkExtension（系统级 VPN），要付费开发者账号或带 NE 权限的证书。"
                             + "协议层已经写完，将来只是套一层壳。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("使用前必读")
                }
            }
            .navigationTitle("VT 直连")
            .sheet(isPresented: $showSelfTest) { SelfTestView() }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k)
            Spacer()
            Text(v).font(.system(.body, design: .monospaced))
        }
    }

    private func bytes(_ n: Int) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        return f.string(fromByteCount: Int64(n))
    }

    // MARK: - 动作

    private func start() {
        let node = VTNodes.all[selectedRelay]
        let relays = VTNodes.all.map { ($0.relayHost, $0.relayPort) }
        // 首选节点放最前，其余作为自动故障转移池
        var ordered: [(String, UInt16)] = [(node.relayHost, node.relayPort)]
        ordered += relays.filter { $0 != (node.relayHost, node.relayPort) }

        // 把隧道的诊断输出接进日志面板（前缀 VT>）
        VTDiag.sink = { m in DispatchQueue.main.async { append("VT> " + m) } }

        let p = VTProxy(port: listenPort, relays: ordered)
        p.onLog = { m in DispatchQueue.main.async { append(m) } }
        p.onStats = { s in DispatchQueue.main.async { stats = s } }
        do {
            try p.start()
            proxy = p
            running = true
            // 起保活：本 App 是"服务端"，被杀掉小火箭就全线断流，所以必须常驻。
            keepAlive.start()
            append("使用节点 \(node.name)")
            append("已开启后台保活（静音音频）")
        } catch {
            append("启动失败: \(error.localizedDescription)")
        }
    }

    private func stop() {
        keepAlive.stop()
        proxy?.stop()
        proxy = nil
        running = false
    }

    private func append(_ s: String) {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        logs.append("[\(df.string(from: Date()))] \(s)")
        if logs.count > 200 { logs.removeFirst(logs.count - 200) }
    }
}

// MARK: - 自检页

struct SelfTestView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var results: [SelfTest.Case] = []
    @State private var ran = false

    private var allPass: Bool { ran && results.allSatisfy(\.pass) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if !ran {
                        Button("开始自检") { results = SelfTest.run(); ran = true }
                    } else {
                        HStack {
                            Image(systemName: allPass ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(allPass ? .green : .red)
                            Text(allPass ? "全部 \(results.count) 项通过" : "有失败项")
                                .font(.headline)
                            Spacer()
                            Button("重跑") { results = SelfTest.run() }
                                .font(.footnote)
                        }
                    }
                }
                ForEach(Array(results.enumerated()), id: \.offset) { _, c in
                    HStack(alignment: .top) {
                        Image(systemName: c.pass ? "checkmark" : "xmark")
                            .foregroundStyle(c.pass ? .green : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.name).font(.system(size: 12, design: .monospaced))
                            Text(c.detail).font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("协议自检")
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("关闭") { dismiss() } } }
        }
        .onAppear { if !ran { results = SelfTest.run(); ran = true } }
    }
}

// MARK: - 入口

@main
struct VTClientApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
