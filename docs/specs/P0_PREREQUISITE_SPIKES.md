# Phase 0 子 Spec：前置真机与环境验证（不动线上）

> 对应总 Spec：[SPEC_DECOUPLE_AND_IOS.md §9 Phase 0](../SPEC_DECOUPLE_AND_IOS.md)
> 原则：**只做最小验证原型与实证记录，不动 `~/.hermes` 生产环境，不改线上代码。**
> 门禁 **Gate 0**：S0-1 ~ S0-5 全部实证通过后方可进入 [Phase 1](./P1_BACKEND_DECOUPLE.md)；任一核心假设不成立必须先调整方案。

---

## 执行顺序与并行安排

```text
S0-0 (Xcode 27 与真机配对) ──► S0-1 (LaunchAgent 无线续签)  ∥  S0-3 (SPKI+ATS)  [共用真机，安装错开]
                                                                    ▲
S0-4 (防火墙 + uv Python + TCC) ───[共用 18170 TLS 最小测试桩]───────┘
S0-2 (独立 CF Tunnel + SSE 保活) ──[独立并行]
S0-5 (barkcrypt + Bark 升权覆盖) ──[完全独立并行]
```

---

## S0-0：Xcode 27 工具链与 iOS 27 真机配对就绪

- **并行性**：🔴 严格串行（S0-1 / S0-3 前置）
- **当前状态**：本机 `Xcode 27.2 (Build 27B52)` 与许可协议已完成；剩余确认项为 iPhone 无线调试配对与 UDID 记录。
- **执行步骤**：
  1. 执行 `xcrun devicectl list devices --json-output -`，确认目标 iPhone 在线、处于已配对状态，记录其 `identifier`（UDID）与局域网 IP（预期 `192.168.50.201`）；
  2. 核对 Xcode Accounts 中免费签名身份 `Apple Development: ffkiyo7@gmail.com`（Team `DY725KK25V`）登录态有效。
- **验收清单**：
  - [x] `xcodebuild -version` 返回 Xcode 27.2 且无 license 阻塞（实测：`Xcode 27.2 Build 27B52`）
  - [x] `xcrun devicectl list devices` 可见已配对 iOS 27 iPhone 并记录 UDID（实测：`wadomark0`，iOS 27.3 `24C5037i`，`iPhone18,4`，UDID `00008150-001C28941138401C`，CoreDevice UUID `FE667877-5229-5F85-9E01-F975FE983491`）
  - [x] 确认 Xcode 个人 Apple ID 登录有效（`Apple Development: ffkiyo7@gmail.com (8LW57467CK)`，Team `DY725KK25V`，有效期至 2027-10-05）

---

## S0-1：LaunchAgent 无线续签 & `ExpirationDate` 后移实证

- **前置依赖**：S0-0
- **并行性**：🟡 与 S0-2 / S0-4 / S0-5 可并行；与 S0-3 共用同一台真机，建议 S0-3 复用本测试 App 壳子。
- **验证目标**：
  1. 在**用户级 LaunchAgent 上下文**（非交互终端）中，`xcodebuild -allowProvisioningUpdates` 与 `xcrun devicectl device install app` 可无人工弹窗完成构建与无线安装；
  2. 覆盖安装同时验证**亮屏**与**锁屏**两种状态；
  3. **核心硬指标**：解析生成的 `.app/embedded.mobileprovision` 中的 `ExpirationDate`，在**未到期前**隔一段时间（或次日）重新执行一次带 `-allowProvisioningUpdates` 的重建，实证 `ExpirationDate` 确实向后延展（而非复用原到期日）。
- **关键核验命令参考**：
  ```bash
  security cms -D -i <path/to/App.app/embedded.mobileprovision> \
    | plutil -extract ExpirationDate raw -
  ```
- **失败回退预案**：
  - 若免费账号在到期前重建**不延展** `ExpirationDate`（Apple 服务端复用原 7 天 Profile），须在 Phase 4 前修订续签触发逻辑（如先删旧 provisioning profile 再触发生成，或改为到期后首次回家自动重签 + 提前人工触发）；
  - 若锁屏无线安装失败，确认守护进程依赖「亮屏重试 + 归家快捷指令唤醒」兜底。
