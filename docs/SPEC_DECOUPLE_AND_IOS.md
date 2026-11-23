# 总 Spec：Wado's MAA 与 Hermes/Discord 解耦及 iPhone 原生 App 规划

> 状态：**二轮复核定稿（可立即进入 Phase 0）** · 更新日期：2026-11-21（北京时间）
> 范围：同仓四目录协同——`maa-remote/`（Mac mini 后端与守护进程，MIT）、`gui/`（现有 Mac GUI 适配，AGPL-3.0）、`ios/`（独立 `WadosMAAiOS.xcodeproj` 原生工程，MIT）与 `shared/`（本地 Swift Package 跨端纯 Foundation 模型，MIT）。
> 说明：本文定义整体架构、安全模型、API 契约、不变量处置、迁移/回滚规程、功能层级与 iOS 27 UI 设计参考基线；具体页面视觉稿待进入 UI 细化阶段展开。当前仅规划，不修改代码。

---

## 1. 背景、目标与硬约束

### 1.1 目标
将 Wado's MAA 从本机 Hermes 调度器与 Discord 交互中**温和解耦**，使 Mac mini 上的 MAA 自动化成为独立自洽的服务，并通过安装在个人 iPhone 上的**原生 SwiftUI App** 实现随时随地的状态监控、日常调度、抄作业控制与配置调整。

### 1.2 核心约束与非目标
1. **温和解耦，零破坏现有 Hermes/Discord 业务，切线前不断手机控制入口**：
   - `~/.hermes` 中现有的 **16 条非 MAA cron**（含 `lax-service` 监控及其他个人任务）、`agent-book/buttons.json` 中的 **14 条非 MAA 按钮键**，以及用户在 Discord 中的自有 webhook **一字不动**。
   - **切线时机（已拍板）**：Phase 1 与 Phase 2 全部在 `devhome`（`~/Developer/forks/maa-remote-devhome`）完成开发与验收，线上 `~/.hermes` 与 Discord 照常运行；**待 Phase 3 iOS App 真机验收通过后，再统一执行生产切线**，避免开发过渡期手机失去日常控制入口。
   - **切线当步彻底杜绝双 `run.lock` 并发**：切线时一次性停用旧入口（Hermes 5 条在跑 MAA cron + 持 `agent-book/state.lock` 清理 18 条 MAA 按钮键 + MAA 技能 + `~/.hermes/scripts/maa_*.py` 替换为拒绝桩），并同步改写 Mac GUI 的 `RemoteHermesHome` 偏好至 `~/.wados-maa`（且 Mac GUI 代码层拒绝解析到 `~/.hermes`）。
2. **不购买付费 Apple Developer 账号**：
   - 使用现有免费个人签名身份（`Apple Development: ffkiyo7@gmail.com`）。
   - **接受的平台边界**：无原生 APNs 推送、无可靠的后台灵动岛/实时活动（ActivityKit 切后台约 30 秒后停止更新且无远程推送更新能力）、真机签名每 7 天过期。
   - **补偿机制**：关键节点推送走 **Bark**（官方服务端 + `barkcrypt` AES-GCM 端到端加密 + 自定义图标 + 同场次原地更新 + URL Scheme 跳回原生 App）；7 天签名靠 **Mac mini 无线自动续签**覆盖（须在 Phase 0 实证到期前重建确能延展 `ExpirationDate`）。
3. **适配本机网络环境，不折腾端口映射，局域网与公网同等防窃取**：
   - 家宽无公网 IP；Mac mini（`192.168.50.2`）常驻 Sparkle/mihomo TUN 并作为家庭旁路网关，且本机 macOS 应用防火墙已开启；iPhone 在外使用 Stash 占用唯一 VPN 槽位。
   - **不引入 Tailscale / 额外 VPN**，避免与 mihomo TUN 和 iPhone Stash 冲突。
   - 外网访问采用 **独立 Cloudflare Tunnel**（独立隧道 UUID 与配置文件），绑定 `maa.luxraykit.com`；局域网内走 **自签 TLS + App 证书/公钥固定（SPKI Pinning）** 直连优先，杜绝外网同名 `192.168.50.x` Wi-Fi 伪造 `.2` 骗取 Token。
4. **继承全部 MAA 核心业务不变量（不可妥协）**：
   - 详见 [maa-remote/docs/DEV_GUIDE.md §8](../maa-remote/docs/DEV_GUIDE.md) 及本文 §3.7（Discord 绑定类不变量的保留/改写/退役清单）：不吃非临期理智药（#2）、永不碎石（#1）、永不借助战（#15）、抄作业不忽略练度（#15/#18）、所有动游戏流程必须持 `run.lock`、游戏与台前调度收尾还原（#62）、单机只维护一份状态真值。

---

## 2. 整体系统架构

```text
┌─────────────────────────────────────────────────────────────────────────┐
│                              iPhone 侧                                   │
│  ┌─────────────────────────┐  ┌──────────────────┐  ┌────────────────┐  │
│  │ Wado's MAA iOS 原生 App │  │ Bark (App Store) │  │ 快捷指令/Safari│  │
│  │ · 4 Tab 控制与监控       │◄─┤ · AES-GCM 密文推送│ │ · 归家自动触发 │  │
│  │ · SSE 实时进度与战报截图 │  │ · URL Scheme跳回  │  │ · 签名过期兜底 │  │
│  └───────────┬─────────────┘  └────────▲─────────┘  └───────┬────────┘  │
└──────────────┼─────────────────────────┼────────────────────┼───────────┘
               │ 双轨 HTTPS 连接：       │ HTTPS 加密推送      │ 公网 HTTPS +
               │ ① 家中 Wi-Fi 优先直连   │ (api.day.app)      │ 独立续签 Token
               │    https://192.168.50.2:18170 (SPKI Pinning) │
               │ ② 出门自动切 CF Tunnel  │                    │
               │    https://maa.luxraykit.com                 │
┌──────────────▼─────────────────────────┼────────────────────▼───────────┐
│                   Mac mini (192.168.50.2, 登录图形会话)                   │
│                                        │                                │
│  ┌─────────────────────────────────────┴─────────────────────────────┐  │
│  │  wados-maa-cloudflared (独立 LaunchAgent，caPool 信任本地证书)     │  │
│  └─────────────────────────────────┬─────────────────────────────────┘  │
│                                    ▼                                    │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │  wados-maa-daemon (用户级 LaunchAgent, AbandonProcessGroup=true)  │  │
│  │  ├── 1. 内置调度器（北京时间，同日 2h 补跑，以 run.lock 防重入）    │  │
│  │  ├── 2. HTTPS / SSE API（线程内带超时 TLS 握手 + 分域 Bearer Token）│ │
│  │  ├── 3. 通知出口（Bark + barkcrypt Swift CryptoKit，不变量 #63）   │  │
│  │  └── 4. iOS 无线续签器（固定从 main 部署 worktree 构建并安装）      │  │
│  └──────────────────┬─────────────────────────────┬──────────────────┘  │
│                     │ 读写 ~/.wados-maa/state/maa │ start_new_session   │
│                     ▼                             ▼                     │
│  ┌───────────────────────────┐    ┌──────────────────────────────────┐  │
│  │ Wado's MAA Mac GUI (现有) │    │ maa_daily / maa_copilot / depot  │  │
│  │ Phase 3 切线时同步迁入     │    │ + PlayCover (MAA-Game 虚拟屏)    │  │
│  └───────────────────────────┘    └──────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

### 核心组件分工

| 组件 | 形态 | 职责 |
|---|---|---|
| `wados-maa-daemon` | 用户级 `LaunchAgent`（Python stdlib HTTPS/SSE 守护进程，`AbandonProcessGroup=true`；若 Phase 0 证实 ad-hoc uv Python 受防火墙/TCC 困扰，外包固定签名 Swift launcher） | 定时调度、TLS/Token 鉴权与动作转发、状态文件监听推送 SSE、Bark 加密推送、iOS 无线续签调度 |
| `wados-maa-cloudflared` | 独立用户级 `LaunchAgent` | 将 `maa.luxraykit.com` 转发到 `https://127.0.0.1:18170`（`caPool` 信任本地自签证书），与 `netease-mcp` 彻底隔离 |
| `barkcrypt` | Swift `CryptoKit` 编译产物（与 `ocrbox` / `winmove` 同纳入 `COMPILED_HELPERS`） | 为 Python 侧提供符合 Bark 规范的 AES-GCM（`ciphertext + tag`）加密能力，保持 Python 零第三方依赖 |
| `maa-remote` 现有脚本 | 独立会话短命子进程（`start_new_session=True`） | 日常执行、自动定关、抄作业搜索与连打、仓库对表、上游更新、PlayCover 窗口治理 |
| Wado's MAA iOS App | 同仓独立原生 Xcode 工程（`ios/WadosMAAiOS.xcodeproj`） | 移动端日常监控、场次调控、手动开跑、抄作业、历史战报与配置管理 |
| Wado's MAA Mac GUI | 现有 SwiftUI macOS Target | 本机桌面管理与高阶运维（敏感路径、完整诊断、桌面外观） |

---

## 3. 后端与 Hermes / Discord 温和解耦

