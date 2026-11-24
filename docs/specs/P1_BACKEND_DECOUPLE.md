# Phase 1 子 Spec：后端解耦与内置调度器（独立分支 + `devhome`）

> 对应总 Spec：[SPEC_DECOUPLE_AND_IOS.md §3 & §8.1 & §9 Phase 1](../SPEC_DECOUPLE_AND_IOS.md)
> 既有不变量参考：[maa-remote/docs/DEV_GUIDE.md §8 & §12](../../maa-remote/docs/DEV_GUIDE.md)
> 硬约束：**全程只在独立分支 `feat/decouple-ios` 与独立 worktree（`~/Developer/wados-maa-decouple`）开发，`dev`/`main` 与线上 `~/.hermes` 零改动；保持纯 Python stdlib 零第三方依赖。**
>
> **状态（2026-11-24 补记）**：Phase 1 已完成，下面的勾选框当时没有逐项回填。代码已随 Phase 3 合入 `dev`/`main` 并上线，`feat/decouple-ios` 分支和 worktree 已删除。离线项在 11-24 复核过（913 个单测、ruff、pyright 全绿）；真机项由 Phase 3 的 S3-5 真机验收和切线后的线上首场覆盖。

---

## 执行顺序与并行安排

```text
S1-0 (分支/worktree/测试隔离)
  ├──► S1-1 (WADOS_MAA_HOME + run_id + ios 来源底座)   [串行底座]
  └──► S1-2 (barkcrypt.swift + maa_notify.py)          [与 S1-1 并行]
         │
         ▼ (S1-1 & S1-2 合入后，4 路完全并行)
  ┌──────┼──────────────┬──────────────┬──────────────┐
  ▼      ▼              ▼              ▼              ▼
S1-3   S1-4           S1-5           S1-6       (跨阶段可同时开 S3-1 UI 设计)
去Discord 抄作业进度   调度器/deploy   Mac GUI 适配
  └──────┴──────────────┴──────────────┘
                        │
                        ▼
               S1-7 (不变量修订 + 回归 + devhome 真机验收) ──► Gate 1
```

---

## S1-0：分支、Worktree 与测试隔离搭建

- **前置依赖**：Gate 0
- **并行性**：🔴 严格串行
- **改动范围**：
  - Git 分支与工作区：新建分支 `feat/decouple-ios` 与独立 worktree `~/Developer/wados-maa-decouple`；将 `~/Developer/forks/maa-remote-devhome/scripts` 软链指向 `~/Developer/wados-maa-decouple/maa-remote/scripts`；
  - `maa-remote/tests/_isolation.py`：除 `HOME`/`HERMES_HOME` 外同时隔离 `WADOS_MAA_HOME`，审计钩子同步守住真实 home 下的 `~/.wados-maa`（避免单测误碰）。
- **验收清单**：
  - [ ] `git status` 在主仓库 `~/Developer/wados-maa`（`dev`）与部署目录 `~/Developer/wados-maa-deploy`（`main`）均保持干净
  - [ ] 新 worktree 下 `python3 -m unittest discover -s tests` 100% 通过

---

## S1-1：`WADOS_MAA_HOME` 底座、`run_id` 全链路与 `ios` 来源基础

- **前置依赖**：S1-0
- **并行性**：🔴 Phase 1 串行底座（仅与 S1-2 并行，合入后再放行 S1-3 / S1-4 / S1-5）
- **改动文件**：
  - `maa-remote/scripts/maa_common.py`
  - `maa-remote/scripts/maa_action.py`
  - `maa-remote/scripts/maa_daily.py`
  - `maa-remote/scripts/maa_upstream.py`
  - `maa-remote/scripts/maa_skland.py`
  - 对应单测：`test_plan.py`、`test_daily.py`、`test_receipts.py`、`test_upstream.py`、`test_skland.py`、`test_state_schema.py`、`test_isolation.py`