- **验收清单**：
  - [x] LaunchAgent 环境下无钥匙串/权限弹窗完成构建与无线安装（实测通过）
  - [x] 亮屏与锁屏安装表现已记录（实测：**亮屏与锁屏无线覆盖安装均成功无弹窗**）
  - [x] 两次构建的 `embedded.mobileprovision` `ExpirationDate` 已比对并确认后移机制（**关键发现**：保留本地缓存 Profile 重建不会延展 `ExpirationDate`；**先移走 `~/Library/Developer/Xcode/UserData/Provisioning Profiles/<OLD_UUID>.mobileprovision` 再 `xcodebuild -allowProvisioningUpdates`**，实证 UUID 由 `7ad5e785-…` 换为 `c44a291e-…`，`ExpirationDate` 由 `2026-11-28T09:34:20Z` 精准后移至 `2026-11-28T09:44:58Z`，已回写至 `P4_AUTO_RESIGN_AND_P2.md`）

---

## S0-2：独立 Cloudflare Tunnel & SSE 25s 保活实证

- **前置依赖**：无
- **并行性**：🟢 完全可并行
- **验证目标**：
  1. 创建独立隧道 `wados-maa`（独立 UUID 与独立 `~/.cloudflared/wados-maa.yml`），绑定子域 `maa.luxraykit.com`，不影响既有 `netease-mcp` 与 `shizukumo.uk`；
  2. `ingress` 指向本地测试 TLS 端口 `https://127.0.0.1:18170`（配 `originRequest.caPool` 指向测试自签 `cert.pem`）；
  3. iPhone 在 **5G + Stash** 与 **家中 Wi-Fi + Stash** 两种网络下测试请求延迟，并保持一条 SSE 流（服务端每 25 秒发 `: keepalive\n\n`）连续不断连 ≥ 5 分钟。
- **验收清单**：
  - [x] 独立隧道 `wados-maa`（UUID `dcd1aac1-ff11-4a1f-b91c-9fb37b045716`）与 `maa.luxraykit.com` DNS 生效，既有 `netease-mcp` 无感；确认须配置 `protocol: http2` 适配本机 TUN/fake-ip
  - [x] `cloudflared` 凭 `caPool` 成功校验本地自签 TLS 证书
  - [x] 5G + Stash 下 SSE 稳定保活 ≥ 5 分钟不断连（实测连续 12 轮 25s keepalive、>5 分钟 0 断连；5G `/healthz` RTT `945ms–1892ms`）

---

## S0-3：iOS 27 真机最小 App 自签 TLS + SPKI Pinning & ATS 实证

- **前置依赖**：S0-0（及与 S0-4 共用的 `18170` 最小自签 TLS 测试桩）
- **并行性**：🟡 与 S0-2 / S0-5 可并行；与 S0-1 错开真机安装；与 S0-4 共享 `18170` 测试桩。
- **验证目标**：
  1. 生成 SAN 含 `IP:192.168.50.2` 与 `IP:127.0.0.1` 的自签证书并提取 SPKI SHA-256 指纹；
  2. 在最小 iOS 27 测试 App 中**不配置 `NSAllowsLocalNetworking`**，仅配 `NSLocalNetworkUsageDescription` + `URLSessionDelegate` 的 SPKI Pinning，在 **Stash 开启**状态下直连 `https://192.168.50.2:18170/healthz`；
  3. 故意填入错误 SPKI 指纹，验证 TLS 握手阶段直接拒绝且不会发出 HTTP Header（确保伪造 `.2` 无法窃取 Bearer Token）。
- **失败回退预案**：若 iOS 27 ATS 在不带 `NSAllowsLocalNetworking` 时仍拦截纯 IP 自签 HTTPS，记录确切 `CFNetwork`/`ATS` 错误码并评估是否仅需最小 ATS 例外（同时严格保持 SPKI Pinning 强校验）。
- **验收清单**：
  - [x] 正确 SPKI 指纹下，真机直连 `https://192.168.50.2:18170/healthz` 成功（实测 `30–42ms`；**关键发现**：须使用 Homebrew `openssl@3` + `ec_param_enc:named_curve` 生成 ECDSA P-256 证书，LibreSSL 默认 explicit 参数会被 Apple `SecCertificateCopyKey` 拒认）
  - [x] 错误 SPKI 指纹下，TLS 握手即中止（`16–24ms`）且服务端日志证实零 HTTP 请求、Bearer Token 零泄露
  - [x] ATS 最终 `Info.plist` 最小配置定型：**无需 `NSAllowsLocalNetworking`**，仅需 `NSLocalNetworkUsageDescription` + `URLSessionDelegate` SPKI Pinning

---

## S0-4：macOS 防火墙下 uv ad-hoc Python 入站放行 & TCC 稳定性实证