### 3.1 数据目录独立（`WADOS_MAA_HOME`）与隐藏依赖修正
- 引入新环境变量 `WADOS_MAA_HOME`（默认 `~/.wados-maa`）。
- 解析优先级：`WADOS_MAA_HOME` → `HERMES_HOME` → `~/.wados-maa`；开发副本通过 `WADOS_MAA_HOME=~/Developer/forks/maa-remote-devhome` 隔离。
- 目录结构：
  ```text
  ~/.wados-maa/
    scripts/          # deploy.py 部署的目标（含编译产物 ocrbox / winmove / barkcrypt）
    state/maa/        # 生产切线时从 ~/.hermes/state/maa/ 迁移而来，schema_version 兼容
    daemon/
      daemon.json     # 守护进程配置（监听端口、Bark 配置、iOS UDID、自动续签策略、depot_enabled）
      secrets.json    # 0600：full / resign_only Token 哈希、Bark Device Key、Bark AES Key
      tls/            # 本地自签证书 cert.pem 与私钥 key.pem（0600，SAN 含 IP:192.168.50.2 与 127.0.0.1）
      scheduler.json  # 内置定时任务的上次运行时间、下次计划时间、补跑/跳过/结果状态
      resign.json     # 上次成功签名时间、ExpirationDate、状态、最近一次续签日志摘要
    logs/             # daemon.log / cloudflared.log / resign.log
    backups/          # 生产切线前自动留存的完整回滚包
  ```
- **换目录必须同步修正的四处隐藏依赖**：
  1. **`maa_upstream.py:177`**：`is_live_home()` 当前写死对比 `LIVE_HERMES_HOME`（`~/.hermes`），改为对比 `LIVE_HOME`（`~/.wados-maa`），否则新目录下手动更新资源会被误判为开发副本而拒绝；
  2. **代理环境变量**：`maa update` 与 `brew` 所需的 `HTTP_PROXY` / `HTTPS_PROXY` / `http_proxy` / `https_proxy` 目前来自 `ai.hermes.gateway.plist`，必须在 `wados-maa-daemon` 的 LaunchAgent plist 中显式配置（并与 `config.json` 的 `upstream_proxy` 对齐）；
  3. **历史与最近运行绝对路径迁移**：实测线上 **`runs/index.jsonl`（28 行）与 `last_run.json`（5 个文件路径字段）** 均含 `.hermes/state/maa/` 绝对路径，切线迁移脚本必须同时将两者中的 `.hermes/state/maa/` 改写为 `.wados-maa/state/maa/`（同时读取层支持相对路径或前缀重映射兜底）；
  4. **森空岛重绑引导文案**：更新 `maa_skland.py`（及错误提示）中指向 `~/.hermes/scripts/maa_skland.py` 的指引命令，改按当前 `SCRIPTS_DIR` 动态生成（即 `~/.wados-maa/scripts/maa_skland.py`），避免切线后提示用户去跑已被置桩的旧脚本。
- **内部状态锁**：从 `~/.hermes/state/agent-book/state.lock` 迁至 `state/maa/state.lock`，不再依赖 Hermes 目录。
- **独立部署模式**：`deploy.py` 新增独立模式（部署脚本、编译 `ocrbox`/`winmove`/`barkcrypt`、同步 `config/maa-cli/` 与状态种子），**不再对 Hermes 的 `adapter.py`、`config.yaml`、`.env`、`SKILL.md` 打补丁**。

### 3.2 核心业务流程去 Discord 硬依赖与 `ios` 来源全量接入
实测现有代码在**无 Discord 配置时核心流程会直接抛异常中断**，Phase 1 必须把「核心业务」与「Discord 交互卡片」彻底解耦：
1. **`maa_plan_card.py`**（原 L1175–L1178 一进来即要求 `channel_id` 与 `discord_token()`）：
   - 拆离「准备步骤」与「卡片发送」：早场上游更新、活动关探测刷新、自动定关写入 `plan.json`、旧日志/文件清理、以及 **森空岛每日体检（#56，L1355）** 必须无条件执行；
   - 原 Discord 计划卡发送改为可选旁路；上游更新失败、活动探测失败、森空岛每日体检告警均改走 `maa_notify.py`。
2. **`maa_action.publish_round()` 本身**（同时被 `maa_action.py:1766` 的 `copilot_go()` 与 `maa_copilot_worker.py:389` 调用）：
   - 直接改造 `publish_round()`：无 Discord 配置时跳过发排程卡与写 `BUTTONS_PATH`，返回 `message_id = ""` 并改由 `maa_notify.py` 发出通知，确保手动抄作业与自动抄作业两条链路在无 Discord 时均不报错、正常落盘排队并派发。
3. **`maa_activity_watch.py`**（原 L60 `_notify()` 及排程卡强依赖 `channel_id` / `discord_token()`）：
   - 替换 `_notify()` 及排程通知为 `maa_notify.py` 统一出口，移除对 `BUTTONS_PATH` 与 `retire_discord_components` 的强制调用。
4. **`ios` 来源全量覆盖**：
   - 将 `"ios"` 加入 `maa_common.ACTION_SOURCES` 白名单；
   - 新增统一辅助函数 `is_app_source(source)`（判断 `source in {"gui", "ios"}`），替换 `maa_action.py` 全部 **6 处** `gui` 特判（L151 `emit()` 隐藏 `detail` + L241 / L1340 / L1361 / L1935 / L2154）；
   - 修正 `maa_daily.py:2634` 手动场来源赋值：不再把非 `gui` 全部写死为 `"discord"`，改为保留白名单内的真实 `found.get("source")`（`"gui"` / `"ios"` / `"discord"`）；
   - Mac/iOS 的 `ChangeMeta.text` 同步识别 `"ios"`（显示「由 iOS 改」或「由 Wado's MAA (iOS) 改」）。

### 3.3 内置定时调度器与进程生命周期（替代 `hermes cron`）
守护进程内部维护轻量分钟级调度循环，**全部直接使用 `Asia/Shanghai` 北京时间计算**，彻底消除 UTC 转换与 `config.yaml` 锚点风险（原 `DEV_GUIDE` §11.17）：

| 任务 key | 脚本与参数 | 触发规则（北京时间） | 默认启停 | 说明 |
|---|---|---|---|---|
| `plan_card_am` | `maa_plan_card.py am` | `session_schedule.am.time` 前 10 分钟（`am.enabled` 为真时） | 启用 | 早场上游更新 + 活动探测 + 自动定关 + 清理 + 森空岛体检（#56） |
| `daily_am` | `maa_daily.py am` | `session_schedule.am.time`（`am.enabled` 为真时） | 启用 | 早场日常 |
| `plan_card_pm` | `maa_plan_card.py pm` | `session_schedule.pm.time` 前 10 分钟（`pm.enabled` 为真时） | 启用 | 晚场活动探测 + 自动定关 |
| `daily_pm` | `maa_daily.py pm` | `session_schedule.pm.time`（`pm.enabled` 为真时） | 启用 | 晚场日常 |
| `depot` | `maa_depot.py` | 每日 04:30（`depot_enabled` 为真且脚本内满 7 天才开游戏） | **默认暂停**（`depot_enabled: false`） | 对齐线上自 11-06 起暂停状态，由用户通过开关决定何时恢复 |
| `activity_watch` | `maa_activity_watch.py` | 每 15 分钟（`:00/:15/:30/:45`） | 启用 | 活动作业监控与自动派发 |

- **调度与进程硬语义**：
  1. **同日 2 小时补跑窗口（严禁跨零点与挤占保护窗口）**：
     - 守护进程因休眠/重启错过某一次性日槽位时，**必须同时满足三条**才补跑：① 当前时刻距计划时刻 ≤ 2 小时；② **同一北京自然日**（`now.date() == scheduled.date()`，杜绝 23:00 晚场在次日 00:30 补跑读到次日计划）；③ 未进入下一场的保护窗口（`manual_run_blackout_minutes`）；
     - 若同场次的 `plan_card_*` 与 `daily_*` 均处于可补跑状态，**严格串行：先跑完 `plan_card_*`，再拉起 `daily_*`**；
     - 超过 2 小时、跨日或挤入下一场保护窗口的槽位记为 `missed` 不再补跑；`activity_watch` 周期任务只执行当前槽位，不补跑历史槽位。
  2. **超时语义区分日常与抄作业，超时走 `SIGINT` 优雅收尾**：
     - **1 小时（3600s）硬超时仅适用于日常场（`daily_am` / `daily_pm` / `now`）**，**绝不应用于抄作业 worker**（多关连打允许超过 1 小时，由抄作业自身的单关超时 `copilot_list_item_timeout` 与时间闸门控制）；
     - 触发日常超时时，调度器必须先向子进程发送 **`SIGINT`**（触发不变量 #64 的 `interrupt_once()` 优雅收尾：关游戏、还原台前调度 #62、写终态战报），仅在宽限期（如 90 秒）后进程仍未退出才升级终止。
  3. **重启不杀正在跑的场次（保不变量 #62）**：
     - 守护进程拉起的所有任务子进程必须设 `start_new_session=True`，脱离守护进程会话与进程组；
     - LaunchAgent plist 必须显式配置 `<key>AbandonProcessGroup</key><true/>`，确保重启 `wados-maa-daemon` 时 `launchd` 不会连带杀死正在运行的 MAA/PlayCover 进程；
     - **防重入以 `run.lock`（及 `activity_watch.lock`）为准**，不单靠守护进程内存态判断。
  4. **调度配置接口同步改造**：`maa_schedule.py` 重构为对接 `config.json` 的 `session_schedule` + `daemon.json` 的 `depot_enabled` + 守护进程热重载（不再调 `hermes cron` CLI），Mac GUI `RemoteStore.swift:161` 的 `ScheduleReport` 解码模型同步适配，不再强依赖 Hermes `jobs_path` 与 `cron` 字典。

