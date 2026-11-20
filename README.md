# VT 直连（iOS 独立客户端）

iPhone 本机跑 VT 隧道，**不依赖电脑、不需要 VPS、不消耗 ViewTurbo 账号配额**。

App 在设备上监听 `127.0.0.1:18890` 做 HTTP 代理，把流量封进 VT 私有协议直连中继，
系统 Wi-Fi 代理或小火箭指向它就完成全局代理。

---

## 一、为什么是「App 内本地代理」这个形态

iOS 上要做真正的系统级 VPN，只有 NetworkExtension + Packet Tunnel 一条路，
**而且必须在付费开发者账号（$99/年）下才能申请到那个 entitlement**。

没有账号的前提下，能落地的形态只有一个：

```
[系统 / 小火箭]  --HTTP-->  127.0.0.1:18890 (本 App)  --VT隧道-->  中继 183.61.173.57:15889
```

- 监听 loopback 不需要任何特殊 entitlement；
- CONNECT 与普通 HTTP 都支持，HTTPS 走 CONNECT 隧道天然可用；
- 小火箭里加一个「HTTP 代理」指向本机，就能把它的规则/分流全部用上。

限制（实话实说）：App 被系统挂起时隧道会断。所以内置了静音音频保活，
前台 + 保活下可长时间在线；省电模式或长时间无交互仍可能被挂起。

---

## 二、协议实现（逐字节对齐 `proto.js`）

| 环节 | 具体做法 |
|---|---|
| master key | `EVP_BytesToKey("password")` = `MD5(pw) ‖ MD5(MD5(pw) ‖ pw)` 取 32B |
| subkey | `HKDF-SHA1(master, salt, "ss-subkey", 32)`，CryptoKit 不暴露 SHA1 版 HKDF，已手写 |
| 本地 salt | 32B 随机；**上线时只把首字节取反**，派生 key 用原值 |
| auth 块 | 60B：铺 `0x41+i%26` → 写 32 位随机 token → 第 n 位放 `':'` → **第 2 字节取反** |
| HTTP 伪装 | `POST /sync HTTP/1.1` + `Host` / `Connection: keep-alive` / `Pragma: no-cache` / `Transfer-Encoding: chunked` / `Content-Type: application/octet-stream`，**body 直发不做 chunk 编码** |
| 帧格式 | `E(2B 大端明文长度)` + `E(payload)`，AEAD = ChaCha20-Poly1305，tag 16B |
| nonce | 12B 小端，从 0 起，**每帧 +1**（长度帧也占一个） |
| 单帧上限 | 写 16383 / 读 16384，超出自动切片 |
| 服务端 salt | 响应头之后 32B，**不取反** |

### auth 块是硬需求（实测）

对着真中继 `183.61.173.57:15889` 做过 8 变体对照：

| 变体 | 请求头 | auth | 结果 |
|---|---|---|---|
| A | 完整 | 有 | ✅ 200 + 目标站点响应 |
| B | 完整 | **无** | ❌ 对端直接关（phase=header） |
| C | 极简 `Host` 一行 | 有 | ✅ 200 |
| D | 极简 | 无 | ❌ |
| E | HTTP/1.0 极简 | 无 | ❌ |
| F | obfs 风格（带 `Content-Length`） | 有 | ✅ 200 |
| G | obfs 风格 | 无 | ❌ |
| H | 完全无 HTTP 头 | 无 | ❌ |

结论：**HTTP 头可以极简，但那 60 字节 auth 不可省**。
这就是为什么小火箭的 SS + obfs(http) 插件救不了 —— obfs 的数据前缀塞不进 auth 块，
所以必须自己实现协议端。同时空 token 也会被拒，每个连接都要新的 32 位随机 token。

---

## 三、构建：Windows 上不用装 Mac

iOS 的 `.app` 只能由 Apple 工具链产出，因此走 GitHub Actions 的免费 macOS runner。

1. 把本目录推到一个 GitHub 仓库（public 或 private 均可）：

```powershell
cd D:\suyou\vt-ios
git init
git add -A
git commit -m "VT iOS client"
git branch -M main
git remote add origin https://github.com/<你的账号>/vt-ios.git
git push -u origin main
```

2. 打开仓库的 **Actions → build-ipa → Run workflow**，等 3~6 分钟。

3. 在该次运行页面底部下载 artifact **`VTClient-unsigned-ipa`**，解压得到
   `VTClient-unsigned.ipa`。

