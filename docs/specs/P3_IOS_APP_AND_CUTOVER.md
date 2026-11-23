# Phase 3 子 Spec：iOS 27 原生 App（P0 + P1）+ 合并与生产切线

> 对应总 Spec：[SPEC_DECOUPLE_AND_IOS.md §3.8 & §6 & §8.2 & §9 Phase 3](../SPEC_DECOUPLE_AND_IOS.md)
> 许可证边界：`shared/`（MIT）、`ios/`（MIT，100% 原创 iOS 27 SwiftUI）、`gui/`（AGPL-3.0，仅引用 `shared/`，不混入 iOS 工程）。
> 切线原则：**必须等 iOS App 在 `devhome` 真机全链路验收通过（Gate 3）后，再合入 `main` 并单步执行生产切线，确保手机端控制零断档。**

---

## 执行顺序与并行安排

```text
[跨阶段提前并行]
  Gate 0 ──► S3-1 (iOS 27 UI 细化设计)
  S1-6   ──► S3-2 (抽出 shared/ 包并让 gui/ 引用)
  Gate 1 ──► S3-6 (生产切线 + 回滚脚本 + Mac GUI 禁 ~/.hermes 保护)

[Phase 3 主线]
  S3-2 + Gate 2 ──► S3-3 (ios/WadosMAAiOS.xcodeproj 工程与网络/安全底座)
                          │
                          ▼ (4 个 Tab 完全并行，依赖 S3-1 + S3-3)
           ┌──────────────┼──────────────┬──────────────┐
           ▼              ▼              ▼              ▼
        S3-4a          S3-4b          S3-4c          S3-4d
        Tab1 今天       Tab2 抄作业    Tab3 日常       Tab4 设置(基础)
           └──────────────┴──────────────┴──────────────┘
                                  │
                                  ▼
                       S3-5 (devhome 全链路真机验收) ──► Gate 3
                                  │
                                  ▼ (+ S3-6)
                       S3-7 (合入 dev → main + 单步生产切线)
```

---

## S3-1：iOS 27 UI 细化设计（HIG + 4 Tab 交互稿）

- **前置依赖**：Gate 0
- **并行性**：🟢 **可提前至 Phase 1 / Phase 2 并行**（零代码依赖）
- **交付物**：UI 细化设计文档（如 `docs/specs/P3_IOS_UI_DESIGN.md`）
- **设计约束**：
  1. 面向 **iOS 27**，遵循 Apple [Human Interface Guidelines — Designing for iOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-ios)，优先采用原生 Liquid Glass Tab Bar / Toolbar、`NavigationStack`、`Sheet`、`confirmationDialog`；
  2. 信息自解释、去冗余辅助标签与说明段落；
  3. 高频操作（手动开跑、换关、停止、确认开打）≥44pt 触控热区，优先下沉单手拇指区；高危/动游戏操作全部配系统二次确认；
  4. 明确 4 Tab、全局悬浮实时运行胶囊、连接异常横幅、空态/骨架/弱网/跨轨切换态、以及深浅色 + Dynamic Type 规范。
- **验收清单**：
  - [ ] 覆盖 §6.3 全部页面与状态，无违背不变量的降级开关入口
  - [ ] 经用户确认后作为 S3-4a ~ S3-4d 实现依据

---

## S3-2：抽出本地 Swift Package `shared/` 并改造 `gui/` 引用

- **前置依赖**：S1-6
- **并行性**：🟢 **可提前至 Phase 2 并行**
- **新增 / 改动目录**：
  - 新增 `shared/Package.swift`（`WadosMAAShared`，纯 `Foundation`，零 `AppKit`/`SwiftUI` 依赖，MIT）
  - 迁入并剥离磁盘/AppKit 耦合的模型与解析器：
    - `RemoteReceipt`（从 `gui/MeoAsstMac/Remote/RemoteBridge.swift` 拆出，剥离 `AppKit` 与 `Diagnostics` 耦合）；
    - `JSONValue`、`ConfigField`、`ChangeMeta`、`ConfigSnapshot`、`DefaultsSnapshot`、`ScheduleReport`、`LastRunText`（从 `RemoteStore.swift` 拆出纯模型部分）；
    - `RunHistory`、`RunProgress`（剥离本地文件 I/O，保留纯数据结构与 JSON 解析）；
    - `RunModels`、`RunStageParser`（纯模型与日志阶段解析）；
    - 补齐 `Snapshot`、`CopilotProgress`、`SchedulerStatus`、`ResignStatus` 等 §5.1 API 模型；
  - `gui/MeoAsstMac.xcodeproj` 添加本地 Package `../shared`，保留 `LocalProcessTransport` 与本地磁盘适配器。