- **规格要点**：
  1. **数据目录解析（`maa_common.py`）**：
     - 解析优先级：`WADOS_MAA_HOME` → `HERMES_HOME` → `~/.wados-maa`；保留 `HERMES_HOME` 别名或过渡常量，确保老测试与平滑迁移兼容；
     - 新增 `DAEMON_DIR = WADOS_MAA_HOME / "daemon"` 与 `LOGS_DIR = WADOS_MAA_HOME / "logs"`；
     - `STATE_LOCK_PATH` 迁至 `STATE_DIR / "state.lock"`（不再依赖 `~/.hermes/state/agent-book/state.lock`）；更新 `tests/_isolation.py` 的 `SHARED_HOME_ALLOWED`。
  2. **`ios` 来源全量接入**：
     - `maa_common.ACTION_SOURCES` 加入 `"ios"`；
     - 新增 `is_app_source(source: str | None) -> bool`（`source in {"gui", "ios"}`），替换 `maa_action.py` 全部 **6 处** `gui` 特判（原 L151 `emit()` 隐藏 `detail` + L241 / L1340 / L1361 / L1935 / L2154）；
     - 修正 `maa_daily.py:2634` 手动场来源赋值：保留白名单内的真实 `found.get("source")`（不再把非 `gui` 统统写成 `"discord"`）。
  3. **`run_id` 贯通与五类文件统一命名**：
     - 生成精确到秒的唯一 `run_id`（如 `2026-11-21-now-143205`、`2026-11-21-copilot-a1b2c3-151022`）；
     - `run_lock` 锁文件 JSON 新增 `run_id` 字段（与 `holder`/`detail`/`pid`/`since` 并列），同步写入 `last_run.json` 与进度文件；
     - `maa_daily.py:2642` 的 `run_stem` 改为 `run_id`，使快照（`.json`）、日志（`.log`）、截图（`.png`）、战报（`-report.json`）、进度（`.progress.json`）五类文件一次性以 `run_id` 命名；历史读取兼容旧 `<日期>-<场次>` 命名；
     - `maa_action.py` 的 `run cancel` 支持 `--run-id <run_id>`：传入时严格比对 `run.lock.run_id`，不一致返回 `ok=false, code="run_changed"` 拒绝。
  4. **隐藏路径依赖修正**：
     - `maa_upstream.py:177`：`is_live_home()` 改为对比 `~/.wados-maa`（`LIVE_HOME`）；
     - `maa_skland.py` 重绑提示命令按当前 `SCRIPTS_DIR` 动态生成（如 `python3 ~/.wados-maa/scripts/maa_skland.py link`）。
- **验收清单**：
  - [ ] `WADOS_MAA_HOME` 优先级与 `state/maa/state.lock` 单测通过
  - [ ] `MAA_ACTION_SOURCE=ios` 时 6 处 `maa_action` 行为与 `gui` 一致、`maa_daily` 保留 `ios` 来源
  - [ ] 同日连跑两场手动场五类文件互不覆盖；`run cancel --run-id` 错配返回 `run_changed`
  - [ ] `maa_upstream.is_live_home()` 与 `maa_skland` 提示路径单测通过

---

## S1-2：`barkcrypt.swift` + `maa_notify.py` 通知出口模块

- **前置依赖**：S1-0（及 S0-5 结论）
- **并行性**：🟢 与 S1-1 完全可并行（全新独立文件）
- **新增文件**：
  - `maa-remote/scripts/barkcrypt.swift`
  - `maa-remote/scripts/maa_notify.py`
  - `maa-remote/tests/test_notify.py`
- **规格要点**：
  1. **`barkcrypt.swift`**：
     - 使用 macOS `CryptoKit.AES.GCM`；
     - 所有敏感参数（明文 JSON、`key`、`iv`）经 **stdin JSON** 传入，绝不经 argv 暴露；
     - Key（32 字节或 16 字节 ASCII UTF-8）与 IV（12 字节随机 ASCII UTF-8）直接取原始 UTF-8 字节；
     - 显式输出 `Base64(sealedBox.ciphertext + sealedBox.tag)`，**严禁使用 `sealedBox.combined`**。
  2. **`maa_notify.py`**：
     - 读取 `daemon/daemon.json`（`notify_backend`: `"bark"` | `"none"`、`bark_base_url` 默认 `https://api.day.app`、`bark_icon_url`）与 `daemon/secrets.json`（`bark_device_key`、`bark_aes_key`）；
     - 外层明文仅发 `device_key`、`ciphertext`、`iv`、`id`（同场次原地覆盖；失败通知 `id` 策略按 S0-5 实证结论落盘）；
     - 内层密文含 `title`、`body`、`subtitle`、`level`（`passive`/`active`/`timeSensitive`）、`group`（`wados-maa`）、`icon`、`url`（`wadosmaa://...`）；
     - 严格遵守不变量 #63：**任何加密、网络、配置缺失异常一律捕获写日志、永不抛给业务主流程**；
     - 提供 `send_test()` 给后续 `POST /api/v1/notify/test` 复用。