### 3.4 `run_id` 全链路贯通、五类文件统一命名与抄作业进度/战报补齐
1. **开跑即生成 `run_id` 并写入锁/状态/进度**：
   - 日常与抄作业开跑时即生成精确到秒的唯一 `run_id`（例如 `2026-11-21-now-143205`、`2026-11-21-copilot-a1b2c3-151022`）；
   - `run_lock` 的锁文件新增 `run_id` 字段（与现有 `holder` / `detail` / `pid` / `since` 并列），并同步写入 `last_run.json` 与进度文件；
   - `run cancel --run-id <run_id>` 严格比对 `run.lock` 中的 `run_id` 一致才发送 `SIGINT`，不一致返回 `run_changed` 拒绝，防止弱网重试误杀下一场。
2. **五类场次文件一步统一为 `run_id` 命名**：
   - 直接将 `maa_daily.py:2642` 的 `run_stem` 改为 `run_id`，使 **快照（`.json`）、日志（`.log`）、截图（`.png`）、战报（`-report.json`）、进度（`.progress.json`）** 五类文件一次性全部以 `run_id` 唯一命名，彻底解决同日多次手动场互盖问题；
   - 历史读取接口兼容既有 `<日期>-<场次>` 命名的历史文件。
3. **补齐抄作业的 `progress.json` 与 `report.json`**：
   - `maa_copilot_worker.py` 在执行期间同步更新与日常同构的 `runs/<run_id>.progress.json`（当前关卡、当前第几关/总关数、当前阶段、已耗时、状态），结束后落盘结构化 `runs/<run_id>-report.json` 并写入 `index.jsonl`（含 `run_id`）。

### 3.5 通知出口插件化（Bark + `barkcrypt` 精确加密契约）
保留不变量 #63（**通知出口异常永不阻断游戏执行与状态落盘**），新增统一通知模块 `maa_notify.py`：
- **出口类型**：支持 `bark`（默认启用，指向官方 `https://api.day.app`，保留 `bark_base_url` 配置项以便日后零代码切自建）与 `none`。
- **`barkcrypt` Swift CryptoKit 加密契约（精确对齐 Bark `Algorithm.swift`）**：
  - 本机 `/usr/bin/openssl`（LibreSSL 3.3.6）与 Homebrew `openssl@3`（3.6.3）的 `enc` 均不支持 GCM，新增 `scripts/barkcrypt.swift`（调用 macOS `CryptoKit.AES.GCM`），与 `ocrbox.swift` / `winmove.swift` 同纳入 `deploy.py` 的 `COMPILED_HELPERS` 并由 `--check` 校验，保持 Python 零第三方依赖；
  - **Key 与 IV 编码**：AES-256-GCM 的 Key 为 32 位 ASCII 字符串的原始 32 字节 UTF-8（或 AES-128-GCM 为 16 位）；每次推送生成 12 位随机 ASCII 字符串，以其 12 字节 UTF-8 作为 GCM Nonce/IV，同时将该 12 位字符串作为请求体明文 `iv` 字段发出；
  - **输出格式（关键，禁用 `.combined`）**：Bark 服务端/App 要求 `ciphertext` 为 **`Base64(sealedBox.ciphertext + sealedBox.tag)`**（不含前导 nonce）；**严禁使用 `CryptoKit` 的 `sealedBox.combined`**（后者会把 12 字节 nonce 拼在最前导致 Bark 解密失败）；
  - 敏感入参（明文 JSON、Key、IV）全部通过 stdin JSON 传给 `barkcrypt`，不经命令行 argv 暴露；
  - **外层明文 vs 内层密文切分**：
    - **外层明文**：`device_key`、`ciphertext`、`iv`、以及 **`id`**（供 Bark 服务端执行同场次原地覆盖）；
    - **内层密文（端到端加密）**：`title`、`body`、`subtitle`、`level`、`group`（`wados-maa`）、`icon`（自定义图标 URL）、`url`（`wadosmaa://...` 深度链接）。
- **推送事件矩阵**：

| 事件 | 级别 (`level`) | 行为 (`id` / 跳转) | 推送内容要点 |
|---|---|---|---|
| 日常 / 抄作业开跑 | `passive`（静音不亮屏） | 明文 `id=run-<run_id>`，跳实时进度 | 场次 + 关卡（如「早场开跑 · TL-9」） |
| 日常 / 抄作业完成（成功） | `active` | 覆盖 `id=run-<run_id>`，跳战报详情 | 关卡、刷理智次数、剩余理智、核心掉落、主页校验结果 |
| 运行失败 / 掉线放弃 / 代理熔断 / 锁冲突 | `timeSensitive` | 覆盖 `id=run-<run_id>`，跳战报详情 | 失败归类原因 + 简明建议（Phase 0 实测同 `id` 覆盖 `passive` 时是否提醒） |
| 计划跳过（「你在玩」或手动跳过） | `passive` | 独立 `id`，跳今日页 | 场次 + 跳过原因 |
| 每日上游更新失败 / 森空岛每日体检异常（#56） | `timeSensitive` | 独立 `id`，跳首页/设置 | 异常摘要 + 需要人工处理的动作 |
| 新活动上线 / 自动抄作业排程完成 | `active` | 跳抄作业页 | 活动名 + 本轮关数/状态 |
| iOS 自动续签成功 | `passive` | `id=ios-resign`，跳设置 | 「已自动续签，有效期至 MM-DD」 |
| iOS 签名即将到期（第 6.5 天）/ Apple ID 过期 / TLS 证书到期提醒 | `timeSensitive` | `id=ios-resign` / `id=tls-cert` | 剩余时长或处理提示 |

### 3.6 macOS 图形会话、防火墙与权限要求
- 守护进程必须安装为**用户级 LaunchAgent**（`~/Library/LaunchAgents/io.github.ffkiyo7.wados-maa.daemon.plist`），配置：
  - `<key>AbandonProcessGroup</key><true/>`；
  - 显式 `EnvironmentVariables`：`WADOS_MAA_HOME`、`PATH`、`HTTP_PROXY`、`HTTPS_PROXY`、`http_proxy`、`https_proxy`。
- **实测本机运行环境（须在 Phase 0 实证）**：
  - 本机 macOS 应用防火墙已启用（`State = 1`），且 `/Users/wadorudi/.local/bin/python3` 实际指向 **uv 管理的 `cpython-3.12.13`（`adhoc` 签名，`Identifier=-`）**，并非 Homebrew Python；
  - Phase 0 须实测该 `adhoc` 签名 Python 在防火墙开启时监听 `0.0.0.0:18170` 的入站放行表现，以及升级后的 **辅助功能**（`winmove`）与 **屏幕录制**（`screencapture` 兜底）TCC 授权稳定性；
  - 若 `adhoc` 签名二进制在防火墙或 TCC 上不稳定，采用**固定本地签名（`Apple Development`）的极简 Swift launcher 二进制**作为 LaunchAgent 入口来承载防火墙放行与 TCC 权限，再 `exec`/拉起 Python。

### 3.7 既有不变量（`DEV_GUIDE.md §8`）处置对照表
遵循「编号固定、永不复用」原则，明确所有与 Discord 绑定的不变量在解耦后的状态，确保单测改造目标清晰、无歧义：

| 编号 | 原约束要点 | 解耦后处置 | 对应代码与单测策略 |
|---|---|---|---|
| **#7** | `buttons.json` 只 merge，计划卡只碰 `hermes:btn:maa:` | **退役（生产切线后）** | 独立模式不再写 `buttons.json`；保留旧测试至切线前，切线后归档/移除 Discord 按钮测试，编号不复用 |
| **#8** | Discord 下拉值经 `select_args` 查表，不直通 argv | **退役（改由 HTTP 结构化白名单替代）** | HTTP API 对 `stage` / 动作名做严格白名单校验；原 adapter 补丁测试随 Discord 退役 |
| **#14** | 抄作业按钮前缀 `hermes:btn:maa-copilot:` | **退役** | 抄作业搜索/排程取消改走 `run_id` / `request_id` 与 API，不再登记按钮 |
| **#14b** | 抄作业卡前缀与 `card.json` 顺序 | **退役** | 不再发 Discord 抄作业卡；保留 `PREVIEWS_DIR` 与 `SEARCHES_DIR` 隔离约束 |
| **#40** | 晚场不跟上游更新；计划卡恰好两行 Discord 控件 | **改写保留核心** | **保留**「晚场准备任务不跟随上游更新」及单测；**退役**「计划卡两行控件与登记表键」断言 |
| **#41** | 已排程卡只有取消/暂停按钮；只在 `scheduled`/`queued` 可取消 | **改写保留核心** | **保留**「只在 `scheduled` / `queued` 状态可取消」状态机约束；**退役**按钮键断言 |
| **#54** | 手动场仅由选关卡派发、不进 `plan.json`、受 blackout 限制 | **改写保留核心** | **保留**「手动关不进 `plan.json`、不带 drops/后备关、受 `manual_run_blackout_minutes` 限制（除非显式强开）」；**退役** `hermes:btn:maa-now:` 选关卡按钮链路 |
| **#55** | 森空岛阻塞、`prefight_error` 上限、`auto_pause.json`、固定按钮 id | **改写保留核心** | **保留**全部状态机、上限与 `copilot auto on/off` 语义；仅**退役**固定 Discord 按钮 id 断言 |
| **#56** | 森空岛每日体检挂在计划卡后、每天至多告警一次 | **完整保留** | 明确纳入无 Discord 计划卡的必跑收尾步骤，通知通道切换至 `maa_notify.py` |
| **#63 / #64 / #65 / #66 / #67** | 通知不阻断执行 / `run cancel` / 进度文件 / `index.jsonl` / 三段回执 | **扩展保留** | #63 扩展到 Bark；#64 补充 `run_id` 校验；#65/#66 扩展覆盖抄作业与 `run_id` 命名；#67 将 `ios` 与 `gui` 同等隐藏 `detail` |