- **验收清单**：
  - [ ] `swift test --package-path shared` 通过（含 `ScheduleReport`、`ChangeMeta(source="ios")`、`RunProgress` 日常/抄作业解析单测）
  - [ ] `gui/` Release 构建通过，在 `devhome` 运行行为与抽离前一致

---

## S3-3：`ios/WadosMAAiOS.xcodeproj` 工程骨架与网络/安全核心层

- **前置依赖**：S3-2, Gate 2
- **并行性**：🔴 Phase 3 阶段内底座（与 S3-6 可并行）
- **新增目录**：`ios/`（独立 Xcode 工程 `ios/WadosMAAiOS.xcodeproj`，MIT，Deployment Target `iOS 27.0`，引用 `../shared`）
- **核心模块**：
  1. **双轨 `HTTPTransport`**：
     - 启动、回前台、网络变化时先探 `GET https://192.168.50.2:18170/healthz`（超时 `800ms`）；
     - `URLSessionDelegate` 强制 **SPKI SHA-256 指纹固定**，支持「主指纹 + 备用指纹」双槽位；握手验证先于任何 Header 发送；
     - 局域网通则锁定直连（记录 RTT，解锁无线续签能力）；否则自动切换 `https://maa.luxraykit.com`；
     - 全部业务请求自动附 `Authorization: Bearer <full_token>`（及可选 `CF-Access-Client-Id` / `CF-Access-Client-Secret`）。
  2. **安全存储与扫码配对**：
     - `full` Token 与可选 CF Access 凭据存系统 Keychain；
     - 相机扫码解析配对二维码写入连接配置，同时支持手工粘贴编辑。
  3. **SSE 实时客户端**：
     - 长连 `GET /api/v1/events`，处理 25s 心跳注释、指数退避重连、前后台暂停/恢复，分发事件至全局 `AppStore`。
  4. **全局外壳**：
     - 4 Tab 框架（`今天` / `抄作业` / `日常` / `设置`）+ 抄作业未通角标；
     - 悬浮实时运行状态胶囊（任一 Tab 可见，点击直达进度 Sheet）；
     - 连接异常横幅（离线 / Token 失效 / 证书不匹配 / 隧道不通）；
     - Deep Link 路由：`wadosmaa://run/latest`、`wadosmaa://run/<id>`、`wadosmaa://today`、`wadosmaa://copilot`、`wadosmaa://resign`。
- **验收清单**：
  - [ ] iOS 27 真机构建安装成功，扫码配对后可双轨拉 `/snapshot` 与保活 SSE
  - [ ] 外网或错误指纹下局域网连接在 TLS 阶段拦截，自动回退 CF 隧道

---

## S3-4a ~ S3-4d：4 个一级 Tab 页面（4 路并行）

> **前置依赖**：S3-1（UI 定稿）+ S3-3（工程与网络底座）
> **并行性**：🟢 **4 条支线各自独立子目录，完全可并行开发**，共用 S3-3 的 `AppStore` / `HTTPTransport`。

### S3-4a：Tab 1「今天」+ 实时进度 + 历史战报/截图/日志（P0/P1）
- 实时运行：底部胶囊 + 进度抽屉（日常 7 步 & 抄作业关数/阶段、刷理智把数、当前理智、掉落、ETA、恢复备注、带 `run_id` 二次确认「停止」）；
- 游戏资源提示条（仅 `verdict ∈ {blocked, stale, running}` 时出现，支持一键触发 `POST /api/v1/upstream/update`）；
- 今日早/晚场计划速控（换关、切回自动定关、跳过/恢复、刷理智开关；已开跑自动只读）；
- 手动开一场（活动关前置、临时 6 项环节开关、锁冲突禁点、blackout 30 分钟内强开二次确认）；
- 最近场次 + 二级页「历史记录」（分页）+ 二级页「场次详情」（战报摘要、主页校验截图支持双指缩放、恢复备注、尾部 200 行日志）。