- **验收清单**：
  - [ ] `swiftc` 编译 `barkcrypt.swift` 0 警告，解密校验与 Bark 规范逐字节一致
  - [ ] `test_notify.py` 离线全绿（含缺配置降级、密文结构、永不抛）

---

## S1-3：核心业务去 Discord 硬依赖

- **前置依赖**：S1-1, S1-2
- **并行性**：🟢 与 S1-4 / S1-5 / S1-6 可并行
- **改动文件**：
  - `maa-remote/scripts/maa_plan_card.py`
  - `maa-remote/scripts/maa_action.py`（`publish_round()`）
  - `maa-remote/scripts/maa_activity_watch.py`
  - `maa-remote/scripts/maa_daily.py`（通知出口接 `maa_notify`）
  - 对应单测：`test_plan_card.py`、`test_activity_watch.py`、`test_daily.py`、`test_copilot_preview.py`
- **规格要点**：
  1. **`maa_plan_card.py`**（原 L1175–L1178 硬校验 `channel_id` / `discord_token`）：
     - 拆离「准备步骤」与「Discord 发卡」：早场上游更新（晚场跳过，#40）、活动关探测刷新、自动定关写入 `plan.json`、旧产物清理、以及 **森空岛每日体检（#56，L1355）** 在无 Discord 时必须无条件完整执行；
     - 上游更新失败、活动探测失败、森空岛每日体检告警改走 `maa_notify.py`（`timeSensitive`）；原 Discord 发卡与 `buttons.json` 登记降为有配置时才跑的可选旁路。
  2. **`maa_action.publish_round()`**（同时服务 `copilot_go()` 与 `maa_copilot_worker.py`）：
     - 无 Discord 配置时跳过发排程卡与写 `BUTTONS_PATH`，返回 `message_id = ""` 并走 `maa_notify.py` 发通知，不抛异常。
  3. **`maa_activity_watch.py`**：
     - 替换 `_notify()` 及排程通知为 `maa_notify.py` 统一出口；移除对 `BUTTONS_PATH` 与 `retire_discord_components` 的强制依赖。
  4. **`maa_daily.py` 通知矩阵接入**：
     - 开跑（`passive`，`id=run-<run_id>`，跳实时进度）、成功完成（`active`，同 `id`，跳战报详情）、失败/掉线/熔断/锁冲突（`timeSensitive`，按 S0-5 策略 `id`，跳战报详情）、计划跳过（`passive`，独立 `id`，跳今日页）。
- **验收清单**：
  - [ ] 彻底不配置 `DISCORD_BOT_TOKEN` 与 `MAA_CHANNEL_ID` 时，早/晚计划卡（含 #56）、日常、活动监控、手动/自动抄作业均正常执行零异常
  - [ ] 对应单测离线全绿

---

## S1-4：抄作业 `progress.json` / `report.json` 与 `index.jsonl` 补齐

- **前置依赖**：S1-1
- **并行性**：🟢 与 S1-3 / S1-5 / S1-6 可并行（与 S1-3 在 `maa_copilot_worker.py` 边界明确：本任务只写进度/战报/索引，不改 `publish_round` 实现）
- **改动文件**：
  - `maa-remote/scripts/maa_copilot_worker.py`
  - `maa-remote/tests/test_copilot_worker.py`、`maa-remote/tests/test_run_index.py`