4. Windows 上装 [Sideloadly](https://sideloadly.io/)，USB 连手机：

   - `IPA` 选刚下载的文件
   - `Apple ID` 填你自己的（免费账号即可）
   - 点 Start，输入 Apple ID 密码；若开了双重认证，用 App 专用密码
   - 手机「设置 → 通用 → VPN与设备管理」里信任证书

   免费账号签的 App **7 天过期**，到期用 Sideloadly 重签一次即可（数据不丢）。

5. 首次启动若提示「不受信任的开发者」，去设置里信任；若提示需要开启开发者模式
   （iOS 16+），按提示重启并在「设置 → 隐私与安全性 → 开发者模式」里打开。

---

## 四、用起来

1. 打开 App → 选节点（默认香港 No.1，实测单流 265 Mbps）
2. 点「连接」，看到 `代理已监听 127.0.0.1:18890`
3. 二选一：
   - **系统级**：设置 → Wi-Fi → 当前网络 → 配置代理 → 手动 → 服务器 `127.0.0.1`，端口 `18890`
   - **小火箭内**：添加一个「HTTP」类型的代理，地址 `127.0.0.1:18890`，在策略组里指向它
4. 打开 Safari 访问 `https://ip.sb`，看到香港/美国 IP 即成功

节点表在 `VTClient/ContentView.swift` 的 `VTNodes.all`：9 条 `/sync` 直连节点，
吞吐实测值写在名字里。切换节点会自动把其余 8 条作为故障转移池，
当前中继失活会立刻换下一条。

---

## 五、自检（装到手机后第一件事）

App 内点「协议自检」，跑 11 项字节级比对：

```
masterKey / subkey(两种 salt) / frame("abc") / frame 第二帧 nonce 推进
FrameReader 闭环 / auth(60B) / addr 域名 / addr IPv4 / addr IPv6
invertFirst 只翻首字节 / 16384 切两帧 = 16420B
```

这些期望值来自 `D:\suyou\vt-client\_gen_vectors.js` 对 `proto.js` 的真实计算输出。
**全部通过就说明 Swift 端与桌面端实现完全一致**，后面连不上只可能是网络/中继问题，
而不是协议写错。

若某项失败，`detail` 会显示 got/want 前 24 个字符，直接对照即可定位。

---

## 六、文件清单

| 文件 | 作用 |
|---|---|
| `VTClient/VTCrypto.swift` | masterKey / subkey / Sealer / FrameReader / auth / 地址编码 |
| `VTClient/VTTunnel.swift` | 到中继的 TCP + 握手状态机 + 帧流 |
| `VTClient/VTProxy.swift` | 本地 HTTP 代理（CONNECT + 普通 HTTP）、中继故障转移、统计 |
| `VTClient/KeepAlive.swift` | 静音音频后台保活 |
| `VTClient/SelfTest.swift` | 11 项字节级自检向量 |
| `VTClient/ContentView.swift` | SwiftUI 界面、节点表 |
| `VTClient/Info.plist` | Bundle 配置、`UIBackgroundModes: audio` |
| `VTClient.xcodeproj/` | Xcode 工程（无签名配置，供 CI 产出未签名包） |
| `.github/workflows/build-ipa.yml` | macOS runner 编译 + 打包 IPA（双路径） |
| `_check_proxy_logic.js` | Windows 上就能跑的代理解析逻辑自检（19 项） |

### 已经验证过的部分

```powershell
node D:\suyou\vt-ios\_check_proxy_logic.js
```

```
✓ host:port          ✓ CONNECT              ✓ 绝对 URI 带端口
✓ ip:port            ✓ CONNECT v6           ✓ 绝对 URI 无端口
✓ [v6]:port          ✓ CONNECT 缺端口       ✓ Host 头
✓ 裸主机(无端口)      ✓ GET 绝对 URI        ✓ Host 头无端口
✓ 裸 v6(无方括号)     ✓ GET 相对 URI        ✓ 两者都没有
✓ 端口越界 70000      ✓ header 小写化
✓ 端口 0 / 空 host

全部 19 项通过 —— VTProxy 的解析逻辑与 Swift 端一致
```

协议侧同样经过了真机（真中继）验证：8 变体握手表、随机 token 可用、
单流 265 Mbps、故障转移、`/sync` 空 `data` 是"只上传不下载"的根因 —— 全部是实测结论。

### CI 双路径兜底

手写的 `project.pbxproj` 万一不被 Xcode 接受，workflow 会自动降级：

1. **路径 A**：`xcodebuild -project ... -scheme VTClient`（正常路径）
2. **路径 B**：`xcrun swiftc -sdk iphoneos -target arm64-apple-ios16.0 -parse-as-library`
   直接把 6 个 `.swift` 编成可执行文件，再手工组 `.app` + 写死 `Info.plist` 的变量
   （源 plist 用的是 `$(EXECUTABLE_NAME)` 这类构建变量，swiftc 路径没有替换器，
   workflow 里用 `PlistBuddy Set` 显式写死，否则装上去会闪退）

两条路径任一成功都会打出同一个 `VTClient-unsigned.ipa`。

---

## 七、已知限制

- 免费账号 7 天重签；企业证书/付费账号可免。
- 后台靠静音音频保活，省电模式下仍可能被挂起。
- 中继是匿名会话，单连接吞吐受服务端单会话配额限制
  （实测单流 265 Mbps、8 并发可跑满千兆；单个 TCP 流拿不满 500M 是服务端策略，不是客户端问题）。
- 日本 No.1（`183.61.173.57:3389`）实测只有 2 Mbps，已排在列表最后。