### S3-4b：Tab 2「抄作业」+ 预览/开打 + 规则 Sheet（P1）
- 顶栏当期活动名 + `copilot auto` 总开关 + 右上角规则 Sheet（4 个阈值参数）；
- 关卡列表（未通排前、已通沉底，区分 ✅ / 🔁 / ⏳ / 🚫 / ⛔）；
- 二级页「关卡作业预览与开打」：携带客户端 UUID `request_id` 调 `POST /api/v1/copilot/preview`，页面退出或点取消立即调 `DELETE /api/v1/copilot/preview/<request_id>`；自动选中最优完美作业；练度不足项标红并列缺口且不可选；二次确认后调 `POST /api/v1/copilot/go`；支持「我打过了」与「撤销通关记录」。

### S3-4c：Tab 3「日常」长期规则与时间表（P1）
- 早晚场时间表（早场 05:00–11:59、晚场 12:00–23:59、开关、blackout 保护窗口，走 `/api/v1/schedule`）；
- 持久默认关 + 5 项默认环节开关（走 `/api/v1/defaults`）；
- 刷理智与剿灭（临期药 0–7 天、匿名上报掉落、剿灭预留理智）；
- 公招与领奖（公招次数 0–4、幸运墙/采矿/月卡开关）；
- 信用商店（优先买/不买列表、低于 300 停买、只买打折）；
- 展示最近修改来源（iOS / Mac）与时间。

### S3-4d：Tab 4「设置」基础连接/配对/通知/资源（P2 必备子集）
- 当前链路状态（局域网 HTTPS / CF 远程 / 离线 + 实测 RTT）；
- 扫码首次配对、局域网地址 + 主/备证书指纹编辑、远程域名、Token 与可选 CF Access Header、手动双轨测试；
- Bark 推送状态与「发一条测试推送」（`POST /api/v1/notify/test`）；
- 游戏资源版本概览与手动更新；
- 为 Phase 4 预留「iOS 签名与无线续签」「调度器」「高级设置」占位入口。

---

## S3-6：生产切线与一键回滚脚本（含 Mac GUI 禁 `~/.hermes` 保护）

- **前置依赖**：Gate 1
- **并行性**：🟢 **可与 S3-3 / S3-4a~d 完全并行**
- **新增 / 改动文件**：
  - `maa-remote/daemon/cutover.py`（含 `--dry-run` 与 `--rollback <backup_dir>`）
  - `maa-remote/tests/test_cutover.py`
  - `gui/MeoAsstMac/Remote/RemoteConfig.swift`（启用硬拒绝 `~/.hermes` 保护：解析到 `~/.hermes` 时拒绝操作并提示切往 `~/.wados-maa`）