- **规格要点**：
  1. 抄作业开跑生成唯一 `run_id`（`YYYY-MM-DD-copilot-<token>-HHMMSS`），写入 `run.lock` 与 `last_run.json`；
  2. 运行期间原子更新与日常同构的 `runs/<run_id>.progress.json`（`schema_version: 1`、`kind: "copilot"`、`run_id`、每关一格的 `steps[]`、当前关卡/进度/已耗时、`notes[]`）；
  3. 结束时（成功/失败/取消）落盘结构化 `runs/<run_id>-report.json`（逐关结果、通过数/总数、截图路径、失败归类），并写入 `runs/index.jsonl`（带 `run_id`、`report`、`progress`、`log` 路径）；
  4. 通过 `maa_notify.py` 发出开跑/完成/失败通知（遵守 #63）。
- **验收清单**：
  - [ ] 抄作业进度 JSON 结构符合 `DEV_GUIDE.md §12.3` `progress.json` 扩展契约
  - [ ] 抄作业战报与索引行单测全绿，无 Discord 时完整可读

---

## S1-5：内置调度器、`maa_schedule.py` 重构与 `deploy.py` 独立模式

- **前置依赖**：S1-1, S1-2（+ S0-4 守护进程入口形态定型）
- **并行性**：🟢 与 S1-3 / S1-4 / S1-6 可并行
- **新增 / 改动文件**：
  - 新增 `maa-remote/scripts/maa_daemon.py`（Phase 1 先落调度器 + 进程管理 + 热重载骨架；HTTP/SSE 在 Phase 2 挂入）
  - 新增 `maa-remote/daemon/` 模板：`io.github.ffkiyo7.wados-maa.daemon.plist`（含 `AbandonProcessGroup=true`、显式 `WADOS_MAA_HOME`/`PATH`/`HTTP_PROXY`/`HTTPS_PROXY`/`http_proxy`/`https_proxy`）与 **S0-4 定型方案 B 的极简固定签名 Swift launcher（`wados-maa-launcher`，以 `Apple Development` + 固定 Identifier 签名并由 `deploy.py` 编译部署，统一承载防火墙放行与 TCC 辅助功能/录屏授权）**
  - 重构 `maa-remote/scripts/maa_schedule.py`
  - 扩展 `maa-remote/deploy.py`
  - 新增/改动单测：`test_daemon_scheduler.py`、`test_schedule.py`、`test_deploy.py`
- **规格要点**：
  1. **6 条内置调度任务（全用 `Asia/Shanghai` 北京时间，零 UTC 换算）**：
     - `plan_card_am`（`am.time - 10m`）、`daily_am`（`am.time`）、`plan_card_pm`（`pm.time - 10m`）、`daily_pm`（`pm.time`）、`depot`（`04:30`，受 `daemon.json` `depot_enabled` 控制，**默认 `false`**）、`activity_watch`（每 15 分钟 `:00/:15/:30/:45`）；
     - 状态落盘 `daemon/scheduler.json`（每条任务上次运行时间、下次计划时间、补跑/跳过/结果状态）。
  2. **同日 2 小时补跑硬规则**：
     - 错过一次性日槽位时，同时满足 ① 距计划时刻 ≤ 2 小时、② 同一北京自然日（`now.date() == scheduled.date()`）、③ 未进入下一场 `manual_run_blackout_minutes` 才补跑；
     - 同场 `plan_card_*` 与 `daily_*` 均待补跑时严格串行（先 `plan_card_*` 后 `daily_*`）；
     - 超时/跨日/挤窗记 `missed`；`activity_watch` 只跑当前槽位，不补历史槽位。
  3. **超时与进程隔离语义**：
     - 子进程一律 `start_new_session=True`；plist 配 `<key>AbandonProcessGroup</key><true/>`；防重入以 `run.lock` / `activity_watch.lock` 为准；
     - **3600s（1 小时）硬超时仅适用于日常场（`daily_am`/`daily_pm`/`now`）**，**绝不用于抄作业 worker**；
     - 日常超时先发 **`SIGINT`** 触发 #64 `interrupt_once()` 优雅收尾（关游戏、还台前调度 #62、写终态战报），宽限 90 秒后仍未退出才 `SIGKILL`。
  4. **`maa_schedule.py` 与 `deploy.py`**：
     - `maa_schedule.py` 改为读写 `config.json` `session_schedule` + `daemon.json` `depot_enabled` + 向守护进程发热重载信号（如 `SIGHUP` 或重载标志），不再调用 `hermes cron` CLI；
     - `deploy.py` 新增独立模式（`--standalone` 或按 `WADOS_MAA_HOME` 自动识别）：部署脚本、把 `barkcrypt.swift` 与 `ocrbox`/`winmove` 一并纳入 `COMPILED_HELPERS` 并由 `--check` 校验、同步 `config/maa-cli/` 与状态种子，**绝不碰 Hermes 的 `adapter.py`/`config.yaml`/`.env`/`SKILL.md`**。
