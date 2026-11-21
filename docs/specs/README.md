# 执行总表：Wado's MAA 解耦与 iOS 27 原生 App 子 Spec 索引

> 上游总规划：[SPEC_DECOUPLE_AND_IOS.md](../SPEC_DECOUPLE_AND_IOS.md)（二轮复核定稿，2026-11-21）
> 后端既有不变量与外部契约：[maa-remote/docs/DEV_GUIDE.md](../../maa-remote/docs/DEV_GUIDE.md)
> 说明：本目录将总 Spec 按**执行顺序、门禁（Gate）与可并行边界**拆分为 5 个阶段、25 个可执行子 Spec，每个子 Spec 均自带依赖声明、修改范围、接口/契约细节与勾选式验收清单。

---

## 1. 全局依赖拓扑与并行总览

```text
[Phase 0: 前置实证] ──► Gate 0（5 项假设全过，否则先调方案）
                          │
       ┌──────────────────┴─────────────────────────────────────────┐
       ▼                                                            ▼ (跨阶段提前并行)
[Phase 1: 后端解耦 (feat/decouple-ios + devhome)]              [S3-1: iOS 27 UI 细化设计]
  S1-0 分支与 worktree
       │
       ├──► S1-1 底座(WADOS_MAA_HOME/run_id/ios)  ∥  S1-2 barkcrypt + maa_notify
       │
       ▼ (4 路并行)
  S1-3 去 Discord ∥ S1-4 抄作业进度/战报 ∥ S1-5 调度器/deploy ∥ S1-6 Mac GUI 适配
       │                                                                │
       ▼                                                                ▼ (跨阶段提前并行)
  S1-7 Phase 1 回归与 devhome 验收 ──► Gate 1                   [S3-2: 抽出 shared/ 包]
       │                                                                │
       ▼                                                                │
[Phase 2: HTTPS/SSE + 独立隧道 + /rescue]                               │
  S2-1 TLS/Token/证书  ∥  S2-3 CF Tunnel 模板  ∥  S2-4 /rescue 页       │
       │                                                                │
       ▼                                                                │
  S2-2 REST/SSE 端点 ──► S2-5 Phase 2 双轨验收 ──► Gate 2               │
                                                     │                  │
                                                     └────────┬─────────┘
                                                              ▼
[Phase 3: iOS 27 App (P0+P1) + 切线]           S3-3 iOS 工程与网络底座 ∥ S3-6 切线/回滚脚本
                                                              │
                                                              ▼ (4 路并行)
                                               S3-4a 今天 ∥ S3-4b 抄作业 ∥ S3-4c 日常 ∥ S3-4d 设置基础
                                                              │
                                                              ▼
                                               S3-5 devhome 全链路真机验收 ──► Gate 3
                                                              │
                                                              ▼
                                               S3-7 合入 main + 单步生产切线（严格串行）
                                                              │
                                                              ▼
[Phase 4: 无线自动续签 + P2 完善]              S4-1 续签引擎 ∥ S4-2 快捷指令 ∥ S4-3 设置 P2 ∥ S4-4 证书轮换
                                                              │
                                                              ▼
                                                       S4-5 Phase 4 终验
```

---

## 2. 阶段文档与门禁汇总

| 阶段 | 子 Spec 文档 | 子任务范围 | 阶段目标 | 硬门禁（进入下一阶段前提） |
|---|---|---|---|---|
| **Phase 0** | [P0_PREREQUISITE_SPIKES.md](./P0_PREREQUISITE_SPIKES.md) | `S0-0` ~ `S0-5` | 实证 5 项真机/网络/系统前置假设 | **Gate 0**：无线续签 `ExpirationDate` 后移、SPKI+ATS、防火墙/TCC、CF Tunnel SSE、Bark 加密与覆盖全部实证通过 |
| **Phase 1** | [P1_BACKEND_DECOUPLE.md](./P1_BACKEND_DECOUPLE.md) | `S1-0` ~ `S1-7` | `feat/decouple-ios` 上完成无 Discord 后端、内置调度器、`run_id`、Bark 与 Mac GUI 适配 | **Gate 1**：`unittest`/`ruff`/`pyright` 全绿，`devhome` 跑通日常/抄作业 + Bark，重启 daemon 不杀运行中场次 |
| **Phase 2** | [P2_API_TUNNEL_RESCUE.md](./P2_API_TUNNEL_RESCUE.md) | `S2-1` ~ `S2-5` | 落地 TLS/SSE API、分域 Token、配对二维码、独立 `cloudflared`、`/rescue` 应急页 | **Gate 2**：Wi-Fi/5G 双轨实测全部端点通过，慢速半开 TLS 不阻塞，`resign_only` 越权返 403 |
| **Phase 3** | [P3_IOS_APP_AND_CUTOVER.md](./P3_IOS_APP_AND_CUTOVER.md) | `S3-1` ~ `S3-7` | 抽出 `shared/`、建成 iOS 27 App（P0+P1），真机验收后合入 `main` 并执行单步生产切线 | **Gate 3**：`devhome` 真机全链路验收通过后才切线；切线后线上首场跑通且非 MAA cron/按钮零误伤 |
| **Phase 4** | [P4_AUTO_RESIGN_AND_P2.md](./P4_AUTO_RESIGN_AND_P2.md) | `S4-1` ~ `S4-5` | 上线满 5 天自动无线续签、快捷指令、设置页 P2 全配置与 TLS 证书轮换演练 | **终验**：模拟满 5 天无线重签验证 `ExpirationDate` 后移，全部白名单配置读写闭环 |