- **脚本精确步骤（严格对齐 §3.8）**：
  1. **安全前置检查**：确认 `~/.hermes/state/maa/run.lock` 空闲且距下一场定时任务 > 30 分钟；
  2. **全量备份**至 `~/.wados-maa/backups/cutover-<YYYYMMDDTHHMMSS>/`：
     - `~/.hermes/state/maa/`、`~/.hermes/state/agent-book/buttons.json`、`~/.hermes/cron/jobs.json`、`~/.hermes/scripts/maa_*.py`、`defaults read io.github.ffkiyo7.MaaRemoteGui RemoteHermesHome` 原值；
  3. **单步停旧入口**：
     - 暂停 Hermes 中 **5 条在跑 MAA cron**（保留 **16 条非 MAA cron** 完整不动）；停用 Hermes MAA skill；
     - **持 `~/.hermes/state/agent-book/state.lock`** 原子读改写 `buttons.json`，**仅删 18 条 MAA 按钮键**（保留 **14 条非 MAA 业务键**）；
     - 将 `~/.hermes/scripts/maa_*.py` 替换为立即非零退出的拒绝桩（打印已迁移至 `~/.wados-maa`）；
  4. **状态与绝对路径迁移**：
     - 复制 `~/.hermes/state/maa/` 至 `~/.wados-maa/state/maa/`；
     - 重写 `runs/index.jsonl` 与 `last_run.json` 中全部 `.hermes/state/maa/` 绝对路径为 `.wados-maa/state/maa/`；
     - 确认 `daemon/daemon.json` 中 `depot_enabled: false`；
  5. **切换 Mac GUI 偏好**：改写 `defaults write io.github.ffkiyo7.MaaRemoteGui RemoteHermesHome '~/.wados-maa'`；
  6. **一键回滚（`--rollback`）**：停新 LaunchAgent（核对无持锁）→ 从备份还原旧脚本、持 `agent-book/state.lock` 还原 `buttons.json`、恢复 5 条 MAA cron 与 `RemoteHermesHome='~/.hermes'` → 保留 `~/.wados-maa` 原样绝不删除。
- **验收清单**：
  - [ ] 在临时模拟 HOME 下完整演练「切线 → 校验非 MAA 数据完好 → 校验旧脚本拒执行 → 回滚还原」全部通过

---

## S3-5：`devhome` 全链路真机验收

- **前置依赖**：S3-4a, S3-4b, S3-4c, S3-4d
- **并行性**：🔴 严格串行（Gate 3 门禁）
- **验收清单**：
  - [ ] Wi-Fi 与 5G 无感切轨，模拟伪造 `192.168.50.2` 被 SPKI Pinning 拦截
  - [ ] 首页实时进度（日常 + 抄作业）、换关/跳过、手动开跑与带 `run_id` 取消、截图缩放与尾部日志全部真机跑通
  - [ ] 抄作业搜索/取消预览/确认开打/标记通关真机跑通
  - [ ] 日常配置与时间表在 iOS 与 Mac GUI 双向同步一致
  - [ ] 收到 AES-GCM 加密 Bark 推送并经 Deep Link 精准跳转对应页面

---

## S3-7：分支合并与单步生产切线

- **前置依赖**：S3-5（Gate 3 通过）+ S3-6（切线脚本演练通过）
- **并行性**：🔴 严格串行（生产单步操作，不可并发）
- **执行步骤**：
  1. 确认线上无正在跑或 30 分钟内开跑的场次（查 `~/.hermes/state/maa/run.lock` 与 `hermes cron list`）；
  2. 合并 `feat/decouple-ios` → `dev` → `git -C ~/Developer/wados-maa-deploy merge --ff-only dev`（同步 `main`）；
  3. 从 `~/Developer/wados-maa-deploy/maa-remote` 运行 `deploy.py` 独立模式部署到 `~/.wados-maa` 并 `--check`；
  4. 初始化 `~/.wados-maa/daemon/`（TLS 证书、分域 Token、配对二维码、Bark 凭据）；
  5. 执行 `cutover.py` 完成备份、停旧、迁状态与路径改写、改 Mac GUI 偏好；
  6. 启动线上 `wados-maa-daemon` 与 `wados-maa-cloudflared` LaunchAgent；重编安装新版 Mac GUI 与绑定线上的 iOS App；
  7. 切线稳定后将 `~/Developer/forks/maa-remote-devhome/scripts` 软链改回 `~/Developer/wados-maa/maa-remote/scripts`，清理临时 worktree `~/Developer/wados-maa-decouple`。
- **切线验收清单**：
  - [ ] iOS App 与 Mac GUI 均正常读写 `~/.wados-maa`，Mac GUI 拒绝旧 `~/.hermes`
  - [ ] 线上跑通首场日常并收到加密 Bark 战报
  - [ ] `~/.hermes` 其余 16 条非 MAA cron、14 条非 MAA 按钮与 Discord webhook 无损运行
  - [ ] 手动尝试执行旧 `~/.hermes/scripts/maa_action.py` 被拒绝桩拦截
  - [ ] 回滚备份目录完整可核验