### 3.8 开发分支隔离与生产切线规程（Phase 3 真机验收后执行：备份 / 迁移 / 停旧 / 回滚）
- **Phase 1–3 分支与 worktree 隔离（保证线上热修通道不阻塞）**：
  - 解耦开发全部放在独立分支（如 `feat/decouple-ios`）与独立 worktree（如 `~/Developer/wados-maa-decouple`）；
  - 将 `~/Developer/forks/maa-remote-devhome/scripts` 改软链至 `~/Developer/wados-maa-decouple/maa-remote/scripts`；
  - `dev`（`~/Developer/wados-maa`）与 `main`（`~/Developer/wados-maa-deploy`）保持纯净，Phase 1–3 期间照常承接线上 `~/.hermes` 的热修与 `deploy.py` 部署；有线上热修时定期合入 `feat/decouple-ios` 控制分叉；
  - **开发期防撞车规程**：在 `devhome` 调试不碰游戏的逻辑（API、调度模拟、Bark、SSE）可随时进行；凡需在 `devhome` 真机动游戏验证，必须**避开线上早晚场与每 15 分钟活动监控窗口**，并在开跑前核对 `~/.hermes/state/maa/run.lock` 处于空闲状态。
- **Phase 3 验收通过后的生产切线步骤（须确认无正在跑或 30 分钟内开跑的场次）**：
  0. **合并分支并同步部署 worktree**：将 `feat/decouple-ios` 合入 `dev`，再 `ff-only` 合并至 `main`（`~/Developer/wados-maa-deploy`），从 `main` 执行独立模式部署；切线稳定后把 `devhome/scripts` 软链改回 `~/Developer/wados-maa/maa-remote/scripts` 并清理临时 worktree。
  1. **全量前置备份**至 `~/.wados-maa/backups/cutover-<YYYYMMDDTHHMMSS>/`：
     - `~/.hermes/state/maa/`、`~/.hermes/state/agent-book/buttons.json`、`~/.hermes/cron/jobs.json`、`~/.hermes/scripts/maa_*.py`、`defaults read io.github.ffkiyo7.MaaRemoteGui RemoteHermesHome` 原值。
  2. **停用旧入口（单步防双锁）**：
     - 暂停 Hermes 中正在运行的 **5 条 MAA cron**（保留 **16 条非 MAA cron** 不动）；停用 Hermes 中的 MAA skill；
     - **持 `~/.hermes/state/agent-book/state.lock`** 原子读改写 `buttons.json`，**仅删除 18 条 MAA 按钮键**（保留 14 条非 MAA 业务键）；
     - 将 `~/.hermes/scripts/maa_*.py` 替换为立即拒绝执行的桩脚本（退出非零并提示已迁移至 `~/.wados-maa`）。
  3. **状态与绝对路径迁移**：
     - 复制 `~/.hermes/state/maa/` 到 `~/.wados-maa/state/maa/`；
     - 重写 `runs/index.jsonl` 与 `last_run.json` 中全部 `.hermes/state/maa/` 绝对路径为 `.wados-maa/state/maa/`；
     - 确认 `daemon.json` 中 `depot_enabled: false`。
  4. **切换 Mac GUI 并上线守护进程**：
     - 改写 `defaults write io.github.ffkiyo7.MaaRemoteGui RemoteHermesHome '~/.wados-maa'`（或删除该键回落新默认值），且 Mac GUI 代码层硬拒绝 `~/.hermes`；
     - 启动 `wados-maa-daemon` 与 `wados-maa-cloudflared` LaunchAgent；在 Mac GUI 与 iOS App 两侧各做一次只读快照与 Bark 测试推送验收。
- **一键回滚步骤（如切线后出现阻塞故障）**：
  1. `launchctl bootout` 停掉 `wados-maa-daemon` 与 `wados-maa-cloudflared`（确保无 `run.lock` 持锁）；
  2. 从 `backups/cutover-<ts>/` 还原 `~/.hermes/scripts/maa_*.py`、持 `agent-book/state.lock` 还原 `buttons.json`、恢复 5 条 MAA cron 与 `RemoteHermesHome='~/.hermes'`；
  3. 保留 `~/.wados-maa` 目录原样备查，绝不删除。

---

## 4. 网络、隧道与安全设计

### 4.1 独立 Cloudflare Tunnel
参照本机已验证的 `netease-mcp` 模式，单独建立专属隧道：
- 隧道名：`wados-maa`（独立 UUID 与 `~/.cloudflared/wados-maa.yml`）；
- 子域名：`maa.luxraykit.com`（独立子域，与 `netease-mcp` 及代理域名 `shizukumo.uk` 完全隔离）；
- 独立 LaunchAgent：`~/Library/LaunchAgents/io.github.ffkiyo7.wados-maa.cloudflared.plist`（开机自启、`KeepAlive=true`）；
- `ingress` 转发至本地守护进程 `https://127.0.0.1:18170`，配置 `originRequest.caPool` 指向 `~/.wados-maa/daemon/tls/cert.pem`（精确校验本地证书），兜底 `http_status:404`；
- 与 mihomo TUN / Stash 协同：两端既有规则对 Cloudflare 域名走代理；SSE 流由后端每 **25 秒**发送一行注释心跳（`: keepalive\n\n`），防止 Cloudflare 免费版 100 秒空闲断连。

### 4.2 双轨 HTTPS 连接策略、TLS 抗挂死与证书生命周期
1. **双轨强制 HTTPS**：
   - **局域网端点**：`https://192.168.50.2:18170`（主用；守护进程使用本地自签证书，SAN 含 `IP:192.168.50.2` 与 `IP:127.0.0.1`；iOS App 内通过 `URLSessionDelegate` 实施 **SPKI 公钥指纹固定（Pinning）**，并配置 `NSLocalNetworkUsageDescription`；Phase 0 在真机 App 上实证不带 `NSAllowsLocalNetworking` 时是否完全畅通）；
   - **远程隧道端点**：`https://maa.luxraykit.com`（自动回退，走系统标准 CA 校验）。
2. **切轨与防窃取规则**：
   - App 启动、回前台或网络切换时，优先对局域网端点发 `GET /healthz`（超时 `800ms`）；
   - **证书固定先于任何 Token 发送**：即使在外连到同名 `192.168.50.x` 陌生 Wi-Fi，伪造 `.2` 因通不过 SPKI 指纹校验在 TLS 握手阶段直接被拒，Bearer Token 绝不泄露；
   - 探测与指纹校验均通过 → 锁定局域网直连（解锁「立即无线续签」按钮）；否则自动切远程隧道。
3. **防止慢速/异常 TLS 握手挂死整个 API**：
   - 守护进程的 `ssl.SSLContext.wrap_socket()` **必须设置 `do_handshake_on_connect=False`**；
   - 在 `ThreadingHTTPServer` 派生出的**连接工作线程**内设置短超时（如 `5s`）再调用 `do_handshake()`，失败直接关闭连接，绝不在主 `accept()` 线程中执行 TLS 握手。
4. **首次配对与证书到期轮换**：
   - **首次配对**：守护进程初始化脚本生成长期本地证书（有效期 **5 年**，支持一键平滑续发）、计算 SPKI SHA-256 指纹，并生成 `full` 与 `resign_only` 两个随机高熵 Token；在 Mac 本地终端/GUI 展示一次性配对二维码（包含局域网地址、远程域名、SPKI 指纹、`full` Token，扫码即完成 iOS App 配置，手动也可复制粘贴）；
   - **到期轮换（避免 `caPool` 过期导致远程入口全断）**：
     - 守护进程每日巡检 `cert.pem` 剩余有效期，**到期前 60 天**起发出 `timeSensitive` Bark 提醒；
     - iOS App 证书固定支持配置「主指纹 + 备用指纹」双槽位；轮换时先在 App 写入新指纹，再在 Mac 替换 `cert.pem` 并重载 `wados-maa-daemon` 与 `wados-maa-cloudflared`，实现零中断切换。

### 4.3 安全与鉴权边界
1. **分域 Bearer Token**：
   - **全权限 Token（`full`）**：供 iOS App（存系统 Keychain）与 `/rescue` 使用，可访问全部 `/api/v1/*` 接口；
   - **独立续签 Token（`resign_only`）**：专供 iOS 快捷指令使用，**仅允许调用 `POST /api/v1/ios/resign?if_due=1`**，访问任何其他接口一律返回 `403`；
   - 除 `GET /healthz` 外，**所有接口（局域网与远程隧道）均必须校验 `Authorization: Bearer <token>`**。服务端仅落盘 SHA-256 哈希（`secrets.json`，权限 `0600`）。
2. **可选边缘防线**：支持在 Cloudflare 侧额外配置 Access Service Token（`CF-Access-Client-Id` / `CF-Access-Client-Secret`），iOS App 预留这两个可选 Header 配置项。
3. **局域网来源收口**：守护进程监听 `0.0.0.0:18170`（TLS），仅放行来源 IP 为 `127.0.0.1` 或 `192.168.50.0/24` 的连接。
4. **命令白名单**：写接口只接受明确映射的动作名和结构化参数，由后端组装受控 argv 交给 `maa_action.py`，**绝不开放透传任意命令或 shell**。
5. **极简应急 Web 页（`/rescue`）**：守护进程内置零依赖单页 HTML，需输入 `full` Bearer Token 后使用，仅提供 3 个救命功能：① 查看当前运行状态、② 带 `run_id` 的紧急停止、③ 触发 Mac mini 无线续签 iOS App。