- **前置依赖**：无
- **并行性**：🟡 与 S0-1 / S0-2 / S0-5 可并行；与 S0-3 共用 `18170` 最小 TLS 监听桩。
- **验证目标**：
  1. 在本机 macOS 应用防火墙开启（`State = 1`）条件下，用 `/Users/wadorudi/.local/bin/python3`（uv 管理的 `adhoc` 签名 `cpython-3.12.13`）在 LaunchAgent 中监听 `0.0.0.0:18170`，实测局域网 iPhone 入站访问是否稳定放行、重启后是否反复弹窗或被拒；
  2. 实测该 Python（或由其拉起的子进程）在辅助功能（`winmove`）与屏幕录制（`screencapture` 兜底）TCC 权限上的稳定性（模拟重建/升级）。
- **决策输出（写入实证记录，供 Phase 1 S1-5 消费）**：
  - 方案 A：uv `adhoc` Python 防火墙与 TCC 均稳定 → `wados-maa-daemon` LaunchAgent 直接运行 Python；
  - 方案 B：存在放行失效或 TCC 丢失 → 采用固定 `Apple Development` 签名的极简 Swift launcher 二进制作为 LaunchAgent 入口，再 `exec`/拉起 Python。
- **验收清单**：
  - [x] 防火墙开启（`State = 1`）时局域网入站 `18170` 放行行为已实测：uv `adhoc` Python 被写入精确版本号路径放行（`cpython-3.12.13`），升级 Python 将失效
  - [x] TCC 权限现状已核实：uv `adhoc` Python 当前 `AXIsProcessTrusted = False`、`CGPreflightScreenCaptureAccess = True`，`adhoc` 无固定 Team/Identifier 无法长期稳定持有辅助功能授权
  - [x] 守护进程入口形态定型：**方案 B（固定 `Apple Development` 签名的极简 Swift launcher 二进制）**

---

## S0-5：`barkcrypt` 加密原型 & Bark 同 `id` 升权覆盖实证

- **前置依赖**：无
- **并行性**：🟢 完全可并行
- **验证目标**：
  1. 用最小 Swift `CryptoKit.AES.GCM` 原型实现 Bark 加密：Key（32 字节 UTF-8 ASCII）、IV（12 字节随机 ASCII UTF-8）、输出 `Base64(sealedBox.ciphertext + sealedBox.tag)`（**禁用 `.combined`**）；
  2. 向官方 `https://api.day.app` 发送测试请求：外层明文 `device_key`、`ciphertext`、`iv`、`id`；内层密文含 `title`、`body`、`level`、`group`、`icon`、`url`（`wadosmaa://...`）；
  3. 实测**同 `id` 升权覆盖**：先发 `level=passive`（开跑静音），10 秒后用相同外层 `id` 发 `level=timeSensitive`（运行失败），观察 iPhone 锁屏与亮屏状态下是否会重新亮屏/震动/响铃提醒。
- **失败回退预案**：若同 `id` 覆盖 `passive` 不会重新提醒，Phase 1 的 `maa_notify.py` 失败/告警推送改为使用独立 `id`（例如 `run-<run_id>-alert`）而非覆盖开跑通知。
- **验收清单**：
  - [x] 真机 Bark App 成功解密 `barkcrypt` 密文并完整展示标题、正文与 `wadosmaa://` URL
  - [x] 同 `id` 下 `timeSensitive` 覆盖 `passive` 实测**原地覆盖生效且锁屏正常亮屏提醒** → 保持同一场次共用 `id=run-<run_id>`

---

## Gate 0 放行记录表（✅ 2026-11-21 18:08 全部通过，正式放行 Phase 1）

- [x] S0-0 就绪（Xcode 27.2 + `wadomark0` iOS 27.3 + Apple ID 登录有效）
- [x] S0-1 通过（移走本地缓存 Profile 后重建 `ExpirationDate` 精准后移至新 7 天；亮屏 & 锁屏无线安装全通）
- [x] S0-2 通过（`wados-maa` 隧道 `protocol: http2` + `caPool`；5G+Stash RTT `0.95–1.89s`，SSE >5 分钟 0 断连）
- [x] S0-3 通过（OpenSSL 3 `named_curve` P-256 + 无 `NSAllowsLocalNetworking` 直连 `30–42ms` + 错指纹握手拒连 0 泄露）
- [x] S0-4 通过（已选定入口形态：**方案 B：固定签名 Swift launcher**）
- [x] S0-5 通过（AES-256-GCM 解密无误，同 `id` 升权覆盖锁屏提醒生效，沿用 `id=run-<run_id>`）
