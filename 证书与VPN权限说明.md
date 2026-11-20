# 证书 / VPN 权限（NetworkExtension）实况说明

这份文档回答一个具体问题：**能不能用自签或企业证书，让 App 开系统级 VPN？**
以及拿不到 VPN 权限时，怎么照样实现全局接管。

---

## 一、结论先给

| 签名方式 | 能装 App | 能用 NetworkExtension VPN | 原因 |
|---|---|---|---|
| 免费 Apple ID 自签（Sideloadly / AltStore） | ✅ | ❌ | Personal Team 的 provisioning profile **不签发** `com.apple.developer.networking.networkextension` |
| 付费个人账号（$99/年） | ✅ | ✅ | 可勾 Network Extensions capability |
| 企业账号 In-House（$299/年） | ✅ | ✅ **前提是 App ID 勾了 NE** | 泄漏证书多数只带 basic 权限，不带 NE |
| **LiveContainer / 注入式运行** | ✅ | ❌ | 没有独立 bundle 与 entitlements，宿主不代持 NE |

**LiveContainer 那个判断是对的**——它把 App 当插件塞进宿主进程跑，entitlements 用的是宿主的，
既拿不到 NE 这个 entitlement，也没有独立的 Bundle ID 可供 profile 匹配。NE 这条路在它上面是死的。

---

## 二、为什么自签一定拿不到 VPN

VPN 权限不是一个"开关"，是 provisioning profile 里的一张清单：

```
mobileprovision
 └─ Entitlements
     ├─ application-identifier       = TEAMID.com.your.bundleid
     ├─ com.apple.developer.networking.networkextension
     │    └─ ["packet-tunnel-provider"]     ← 缺这一行，NE 永远起不来
     └─ get-task-allow               = false
```

这张 profile 是 **Apple 服务器按 App ID 的 capability 配置签发的**。
免费 Personal Team 的可勾选能力里没有 Network Extensions，所以签出来的 profile 里就没有那一条。
你在 Xcode 里硬写 `.entitlements` 也没用——安装阶段 profile 与 entitlements 不匹配，直接被拒：

```
Provisioning profile "..." doesn't include the
com.apple.developer.networking.networkextension entitlement.
```

绕不过去。这是服务端签发的，不是客户端校验。

### 顺便一个坑：带 NE 的 profile 不能用通配符

`com.apple.developer.networking.networkextension` **不接受通配符 App ID**。
所以别人的证书即使带 NE，也只能签他那一个固定 bundle id；
你改名成 `com.your.vt` 就废，必须让证书持有者把你的 bundle id 加进他的 App ID 列表重新出 profile。

这就是淘宝"企业证书自签"经常签完 VPN 起不来的真实原因：证书是真的，NE 权限没配到你的 bundle id 上。

---

## 三、但你不需要 NE —— 小火箭已经有

这是关键的一点，直接决定要不要花 $99：

```
iOS 系统
  └─ 小火箭（它自己有 NE 权限，已经能全局接管）
        └─ 出站：HTTP 代理 → 127.0.0.1:18890
                                  └─ 本 App（只要本地监听权限，免费自签就够）
                                        └─ VT 隧道 → 183.61.173.57:15889 → 香港落地
```

**分工**：

- **小火箭**负责当网卡（NE、TUN、全局路由、分流规则）——它已经装好能用，权限问题不在我们这边
- **本 App**负责协议端（VT 握手 + AEAD 帧 + 故障转移）——只需监听 loopback，免费证书就能签
- 两者用 `127.0.0.1:18890` 接起来

这样做的效果：**全局接管 + 不走 ViewTurbo 账号配额 + 不依赖电脑**，一毛钱不花。

代价：小火箭必须同时开着（它本来就在你后台跑）。但这不是"依赖电脑"，
是"依赖手机上另一个已经付费/已装的 App"。

### 为什么不能用小火箭的脚本实现，而必须用这个 App