- **验收清单**：
  - [ ] 补跑（含跨零点拒绝、保护窗拒绝、先计划卡后日常）、1h `SIGINT` 超时、抄作业豁免超时、重启防重入单测全绿
  - [ ] `maa_schedule.py` 新返回结构稳定清晰，供 S1-6 Mac GUI 消费
  - [ ] `deploy.py` 独立模式部署到临时目录并 `--check` 通过，零触碰 `~/.hermes`

---

## S1-6：Mac GUI 轻度适配（`gui/`）

- **前置依赖**：S1-0（与 S1-5 约定新 `ScheduleReport` JSON 结构）
- **并行性**：🟢 与 S1-3 / S1-4 / S1-5 完全可并行（完全在 `gui/` 目录）
- **改动文件**：
  - `gui/MeoAsstMac/Remote/RemoteStore.swift`（`ScheduleReport` L161、`ChangeMeta.text` L126）
  - `gui/MeoAsstMac/Remote/RemoteConfig.swift`（识别 `WADOS_MAA_HOME`，为 Phase 3 切线预留禁用 `~/.hermes` 保护开关）
  - `gui/MeoAsstMac/Remote/Redesign/` 中消费 `ScheduleReport` 的日程页面
- **规格要点**：
  1. `ScheduleReport` 改为适配内置调度器返回结构（不再强要求 Hermes `jobs_path` 与 `cron` 字典，同时兼容 `depot_enabled` 等字段）；
  2. `ChangeMeta.text` 识别 `"ios"`（显示「由 iOS 改」或「由 Wado's MAA (iOS) 改」）；
  3. `RemoteConfig` 支持新环境变量/目录，但在 Phase 3 切线前允许在开发模式继续读 `devhome`。
- **验收清单**：
  - [ ] `xcodebuild -project gui/MeoAsstMac.xcodeproj -scheme MAA -configuration Release -derivedDataPath ~/Developer/forks/wados-maa-build/decouple-p1 -skipMacroValidation -skipPackagePluginValidation build` 通过
  - [ ] 指向 `devhome` 时日程页、首页与修改来源均无解码报错

---

## S1-7：Phase 1 不变量修订、全量回归与 `devhome` 真机验收

- **前置依赖**：S1-3, S1-4, S1-5, S1-6
- **并行性**：🔴 严格串行（Phase 1 收口门禁）
- **核心任务**：
  1. 对照 [SPEC_DECOUPLE_AND_IOS.md §3.7](../SPEC_DECOUPLE_AND_IOS.md) 核查并更新不变量与单测（#40/#41/#54/#55/#56/#63–#67 改写或扩展；#7/#8/#14/#14b 标明切线后退役、编号不复用），同步更新 `maa-remote/docs/DEV_GUIDE.md`；
  2. 跑全量离线单测（含干净 HOME 与系统 `/usr/bin/python3`）+ `uvx ruff@0.17.3 check` + `uvx pyright@1.1.414` 全部 0 报错；
  3. **真机验收（须避开线上早晚场与 15 分钟活动监控窗口，且确认 `~/.hermes/state/maa/run.lock` 空闲）**：
     - 在 `devhome` 启动 `wados-maa-daemon`；
     - 跑通一场手动日常 + 一场抄作业，iPhone 收到 AES-GCM 加密 Bark 推送；
     - 在任务运行中重启 `wados-maa-daemon`，确认运行中任务不被杀死、重启后不会重复派发。
- **Gate 1 验收清单**：
  - [ ] `unittest` / `ruff` / `pyright` 全部 0 报错
  - [ ] `devhome` 日常 + 抄作业真机跑通并收到加密 Bark 推送
  - [ ] 重启守护进程不杀运行中场次且不重入
  - [ ] `dev` / `main` 与线上 `~/.hermes`、Discord 全程零改动