---

## 3. 全量 25 个子 Spec 并行速查表

> 并行标记：`🔴 严格串行`（底座/门禁/单步切线）、`🟢 可并行`（文件与资源完全隔离）、`🟡 有条件并行`（代码可并行，真机或端口实测需错开）。

| 阶段 | 编号 | 名称 | 前置依赖 | 并行性 | 可并行的同伴 |
|---|---|---|---|---|---|
| P0 | S0-0 | Xcode 27 与 iOS 27 真机配对就绪 | 无 | 🔴 严格串行 | —（Xcode 27.2 与 license 已完成，待核真机配对） |
| P0 | S0-1 | LaunchAgent 无线续签 & `ExpirationDate` 实证 | S0-0 | 🟡 有条件并行 | S0-2 / S0-4 / S0-5（与 S0-3 错开真机安装） |
| P0 | S0-2 | 独立 CF Tunnel & SSE 25s 保活实证 | 无 | 🟢 可并行 | S0-1 / S0-3 / S0-4 / S0-5 |
| P0 | S0-3 | iOS 27 真机 SPKI Pinning & ATS 实证 | S0-0 | 🟡 有条件并行 | S0-2 / S0-5（与 S0-1 错开真机，与 S0-4 共用 18170 桩） |
| P0 | S0-4 | 防火墙入站放行 & TCC 稳定性实证 | 无 | 🟡 有条件并行 | S0-1 / S0-2 / S0-5（与 S0-3 共用 18170 桩） |
| P0 | S0-5 | `barkcrypt` 原型 & Bark 同 `id` 升权覆盖实证 | 无 | 🟢 可并行 | S0-1 / S0-2 / S0-3 / S0-4 |
| P1 | S1-0 | `feat/decouple-ios` 分支、worktree 与测试隔离 | Gate 0 | 🔴 严格串行 | — |
| P1 | S1-1 | `WADOS_MAA_HOME` 底座、`run_id` 与 `ios` 来源 | S1-0 | 🔴 底座（仅与 S1-2 并行） | S1-2 |
| P1 | S1-2 | `barkcrypt.swift` + `maa_notify.py` 通知模块 | S1-0 | 🟢 可并行 | S1-1 |
| P1 | S1-3 | 核心业务去 Discord 硬依赖 | S1-1, S1-2 | 🟢 可并行 | S1-4 / S1-5 / S1-6（+ 跨阶段 S3-1） |
| P1 | S1-4 | 抄作业 `progress.json` / `report.json` 补齐 | S1-1 | 🟢 可并行 | S1-3 / S1-5 / S1-6（+ 跨阶段 S3-1） |
| P1 | S1-5 | 内置调度器、`maa_schedule.py` 与 `deploy.py` 独立模式 | S1-1, S1-2 | 🟢 可并行 | S1-3 / S1-4 / S1-6（+ 跨阶段 S3-1） |
| P1 | S1-6 | Mac GUI 适配（`ScheduleReport`、`ios` 来源、防回落） | S1-0 | 🟢 可并行 | S1-3 / S1-4 / S1-5（+ 跨阶段 S3-1） |
| P1 | S1-7 | Phase 1 不变量修订、全量回归与 `devhome` 真机验收 | S1-3 ~ S1-6 | 🔴 严格串行 | — |
| P2 | S2-1 | TLS 握手防挂死、分域 Token、证书与配对二维码 | Gate 1 | 🟢 可并行 | S2-3 / S2-4（+ 跨阶段 S3-1 / S3-2） |
| P2 | S2-2 | REST 读/写端点与 SSE 广播引擎 | S2-1 | 🟡 可拆内部两路 | S2-3 / S2-4（+ 跨阶段 S3-1 / S3-2） |
| P2 | S2-3 | 独立 Cloudflare Tunnel 配置与 LaunchAgent 模板 | S0-2, S2-1 | 🟢 可并行 | S2-2 / S2-4（+ 跨阶段 S3-1 / S3-2） |
| P2 | S2-4 | `/rescue` 极简应急 Web 页 | Gate 1 | 🟢 可并行 | S2-1 / S2-2 / S2-3（+ 跨阶段 S3-1 / S3-2） |
| P2 | S2-5 | Phase 2 双轨安全与 API 实测验收 | S2-2 ~ S2-4 | 🔴 严格串行 | — |
| P3 | S3-1 | iOS 27 UI 细化设计（HIG + 4 Tab 交互稿） | Gate 0 | 🟢 **可提前至 P1/P2 并行** | P1 / P2 任意任务 |
| P3 | S3-2 | 本地共享包 `shared/` 抽离与 `gui/` 切换引用 | S1-6 | 🟢 **可提前至 P2 并行** | P2 任意任务 / S3-1 |
| P3 | S3-3 | `ios/WadosMAAiOS.xcodeproj` 工程与网络/安全底座 | S3-2, Gate 2 | 🔴 P3 底座（与 S3-6 并行） | S3-6 |
| P3 | S3-4a | iOS Tab 1「今天」+ 实时进度 + 历史战报/截图/日志 | S3-1, S3-3 | 🟢 4 路并行 | S3-4b / S3-4c / S3-4d / S3-6 |
| P3 | S3-4b | iOS Tab 2「抄作业」+ 预览/开打 + 规则 Sheet | S3-1, S3-3 | 🟢 4 路并行 | S3-4a / S3-4c / S3-4d / S3-6 |
| P3 | S3-4c | iOS Tab 3「日常」长期规则与时间表 | S3-1, S3-3 | 🟢 4 路并行 | S3-4a / S3-4b / S3-4d / S3-6 |
| P3 | S3-4d | iOS Tab 4「设置」基础连接/配对/通知/资源 | S3-1, S3-3 | 🟢 4 路并行 | S3-4a / S3-4b / S3-4c / S3-6 |
| P3 | S3-6 | 生产切线与回滚脚本（含 Mac GUI 禁 `~/.hermes`） | Gate 1 | 🟢 **可与 S3-3/S3-4 并行** | S3-3 / S3-4a~d |
| P3 | S3-5 | `devhome` 全链路真机验收 | S3-4a ~ S3-4d | 🔴 严格串行 | — |
| P3 | S3-7 | 分支合并与生产切线执行（单步不可并发） | S3-5, S3-6 | 🔴 严格串行 | — |
| P4 | S4-1 | Mac 侧无线自动续签引擎（`maa_ios_resign.py`） | S3-7 | 🟢 可并行 | S4-2 / S4-3 / S4-4 |
| P4 | S4-2 | iOS 快捷指令个人自动化模板 | S3-7 | 🟢 准备并行（联调等 S4-1） | S4-1 / S4-3 / S4-4 |
| P4 | S4-3 | iOS「设置」Tab P2 完善（续签/调度器/高级配置） | S3-7 | 🟢 可并行 | S4-1 / S4-2 / S4-4 |
| P4 | S4-4 | TLS 证书到期告警与双指纹零中断轮换演练 | S3-7 | 🟢 可并行 | S4-1 / S4-2 / S4-3 |
| P4 | S4-5 | Phase 4 端到端终验 | S4-1 ~ S4-4 | 🔴 严格串行 | — |

---

## 4. 并行执行四条硬红线

1. **同一台 iPhone 真机独占**：`S0-1` 与 `S0-3`、以及 Phase 3 任何真机安装调试禁止同时执行 `xcrun devicectl device install app`。
2. **`18170` 测试端口独占**：`S0-3` 与 `S0-4` 实测期间共用同一份最小 TLS 监听桩，避免双进程争抢端口。
3. **PlayCover 与 `run.lock` 独占**：Phase 1–3 所有在 `devhome` 动游戏的验证（`S1-7` / `S2-5` / `S3-5`）必须避开线上北京时间早晚场与每 15 分钟活动监控窗口，开跑前先确认 `~/.hermes/state/maa/run.lock` 空闲。
4. **`maa_common.py` 底座先合入**：Phase 1 务必等 `S1-1` 落定并过单测后再并行展开 `S1-3` / `S1-4` / `S1-5`，避免多路同时改动 `maa_common.py` 的路径常量、锁协议与 `TypedDict` 导致合并冲突。