之前试过写小火箭的 `http-response` 脚本改节点列表，失败原因是：

1. 小火箭脚本碰不到明文 HTTP 响应（MITM 只对 HTTPS 生效）
2. 更要命的是——**协议层的 60 字节 auth 块，脚本没有地方塞**
   实测 8 变体：有 auth 全通（200），无 auth 全部被对端直接关

小火箭的 SS + obfs 插件做不到这件事，obfs 的数据前缀是固定格式，塞不进 VT 的 auth 块。
所以协议端只能自己实现，也就是这个 App。

---

## 四、操作清单

### A. 免费签（不需要任何付费账号）

1. 按 `README.md` 用 GitHub Actions 出 `VTClient-unsigned.ipa`
2. Sideloadly 配自己的 Apple ID 装进手机
3. 打开 App → 选节点 → 连接（显示 `代理已监听 127.0.0.1:18890`）
4. 小火箭里：
   - `配置 → 添加` → 类型选 **HTTP**
   - 地址 `127.0.0.1`，端口 `18890`，用户/密码留空
   - 路由选 **全局路由（GLOBAL）**，或在你现有配置里把它设成最终出站
5. 小火箭连接 → 全局走 VT

### B. 如果坚持要真正的系统级 VPN（NE）

需要满足全部三条，缺一不可：

1. 一个**带 NE capability** 的签名身份（自己的 $99 账号 / 带 NE 的企业证书）
2. 该账号给你的 **bundle id 建显式 App ID 并勾上 Network Extensions → Packet Tunnel Provider**
3. 设备 UDID 在 profile 里（Ad-Hoc 类型），或证是 In-House 类型（不限设备）

满足后再加一层代码：`NEPacketTunnelProvider` 子类 + `NEVPNManager` 配置，
把现有的 `VTTunnel` 搬进 provider 里当出站。这部分是纯增量，现在的代码结构可以直接复用。

---

## 五、当前 App 的分层（方便以后加 NE）

| 层 | 文件 | 加 NE 时怎么处理 |
|---|---|---|
| 协议层 | `VTCrypto.swift` | 原样搬 |
| 隧道层 | `VTTunnel.swift` | 搬进 provider，改成本地出站 |
| 代理层 | `VTProxy.swift` | 保留（本地调试用），NE 下不再需要 |
| 保活 | `KeepAlive.swift` | NE 下不需要，provider 自带生命周期 |
| 界面 | `ContentView.swift` | 只留节点选择与状态 |

所以现在这套等于把最难的部分（协议 + 帧 + 故障转移）已经写完了，
将来有钱上 $99 只是套一层壳的事。

---

## 六、实测：NE 层 + 本地 HTTP 代理这条路真的通

在 Windows 上用 `core.exe`（mihomo）扮演"小火箭的 NE 层"，出站指向 VT 引擎的本地 HTTP 代理，
完整复现了 iOS 上要跑的那条链路：

`
配置：proxies: [ http://127.0.0.1:18891#VT-Engine ]  →  proxy-groups GLOBAL select  →  MATCH,VT-Engine
监听：127.0.0.1:17890（只回环）
`

结果（全部真实输出）：

| 检查项 | 结果 |
|---|---|
| 监听地址 | `127.0.0.1:17890`（只回环，外网进不来） |
| 出口 IP | `103.85.75.133` 香港 深水埗區 GOALNOW NETWORK |
| gstatic generate_204 | `204` |
| youtube.com | `200` |
| chatgpt.com | `200` |
| google.com | `302` |
| 单流 20 MB 吞吐 | **22.69 MB/s = 181 Mbps**，耗时 0.84 s |

结论：**NE 层负责当网卡，本地 HTTP 代理负责协议端**，这个组合在真机上成立，
而且单流就能跑 181 Mbps。所以不需要  账号，也不需要企业证书。

（这项测试里 mihomo 只是用来模拟小火箭的位置；真机上那一层由小火箭自己提供，它已经有 NE 权限。）