---

## 5. HTTP / SSE API 契约

API 完整复用 [DEV_GUIDE.md §12](../maa-remote/docs/DEV_GUIDE.md#L732-L864) 的回执语义（`{ok, code, message, detail?, data?}`）与文件数据结构，减少两端模型漂移。

### 5.1 读接口与实时流

| 方法与路径 | 用途 | 返回摘要 |
|---|---|---|
| `GET /healthz` | 探活与双轨选择（免鉴权，不含任何账号/游戏信息） | `{ok: true, service: "wados-maa", api_version: 1, server_time: "<ISO8601>"}` |
| `GET /api/v1/snapshot` | **首屏聚合快照**（1 次 RTT 拿齐首页全部状态） | `{lock, last_run, progress, today_plan, schedule, upstream, copilot_auto_paused, activity, scheduler, resign}` |
| `GET /api/v1/events` | **SSE 实时推送流**（带 25s 心跳） | 推送事件：`progress`（日常与抄作业均覆盖，变化时推送）、`lock`、`last_run`、`today_plan`、`schedule`、`upstream`、`resign` |
| `GET /api/v1/choices` | 手动日常关卡选项、开关、冲突与当期活动 | 同 `maa_action run choices` 的 `data` |
| `GET /api/v1/copilot/stages` | 抄作业关卡列表与通关状态 | 同 `maa_action copilot stages` 的 `data` |
| `GET /api/v1/config` | 可调配置白名单、当前值与修改元信息 | 同 `maa_action config get` 的 `data` |
| `GET /api/v1/defaults` | 持久默认关与默认环节 | 同 `maa_action defaults show` 的 `data` |
| `GET /api/v1/history?limit=50&offset=0` | 场次历史索引（读 `runs/index.jsonl` 倒序分页） | `{items: [...], total, has_more}` |
| `GET /api/v1/runs/<id>/report` | 指定场次的战报原文（按 `run_id` 定位，兼容旧命名；日常与抄作业统一支持） | 战报结构化 JSON |
| `GET /api/v1/runs/<id>/screenshot` | 主页校验截图（支持 `?thumb=1` 压缩预览与原图） | `image/png` 或 `image/jpeg` |
| `GET /api/v1/runs/<id>/log?tail=200` | 日志尾部片段（按 `run_id` 定位，只返回最后 N 行） | `{lines: [...], truncated: bool}` |

### 5.2 写接口与动作派发

所有写接口均走受控动作（默认注入 `MAA_ACTION_SOURCE=ios`），统一返回 `{ok, code, message, detail?, data?}`：

| 方法与路径 | 对应后端动作 | 说明 |
|---|---|---|
| `POST /api/v1/plan/stage` | `plan set-stage` / `plan auto-stage` | 修改某场关卡，或切回自动定关 |
| `POST /api/v1/plan/skip` | `plan skip-today on\|off` | 跳过或恢复今天某一场 |
| `POST /api/v1/plan/fight` | `plan fight on\|off` | 开关今天某一场的「刷理智」 |
| `POST /api/v1/run/local` | `run local <stage> <switches> [--force]` | 手动开一场日常（受锁与 blackout 保护，`session_soon` 码可二次确认强开；来源记为 `ios`） |
| `POST /api/v1/run/cancel` | `run cancel --run-id <run_id>` | **必须携带目标 `run_id`**；服务端比对当前 `run.lock.run_id` 一致才发 `SIGINT`，不一致返回 `run_changed` 拒绝 |
| `POST /api/v1/copilot/preview` | `copilot preview <stage>` | 请求体**由 App 携带客户端生成的 `request_id`（UUID）**；长请求（超时 60s），搜索完成返回 `token` 与候选列表 |
| `DELETE /api/v1/copilot/preview/<request_id>` | 取消/清理指定预览 | 按客户端 `request_id` 取消**进行中的搜索子进程**，或清理已生成的预览临时文件 |
| `POST /api/v1/copilot/go` | `copilot go <token> [id]` | 派发完美候选开打（不依赖 Discord） |
| `POST /api/v1/copilot/auto` | `copilot auto on\|off` | 暂停或恢复活动自动抄作业 |
| `POST /api/v1/copilot/mark` | `copilot mark-cleared` / `unmark` | 标记「我打过了」或撤销本地通关记录 |
| `POST /api/v1/schedule` | `schedule set / enable / disable` + `depot_enabled` | 调整早晚场时间与开关、以及 `depot` 开关，立即热重载内置调度器 |
| `POST /api/v1/defaults` | `defaults set stage / task` | 修改持久默认关卡与默认环节开关 |
| `POST /api/v1/config` | `config set` / `config patch` | 按 `maa_settings.FIELDS` 白名单逐项校验写入（标记 `source="ios"`） |
| `POST /api/v1/upstream/update` | `upstream update` | 触发 maa-cli / MaaCore / MaaResource 更新 |
| `POST /api/v1/notify/test` | `maa_notify` 测试 | 发送一条 AES-GCM 加密 Bark 测试推送并返回回执 |
| `POST /api/v1/ios/resign` | 内置无线续签器 | 触发 Mac mini 从 `main` worktree 重签并无线安装到 iPhone（支持 `?if_due=1`；同时接受 `full` 与 `resign_only` 两种 Token） |

---

## 6. iOS 原生 App 产品架构：功能层级、优先级与能力边界

> 本节聚焦**信息架构、优先级分层与能力边界**，不约束具体视觉样式。

### 6.1 移动端定位与核心原则
- **核心场景**：出门在外或不在电脑前时，**3 秒看清 Mac mini 在干什么、1 步触发或叫停任务、随时微调今天两场的计划与日常规则、活动期一键抄作业、收到 Bark 推送后点进来核对战报与主页截图**。
- **与 Mac GUI 概念同构，但按手机动线收敛**：保留与 Mac 端一致的 4 个一级页面概念（`今天` / `抄作业` / `日常` / `设置`），避免两套心智模型；低频复杂表单和桌面运维项向后收纳或留在 Mac 端。
- **高危动作二次确认**：所有会动游戏或打断运行的操作（手动开一场、强行无视定时场优先开跑、抄作业确认开打、紧急停止）均需系统级确认框，且默认不误触。

### 6.2 功能优先级分层

| 优先级 | 定义 | 包含功能 | 在 App 中的落位要求 |
|---|---|---|---|
| **P0（最高）** | 每天必看 / 应急必用 | ① 实时运行态（日常 7 步进度 & 抄作业关数/阶段进度、刷理智把数、当前理智、掉落、ETA、**一键停止（带 `run_id`）**）<br>② 今日早/晚场计划速控（换关、切回自动定关、跳过/恢复、开关刷理智）<br>③ 手动开一场（选关、临时勾环节、感知锁与定时场冲突）<br>④ 最近战报摘要与主页校验截图查看<br>⑤ 游戏资源异常/需更新提醒与一键更新 | **全部落位在首页「今天」首屏与次屏**；运行中时「实时运行态」置顶最高显眼位，且在任意 Tab 可见或一键跳回 |
| **P1（高）** | 每周 / 每期活动高频使用 | ① 自动抄作业全流程（未通列表、带 `request_id` 搜候选与随时取消预览、选完美作业开打、总控开关、标记我打过了/撤销）<br>② 完整历史战报列表（筛选、查看任意日常/抄作业场次战报、截图、尾部日志）<br>③ 日常核心规则与时间表（早晚场时间与开关、默认关与默认环节、吃药天数、公招、剿灭预留、商店买卖、领奖、保护窗口） | 独立一级 Tab（「抄作业」「日常」）及首页直达二级页（「全部记录」） |
| **P2（中/低）** | 偶尔调整 / 连接与维护 | ① 双轨 HTTPS 连接管理（首次扫码配对、局域网地址 + 主/备证书指纹、远程域名、Token、链路状态、连通性测试）<br>② iOS 无线续签状态与手动一键触发<br>③ 抄作业规则阈值（4 项）<br>④ 高级配置（默认折叠：自动定关算法参数与手工表、代理指挥熔断、运行超时与重试、森空岛刷新天数）<br>⑤ 内置调度器状态查看（6 条任务下次触发时间，含 `depot` 独立启停开关）与 Bark 测试推送 | 收纳在「设置」Tab 或各自页面的右上角二级入口，不抢占主视线 |
| **边界外（明确不做）** | 违背不变量或仅属 Mac 运维 | ① 任何降级开关（碎石、吃非临期药、借助战、忽略练度）<br>② 森空岛 `link` 绑定 token（仅限 Mac 终端 stdin，不变量 #16）<br>③ 底层路径与设备参数（PlayCover 路径、MaaTools 地址、突袭开关、`cli.toml`）<br>④ Mac 桌面外观设置（背景图、Liquid Glass）与本地日志目录打开<br>⑤ 肉鸽 / 生息演算 / 手贴作业（后端尚未接入） | **不提供入口**；涉及需 Mac 处理的异常（如森空岛过期）只展示清晰指引文案 |

### 6.3 4 Tab 一级页面与功能层级树

```text
Wado's MAA (iOS)
├── 全局层
│   ├── 顶部/悬浮实时状态胶囊（任一 Tab 下当有任务运行中时可见，点开直达「实时进度详情 Sheet」）
│   ├── 连接状态异常横幅（离线 / Token 失效 / 证书不匹配 / 隧道不通时浮现）
│   └── Deep Link 路由（wadosmaa://run/latest、run/<id>、today、copilot、resign）
│
├── Tab 1：今天（首页 · 最高频控制台）
│   ├── [P0] 实时运行卡片（仅运行中置顶展开：日常/抄作业实时步骤、把数/关数/掉落、ETA、恢复备注、「停止」按钮）
│   ├── [P0] 游戏资源提示条（仅当 upstream verdict 为 blocked / stale / running 时浮现，支持「现在更新」）
│   ├── [P0] 今日场次区（早场 + 晚场两张卡）
│   │   ├── 显示：时间、状态（待跑/已跑/已跳过/已关）、当前关与来源（自动定关含 drops 上限 / 手动 / 默认）
│   │   └── 快捷操作：换关、切回「自动定关」、跳过/恢复本场、刷理智开关（已开跑的场次自动锁定只读）
│   ├── [P0] 手动开一场区（折叠/紧凑入口，或直接展开）
│   │   ├── 活动期自动前置当期活动关，其余走标准关卡列表
│   │   ├── 临时环节开关（刷理智 / 剿灭 / 基建 / 公招 / 商店 / 领奖，仅对本次生效）
│   │   └── 开始按钮（感知 run.lock 忙碌禁止；感知定时场前 30 分钟内弹出强开确认）
│   └── [P0/P1] 最近场次区（显示最近 3～5 条 +「查看全部」→ 二级页「历史记录」）
│       └── 点击任意场次 → 二级页「场次详情」（战报摘要、主页校验截图可双指缩放、恢复备注、日志尾部 200 行）
│
├── Tab 2：抄作业（带未通活动关数字角标）
│   ├── 顶部状态栏：当期活动名 +「自动抄作业」总开关（copilot auto on/off）+ 右上角「规则」入口
│   ├── [P1] 关卡列表（未通排前，已通沉底；区分 ✅已通 / 🔁突袭待补 / ⏳排程中 / 🚫练度不足 / ⛔无导航）
│   └── 点击关卡 → 二级页「关卡作业预览与开打」
│       ├── 自动携带 request_id 触发 copilot preview（可随时取消，调用 DELETE /api/v1/copilot/preview/<request_id>）
│       ├── 候选作业列表（自动选中最优完美作业；练度不足项标红并列明缺哪个干员/精二/专精/模组，不可选）
│       ├── 主按钮：「确认开打」（二次确认后派发 copilot go，跳回实时进度）
│       └── 辅助操作：「我打过了」（mark-cleared）/「撤销通关记录」（unmark）
│
├── Tab 3：日常（长期规则与时间表）
│   ├── [P1] 早晚场时间表（早场 05:00–11:59、晚场 12:00–23:59、到点自动开始开关、早晚场前不接手动日常窗口）
│   ├── [P1] 默认执行项（默认关卡 + 5 个默认环节开关：刷理智/基建/公招/信用商店/领奖）
│   ├── [P1] 刷理智与剿灭（临期药天数 0–7、匿名上报掉落开关、剿灭预留理智）
│   ├── [P1] 公招与领奖（公招次数 0–4、幸运墙/采矿/月卡奖励开关）
│   └── [P1] 信用商店（优先买列表、不买列表、低于 300 停买开关、只买打折开关）
│       └── 所有改动即时生效（或带撤销提示），顶部展示最近修改来源（iOS / Mac）与时间
│
└── Tab 4：设置（连接、续签、高级配置与主机状态）
    ├── [P2] Mac mini 连接
    │   ├── 当前链路状态（局域网 HTTPS 直连 / Cloudflare 远程 / 离线 + 实测 RTT）
    │   ├── 扫码首次配对、局域网地址 + 主/备固定证书指纹、远程域名、Bearer Token（可选 CF Access Header）
    │   └── 手动测试双轨连接
    ├── [P2] iOS 签名与无线续签
    │   ├── 上次签名时间、Profile 到期倒计时、上次自动续签结果
    │   └── 「立即无线续签」按钮（局域网直连时可用）
    ├── [P2] 通知与主机状态
    │   ├── Bark 加密推送状态与「发一条测试推送」按钮（POST /api/v1/notify/test）
    │   ├── 内置调度器 6 条任务的下次运行时间与上次状态（含 `depot` 仓库对表独立启停开关，默认关闭）
    │   └── 游戏资源版本概览（maa-cli / MaaCore / MaaResource 与手动触发更新）
    └── [P2] 高级设置（默认收起，点击进入二级页防误触）
        ├── 代理指挥熔断（连续失败次数、停下后其余任务照做）
        ├── 自动定关算法（三项权重、掉率最低样本、缺口天数、活动倍率、复刻间隔、视野天数、指定材料关卡表、材料手动权重表）
        ├── 森空岛（练度强制刷新天数）
        ├── 运行参数（超时与重试次数、本地日志保留天数）
        └── Mac 主机窗口行为（只读或带提醒折叠：`game_display_name`、`disable_stage_manager_during_run`）
```

### 6.4 配置调节能力边界全量对照表（对应 `maa_settings.FIELDS`）

所有可写配置严格受后端 [maa_settings.py](file:///Users/wadorudi/Developer/wados-maa/maa-remote/scripts/maa_settings.py) 白名单与校验规则守护，iOS 端分层暴露：

| 分组 | 配置项（key） | iOS 暴露层级 | 备注 |
|---|---|---|---|
| **早晚场** | `session_schedule`（时间 + 开关） | **P1 · 日常 Tab 顶层** | 走 `/api/v1/schedule`，即时更新内置调度器 |
| **仓库对表开关** | `depot_enabled`（位于 `daemon.json`，默认 `false`） | **P2 · 设置 → 调度器** | 迁移后保持暂停，由用户显式开启 |
| **持久默认** | `defaults.stage`、`defaults.tasks.*` | **P1 · 日常 Tab 顶层** | 走 `/api/v1/defaults` |
| **日常核心** | `manual_run_blackout_minutes`、`medicine_expire_days`、`recruit_times`、`report_drops`、`annihilation_sanity`、`award_orundum`、`award_mining`、`award_specialaccess`、`mall_buy_first`、`mall_blacklist`、`mall_reserve_max_credit`、`mall_only_buy_discount` | **P1 · 日常 Tab** | 常用项，手机高频调节 |
| **抄作业规则** | `copilot/auto_pause`（总开关）、`copilot_blackout_minutes`、`auto_copilot_min_lead_minutes`、`activity_search_retry_minutes`、`auto_copilot_max_attempts_per_day` | **P1/P2 · 抄作业 Tab 规则页** | 总开关在抄作业顶栏；4 个阈值在右上角规则 Sheet |
| **代理指挥** | `proxy_failure_limit`、`proxy_failure_salvage` | **P2 · 设置 → 高级** | 避免日常页过长 |
| **自动定关** | `farming_weights`、`farming_min_samples`、`farming_target_days`、`farming_activity_edge`、`farming_rerun_days`、`farming_scarcity_horizon_days`、`farming_stage_table`、`farming_manual_weights` | **P2 · 设置 → 高级** | 低频算法调参；键值表用移动端列表行增删编辑 |
| **森空岛** | `skland_roster_refresh_days` | **P2 · 设置 → 高级** | 仅调刷新间隔；**不提供 token 录入** |
| **运行超时/重试** | `game_launch_timeout`、`game_quit_timeout`、`game_probe_timeout`、`maa_run_timeout`、`update_wait_minutes`、`connect_retry_limit`、`offline_retry_limit`、`retention_days`、`resource_update_timeout`、`maa_cli_update_timeout` | **P2 · 设置 → 高级** | 低频稳定性参数 |
| **Mac 桌面行为** | `game_display_name`、`disable_stage_manager_during_run` | **P2 · 高级（带主机提示）** | 影响 Mac 桌面窗口，默认不推荐手机频繁修改 |
| **系统底层（白名单外）** | `playcover_app_path`、`game_bundle_id`、`maatools_address`、`copilot_raid_switch_task`、`upstream_proxy`、森空岛凭据等 | **不可改（后端硬拒绝）** | 仅限 Mac 本地维护 |
| **降级开关（永久禁止）** | 碎石、吃非临期药、借助战、忽略练度 | **永久禁止** | 前后端双重封死（不变量 #1/#2/#15） |

### 6.5 iOS 27 平台与 UI 设计参考（待 UI 细化阶段遵循）
- **目标系统与工具链**：面向 **iOS 27** 真机设计，Mac mini 侧升级至 **Xcode 27**（匹配 iOS 27 SDK 与真机无线调试安装）。Deployment Target 设为 `iOS 27.0`（或按需向下兼容 `iOS 26.0`），与现有 Mac GUI（macOS 26+）保持同一代 SwiftUI 原生设计语言。
- **权威设计参考**：严格遵循 Apple 官方 [Human Interface Guidelines — Designing for iOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-ios)，重点落实：
  1. **原生导航与悬浮层范式**：优先使用 iOS 26/27 原生 SwiftUI 组件（Liquid Glass 浮层 Tab Bar / Toolbar、系统原生 `NavigationStack`、`Sheet`、`confirmationDialog`），不做违背平台手势习惯的自绘控件；
  2. **信息自解释、去冗余文案**（呼应仓库 `AGENTS.md` 原则）：避免堆砌解释性辅助标签与大段说明文字，靠层级、间距、状态语义和原生地点布局自然传递信息；
  3. **移动端人体工学**：高频操作（手动开跑、换关、停止、确认开打）满足 ≥44pt 触控热区，优先下沉至单手拇指易达区，危险/不可逆操作隔离并走系统确认框；
  4. **状态连续性与微反馈**：结合动态字体（Dynamic Type）、深/浅色系统适配、触觉反馈（Haptics）与清晰骨架/加载态，确保弱网或跨轨切换时界面不卡死、不闪烁。

---

## 7. iOS 无线自动续签机制（免费账号专项）

为消除免费个人 Apple ID 每 7 天签名过期的日常负担，由 Mac mini 守护进程承担自动续签（**前提：Phase 0 实证到期前重建确实延展 `embedded.mobileprovision` 的 `ExpirationDate`**）：

### 7.1 双触发源
1. **Mac mini 后台自动探测（主力）**：
   - 记录上次签名成功时间与实际解析出的 `ExpirationDate` 于 `daemon/resign.json`；
   - 满 **5 天**（120 小时，或距 `ExpirationDate` 不足 48 小时）进入 `due` 待续签窗口；
   - 窗口期内每 25 分钟检查一次：
     1. 局域网 `192.168.50.201` 可达；
     2. `xcrun devicectl list devices --json-output -` 确认已配对的 iPhone 在线；
     3. 当前 `run.lock` 空闲（错开游戏运行高峰，降低 CPU/网络干扰）；
     4. 最近 2 分钟无来自 iOS App 的活跃 API 请求（避免正在操作 App 时被覆盖安装顶退）。
2. **iOS 快捷指令个人自动化（可选加速）**：
   - 触发条件：连接到家里 Wi-Fi（`Alice3u3` / `Aliceuwu`）时立即自动运行（无需确认）；
   - 动作：静默请求 `POST https://maa.luxraykit.com/api/v1/ios/resign?if_due=1`，Header 携带 `Authorization: Bearer <resign_only_token>`（走公网正规 TLS 避免快捷指令拒绝自签证书，且独立 Token 仅限续签权限；未满 5 天直接返回 `not_due`）。

### 7.2 执行与兜底流程
1. 守护进程持独立 `resign.lock` 锁，防止并发构建；
2. **固定从 `main` 部署 worktree 构建**：构建目录锁死在 `~/Developer/wados-maa-deploy/ios`（固定签出 `main` 分支），**绝不使用开发工作区 `~/Developer/wados-maa`（`dev` 分支）或独立开发 worktree**，避免将未完成代码自动装到手机；
3. 在独立 derivedData 目录执行增量 `xcodebuild -project ~/Developer/wados-maa-deploy/ios/WadosMAAiOS.xcodeproj -scheme WadosMAAiOS -destination id=<UDID> -allowProvisioningUpdates build`，完成后解析 `.app/embedded.mobileprovision` 核验 `ExpirationDate` 确实后移；
4. 执行 `xcrun devicectl device install app --device <UDID> <App包路径>` 无线覆盖安装到 iPhone；
5. **结果处理**：
   - 成功：更新 `resign.json`（含新的 `ExpirationDate`），发一条静默 Bark 通知（`passive`）「iOS App 已自动续签至 MM-DD」；
   - 暂时失败（如手机锁屏休眠导致无线安装超时）：记日志但不打扰，下个探测周期继续自动重试；
   - **第 6.5 天仍未成功**，或识别到 Xcode Apple ID 登录态失效、或 `ExpirationDate` 未后移：发 `timeSensitive` Bark 告警，提示回家后通过 App 内按钮 / 快捷指令 / Safari `/rescue` 页面一键触发，或在 Mac 上重登 Xcode 账号。

---

## 8. 工程结构与跨端复用规划

### 8.1 后端（`maa-remote/`）
保持纯 Python stdlib 零第三方依赖（兼容现有 `unittest`、`ruff`、`pyright`），加密能力复用现有 Swift 编译小工具机制：
- `scripts/maa_daemon.py`：常驻守护进程入口（同日 2h 补跑调度器 + 线程内带超时 TLS 握手的 `ThreadingHTTPServer` + SSE 广播 + `request_id` 预览取消表 + `start_new_session` 子进程管理 + 日常超时 `SIGINT` 优雅中断）；
- `scripts/maa_notify.py`：可插拔通知出口（Bark 官方 + 调用 `barkcrypt` 加密 + 同场次明文 `id` 更新 + 失败永不抛）；
- `scripts/barkcrypt.swift`：Swift `CryptoKit.AES.GCM` 小工具（显式输出 `Base64(ciphertext + tag)`，禁用 `.combined`；Key/IV 按 UTF-8 原始字节读取），纳入 `COMPILED_HELPERS` 由 `deploy.py` 编译部署与 `--check`；
- `scripts/maa_ios_resign.py`：无线续签状态机、`main` worktree 构建、`embedded.mobileprovision` 到期日核验与 `devicectl` 封装；
- `scripts/maa_schedule.py`：重构为对接内置调度器（读写 `config.json` `session_schedule` 与 `daemon.json` `depot_enabled` + 触发热重载），移除 `hermes cron` 硬依赖；
- `scripts/maa_plan_card.py`、`scripts/maa_action.py`（含 `publish_round()` 与全部 6 处 `is_app_source()`）、`scripts/maa_activity_watch.py`、`scripts/maa_daily.py`（L2634 来源 + L2642 五类文件统一 `run_id`）、`scripts/maa_upstream.py`（L177 `is_live_home()`）、`scripts/maa_copilot_worker.py`（补齐 `progress.json` / `report.json` 与 `run_id`）、`scripts/maa_skland.py`（动态重绑路径）、`scripts/maa_common.py`（`WADOS_MAA_HOME`、`ACTION_SOURCES` 加入 `ios`、`run_lock` 写入 `run_id`）；
- `daemon/` 模板：`launchd` plist 模板（含 `AbandonProcessGroup=true` 与代理环境变量）、`cloudflared` 配置模板（含 `caPool`）、应急页 `rescue.html`、证书初始化/轮换与配对二维码脚本、以及 Phase 3 切线专用迁移/置桩/回滚脚本。

### 8.2 客户端与跨端结构（`gui/` + `ios/` + `shared/`）
iOS 工程不塞入源自上游 MaaMacGui 的 `gui/MeoAsstMac.xcodeproj`（AGPL-3.0 边界与 macOS 历史配置），而是在**同仓顶层独立建工程**，兼顾同 commit 改接口、统一 `main` 续签与许可证/构建隔离：
```text
wados-maa/
├── maa-remote/   # Python 后端与守护进程（MIT）
├── gui/          # 现有 Mac GUI（MeoAsstMac.xcodeproj，AGPL-3.0）
├── ios/          # 独立 iOS 工程（WadosMAAiOS.xcodeproj，100% 原创 iOS 27 SwiftUI，MIT）
└── shared/       # 本地 Swift Package（WadosMAAShared，纯 Foundation，MIT；gui/ 与 ios/ 共同引用）
```
- **Mac GUI 适配（`gui/`，在 devhome 验通，Phase 3 切线时切换线上默认）**：
  - 改造 `RemoteStore.swift:161`（`ScheduleReport`）适配内置调度器返回结构（不再强校验 Hermes `jobs_path` 与 `cron` 字典）；
  - `ChangeMeta.text` 兼容 `source == "ios"`；
  - 新增防回落保护：当 `RemoteHermesHome` 或默认解析结果为已停用的 `~/.hermes` 时拒绝执行并提示切往 `~/.wados-maa`；生产切线脚本同步改写 `defaults` 中的 `RemoteHermesHome`。
- **本地共享包 `shared/` + 独立工程 `ios/WadosMAAiOS.xcodeproj`（Phase 3）**：
  - 将纯数据模型与解析逻辑抽入本地 Swift Package `shared/`（`RemoteReceipt` 从依赖 AppKit 的 `RemoteBridge.swift` 拆出；`RunHistory`、`RunProgress` 剥离本地磁盘 I/O，保留纯模型与解析；连同 `RunModels`、`RunStageParser` 一起迁入 `shared/`），编译期物理隔离 AppKit；
  - `gui/` 保留本地文件读取适配器与 `LocalProcessTransport`，引用 `shared/`；
  - `ios/WadosMAAiOS.xcodeproj` 面向 **iOS 27**（Xcode 27 构建），仅引用 `shared/` 并实现 `HTTPTransport`（双轨 HTTPS + 主/备 SPKI 指纹固定 + Keychain Token + SSE 客户端）与新建 iOS SwiftUI 页面。

---

## 9. 分阶段实施路线图与验收标准

| 阶段 | 核心内容 | 验收标准 | 风险/备注 |
|---|---|---|---|
| **Phase 0：前置真机与环境验证**（不动线上） | ① 升级 Mac mini 至 Xcode 27，在 **LaunchAgent 环境**实测 `xcodebuild -allowProvisioningUpdates` + `xcrun devicectl` 无线装测试包到 iOS 27 iPhone（亮屏 + 锁屏），并**解析 `embedded.mobileprovision` 确认到期前重建确实延展 `ExpirationDate`**；<br>② 实测独立 `cloudflared` 隧道（`maa.luxraykit.com`）与局域网自签 TLS 在 5G + Stash、Wi-Fi + Stash 下的连通性、延迟与 SSE 25s 心跳保活；<br>③ 用**真机最小 iOS 27 测试 App** 实测 SPKI Pinning 直连 `https://192.168.50.2:18170`（确认不配 `NSAllowsLocalNetworking` 时 ATS 与局域网访问是否畅通）；<br>④ 实测开启 macOS 防火墙下 **uv ad-hoc 签名 Python** 监听 `18170` 的入站放行与升级后 TCC（辅助功能/屏幕录制）授权稳定性（决定是否包固定签名 Swift launcher）；<br>⑤ 实测 `barkcrypt`（`ciphertext + tag`）解密成功，以及 Bark 同 `id` 下 `timeSensitive` 覆盖 `passive` 时是否仍正常提醒 | ① LaunchAgent 下无弹窗无线覆盖安装成功，且 `ExpirationDate` 实证后移；<br>② 真机测试 App 在 Stash 开启时可凭 SPKI Pinning 直连局域网，5G 下 SSE 稳定 ≥5 分钟不断连；<br>③ 防火墙放行与 TCC 稳定方案定型；<br>④ Bark AES-GCM 密文真机解密正常，同 `id` 升权覆盖确认提醒表现 | 任一前置假设不成立（尤其是 `ExpirationDate` 或 ATS 行为）须先调整方案再进编码 |
| **Phase 1：后端解耦与调度器（独立分支 + `devhome`）** | 新建独立分支 `feat/decouple-ios` 与独立 worktree（`~/Developer/wados-maa-decouple`），将 `devhome/scripts` 软链切过去（`dev`/`main` 继续保留给线上热修）；落地 `WADOS_MAA_HOME`、修正 `maa_upstream.py:177` 与 `maa_skland.py` 路径、解除 `maa_plan_card`（含 #56 体检）/`publish_round`/`activity_watch` 对 Discord 的硬依赖、全量接入 `ios` 来源（6 处 `maa_action` + `maa_daily:2634`）、`run_id` 写入锁/状态/五类文件与抄作业 `progress`/`report`、`barkcrypt.swift` + `maa_notify.py`、内置调度器（同日 2h 补跑、`depot_enabled: false`、日常 1h `SIGINT` 超时、抄作业不限 1h、`start_new_session`、`AbandonProcessGroup=true`、以 `run.lock` 防重入）；按 §3.7 更新不变量与单测；同步改造 Mac GUI `ScheduleReport` 与 `ChangeMeta`（指向 `devhome` 联调） | ① `unittest` / `ruff` / `pyright` 全绿；<br>② `devhome` 守护进程跑通日常与抄作业（避开线上早晚场且核对线上锁空闲）并收到 AES-GCM 加密 Bark 推送；<br>③ 重启守护进程时正在跑的场次不被杀死且不重复派发；<br>④ `dev`/`main` 与线上 `~/.hermes`、Discord 全程零改动、热修通道畅通 | 不切生产，手机端继续使用现有 Discord 卡片 |
| **Phase 2：HTTPS/SSE API + 独立隧道 + 应急页（`devhome`）** | 实现 §5 全部 REST/SSE 端点（TLS `do_handshake_on_connect=False` + 线程内 5s 握手超时）、`full` + `resign_only` 分域 Token、带 `run_id` 的 `cancel`、`request_id` 取消进行中预览、`notify/test`、首次配对二维码与双指纹轮换机制、独立 `cloudflared` LaunchAgent（`maa.luxraykit.com` + `caPool`）、`/rescue` 应急页 | 手机在家里 Wi-Fi 与外网 5G 下均能拉 `devhome` 快照、看 SSE、发起并取消预览、发起并带 `run_id` 取消手动场、发送 Bark 测试推送；慢速半开 TLS 连接不阻塞其他请求；`resign_only` Token 访问非续签端点返回 403 | 此时已具备完整安全远程控制能力，线上仍不动 |
| **Phase 3：iOS 27 原生 App（P0 + P1）+ 合并与生产切线** | ① 先做一轮 iOS 27 UI 细化设计；<br>② 抽出本地 Swift Package `shared/`（脱离 AppKit 与本地磁盘强绑定）、新建同仓独立工程 `ios/WadosMAAiOS.xcodeproj`，实现双轨 HTTPS + SPKI Pinning、扫码配对、4 Tab、日常+抄作业 SSE 实时进度、主页截图查看、Bark Deep Link；<br>③ **在 `devhome` 全链路真机验收通过后，将 `feat/decouple-ios` 合入 `dev` → `main` 并执行 §3.8 生产切线**（前置备份 → 迁移状态并重写 `index.jsonl` & `last_run.json` → 持 `agent-book/state.lock` 仅清 18 条 MAA 按钮 → 旧脚本置桩 + 暂停 5 条 MAA cron → 改写 Mac GUI `RemoteHermesHome` 至 `~/.wados-maa` → `devhome/scripts` 软链切回主仓库） | ① 真机在 Wi-Fi 与 5G 切换丝滑，外网伪造 `192.168.50.2` 被证书固定拦截；<br>② 切线后 iOS App 与 Mac GUI 均正常读写 `~/.wados-maa`，线上跑通首场日常并收到加密 Bark 战报；<br>③ `~/.hermes` 其余 **16 条非 MAA cron**、14 条非 MAA 按钮键与 Discord webhook 无感运行，旧 MAA 脚本拒绝执行，回滚包完整可用 | 手机控制入口实现零断档平滑交接 |
| **Phase 4：无线自动续签 + P2 完善** | 上线 Mac mini 满 5 天自动探测续签（固定构建 `~/Developer/wados-maa-deploy/ios` 的 `main` 分支并核验 `ExpirationDate`）、App 内续签按钮、iOS 快捷指令模板（公网 URL + `resign_only` Token）、设置 → 高级全部配置项、调度器（含 `depot` 开关）与 TLS 证书到期轮换提醒 | 模拟满 5 天触发自动无线续签成功、验证 `ExpirationDate` 后移并收到加密 Bark 回执；全部白名单配置项可正确读写并回显 `iOS` 修改来源 | 仅在 Phase 0 验通续签前提下按此设计交付 |

---

## 10. 已拍板决策清单（2026-11-21 二轮复核定案）

| 参数 | 拍板值 | 备注 |
|---|---|---|
| 独立数据目录 | `~/.wados-maa` | 环境变量 `WADOS_MAA_HOME`；迁移时重写 `index.jsonl` 与 `last_run.json` 绝对路径，修正 `maa_upstream.py:177` 与 `maa_skland.py` 提示路径 |
| 开发分支与生产切线 | **独立分支 `feat/decouple-ios` + 独立 worktree（`devhome` 软链过去）；Phase 3 验收后合入 `dev`/`main` 并切线** | Phase 1–3 期间 `dev` 与 `main` 继续承接线上 `~/.hermes` 热修；`devhome` 动游戏测试须避开线上窗口并检查线上锁空闲 |
| iOS 工程组织方式 | **同仓独立工程 `ios/WadosMAAiOS.xcodeproj` + 本地 Swift Package `shared/`** | 与 `gui/`（AGPL-3.0）清晰解耦、物理隔离 AppKit，同时保留同 commit 改接口与统一 `main` 续签 |
| 旧入口停用与 Mac GUI 切换 | 切线当步：`~/.hermes/scripts/maa_*.py` 换拒绝桩 + 持 `agent-book/state.lock` 仅清 18 条 MAA 按钮键 + 暂停 5 条 MAA cron + 改写 `RemoteHermesHome` 偏好且代码拒用 `~/.hermes` | 保留 16 条非 MAA cron、14 条非 MAA 按钮键与 Discord webhook 不动；前置完整备份与一键回滚步骤 |
| 守护进程与端口安全 | 监听 `0.0.0.0:18170`（**自签 TLS HTTPS**，`do_handshake_on_connect=False` + 线程内 5s 握手超时），来源收口 `127.0.0.1` + `192.168.50.0/24` | iOS App 局域网启用 **主/备双槽 SPKI 证书固定** + 扫码配对；`cloudflared` 用 `caPool` 信任同一本地证书并设到期前 60 天轮换告警 |
| Cloudflare Tunnel | 独立隧道 `wados-maa` → `maa.luxraykit.com` | 与 `netease-mcp` 和代理域名 `shizukumo.uk` 完全隔离 |
| Token 分域 | `full`（iOS App / `/rescue`）+ `resign_only`（快捷指令专用，仅限 `ios:resign`） | 快捷指令走公网 `https://maa.luxraykit.com` + `resign_only` Token |
| 推送通道与加密 | Bark 官方 `https://api.day.app` + **Swift `CryptoKit` 小工具 `barkcrypt`** | 显式输出 `Base64(ciphertext + tag)`（禁用 `.combined`），Key/IV 按 UTF-8 原始字节；明文 `id` 放外层做原地覆盖，`level`/`group`/`title`/`body` 进密文 |
| 调度与超时语义 | 同北京日 ≤2h 补跑（先计划卡后日常，不挤下一场保护窗）；**1h 硬超时仅限日常且发 `SIGINT`**；抄作业不设 1h 硬超时 | `start_new_session=True` + `AbandonProcessGroup=true` + 以 `run.lock` 防重入 |
| Depot 仓库对表 | **迁移时保持暂停**（`depot_enabled: false`） | 在调度器与设置页提供独立开关，由用户决定何时恢复 |
| 续签构建源 | 固定使用 `~/Developer/wados-maa-deploy/ios`（`main` 分支） | 不从 `dev` 工作区构建，每次重签后核验 `embedded.mobileprovision` 的 `ExpirationDate` 后移 |
| iOS 目标版本与工具链 | **iOS 27** 真机 + Mac mini 升级 **Xcode 27** | UI 细化阶段严格参考 Apple iOS HIG（Liquid Glass 原生范式） |
