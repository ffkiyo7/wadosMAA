# 开发指南（基于当前代码实现）
面向要改这套东西的人。本文只讲**现在的自动化链路是怎么串起来的、改哪里会影响什么**。事故经过、排查过程和「为什么改成这样」在 [incidents/](./incidents/README.md)；手动场选关卡的方案在 [PLAN_MANUAL_RUN.md](./PLAN_MANUAL_RUN.md)；四期及更早的设计意图在[archive/](./archive/)（[archive/PLAN_PHASE4.md](./archive/PLAN_PHASE4.md) 为四期）；功能与落地状态见 [README.md](../README.md)。

> **2026-11-24 生产切线之后**：线上运行根目录从 `~/.hermes` 换成 `~/.wados-maa`，调度从 Hermes cron 换成自带守护进程 `maa_daemon.py`（§1、§13），通知从 Discord 换成 Bark，操作入口是 Mac App（§12）和 iPhone App（§13）。
> §3、§5 里关于 Discord 计划卡、按钮、子区、聊天的描述，对应的代码还在，但线上没有 Discord token，这些出口全部跳过（#63），只作理解代码用。正文里剩下的 `~/.hermes/state/maa/…` 路径，现在一律读作 `~/.wados-maa/state/maa/…`（代码里叫 `HERMES_HOME` 的常量就是这个目录）。

## 0. 心智模型：仓库 ≠ 运行时
运行根目录（下称 `$WADOS_MAA_HOME`）按 `WADOS_MAA_HOME` → `HERMES_HOME` → `~/.wados-maa` 解析（`maa_common.resolve_home()`）。线上是 `~/.wados-maa`，开发副本是 `~/Developer/forks/maa-remote-devhome`。

| 仓库里的 | 部署后运行于 | 谁负责搬运 |
|---|---|---|
| `scripts/*.py` | `$WADOS_MAA_HOME/scripts/*.py` | `deploy.py --standalone` |
| `scripts/*.swift`、`daemon/wados-maa-launcher.swift` | `$WADOS_MAA_HOME/scripts/{ocrbox,winmove,barkcrypt,wados-maa-launcher}`（编译产物） | `deploy.py` 编译 |
| `state/*.json` | `$WADOS_MAA_HOME/state/maa/*.json` | `deploy.py`（种子/合并，见 §7） |
| `config/maa-cli/**` | `~/.config/maa-cli/**` | `deploy.py` |
| `daemon/*.plist`、`*.yml.tmpl`、`rescue.html` | `$WADOS_MAA_HOME/daemon/`（渲染好的 LaunchAgent、隧道配置、应急页） | `deploy.py`；plist 装进 `~/Library/LaunchAgents/` 是人工的一次性操作 |
| `daemon/init_daemon.py`、`rotate_tls.py`、`cutover.py` | 不部署，从仓库直接跑 | 人工 |
| `skills/games/maa-operator/SKILL.md` | 只在旧 Hermes 模式部署，切线后不用 | — |

**改了仓库不部署，线上行为不会有任何变化。** 直接手改 `~/.wados-maa/scripts/` 不会回流仓库，下次部署会被覆盖（覆盖前有备份）。例外：`~/.config/maa-cli/tasks/daily.toml` **每场执行前都被 `maa_daily.py`整个重写**（§4 第 7 步），仓库那份只是种子和阅读参考。

## 0.5 设备层：PlayCover
设备层是 PlayCover 原生明日方舟，全部在 `scripts/maa_playcover.py`（只用 stdlib）。旧文档里模拟器 / ADB / MaaTouch / `emulator_*` 的说法按这张表对应：

| 模拟器时期 | PlayCover |
|---|---|
| `open -a <emulator_app>` 开机，等 `sys.boot_completed` | `launch_game()`：`open -a <playcover_app_path>`（容器里那个 `.app`；**不用** `open -b`，游戏在跑时回 -10670）；`wait_for_game()` 轮询 MaaTools `SIZE`（`game_launch_timeout`，120s） |
| `pm path` 确认装了国服 | `verify_game_installed()`：可执行文件存在 + `App Settings/<bundle>.plist` 里 `maaTools = true` 且端口一致 |
| 等 `app_process` 安静 | `settle_game_window()`：见下文 |
| `emulator_is_online()` | `game_is_online()`：只看 `pgrep -f <可执行文件完整路径>`，预算 `game_probe_timeout` |
| `adb exec-out screencap -p` | `capture_geometry()`：MaaTools `SCRN`（RGBA，Retina 3840×2160 降采样到 1920 宽）；回 0 字节时退到 `screencapture -l<窗口号>`（要录屏权限，图里带标题栏，`top` 记它的高度） |
| `adb shell input tap x y` | `tap()`：1920×1080 游戏坐标按 `SIZE` 换算，MaaTools `TUCH` Began + Ended |
| `adb shell input keyevent 4` | **没有**。MaaCore 的 PlayTools 控制器也不支持 back |
| `maa closedown` + `pkill` + `adb disconnect` | `close_game()`：MaaTools `TERM`（实测 20 多秒退出）→ 等 `game_quit_timeout`（30s）→ `pkill -f <完整路径>` 兜底 → 复核。PlayCover 本体不动 |
| profile `adb_path` / `MaaTouch` | `preset = "PlayCover"`、`address = "127.0.0.1:1717"`、`touch_mode = "MacPlayTools"` |

**MaaTools 协议**（PlayCover MAA 分支 `4.0.0.maa`，`VERN` = 4）：连 `127.0.0.1:1717`，先发 `MAA\0` 收 `OKAY`；之后每条请求是 `>H` 长度（4 + 负载）+ 4 字节命令。`MaaTools.__enter__` 握手后先发 `VERN`，收 4 字节 `>I`（依据上游 `MaaToolsClient.swift`，大端），存进 `tools.version`，`maatools_ready()` 的说明带出 `v<版本>`。低于 `MIN_MAATOOLS_VERSION`（= 4；上游对 SIZE/SCRN/TUCH/TERM 只要求 ≥ 2、RECT/BNDL/BGR ≥ 3）、VERN 时对端断开、读超时，各报一条带处理办法的 `MaaToolsError` 并关 socket；`wait_for_game()` 照常轮询到超时。`SIZE` 回 `>HH`；`SCRN` 回 `>I` 长度 + RGBA；`TUCH` 负载 `>BHH`（phase 0 = Began、1 = Moved、3 = Ended，坐标是 `SIZE` 空间）；`TERM` 结束游戏。**两处还没真机验证**：VERN 回包格式（若每场报「读不到 VERN」/「对端关闭」或版本号离谱如 `v67108864`，先怀疑字节序）；抄作业看门狗在 MaaCore 连着时另开连接截图、点击能不能点（留意日志 `# watchdog:` 行）。

**截图为空 = 窗口不在台前**。`SCRN` 只在游戏窗口在某块屏的台前时有画面；最小化、隐藏、被台前调度收进侧边栏时回0 字节，MaaCore 只会刷 `ScreencapFailed`。游戏**不需要是前台 App**。运行环境给它一块 BetterDisplay 虚拟屏（`MAA-Game`，1920×1080，不论显示器开没开都在 x=1920）独占；台前调度开着时，任何别的窗口开到这块屏上都会把游戏挤走。窗口一旦在 `MAA-Game` 上，主屏怎么切前台都不影响截图。

**窗口恢复让游戏直接开在虚拟屏上**：游戏默认按「新开窗口」启动，总开在当前主屏正中，无视存着的位置（启动前挪鼠标没用）。打开 `NSQuitAlwaysKeepsWindows` 后按「恢复上次的窗口」启动，回到上次 `close_game()` 时的位置。所以 `launch_game()` 在游戏**没在跑**时先调 `ensure_window_restore()`：`defaults read` 游戏容器的偏好设置域（`game_prefs_domain()`），不是 1 就写 `-bool true`；失败只打一行 stderr。游戏在跑时不碰设置。显示器关着时的恢复还没实测。来由见 [incidents/2026-11-05-pm-screencap-failed.md](./incidents/2026-11-05-pm-screencap-failed.md)。

**挪屏是兜底**：`move_to_game_display()` 用 JXA 读 `NSScreen` 找 `game_display_name`（默认 `MAA-Game`）的范围，窗口没有**整个**落在里面就调 `$WADOS_MAA_HOME/scripts/winmove <pid> <x> <y>`（`scripts/winmove.swift`，`deploy.py` 编译，AX `kAXPositionAttribute`）挪过去居中。winmove 要调用方有**辅助功能**权限（旧线上是 Hermes gateway 那个 Python，新后端是 `wados-maa-launcher`，要在系统设置里单独授权），没有就退出码 3、只记警告。System Events / JXA 直接设 AX 位置都不行（前者要自动化权限，后者 `AXValueCreate` 回 -25200）。

**侧边栏缩略图**：台前调度把窗口缩成约 144×149 的缩略图时 `kCGWindowIsOnscreen` 仍是真，`SCRN` 却回 0 字节；进程另挂着几条不在屏的 1920×30 横条和一个 500×500 空窗口。`game_window()` 只滤两边都 < 100 的横条；`window_shelved()`（在屏且宽 < `MIN_GAME_WIDTH`）认缩略图；`window_usable()` = 在屏且不是缩略图。`settle_game_window()` 不挪缩略图，激活后每 0.5 秒看一次、最多 5 秒，一回到屏上就马上挪到虚拟屏并居中；摆不回来时告警里带窗口尺寸、位置、状态和各块屏的位置（`describe_window()`）。

**跑场期间关掉台前调度**（2026-11-09 起，#62）：日常和抄作业开游戏前 `pause_stage_manager()` 把台前调度临时关掉、跑完还原（§4「恢复策略」）。真机确认有效之前，下面的救法照留。

**截不到时怎么救**（`settle_game_window()` 逐级升级，救回来就停；spike 见 `docs/PLAN_SHELVED_WINDOW.md`、[incidents/2026-11-08-am-window-shelved.md](./incidents/2026-11-08-am-window-shelved.md)）：

1. 激活（`launch_game()`）；
2. 切走再切回：`front_finder()` 用 `winmove --front <访达 pid>` 把访达设成前台再激活游戏（不用 `open -b com.apple.finder`，访达没窗口时会新开一个、可能正好开在 MAA-Game 上）。这一级是从 spike 推断的，没有实测；
3. 重启游戏（仅 `allow_restart=True`）：`restart_game()`（`close_game()` → `launch_game()` → `wait_for_game()`，全库**只有这一份**，掉线重开也用它）。只在一个键都没点过时放行：开跑前、`run_maa_resilient()` 重开前。

`trail` 参数收集每一步做了什么、窗口变成什么样（`摆窗：<步骤> → <尺寸 @ 位置 状态>（耗时）`），只写进运行日志；开跑前那份经 `run_maa_resilient(log_preamble=…)` 写在日志开头。三道防线：

1. 开跑前 `settle_game_window(allow_restart=True)`（含挪屏）；
2. `run_maa()` 每 5 秒看日志，`ScreencapFailed` 变多就再 `settle_game_window()`（`SCREENCAP_SETTLE_INTERVAL` = 30s 节流；跑到一半**不**重启）；
3. `run_maa_resilient()` 认出连接阶段就失败才重开（§4「恢复策略」）。

**没用 MacSCK**：MaaCore 的 `config = "MacSCK"` 在 maa-cli 里会撞 `CGS_REQUIRE_INIT` 断言（要 DYLD 注入先调 `CGMainDisplayID()`的 shim），还要给 maa 进程开录屏权限。虚拟屏 + `SCRN` 更简单。

## 1. 全链路总图
```
   wados-maa-daemon（LaunchAgent io.github.ffkiyo7.wados-maa.daemon，经 wados-maa-launcher 启动）
   ├── 内置调度器（北京时间，每 10 秒一 tick）          ├── HTTPS + SSE API（:18170，§13）
   │   activity_watch  每 15 分钟 maa_activity_watch.py │     iPhone App：局域网直连 / Cloudflare Tunnel
   │   depot           04:30 maa_depot.py（默认关）      │     /rescue 应急停止页
   │   plan_card_am/pm 场前 10 分钟 maa_plan_card.py <场>│     写操作 → 子进程 maa_action.py
   │   daily_am/pm     开跑时刻 maa_daily.py <场>        │
   └── 证书到期巡检（Bark 告警）                          └── Mac App：直接子进程调 maa_action.py（§12）
                        │                                        │ 只写 plan.json / defaults.json / config.json / 派发
                        ▼                                        ▼
   ~/.wados-maa/state/maa/{config,defaults,plan,last_run}.json + run.lock + runs/
                        │  effective_plan(at, phase) = defaults ⊕ 当天 sessions.<场次>
                        ▼
   maa_daily.py ── flock ── 探游戏进程 ── 快照 runs/<run_id>.json ── 开游戏
        └─ 渲染 daily.toml ─ maa run daily ─ 写 runs/<run_id>.progress.json
                                 └─ 截图 ─ MaaTools TERM / pkill ─ 战报 runs/<run_id>-report.json ─ Bark
```

定时任务全是守护进程拉起的**短命子进程**（`start_new_session=True`），重启守护进程不会杀掉正在跑的场次。补跑、超时、热重载的规则见 `maa_daemon.py` 开头的说明和 §13。

## 2. 组件清单
| 文件 | 角色 | 触发方式 | 典型耗时 |
|---|---|---|---|
| `scripts/maa_common.py` | 公共层：时区、三把锁、原子写、Discord REST/multipart、清理、`prune_button_registry`、场次级计划求值（`plan_sessions` / `effective_plan`）、「你在玩」跳过的统一出口 `report_game_busy` | 被 import | — |
| `scripts/maa_plan_card.py` | 早晚两张计划卡 + 抄作业卡的渲染；早场卡先跟上游更新；刷新活动关；写按钮登记；清理旧子区/卡片/产物 | 调度器，早晚场前 10 分钟；抄作业卡由 `maa_action.py` 调 | 早场数秒～5 分钟，晚场数秒 |
| `scripts/maa_depot.py` | 每周仓库对表；只接纳 `done=true` 的完整 Depot，算掉落增量与消耗率；森空岛不可用时顺手跑 `OperBox` | 调度器 04:30（`depot_enabled`，默认关），满 7 天才执行 | 到期数分钟；未到期不开游戏 |
| `scripts/maa_activity_watch.py` | 轮询活动；排目标集合、按理智排一轮 `(关, 模式)`、发「已排程」卡、到点派 `run-batch` | 调度器每 15 分钟 | 通常 <1s；现搜作业每关 5~20s（每 tick ≤6 关） |
| `scripts/maa_daily.py` | 执行主体：开游戏 → maa-cli → 流式进度 → 截图 → 关游戏 → 战报 | 调度器，早晚场开跑时刻；`now <token>` | 10～50 分钟 |
| `scripts/maa_action.py` | **唯一**状态变更与派发入口（Mac App、iPhone App 经 API、终端；旧时还有 Discord 按钮和聊天） | Mac App 子进程；`maa_api` 子进程；终端 | < 1s（硬性要求） |
| `scripts/maa_copilot.py` | 抄作业领域层：关卡索引、prts 客户端、匹配打分、目标集合、本地记账、已排程卡 | 被 import | — |
| `scripts/maa_copilot_worker.py` | 抄作业后台：`search <token>` 搜一关并排程；`run-batch <token>` 串行连抄一轮 | 仅由 `maa_action` / watcher 派发 | 搜索 5~20s；一关 8~15 分钟 |
| `scripts/maa_farming.py` | 素材权重领域层：一图流 / 企鹅抓取（缓存 `state/maa/farming/`）+ 三项加权分 + 候选关集合（D5）+ `stage_ap_cost()` | 被 plan_card / watcher import | 有缓存 <0.5s；冷缓存 3~10s |
| `scripts/maa_clearing.py` | 作业链领域层：条目形态（`#raid`）、导航键闸门、理智预算与排轮、退避记账、通关判据 | 被 import | — |
| `scripts/maa_gamedata.py` | ArknightsGameData 地形（解锁链、区域名、EX 理智），一天抓一次，缓存 `copilot/gamedata.json` | watcher 刷新 | — |
| `scripts/maa_skland.py` | 森空岛：HMAC 签名、grant→cred、练度与理智、`link`（stdin 收 token）、每日体检 | 本机终端；见 §5.5 | 秒级 |
| `scripts/maa_upstream.py` | **上游更新的唯一实现**（#60）：持 `run.lock` 跑 maa-cli / MaaCore / MaaResource 三步，写 `upstream.json`；离线判定和开跑前硬拒 | 早场计划卡；`upstream update` 的 worker | 更新几分钟；`status` < 2s |
| `scripts/maa_schedule.py` | 早晚场时间、Depot 开关 ↔ 内置调度器：改 `session_schedule` / `daemon.json` 后发 `SIGHUP` + 写 `daemon/reload.flag` 让守护进程热重载；`schedule_report()` 合并 `daemon/scheduler.json` 给 App 看（K6） | `maa_action schedule *` | < 1s |
| `scripts/maa_daemon.py` | **唯一常驻进程**：6 条内置定时任务（补跑、超时、防重入）、起 HTTPS API、证书到期巡检（§13） | LaunchAgent `io.github.ffkiyo7.wados-maa.daemon` | 常驻 |
| `scripts/maa_api.py` | HTTPS + SSE 接口：Bearer Token 分域鉴权、来源 IP 白名单、快照 / 历史 / 截图 / 日志，写操作转调 `maa_action.py`（§13） | 被 `maa_daemon` import | 读 < 1s |
| `scripts/maa_tls.py` | 自签证书（OpenSSL 3 ECDSA P-256）、SPKI 指纹、Token 哈希、到期巡检、终端二维码 | 被 daemon / `daemon/*.py` import | — |
| `scripts/maa_notify.py` | 统一通知出口：Bark + `barkcrypt` AES-GCM 加密；缺配置、失败一律只记日志（#63） | 被日常 / 抄作业 / 活动监控 / 证书巡检调 | 秒级 |
| `scripts/maa_settings.py` | 可从外面改的配置项白名单和校验（`FIELDS`，K3 / K5） | `maa_action config *` | < 1s |
| `scripts/maa_playcover.py` | **设备层**（§0.5） | 被日常 / Depot / 抄作业 import | — |
| `scripts/ocrbox.swift` / `winmove.swift` / `barkcrypt.swift` | Vision OCR（watchdog、主页校验）/ AX 挪窗口 / Bark 加密，`deploy.py` 编译到 `$WADOS_MAA_HOME/scripts/` | 被调用 | <1s |
| `daemon/wados-maa-launcher.swift` | 守护进程的固定签名入口，辅助功能权限授给它（S0-4 方案 B） | LaunchAgent 的 `ProgramArguments[0]` | — |
| `daemon/init_daemon.py` / `rotate_tls.py` / `cutover.py` | 一次性运维：生成证书、Token、配对二维码 / 证书轮换（`--stage` 预生成、`--activate` 切换并重载）/ 生产切线与 `--rollback` | 人工，从仓库直接跑 | 秒级 |
| `deploy.py` | 幂等部署 + 备份 + 编译；`--standalone` 部署到 `~/.wados-maa`（现行），不带时是旧 Hermes 模式（§7） | 人工 | 秒级 |
| `skills/games/maa-operator/SKILL.md` | 旧 Hermes 时期约束 LLM 只能走 `maa_action.py` 的护栏；切线后不部署 | — | — |
| `tests/test_*.py` | stdlib 单测，按领域分文件；共用桩 `tests/_helpers.py`，隔离层 `tests/_isolation.py`（§9） | 人工 / CI | 约 6s |
| `.github/workflows/tests.yml` | CI：macOS 上 3.11 / 3.12 × 两种 HOME 跑单测 + ruff + pyright（§9） | push / PR | 几分钟 |

## 3. 链路一：两张计划卡（`maa_plan_card.py`，早晚场前 10 分钟，默认 07:50 / 21:50）
**一天两张卡，一张管一场**（D1）。场次来自 argv（守护进程传 `am` / `pm`），也认工作目录名（旧 Hermes cron 用 `--workdir …/maa/{am,pm}` 传）；都没有时按小时兜底（`select_phase()`，`< 14 点` → `am`）。切线后没有 Discord，「发卡」那几步跳过，定关、上游更新、活动探测、清理照做（#40）。`main(argv)` 严格按顺序：

1. **`check_and_update_upstream()`，只有早场卡跑**：调 `maa_upstream.run_update(config, "plan_card")`，计划卡只管失败时发红卡（#60，GUI 的「更新」按钮走同一个函数）。
   - 持 `run.lock`（持有者 `update`）。抢不到记「跳过：<谁>正在用 maa-cli」，不发红卡；拖过 08:00 时日常会等它（K17，上限 `update_wait_minutes`，默认 15）。
   - 三步：`brew outdated --json=v2` / `brew upgrade` 跟随 maa-cli；`maa update --batch`；`maa hot-update --batch`（超时 180s / 300s / 300s）。
     **brew 只看 JSON，不看退出码**（点名查一个 formula 时有新版退出码就是 1，K19）。hot-update 只在 Core 那步成功后跑（[incidents/2026-08-26-maaresource-out-of-sync.md](./incidents/2026-08-26-maaresource-out-of-sync.md)）。
   - **必须保留本机代理**（`maa_subprocess_env(..., keep_proxy=True)`）；环境里没代理时用 `config.upstream_proxy` 补，PATH 补 `/opt/homebrew/bin`。hot-update 认不认代理取决于 `cli.toml` 的 `backend`（必须是 `git`，§11 第 18 条）。
   - 分步结果写 `state/maa/upstream.json`（§12.3），版本写回 `config.json`，摘要进早场卡「上游更新」字段。失败发红色 Embed，`main()` 末尾 `raise`，调度器把这次记成失败。
   - **晚场卡整步跳过**（`update is None`），所以末尾的 `raise` 要判 `update is not None`（#40）。
2. **`refresh_activity_stages()`**：跑 `maa activity Official`，解析 `TO-9` 形的活动关写回 `config.json`；公告里有「资源收集」则置 `all_supply_stages_open=true`。
3. **重新 `load_config()`**：卡片从落盘后的真值渲染。
4. **算本场默认关**：`current_farming_result(effective_plan(phase=phase), config)` → `apply_auto_stage(farming, phase)`，写 `plan.json` 的 `sessions.<phase>`。
5. **`build_components(plan, config, phase)`**：**恰好两行**——关卡下拉 + 「跳过本场 / 恢复本场」按钮，同时产出登记表条目。
6. **写按钮登记**：在 `state_lock()` 里**先删所有 `hermes:btn:maa:` 前缀的 key，再 merge 写回** `~/.hermes/state/agent-book/buttons.json`（全局共享，**绝不能整体覆盖**）。21:50 那趟顺手废掉早场卡的控件是预期行为。
7. `cleanup_old_threads()` 删 >24h 的子区；`cleanup_run_files()` 删 >14 天的 `runs/` 产物。
8. `retire_old_plan_cards()`：扫最近 100 条消息，标题以 `🌱 MAA 今日计划` 开头且仍带 components 的旧卡 `PATCH components: []`。
9. 发新卡；之后跑森空岛每日体检（#56）。

**卡片字段**：刷什么（本场的关 + 归属 `（按材料缺口自动选）` / `（你手动选的）`，来自 `today_stage_source(phase)`）、为什么（缺口理由或降级说明）、本场跳过（并写明另一场与手动开跑不受影响）、当前活动关、活动截止（`activity_deadline_text()`，读不出来整行不显示）、理智规则 / 每日剿灭（固定文案）、上游更新（**只有早场卡有**）。

`activity_deadlines()` 读 `~/Library/Caches/com.loong.maa/StageActivityV2.json` 的`Official.sideStoryStage.<前缀>.Activity.{Tip,UtcExpireTime,TimeZone}`。字段名带 `Utc` 但**实际是 `TimeZone` 时区的本地时间**，要按 `TimeZone` 构造 tzinfo 再换北京时间。文件不存在 / JSON 坏 / 字段缺失**一律返回空表、绝不抛**（D-2）。路径可用 `config.maa_activity_cache` 覆盖。

### 抄作业卡（`copilot card`）
渲染在 `copilot_card_view()`，派发在 `maa_action.copilot_card()`（聊天「抄作业」→ `copilot card`，只读本地 + 一次 Discord POST，同步做完）：`copilot_card_stages()` 取当期活动 `current_activity_key()` 的整个前缀（无活动 → 当天资源本 + 1-7）× `stage_drops()` 主掉落 × `copilot_nav_checker()` × 本地关卡索引；一览列全部候选（✅已通 / 🔁突袭待补 / ⏳排程 / 🚫练度不满足 / ⛔无导航）；收旧卡（`retire_discord_components(上一张 message_id)` → 删旧登记）→ `state_lock()` 下 merge 写 `hermes:btn:maa-copilot:card:stage-select` → 发卡 → 新 message_id 写进 `copilot/card.json`（0600）。选中一关 → `select_args` → `["copilot","find",<关卡>]` → 搜索 worker → 选中即执行（§5.5）。

**「当期活动」以 MaaCore 活动缓存为准**（`maa_plan_card.current_activity_key()`）：读 `StageActivityV2.json` 里**此刻开放**的 SideStory，key 拼法与 watcher 的 `activity_target()` 一致（`Tip|前缀`；复刻 `SSReopen` 的前缀从它的关卡里取；同时开放几期取开始最晚的）；缓存读不出来才退回 `activity_watch.json` 的 `activity_key`。抄作业卡、`copilot stages`、`copilot find` / `preview` / `mark-cleared` / `unmark`都走它；watch 的逐关失败记录（`stage_state`）只在 watch 的 key 与当期一致时才用。watcher 与 worker 开打前仍按 `maa activity` 认活动。来由见 [incidents/2026-11-07-paused-watch-stale-activity.md](./incidents/2026-11-07-paused-watch-stale-activity.md)。

按钮前缀 `hermes:btn:maa-copilot:card:` 躲开计划卡清扫和 `prune_expired_searches()`，所以 **`card.json` 绝不能放进 `searches/`**（#14b）。

### 关卡下拉
`_stage_choices()` 顺序拼接，上限 25 项：`上次作战关卡`（空串 → 沿用游戏内上次关卡）→ `1-7` → **当天开放的资源本**（`current_supply_choices()` 用 `(now - 4h).weekday()` 算游戏日，按 `SUPPLY_STAGES` 星期表过滤；`all_supply_stages_open` 为真时全给）→ `config.activity_stages` → 当前计划关不在以上任何一项时插到第 2 位。

**下拉值不是关卡名**：选项 `value` 是不透明的 `choice:N`，真正的 argv 存在登记项的 `select_args` 里，例如 `hermes:btn:maa:am:stage-select` 的 `select_args = {"choice:0": ["plan","set-stage","","am"], "choice:1": ["plan","set-stage","1-7","am"], …}`（`kind: "exec"`，`script: "maa_action.py"`）。

adapter 补丁只做精确查表，未知值、多值一律拒（#8，`test_adapter_patch_dispatches_only_registered_select_values`）。场次写死在 argv 末尾；custom_id 也带场次（`hermes:btn:maa:{phase}:stage-select` / `:skip` / `:unskip`），点到没收干净的旧卡只会得到「未登记」。现在所有登记项都是 `kind: "exec"`。

### 材料缺口 → 自动定关
缺口是**后台固定计算**的结果，不是下拉（[incidents/2026-09-08-farming-select-removed.md](./incidents/2026-09-08-farming-select-removed.md)）。算法在 `scripts/maa_farming.py`（纯函数 + 抓取层分开），`maa_plan_card` 只剩 `farming_recommendations` / `auto_stage` / `farming_note` 三个薄封装。

数据流：一图流 `matrix.json`（ETag）/ `stage/info`（1h）/ `item/v7/value`（24h）/ `store/activity`（可选）经 `load_market_data()` 缓存到 `state/maa/farming/`（企鹅 `result/matrix`、`zones`+`stages` 作后备）；`stages.json` + `item_index.json` → `stage_drops()` → `material_stage_candidates()`（手工表在前，#38）；`depot.json` → `consumption_rates_window(≥4 周)`；`StageActivityV2` + 导航键 → `candidate_stages()`（D5）→ `farming_result()` → `auto_stage()` / `drops_cap()` / `fallback_stage()` → `apply_auto_stage()` 写 `sessions.<phase>` 的 `stage` / `stage_source=auto` / `farming_drops` / `farming_fallback_stage`。

**候选关集合**（`candidate_stages()`，#42）：活动进行中（`StageActivityV2` 截止未过；读不到日历才看 `activity_stages` 非空）→ **只有活动关**（`config.activity_stages ∩ 上游导航键`，与自动抄作业同一个闸门）；活动结束 / 无活动 → `1-7` + 当天开放资源本；活动期但没有一个带导航键的活动关 → 退回后者并在卡上写明。判「活动还在」**优先看日历**。

**三项加权分**（`config.farming_weights`，默认 `0.5 / 0.3 / 0.2`，和为任意值都归一）：

| 项 | 口径 | 数据 |
|---|---|---|
| ① 稀缺 | `best_perm / best_now ≥ farming_activity_edge`（1.3）才算活动关明显更优；下次可刷日 = 首发 start + `farming_rerun_days`（378），已复刻按 `end + 2 年`；分值 = `clamp(剩余天数 / farming_scarcity_horizon_days, 0, 1)`。只管时间维度 | `stage/info` + `matrix.json` |
| ② 缺口 | 件数 = `farming_target_days`（30）天用量 − 库存估算；价值 = 件数 × `itemValue`（1 个晶体电子单元 ≈ 302 理智）；分值 = 价值 / 本场可用理智，clamp 到 1 | Depot + `item/v7/value` |
| ③ 效率 | 候选集内该材料最优「件/理智」÷ 全游戏历史最优 | `matrix.json` + `apCost` |

掉率过滤（抄一图流前端口径）：`times < farming_min_samples`（300）不计；matrix 行 `end` 非空且早于 now 不计。`ap_per_item = apCost / (quantity / times)`。数据源的固定事实（都有单测）：`stage/info` 的 `end` **永不为 null**，常驻用哨兵 `4070880000000`，判常驻靠 `stageType ∈ {MAIN, ACT_PERM}` 或end 在 10 年后；企鹅 `/zones` 相反，`closeTime: null` 才是常驻，后备转换时统一成哨兵。`item/v7/value` 有 16 条 `itemValue == null`（活动代币、理智小样），不参与缺口计价。`matrix.json` 的 `max-age=7200` 不可信（实测约 10 分钟刷一次），用 ETag 条件请求。

**降级路径**（`degraded_reasons`，全部不抛、全部在卡上可见，#32）：抓取失败用缓存，缓存也没有当空数据；冷启动（`consumption_history`不足 2 次对表）或 ≥4 周零消耗 → 缺口项退 `farming_manual_weights`，**仍然自动定关但不写 drops 上限**；掉落表与手工表都查不到 → 不推荐，**永不猜关**。同分先比「理智/件」再比材料名，保证确定性。

`stage_source` 是「这关是谁定的」的唯一依据，必须留在 `maa_common.PLAN_SESSION_FIELDS` 白名单；写它的只有 `apply_auto_stage()`（`auto`）与`maa_action.set_stage()`（`discord`）。手动选关时 `farming_drops` / `farming_fallback_stage` 被清空。

## 3.5 链路一半：活动上线自动抄作业（`maa_activity_watch.py`）
**静默执行 + 事后汇报**（D6 / D11）。每 15 分钟一 tick，`activity_watch.lock` 防重叠。

```
maa activity Official ── activity_snapshot() ── activity_target() ── key = "标题|前缀"
   ├─ 没活动 → 连续 2 次空快照才 idle（#20），作废未打完的一轮并发通知
   ├─ key 变了 → 归档旧记账 → 新开账本 → 清 stage_state → 发「🆕 已上线」
   ├─ _refresh_gamedata()（一天一次；缺当期关时一小时一次），和自动作业解耦：暂停 / 停排 / 一轮在打都照刷
   ├─ 已有 batch_token
   │    executing → 记 running；queued → 20 分钟失联则放回 scheduled；
   │    scheduled → 查派发闸门，通过就 `run-batch`；终态 → 清 token，按最新记账重排
   └─ 排新一轮
        collect_targets()  索引里前缀相同的全部关 ∩ 上游导航键
                           − 已通关(记账 ∪ zone 全清) − 教学关 − zone 未开 − daily_cap − 退避中
        build_round()      plan_round(条目, 预算, 理智查表) → 现搜作业（≤6 关/tick）
                           排得满 → 现在打；排不满 → 只排第一条 + `sanity_preflight().ready_at`
        写 searches/<token>.json（scheduled）→ publish_round() 发「已排程」卡
        dispatch_blocker()  到点？blackout？Depot 窗口？时间预算？run.lock？游戏在跑？
```

`copilot/gamedata.json` 也是抄作业页和手动抄作业判「能不能导航」的依据，所以**活动监控要一直开着**；不想让它开游戏用「暂停自动作业」（`copilot auto off`），不要停掉这条定时任务。暂停时换活动的通知会写明不会自动排轮。

**「空窗」还是「格式变了」只有一个判据** `is_side_story_heading()`（闸门与 `parse_activity_events()` 共用，#19）：有活动关分区标题行 → 正常解析；没有标题行但有其它认识的 `Opening …` 分区 → 查询成功的空窗；标题文本出现却不是完整一行、或一个认识的分区都没有 → 格式已变，抛异常。

**目标集合的排除理由**（`collect_targets()` 的 `excluded`，卡片分开显示）：

| 理由 | 含义 | 会不会自己变好 |
|---|---|---|
| `no_nav` | 上游没这关的导航键（D8 / #37） | 不会，热更新带来才会 |
| `not_indexed` | 有导航键但本地 Tile-Pos 索引没有 | 热更新后会 |
| `zone_unopened` | 森空岛该活动所有 zone `totalStage == 0`（D9） | 会，不记失败 |
| `cleared` | 记账齐全或 zone 全清（D10） | — |
| `daily_cap` | 今天这个 `(关, 模式)` 失败 / `unknown` 已达 `auto_copilot_max_attempts_per_day` | 次日归零 |
| `backoff` | 搜过、练度不满足 / 暂无作业，未到 `activity_search_retry_minutes` | 练度或上游变了就会 |

`backoff` 管「隔多久再试」，`daily_cap` 管「一天试几次」，两把尺子缺一不可（[incidents/2026-09-09-copilot-log-marker-flush.md](./incidents/2026-09-09-copilot-log-marker-flush.md)）。

**顺序**：数字关升序 → EX → S，每关先 `normal` 后 `raid`（`activity_stage_codes()` + `required_modes()`）；认不出形状的排最后，不静默丢弃。**森空岛刷新**：只在「集合里有未执行的关」的 tick 刷一次，其余用缓存 + 6 分钟/点估算（`estimated_sanity()`）；worker **每关**开打前再强制刷新。

**状态**：`activity_watch.json` 是粗状态——`idle` / `searching` / `waiting`（排不出条目）/ `done`（没有未打的关）/ `scheduled` / `dispatched` / `running` / `paused` / `blocked`（森空岛读不到或今天开打前环境故障已达上限，原因在 `blocked_reason`，#55）。一轮的细状态在`searches/<token>.json`：`scheduled → queued → executing → executed / execution_failed`，另有 `canceled` / `superseded`。`queued` 超 20 分钟且`run.lock` 空闲 = worker 碰设备前失联，放回 `scheduled`；`executing` 起绝不自动重排（没法证明理智没花掉）。

关卡索引同时扫 MaaCore 自带 resource 与 `MaaResource/resource` 热更新覆盖层，基础先读、覆盖层后读。

## 4. 链路二：执行一场日常（`maa_daily.py`）
`execute(phase)`：

0. **通知出口** — `discord_outlet(config)` 取 `(token, channel_id)`：没配频道、读不到 `.env` 都返回两个空串、打一行日志，**不抛**。Discord 只是出口之一，下面所有发帖都走 `notify()` / `open_thread()`：没有出口就跳过，网络 / HTTP / token 失效只记一行 stderr，一场照常跑完（#63）。开发副本（没有 `.env`）的 `run local` 因此也能跑。现在线上真正的出口是 Bark：开跑、结束、告警各处另调 `maa_notify.notify()`，同样永不抛。

1. **定场次** — `select_phase()`：argv（`am|pm|now`）> 工作目录名（旧 Hermes cron 的 `--workdir …/maa/am` → `am`）> 按北京时间小时猜。守护进程总是传 argv。
2. **抢锁** — `run_lock(blocking=False)`。持有者是 `update` 时先等（上限 `update_wait_minutes`，等掉的时间从 `maa_run_timeout` 里扣，K17）；否则不碰持锁任务的顶层状态，只追加 `last_lock_conflict_*`，发红色告警（写明谁占着）并返回失败（#23）。
3. 清理 >14 天产物；把**本场实际使用的计划**快照到 `runs/<date>-<phase>.json`（之后改 `plan.json` 不影响本场，#10）；`last_run.json` 用 `merge_last_run(..., new_run=True)` 置 `status=running` 并清掉上一场的字段（§6）。
4. `plan.skip` 为真**且 `phase != "now"`** → 灰色「已跳过」Embed，`status=skipped`，不开游戏。skip 按场次（D2，#5d）；手动场照跑。
4.5. **探游戏（只对 `am`/`pm`）** — `maa_playcover.game_is_online()` 命中即「用户正在玩」，`report_game_busy()` 发灰卡、写`status=skipped` / `skip_reason=game_busy`，不开游戏（任何失败路径都会 `close_game()`，等于把用户踢出游戏）。探测预算 5s、失败按离线照常执行（#24）。实现只有一份，日常、抄作业 `run-batch`、Depot 共用（D18）。别和开游戏**之后**的 `settle_game_window()` 混淆。
5. **预检 → 开游戏** — `require_executable` → `verify_game_installed()` → `launch_game()` → `wait_for_game()`（120s）。任一步失败（`session_open` 还是 False）记 `startup_error`，`send_direct_failure()` 尽力在频道发红色告警。开跑前还过 `maa_upstream.hard_block()`（#60）。
6. **发开跑消息 → 建子区 → 发进度占位消息**（`open_thread()`，永不抛），建成了才把 thread_id 记进 `last_run.threads`。任何一步失败 `thread_id` / 进度消息 id 就是空串：之后的进度 PATCH 全部跳过，战报照样往频道发（发得出去的话），`last_run.thread_id` 保持 `null`（#63）。
7. **渲染 `daily.toml`** — `render_daily_toml(plan, config)` 渲染本场快照，`atomic_write_text` 覆盖 `~/.config/maa-cli/tasks/daily.toml`。任务链固定：

   `StartUp → [当日第一场 Annihilation] → Fight(缺口第一名) → [Fight(第二名)] → Infrast → Recruit → Mall → Award → Custom(Home)`

   | 块 | 名字（`FARMING_TASK_NAMES`） | 关 | `drops` |
   |---|---|---|---|
   | 第一个 | `刷理智` | `plan["stage"]` | `plan["farming_drops"]` = `{itemId: 还差多少个}`，刷够即停 |
   | 第二个 | `刷理智·续` | `plan["farming_fallback_stage"]` | 没有，打到理智不足 |

   - 第二块**只在第一块设了 `drops` 时才渲染**（冷启动、缺口 ≤ 0、手动选关时退回一个块打到底）。三个 Fight 块（剿灭 + 两个刷理智）都走`_fight_block()`，`medicine = 0 / stone = 0 / series = 0` 只写一次（#1~#3），掉落上报也只写一次：`report_to_penguin` / `report_to_yituliu`由 `config.report_drops` 总控、两个 ID 写空串（匿名）；关掉时这四行一行都不写。理智让路（`plan["farming"] = False`）一次摘掉两个块。
   - 战报里第二块的 `TASK_STEPS` key 是 **`Fight2`**（共用 `Fight` 会让没跑过的第二块被通配判成完成）；掉落回写用 `farming_sections()` 合并两段（#44）。
   - `StartUp` 复用 MaaCore 首登处理链（签到 / 配给弹窗）。剿灭是第二个 `Fight(stage = "Annihilation")`：每个国服游戏日（04:00 刷新）只进一次，`last_run.annihilation_game_day` 记账；MaaCore 从右上角待办进当期剿灭，自动「全权委托」，满 1800 合成玉就停。开跑前 `attach_annihilation()`看森空岛快照 `roster.annihilation_weekly`（`player/info` 的 `campaign.reward`）：**本周**（周一 04:00，`cn_game_week()`）已满就不渲染剿灭块、战报写「⏭️ 本周剿灭合成玉已满（1800/1800），本场跳过」、不记 `annihilation_game_day`；快照旧 / 缺字段 / 坏掉一律照常进。
   - `Award` 固定 `award = true`、`mail = true`；`orundum` / `mining` / `specialaccess` 读 `award_*`（默认 false）。`Mall` 的 `visit_friends` / `shopping` 固定开、`credit_fight` 固定关（要借助战，#15 的精神）；`buy_first` / `blacklist` / `reserve_max_credit` / `only_buy_discount` 读 `mall_*`。列表过 `_mall_item_list()` 的 `SAFE_MALL_ITEM_RE`，不合规**静默丢弃**；布尔走 `_toml_bool()`（#51）。
   - 最后的 `Custom` 的 `task_names` **每项带 `Home@` 前缀**（`HOME_TASK_NAMES` = `["Home@QuickSwitch@ToHome#next", "Home@ReturnButtons#next"]`，手工展开，因为顶层 `task_names` 原样交给 `ProcessTask`）：`#back` 取第一个 `@` 之前的前缀，回到 `Home`（`action = Stop`）认出主页即成功（#5c，[incidents/2026-08-02-home-quickswitch-custom-error.md](./incidents/2026-08-02-home-quickswitch-custom-error.md)）。
   - `Infrast` 固定 `mode = 0`，MaaCore 按实时识别的干员、技能、心情排七类设施；不用无人机、不补源石碎片订单、宿舍不刷信赖。
     **链里没有 CloseDown**。`profiles/default.toml` 开用户资源层，`resource/tasks/tasks.json` 完整覆盖 `InfrastDormDoubleConfirmButton`（用 `PopupConfirm.png` 认红色确认条、点右侧对勾）。**这条覆盖还没有 run 级实测**；MaaCore 在**进程启动时**一次性载入 `resource/`。再遇到卡确认条先抓截图比对模板与位置，不要改 `roi` 猜（[incidents/2026-09-01-infrast-dorm-confirm-unverified.md](./incidents/2026-09-01-infrast-dorm-confirm-unverified.md)）。
8. **`run_maa_resilient()` → `run_maa()`** — `maa run daily -v --batch`，注入 `MAA_CONFIG_DIR` / `MAA_LOG_PREFIX=Never` /（可选）剔除代理。两个 reader 线程把 stdout+stderr tee 到 `runs/<date>-<phase>.log`；每 5 秒把解析后的中文状态 PATCH 进子区消息，内容无变化不发，Discord 异常一律吞掉；同一个循环里用同一套解析写 `runs/<date>-<phase>.progress.json`（`RunProgressFile`，§12.3，#65），恢复动作（重试、重启、摆窗、补跑、改刷后备关、台前调度、超时、停下）各记一条 `notes`。超时 `maa_run_timeout`（3000s，给 Hermes 外层 3600s 留 10 分钟）→ terminate/kill，返回码 **124**；`KeyboardInterrupt` → **130**。重开与补跑见下。
   **停下（`run cancel`，#64）**：`execute()` 外面套 `interrupt_once()`，只有第一次 SIGINT 变成 `KeyboardInterrupt`，之后的忽略（不打断收尾）。落在 `maa run` 里 → 130；落在开游戏 / 等游戏 / 重开前等待 / 截图 → 主流程的 `except KeyboardInterrupt` 记 130。两种都不补跑、不截图，照常关游戏（开游戏半路上也关）、还原台前调度、发「⏹️ 已停止」战报，`last_run.status = cancelled`，返回 130。落在主流程之外（拿锁之后、开游戏之前，或收尾时）由外层补写 `cancelled`。
9. **截图 + 主页校验**（`capture_home_screenshot()`）— 等 `home_screenshot_delay` 秒 → `maa_playcover.capture_screenshot()` → chmod 600 → `ocrbox`核对 `HOME_MARKERS`（终端/编队/采购中心/公开招募/基建/好友/档案/SANITY）命中 ≥ `HOME_MARKER_MIN`（4），不在就重截，最多 `home_screenshot_attempts`（3）次。截图失败不阻断；判定 False 让整场判红并在备注写命中数；无法判定（ocrbox 没部署 / 崩了）记 `None`、不改结论，写 `last_run.home_verify_detail`。这条闸门只挂日常链，抄作业直接 `capture_screenshot()`（#5b）。
10. **`close_game()`**（在 `finally` 里，只要 `launch_game()` 被调过）：`TERM` → 等退出 → `pkill -f <完整路径>` 兜底 → 首字符加方括号的同一模式 `pgrep -f` 复核。
11. **判定与上报** — `ok = (return_code == 0 and not cleanup_errors and home_verified is not False)`。有子区就最后编辑一次子区消息。战报两个出口：**一定**写 `runs/<date>-<phase>-report.json`（战报 Embed 原文，路径记进 `last_run.report`）；开始干活之后（启动失败已直报）再往频道发战报 Embed + `attachment://shot.png`，多段上传失败降级成「无图 Embed + `hermes send MEDIA:`」，整个发送失败只记日志。最后写 `last_run.json`（#63）。

### 恢复策略
所有重开、补跑共用同一个 `maa_run_timeout` 预算；124/125/130 是我们自己的返回码，一律不重试。

| 情况 | 判据 | 动作 |
|---|---|---|
| 连接阶段就失败 | `CONNECT_FAILURE_MARKERS`（含 `ScreencapFailed`）且**一条任务链都没 Completed**；整份日志只有 `never_saw_the_game()` 白名单里的行（截图失败、任务起止、收尾汇总、`SCREENCAP_SETTLE_NOTE`）时 `AllTasksCompleted` 也不算跑过 | 等 `connect_retry_delay`（8s）→ `settle_game_window(allow_restart=True)` → `wait_for_game()` → 重开，最多 `connect_retry_limit`（2）次，日志**追加**进同一文件。放弃时说明带 `CONNECT_GAVE_UP`，`execute()` 跳过所有补跑，只记 `SCREEN_LOST_SKIP_NOTE` |
| 游戏没登录上（「获取网络配置失败」） | `never_logged_in()` 三条全满足：StartUp 段撞过 `GameOffline`、紧接的任务链也撞上、没有任何作战 / 掉落 / 基建 / 公招进展 | 等 `offline_retry_delays`（120s、300s）→ 写一行 `conf_probe()` 连通性探测 → `restart_game()` → 摆窗 → 整场重跑，最多 `offline_retry_limit`（2）次。死掉那趟的输出不交给战报。放弃时带 `OFFLINE_GAVE_UP`，补跑跳过（`OFFLINE_SKIP_NOTE`）。登录后才掉线的不重开，只如实报红；撞上 `GameOffline` 的任务一律「❌ 未完成（游戏掉线）」（`offline_tasks()`，#61） |
| 代理指挥失误 | 掉落项里出现「理智」（`SANITY_REFUND_ITEM`，游戏把返还的理智画成道具）= 失误批次 | `_drop_pairs()` 剔掉「理智」；`fight_wiped_out()`（有失误且零真掉落）时 Fight 翻红、写「实际完成 0 次」、整场 ❌、备注提示手动重打三星刷新录像。**熔断**：`run_maa()` 每 `PROGRESS_INTERVAL_SECONDS` 看末尾**连续**失误批次，达 `proxy_failure_limit`（2）就终止，返回 `PROXY_BREAK_CODE = 125`（中间有真掉落就清零）。**补跑**：`_salvage_run()` 用去掉 Fight 的 `daily.toml` 再跑一趟捞回基建 / 公招 / 商店 / 奖励，剩余预算不足 `proxy_failure_salvage_min_seconds`（300）就跳过，`proxy_failure_salvage: false` 关掉，日志 `runs/<date>-<phase>-salvage.log`。「StartUp 能否从结算页带回主界面」未真机验收 |
| 主关空跑失败 | `return_code != 0` 且 `fight_failed_dry()`（段里没有 `Fight <关> n times`、没有掉落、`[刷理智·续]` 没跑过） | `_fallback_fight_run()`：`fallback_fight_plan()` 只留 Fight、`annihilation = False`、块名 `FARMING_TASK_NAMES[1]`，剩余不足 `fight_fallback_min_seconds`（300）跳过，`fight_fallback_on_error: false` 关掉，日志 `runs/<date>-<phase>-fallback.log`（复用 `last_run.salvage_log`）。打了几批才 Error 的不补 |
| 台前调度把游戏收进侧边栏（预防，不是事后救） | 每场都做：拿到 `run.lock` 后、`launch_game()` 前 `pause_stage_manager()` 读 `com.apple.WindowManager GloballyEnabled` | 开着就先把原状态写进 `state/maa/stage_manager.json` 再 `defaults write … -bool false`；`finally` 里关完游戏后 `restore_stage_manager()` 写回开、删文件（成功 / 失败 / `KeyboardInterrupt` 都走）。原本关着不动也不还原；文件是上一场中途被杀留下的就以它为准、本场结束时一并还原；`disable_stage_manager_during_run: false` 时只还原遗留、不关。读写失败只打一行 stderr，不影响跑场（#62）。旧的摆窗救法（§0.5）照留，真机确认有效后再删 |

来由：[2026-08-07](./incidents/2026-08-07-proxy-failure-sanity-refund.md)、[2026-08-08](./incidents/2026-08-08-maatouch-sigsegv.md)、[2026-09-09 早场](./incidents/2026-09-09-am-fight-dry-fallback.md)、[2026-11-08](./incidents/2026-11-08-am-window-shelved.md)、[2026-11-09](./incidents/2026-11-09-am-game-offline.md)；方案见 `PLAN_GAME_OFFLINE.md`。

### CLI 输出 → 中文
`progress_content()` 和 `extract_summary()` 是纯函数：CLI 行数组 → Discord 文本。**原始 CLI 文本从不进 Discord**，只落 `runs/*.log`（#9）。靠 `TASK_STEPS` + 一组正则识别任务状态、理智、连战次数、临期药、掉落、设施、公招。maa-cli / MaaCore 输出格式变了通常只改这两个函数，用 `test_progress_and_summary_translate_cli_events` 验证。

## 5. 链路三：Discord 交互（`maa_action.py`，切线后停用）
> 2026-11-24 起线上不走 Discord：没有按钮登记、没有技能、没有聊天入口。`dispatch()` 里的命令照样能从终端和 App 调，下面的 adapter 约束只对旧 Hermes 环境有意义。

```
按钮/下拉 ─ adapter 查 buttons.json ─┐
                                     ├─→ python3 ~/.hermes/scripts/maa_action.py <argv>
自然语言 ─ maa-operator 技能 ─ terminal ┘        └─ stdout: {"ok":bool,"code":str,"message":str,"detail"?:str}
```

**来自 Hermes adapter 源码的三条硬约束**：exec 脚本硬超时 **20 秒**（只能写状态或 `Popen(start_new_session=True)` 后立即返回）；exec 白名单是**精确文件名**（`deploy.py` 显式加入 `maa_action.py`）；`buttons.json` 路径写死且全局共享（必须 merge、用 agent-book 的 `state.lock`）。

子命令（`dispatch()`；GUI 专用命令见 §12.1）：

| 命令 | 行为 |
|---|---|
| `plan set-stage <关卡> <am\|pm>` / `plan skip-today on\|off <am\|pm>` | 白名单校验后写**那一场**的今日覆盖 |
| `plan show` | 只读，一次念完两场 |
| `run now` | **不开跑**：抢锁探测 → 拒绝窗（`manual_run_blackout_minutes`，30）→ 预检 → 作废上一张 pending 选关卡 → 发「🎯 手动场选关」卡（`_stage_choices()`，无 default）→ 写 `manual_run.json`（`pending`，10 分钟 TTL）→ `Popen` 过期哨兵 + 推荐补写 |
| `run start <关卡> <token>` | 只由选关卡登记表触发：token 匹配且 `pending` 且未过期 → 关卡白名单 → 锁 → 拒绝窗 → 预检 → `dispatched` → 删登记 → 收卡 → `Popen maa_daily.py now <token>`。过期就地收卡 |
| `run cancel` | 停下正在跑的日常 / 抄作业（#64）：读 `run.lock` 持有者 → 只认 `daily` / `copilot` → 用 `ps -o command=` 核对那个 pid 真是 `maa_daily.py` / `maa_copilot_worker.py run-batch`（防 pid 复用）→ `SIGINT`，立即回执。对方自己收尾。没在跑 / 别的持有者 / 核对不上一律 `ok=false`、什么都不发。Wado's MAA 状态条的「停止」也调它 |
| `run expire <token> [--after 秒]` | 过期哨兵：睡够后仍 `pending` 且到期 → `expired` + 删登记 + 收卡；幂等 |
| `run recommend <token>` | 推荐补写（脱离会话）：仍 `pending` 才 PATCH 卡写「缺口推荐」并打 🎯；算不出写「推荐暂不可用」 |
| `log tail` | 读 `last_run.summary`；旧格式则回读 log 用 `extract_summary` 重建 |
| `copilot card` | 发抄作业一览卡（§3） |
| `copilot find <关卡>` | 写一份 `pending` 搜索并 `Popen` 派 `search` worker（§5.5） |
| `copilot status <token>` / `copilot cancel <token>` | 只读；只在 `scheduled` / `queued` 可取消 |
| `copilot auto <off\|on\|status>` | 暂停 / 恢复 watcher 的自动作业（#55） |

`maa_action.py` 还导出 `publish_round()`（发「已排程」卡 + 登记唯一的取消按钮）与 `dispatch_batch(token)`（`Popen(worker run-batch <token>)`），手动与自动路径共用，执行链只有一条（D14）。

- **场次参数不可省**（按 argv 长度精确匹配），只接受 `am` / `pm`（`valid_phase()`）；`now` 不是可写场次（D4）。
- 关卡白名单 `valid_stage()`：空串 / `^[A-Za-z0-9]{1,8}-\d{1,2}$` / 在 `config.activity_stages` 里 / 否则现场跑 `maa activity Official` 按词边界精确匹配（超时 **0.7s**）。
- `_today_override()` 返回 `{date, sessions: {am, pm}}`，只保留 `PLAN_SESSION_FIELDS` 的键；日期不是今天或是旧的按天格式（顶层 `stage`/`skip`）就重置成空，所以「今天说的话明天失效」，不需要清理任务和迁移。`is_run_locked()` 决定确认话术（正在跑就回「不打断本场」）。
- `emit()` 把输出压在 7900 字节内（组件运行器只收 ≤8192 字节）。回执三段见 §12.1（#67）：Discord 的组件运行器和技能只读 `ok` / `message`；不是 GUI 调的（`MAA_ACTION_SOURCE` ≠ `gui`）`emit()` 会把 `detail` 接在 `message` 后面，所以 Discord 上看到的和拆三段之前一样。

**技能只是第一道防线**：`SKILL.md` 禁止 `write_file` 改状态、禁止调 `maa_daily.py`、碎石永久关闭、原样转述 `message`。即使 LLM 无视技能，`maa_action.py` 的白名单和 `render_daily_toml` 的硬编码字面量仍然拦得住。写代码时始终假设「提示词会失效」。

## 5.5 链路四：抄作业（`maa_copilot.py` + `maa_copilot_worker.py`）
**一条执行链，两个入口**（D6 / D14），与日常共用 `run.lock`，早晚场前 `copilot_blackout_minutes`（25）内不派发。两个入口共用同一份闸门`maa_action.dispatch_blocker()`（#13）。手动路径被挡时**不排程**：`copilot find` 当场拒绝、什么都不写；搜完才跨进 blackout 的那一轮停在`scheduled`、卡上写「本轮未启动：<原因>」，**手动轮不自动重试**（watcher 只跟踪自己的 `batch_token`），靠 ❌ 或 `prune_expired_searches()` 清掉。

- **自动**（§3.5 的 watcher）：排目标集合 + 现搜作业 → 写 `searches/<token>.json` → `publish_round()` 发「已排程」卡 → 到点 `dispatch_batch()`。
- **手动**（卡片下拉 / 聊天「抄 SR-8」）：`copilot find`（~10ms）先用 `nav_checker()` 拒掉没导航的关、`dispatch_blocker()` 被挡就拒绝、`modes = required_modes()` → `Popen(worker search <token>)`。worker search（5~20s，flock 防并发）：`refresh_roster()` 失败直接失败（D13）→ `pick_perfect_candidate()`（ratio==1.0 且无缺口，搜不到红卡写缺什么，D12）→ 再查 `dispatch_blocker()`（被挡 `scheduled` +「本轮未启动」）→ `publish_round()` → `queued` → `dispatch_batch()`。
- **worker run-batch**（一关 8~15 分钟，串行连抄）：`run_lock(blocking=False)` 抢不到 → 放回 `scheduled` + 通知；三条时间闸门命中 → 放回 `scheduled` + 灰卡、不碰设备；`game_is_online()` 在跑 → 放回 `scheduled` +「明日方舟正在运行」；否则 `executing` → 收「取消本轮」按钮 → verify/launch/wait/settle。每个条目：`raid` 且突袭开关为空 → `skipped`；`min_lead_reason()` 不够 → 收尾；`_recheck_before_stage()`（活动 key + 实时理智）；当期活动关走 `copilot_list` 多作业（`_run_activity_round()`），其余逐关 `_navigate_to_stage()` → [`switch_to_raid()`] → `maa copilot <uri> --formation --batch -v --raid <mode>`（watchdog）；`copilot_outcome()` → `settle_after_battle()`（非 nav 都跑）→ `record_copilot_attempt()` → `save_ledger()`。一关失败继续下一关，`nav` 失败停整轮。最后截图 → `close_everything()` → 一条多关战报 → `executed` / `execution_failed`。

### 抄作业的关键事实
1. **单作业 `maa copilot` 从主界面跑不起来**（任务链没有 StageNavigationTask）。先 `_navigate_to_stage()`：临时 `MAA_CONFIG_DIR`（复制现有profile/cli/用户资源）里跑 `Fight(times=1)`（`times=0` 会禁用全部子任务），只把 `FightBegin` 覆盖成继承上游 `BattleStartPre` 的 OCR、`DoNothing`、空 sub/next；再 `Custom(CopilotNavigationReady)` 认关卡详情页。退出码 0、`Fight Completed`、`Custom Completed` 缺一不可。临时目录退出或异常时删除。2026-09-08 真机通过（`runs/2026-09-08-copilot-9e14e500ac25.log`）。
2. **当期活动关走多作业（`copilot_list`）**，资源本 / 主线仍走上面的逐关路径。逐关成败：`maa run -vvv` 时 maa-cli 打出每份作业开始的`CopilotListLoadTaskFileSuccess`（带 `file_name`），每份都要过三星检查才开始下一份，所以「第 k 份开始了」= 前 k−1 份通过（`list_outcomes()`）。卡死：`_run_copilot_with_watchdog(stall=…)` 在一份开始后 `copilot_list_item_timeout`（1500s）内没有下一份就结束进程。打哪关**只看作业文件里的`stage_name`**；一份解析失败的文件会让整张列表跑不起来，所以组表前逐份 `job_file_problem()` 预检；执行用 `/copilot/get/<id>` 的完整内容。导航见 #57，地形来自 `maa_gamedata.py`。**区域入口（EX / S）那一步还没真机跑过**，认不准会停下通知。（2026-10-19 真机核对，maa-cli 0.7.5 / MaaCore 6.20.0）
3. **突袭**：活动关难度由 `copilot_list` 条目的 `is_raid` 切，YW-EX-1 / EX-2 突袭真机通过。逐关路径的 `switch_to_raid()`（隔离目录里跑`Custom(<copilot_raid_switch_task>)`，照抄 MaaCore `MultiCopilotTaskPlugin` 的 `ChangeToRaidDifficulty`）2026-09-09 真机失败——首次开放的 SideStory根本没有突袭难度（[incidents/2026-09-09-raid-switch-failed.md](./incidents/2026-09-09-raid-switch-failed.md)）。**`copilot_raid_switch_task` 空串 =突袭功能整体关闭**（单文件 `--raid raid` 只挑作业不切难度），三层落实：`required_modes()` 不产生 `raid` → worker 判 `skipped` → `switch_to_raid()` 拒绝。仓库种子现在是 `ChangeToRaidDifficulty`。
4. **代理指挥接管弹窗**：开始行动时代理开着会弹「确认要接管作战吗？」，MaaCore 的 copilot 链不处理。worker 的 watchdog（MaaTools 截图 + `ocrbox` + MaaTools 点击）在弹窗出现时点确认（确认按钮在正文下方约 100px）。正常路径不触发。
5. **prts 的 `-1` 是「无要求」哨兵**（elite/level/skill_level/module），不判会 `module_levels[-1]` 越界。
6. **prts 服务端索引滞后**：当期活动关 `level_keyword` 会静默退化（total=全量），必须探针比对 + 客户端过滤（`test_level_keyword_degradation_*`）。
7. **作业 `stage_name` 两种写法并存**（内部 id / 展示码）：展示码的作业执行时取全文、改写为 stageId 后经 `file://` 传入。
8. **prts 的 `content.difficulty` 全为空**，判不出作业支不支持突袭，所以 D7：活动关一律普通 + 突袭，同一份作业先普通再突袭。
9. **逐关标记必须 `flush()` 后再把句柄交给子进程**：`_fight_one()` 写 `# <时刻> copilot <关> mode=<模式> id=<作业>` → `handle.flush()` → 记`os.fstat(handle.fileno()).st_size` → 事后 `_log_since(log_path, offset)` 按**字节偏移**切本关输出（#33，[incidents/2026-09-09-copilot-log-marker-flush.md](./incidents/2026-09-09-copilot-log-marker-flush.md)）。
10. **解锁预检是单向的**（`zone_progress_warning`）：森空岛 zone 进度含剧情关、`stage_id` 序号只数战斗关，只有 `cleared < seq`（突袭必锁）和`cleared < seq-1`（关卡必锁）成立。**有警告 = 基本锁着，没警告 = 不知道**，只用于卡上一行 `🔒 …大概率未解锁`，永不当闸门（#29）。序号超出第一个 zone 一律静默；警告带快照时效。
11. **打完先跳剧情、回主界面再关游戏**：顺序是战斗结束 → 剧情 → 结算页，界线是结算页。`_batch_run_locked()` 对 `outcome != "nav"` 的条目调`settle_after_battle()`：隔离目录里跑 `copilot-settle.toml` 两段 Custom——`["CopilotSettleSkip", *HOME_TASK_NAMES]` + `HOME_TASK_NAMES`。`CopilotSettleSkip` / `CopilotSettleSkipConfirm` 派生自上游 `SkipBattlePlot` / `SkipBattlePlotConfirm`（`SETTLE_OVERLAY_TASKS`，经 `_isolated_config()`的 `overlay_tasks` 只写临时 tasks.json），差别只有确认后的 `next` 清空（上游接的 `EndOfPlot` 在直接进结算页时永远等不到）。任一段 `Completed`即成功；都 Error 才在战报和账本 `detail` 写中性的「战后未回到主界面」，**不改胜负**。`copilot_settle_timeout` 240s。结算页本身不处理：下一关`StartUp` 自带 `EndOfAction → ClickCorner`，最后一关停在结算页被关掉无害；要派生 `EndOfAction` 时注意上游 `ClickCorner.next` 有 `StartButton2`（照搬会再开一局）。来由见 [incidents/2026-09-09-copilot-killed-in-post-battle-plot.md](./incidents/2026-09-09-copilot-killed-in-post-battle-plot.md)。

### 本地作业记账（`copilot/ledger.json`）
形状：`{activity_key: "SideStory「月行水上」|SR", stages: {"SR-5": {normal: <时间戳>, raid: null, attempts: [{at, mode, op, outcome, detail}]}}}`。

- **一关「通关」= 所需模式全部拿到 `Copilot Completed`**（`copilot_outcome()`，#33）。所需模式 `required_modes(stage, prefix, config)`：当期活动前缀的关是 `normal + raid`，资源本 / 主线只有 `normal`；突袭开关为空时活动关也只有 `normal`，卡上写「✅ 已通（突袭功能未启用）」。突袭失败 → 不算通关，下一轮只排 `raid`（D7）。
- `record_copilot_attempt()` **只有 `won` 才写模式时间戳**；`unknown` 与 `failed` 只进 `attempts`（留最近 40 条）。
- **「已通关」两条判据是「或」**（D10，`ledger_pending_modes()`）：本地记账有时间戳；或森空岛该关 zone `clearedStage == totalStage`（zone 粒度妥协，用户已接受）。
- `activity_key` 变了 → 旧账**归档**成 `ledger-<安全化的 key>.json` 再新开（`ensure_ledger()`）；切回归档过的活动就接回那份归档。
- **非活动关**记在 `ledger-standalone.json`：空 key → 独立账本，永不归档、永不新开活动账本；worker 必须用同一个 key 算出的路径 `save_ledger()`。独立账本不参与自动排轮（#52，[incidents/2026-09-09-standalone-ledger.md](./incidents/2026-09-09-standalone-ledger.md)）。
- **种子**（`seed_ledger()`）：前缀是 `SR` 时把 `SR-5 / SR-6 / SR-8` 的普通写成 `2026-09-08T23:58:00+08:00`（SR-5/6 用户打过、SR-8 是 09-08 抄作业通关），突袭留空；只补空位、换活动绝不写；判据是账本的 **`seeded` 标记**（#30，[incidents/2026-09-09-ledger-seed-skipped.md](./incidents/2026-09-09-ledger-seed-skipped.md)）。
- **当日上限** `auto_copilot_max_attempts_per_day`（2）：同一 `(关, 模式)` 当天失败 / `unknown` 达到次数后当天不再自动排（`daily_cap`，数据取 `attempts`里今天的记录，`won` 不计），卡上「🚫 今日已尝试 N 次」，次日 `attempts_today()` 自然归零。只挡自动，手动不受限（D14）。
- `save_ledger()` 0600 + `atomic_write_json`；账本坏掉 `load_ledger()` 返回 `None` 不抛——最坏重抄一遍（D-2）。

### 森空岛（`maa_skland.py`）
- 签名黄金向量已冻结（`test_signing_golden_vector`）：`MD5(HMAC-SHA256(path + query/body + t + header_ca))`，`t = now - 2`，GET query 不带 `?`，请求头小写 `cred/sign/platform/timestamp/dId/vName`，`dId/platform/vName` 可为空串。
- 链路：grant → cred（返回的 `token` 是签名密钥）→ binding（`data.list[]` 按 `appCode == "arknights"`，uid 取 `defaultUid`）→ `player/info?uid=` 的 `chars[]`（`evolvePhase`=精英化、`skills[].specializeLevel`=专精、`equip[].{id,level,locked}`=模组，锁着的不计）。
- 同一响应的 `currentTs` 与 `status.ap.{current,max,lastApAddTime,completeRecoveryTime}` 归一化进 `roster.sanity`。可按 6 分钟/点估算，但**每关开打前必须再`refresh_roster()`**。
- 干员名→charId 用本地 `battle_data.json` 的 `chars`（没有 `names` 键）；只解析到 `token_*`/`trap_*` 的视为召唤物。
- token 只从 stdin（`link`）或 `SKLAND_HG_TOKEN`（deploy）进，永不经 argv/Discord/agent（#16）；`skland.json`/`roster.json` 0600。
- cred 过期（10002/HTTP 401）→ 用存的 `hg_token` 重跑 grant，**只重试一次**，再失败记 `last_error` 提示重新 `link`。
- 刷新时机：手动搜索强制刷新（失败即失败）；watcher 在「有未执行的关」的 tick 刷新；每关开打前再刷。每日体检见 #56。

### 练度后备：OperBox
森空岛不可用时，**Depot 那趟**（`run_depot()`，每周 04:30）在拿完库存后顺手跑 `maa run operbox`（`config/maa-cli/tasks/operbox.toml`）。

- 判据 `skland_unavailable()` **只读本机状态、绝不发请求**：`skland.json.last_error` 非空，或 `roster.json` 缺失 / 坏 / 无时间戳 / 超过 `skland_roster_refresh_days`。
- 输出：maa-cli 打成 `OperBox: <json>`（与 `Depot:` 同形），`details` 是 `{done, all_opers[], own_opers[{id, name, own, elite, level, potential, rarity}]}`；与 Depot 共用 `_json_objects_after()`，只认 `done=true`。认不出 `char_xxx` id 的条目丢掉，一个不剩就报错。
- 快照落 `copilot/roster-operbox.json`（0600，`source = "operbox"`），**不覆盖 `roster.json`**；`load_roster()` 取 `fetched_at` 更新的一份。
- **fail-closed**（D12，#53）：`source == "operbox"` 时技能与模组要求一律记**硬**缺口；没有 `sanity` / `activity_progress`，理智按未知、zone 判据不成立。
- OperBox 失败不影响对表，成败写 `last_run.depot_operbox_note`（#22 的精神）。

## 5.6 理智让路（`maa_daily.attach_sanity_yield()`）
D11。判据只有一条：**估算理智 < 默认关的 `apCost` → `plan["farming"] = False`**（只摘刷理智，保留剿灭）。

- 估算走 `load_roster()` + `estimated_sanity()`，关卡理智走 `stage_index` + `stages.json`。**估不出来一律照常刷**（#26、#27）。
- 让路时开跑消息写明理由（`plan["farming_skip_reason"]`）。
- `plan["annihilation"]` 管剿灭、`plan["farming"]` 管刷理智，`tasks.fight` 是总开关。剿灭是周上限 1800 合成玉、代理卡驱动，不跟着让路。

三期的通关队列（`clearing.json`、手动打一次出口、EX 开放闸门、编队界面理智 OCR、日常收尾派发）已在四期整体删除（D15），只保留领域函数。

## 5.7 链路五：肉鸽（已移除）
2026-11-06 起 maa-remote 的肉鸽整套删除（K16）：`maa_roguelike.py`、worker、`roguelike *` 命令、Discord 肉鸽卡和 `hermes:btn:maa-roguelike:` 前缀、`roguelike.json`、原不变量 #46–#50。Mac App 里的上游肉鸽也已在 2026-11-09 随上游代码删掉；以后要用，先在 maa-remote 加命令。

## 6. 状态模型
```
~/.wados-maa/state/maa/        （旧线上是 ~/.hermes/state/maa/，切线时整体复制过来）
  config.json     环境与阈值（§6.2）                                  ← 计划卡会改写
  defaults.json   持久默认：stage="1-7" / medicine=expiring / tasks 全开
  plan.json       今日覆盖（按场次）：{date, sessions: {am: {stage, stage_source, skip, fight, source, updated_at, farming_drops, farming_fallback_stage}, pm: {…}}, updated_at}
  manual_run.json 手动场请求（单文件）：{token, status ∈ pending/dispatched/expired/superseded, stage, choices, recommendation, recommended_stage, message_id, created_at, expires_at(+10min), …}； 手动关只经它传给 `maa_daily.py now <token>`；`run local` 另带 tasks / annihilation / source / forced
  last_run.json   最近一次运行状态 + threads[] + 资源更新时间戳
  upstream.json   上游更新分步结果（§12.3）
  plan_card.json  最新一张计划卡 {phase, message_id, date, update_summary}；`plan refresh-card <场次>` 按它 PATCH（K3）
  activity_watch.json 当前活动 + 本轮 token + stage_state + prefight_failures + 状态
  depot.json      最近完整 Depot 真值 + 掉落增量 + 历次消耗与日均消耗率
  farming/{matrix,stage_info,item_value,store_activity}.json  一图流缓存 {fetched_at, etag, payload}，0600； 只有 maa_plan_card 写，`cost_lookup()` 只读
  copilot/ledger.json / ledger-<活动>.json / ledger-standalone.json   记账 / 归档 / 非活动关（0600）
  copilot/roster.json          森空岛练度 + 理智 + zone 进度 + annihilation_weekly（0600，source=skland）
  copilot/roster-operbox.json  练度后备（0600，source=operbox）
  copilot/searches/<token>.json 一轮的清单 entries:[{stage, stage_id, mode, candidate, sanity_cost}] + scheduled_at + 状态（25h TTL）
  copilot/previews/<token>.json GUI 预览（30 分钟）
  copilot/card.json   上一张抄作业卡的 message_id（不能放进 searches/）
  copilot/auto_pause.json  暂停自动作业开关；copilot/gamedata.json 游戏数据缓存
  run.lock        flock 独占锁（执行）；持有者标记 {holder: daily|copilot|depot|update, detail, pid, since}（K15，§12.2）
  last_run.lock   flock（保护 last_run.json 的跨进程 read-modify-write）
  stage_manager.json 台前调度原状态 {enabled: true, saved_at}：只在「原本开着、被跑场临时关掉」期间存在，还原后删（#62）
  am/ pm/         空目录，旧 Hermes cron 用来传场次，现在没用
  runs/<run_id>.{json,log,png,progress.json}、<run_id>-report.json   快照 / 日志 / 截图 / 本场进度（§12.3）/ 战报（14 天）。`run_id` = `<date>-<phase>-<HHMMSS>`（`make_run_id()`），同天多场不再互相覆盖；切线前的旧场是 `<date>-<phase>.*`，按 `resolve_run_artifact()` 兼容
  runs/index.jsonl  场次索引：每场结束追加一行（#66，§12.3）；超过 600 行裁到最近 500 行，不跟 14 天清理走；`runs/index.lock` 是它的写锁

~/.hermes/state/agent-book/    （只在旧 Hermes 环境存在，切线时已删掉 MAA 的键）
  buttons.json    全局共享按钮登记表（MAA 只碰自己的前缀）
  state.lock      共享写锁

~/.wados-maa/daemon/
  daemon.json     守护进程配置：端口、监听地址、允许的网段、局域网 IP、远程地址、通知后端、depot_enabled、
                  续签用的 ios_device_udid / ios_device_lan_ip / ios_resign_enabled（§13.4）
  secrets.json    Token 哈希、Bark 密钥（0600，不进仓库）
  scheduler.json  每条定时任务的上次槽位、状态和下次运行时间
  resign.json     iOS 无线续签状态；resign.lock 是续签单实例锁（§13.4）
  tls/            自签证书和私钥（0600）；active_tls.json / tls_check.json 是当前证书和巡检结果
  *.plist、wados-maa-cloudflared.yml、rescue.html   deploy.py 渲染的 LaunchAgent、隧道配置、应急页
  reload.flag     maa_schedule 写，守护进程看到就热重载
```

**计划的求值**（`effective_plan(at, phase)`）：`normalize_plan(defaults)`，若 `plan.date == 今天` 只叠 `sessions[phase]` 的`stage / stage_source / skip / farming_drops / farming_fallback_stage`，再 `normalize_plan` 一次（#39）。

- **`now` 永远拿不到覆盖**（没有写路径产生 `sessions.now`），手动场天然走缺口默认关（D4）。旧的按天格式读成空，不迁移。
- `normalize_plan()` 每次**强制** `medicine="expiring"`、`stone=0`（`test_persisted_medicine_choice_cannot_disable_fixed_expiry_policy`）；保留 `stage_source`；`farming_drops` 的 itemId 过 `SAFE_ITEM_ID_RE`，空值等于没有（手动选关就是写空清掉上限）。

**三把锁**：

| 锁 | 作用域 | 用法 |
|---|---|---|
| `run.lock` | 同一时刻只有一场 MAA | runner 非阻塞抢并显式处理冲突，抢到写持有者标记；`maa_action` 只做只读探测。日常遇 `update` 先等（K17），别的持有者走锁冲突（#23） |
| `last_run.lock` | `last_run.json` 合并不丢字段 | `merge_last_run()` 内部阻塞持有 |
| `agent-book/state.lock` | 按钮登记表 + `plan.json` 写入 | 阻塞式，跨功能共享 |

`merge_last_run()`：普通字段覆盖，`threads` **按 thread_id 去重后追加**（子区清理靠它）。`new_run=True` 是新一场的第一笔：先删 `RUN_SCOPED_LAST_RUN_KEYS`（`stage`、`ok`、`skip_reason`、`plan`、`summary` 等）再合并，跨场字段（`threads`、剿灭记账、depot、资源更新、`last_lock_conflict_*`）保留。日常 / 抄作业的开跑与探测跳过都必须带它，且只能在持 `run.lock` 时写；锁冲突、Depot、资源更新不带。

### 6.1 状态文件格式版本（`schema_version`）
`config.json` / `plan.json` / `last_run.json` / `manual_run.json` 顶层带 `schema_version`（现在都是 1）；`depot.json`（`maa_depot.SCHEMA_VERSION`）、`copilot/ledger*.json`（`LEDGER_SCHEMA_VERSION`）约定一致。

版本常量 `CONFIG_` / `PLAN_` / `MANUAL_RUN_` / `LAST_RUN_SCHEMA_VERSION`；写入方：`config.json` 由种子经 `deploy_state()` merge（运行时改写保留原值），`plan.json` 由 `_save_override()` / `apply_auto_stage()` / 种子，`manual_run.json` 由 `_save_manual_run()`，`last_run.json` 由 `merge_last_run()` / `cleanup_old_threads()` / 种子。读到未知更高版本：前三个**拒跑**（`config.json` 还让 `deploy_state()` 拒绝部署），`last_run.json` 告警一条后宽读。

`maa_common.check_schema(name, value, current, migrations=None, *, strict=True)`：缺字段 = 1；低于当前 → 按 `migrations[N]` 逐级升级（只在内存，下次写入落盘），缺一级就抛；高于当前或非正整数 → `SchemaVersionError`（`RuntimeError` 子类），`strict=False` 只告警；不是 dict 原样返回。

回滚到旧脚本会显式拒跑（「schema_version=2 本脚本不认识……多半是回滚到了旧脚本」）：重新部署新版，或删掉 / 改回那个文件（`plan.json` / `manual_run.json`删掉就是「没覆盖 / 没请求」）。`last_run.json` 只告警，旧脚本写回会把版本号盖回去，所以**迁移函数要幂等**。

**下次改格式**：① 常量 +1；② 写 `_plan_v1_to_v2(doc)`，在**所有**读该文件的 `check_schema()` 处传 `{1: …}`（`grep -n '"plan.json"' scripts/*.py`，迁移表在`maa_common` 一处定义）；③ 写入点不动，种子版本号一起改（`SeedVersionTests`）；④ `tests/test_state_schema.py` 补用例。`config.json` 不在运行时迁移：迁移放 `deploy.CONFIG_MIGRATIONS`（`migrate_live_config()` 在 merge 前升级，线上比种子新就拒绝）。`RETIRED_CONFIG_KEYS`只删没人读的键，不升版本；改既有键的含义 / 结构才升。`schema_version` 不得进 `PRESERVED_RUNTIME_CACHE_KEYS`（#58）。

### 6.2 配置项（`config.json`）
`state/config.json` 是种子（逐键合并，见 §7）。几个值得知道的键：

| 键 | 默认 | 含义 |
|---|---|---|
| `channel_id` | 占位符 | 部署时由 `MAA_CHANNEL_ID` 或本机已有配置解析，**不入库** |
| `session_schedule` | `{am: {time: "08:00", enabled: true}, pm: {time: "22:00", enabled: true}}` | 早晚场时间（北京时间）和开关（K6）。早场限 05:00–11:59，晚场限 12:00–23:59（`SESSION_WINDOWS`）；计划卡固定提前 10 分钟；手动场 / 抄作业 blackout、`min_lead` 都按它算，关掉的场次不算。改它走 `maa_action schedule *`，内置调度器热重载；一场写坏只退回那一场的默认 |
| （可改的键） | — | **只有 `maa_settings.FIELDS` 里的能从外面改**（`config set/patch`）：逐项校验、全部合规才写；物品名 / 材料名与渲染器共用 `SAFE_MALL_ITEM_RE`（#51）。路径、可执行文件、MaaTools 地址、运行时缓存、突袭开关不在表里；降级开关永远不许进表（`test_no_downgrade_switch_is_ever_editable`） |
| `config_meta` | 不在种子里 | `{键: {source: gui\|discord, updated_at}}`（K3）。**记过的键 `deploy.py` 保留线上值** |
| `game_bundle_id` / `playcover_app_path` / `maatools_address` / `game_display_name` | `com.hypergryph.arknights` / `~/Library/Containers/io.playcover.PlayCover/Applications/com.hypergryph.arknights.app` / `127.0.0.1:1717` / `MAA-Game` | `App Settings/<bundle id>.plist` 的文件名；`open -a` 拉起；`pgrep` / `pkill -f` 用里面可执行文件的完整路径；只接受回环；与 PlayCover、maa-cli profile 三处一致；游戏窗口常驻的虚拟屏名；空串 = 不管 |
| `disable_stage_manager_during_run` | `true` | 日常和抄作业动游戏期间临时关掉台前调度、跑完还原（#62，§4「恢复策略」）；GUI 标签「跑的时候临时关掉台前调度」 |
| `game_launch_timeout` / `game_quit_timeout` / `game_probe_timeout` / `maa_run_timeout` | `120` / `30` / `5` / `3000` | 等 MaaTools / 等 `TERM` 后退出 / 「你在玩」探测预算（`0` 关闭探测）；为守护进程 1 小时硬超时（§13.1）预留清理时间；重开与补跑共用 |
| `connect_retry_limit` / `connect_retry_delay` / `offline_retry_limit` / `offline_retry_delays` / `proxy_failure_limit` / `proxy_failure_salvage` / `proxy_failure_salvage_min_seconds` / `fight_fallback_on_error` / `fight_fallback_min_seconds` / `update_wait_minutes` | `2` / `8` / `2` / `[120, 300]` / `2` / `true` / `300` / `true` / `300` / `15` | 连接阶段失败的重开次数与间隔；没登录上时重启重跑的次数和第 n 次前等几秒（不够长用最后一个值）；代理失误熔断与补跑；主关空跑失败改刷后备关；日常等上游更新放锁的上限 |
| `medicine_expire_days` | `2` | 只吃这个窗口内将过期的理智药 |
| `fight_times` | `2147483647` | 生产值，配 `series = 0` 打到理智不足（有限 `times` 下 Beta MaaCore 改倍率偶发多起一批）。真机验链不想耗理智时临时设 `0`，验完务必改回 |
| `maa_activity_cache` | 不在种子里 | 覆盖 `StageActivityV2.json` 路径 |
| `report_drops` / `award_orundum` / `award_mining` / `award_specialaccess` | `true` / `false` | 匿名上报掉落给一图流与企鹅；幸运墙合成玉 / 采矿合成玉 / 月卡奖励 |
| `mall_buy_first` / `mall_blacklist` / `mall_reserve_max_credit` / `mall_only_buy_discount` | `[]` / `false` | 信用商店优先买 / 不买；过白名单（中日文 / 拉丁字母 / 数字 / `·`，≤20 字），不合规静默丢弃；信用点低于 300 停止购买 / 只买打折 |
| `retention_days` | `14` | `runs/` 保留天数（子区固定 24h） |
| `copilot_blackout_minutes` / `manual_run_blackout_minutes` | `25` / `30` | 场次前多久禁止派发抄作业；场次前多久不发选关卡、不派手动场 |
| `activity_search_retry_minutes` / `auto_copilot_min_lead_minutes` | `30` / `40` | 练度不满足 / 暂无作业的重试间隔；距下一场不足这么多分钟不开新的一关 |
| `auto_copilot_max_attempts_per_day` / `auto_copilot_max_prefight_failures_per_day` / `copilot_list_item_timeout` / `copilot_settle_timeout` | `2` / `2` / `1500` / `240` | 同一「关 + 模式」当天失败 / 未确认上限，`0` = 不限；开打前环境故障当天上限（#55）；多作业一份的无进展超时 / 战后收尾超时 |
| `copilot_raid_switch_task` | `ChangeToRaidDifficulty` | 逐关路径切突袭的上游任务名；**空串 = 突袭功能整体关闭**。改逐关切换前先真机验一关（清单在 `docs/archive/PLAN_PHASE4.md`，见 [incidents/2026-09-09-raid-switch-failed.md](./incidents/2026-09-09-raid-switch-failed.md)） |
| `skland_roster_refresh_days` / `annihilation_sanity` | `7` / `25` | 练度快照多旧算「森空岛一直没成功」；排作业理智预算时为剿灭预留 |
| `farming_weights` / `farming_min_samples` / `farming_target_days` / `farming_activity_edge` | `{"scarcity":0.5,"gap":0.3,"efficiency":0.2}` / `300` / `30` / `1.3` | 三项权重，和为任意值都归一；掉率最低样本 / 缺口按几天用量算 / 活动关要便宜多少倍 |
| `farming_rerun_days` / `farming_scarcity_horizon_days` / `farming_stage_table` / `farming_manual_weights` | `378` / `400` / 见下 | 预计复刻间隔（42 组 `ACT→ACT_REP` 中位数，p25–p75 351–387）/ 稀缺分视野；材料 → 关卡手工映射 / 冷启动手工权重 |

**材料关卡表**：映射以上游 `stages.json` 掉落表为主，新活动自动跟随。手工表只在两种时候有用：资源本（`CE-6` / `AP-5` 在上游只有家具掉落）、想钉死某材料。两张表在 `state/config.json`，是**仓库拥有的配置**，改完 `python3 deploy.py` 覆盖线上。例：`"farming_stage_table": {"固源岩组": "1-7", "碳素": "SK-5"}`（材料 → 去哪刷）、`"farming_manual_weights": {"固源岩组": 100, "碳素": 60}`（越大越优先）。

材料名必须与 `depot.json` 的 `items[].name` 逐字一致（MaaCore `item_index.json` 中文名），对不上只是不出现。手工表优先于派生表。两边都查不到的材料不推荐、卡上列出来，**不要让代码猜**。种子只放 `1-7` 与五个资源本（`AP-5`/`CA-5`/`CE-6`/`LS-6`/`SK-5`），当天没开的自动排除。掉率来自一图流 / 企鹅，抓不到退启发式（手工表钉的优先 → 理智低的优先 → 关卡名兜底）。

`defaults.json` 写入口是 `maa_action defaults set stage <关>` / `defaults set task <环节> <on|off>`（只给 GUI，写时带 `source` / `updated_at`）；`plan.json` 是带日期戳的今日覆盖；`medicine` / `stone` 不在可变状态里，由 runner 硬编码。

## 7. 部署链路（`deploy.py`）
现行是**独立模式**（`--standalone`，或只设了 `WADOS_MAA_HOME`、没设 `HERMES_HOME`），目标默认 `~/.wados-maa`，可用 `--target-home` 改。**不带 `--standalone` 且没设 `WADOS_MAA_HOME` 时走旧 Hermes 模式、写 `~/.hermes`，切线后不要这样跑。**

```bash
python3 -m unittest discover -s tests -v       # 必须在 maa-remote/ 里跑
python3 deploy.py --standalone                 # 幂等；输出 {"ok":true,"mode":"standalone","changed":[…],"backup":"…"}
python3 deploy.py --standalone --check         # 只读体检
launchctl kickstart -k gui/$(id -u)/io.github.ffkiyo7.wados-maa.daemon   # 让常驻进程加载新代码
```

线上从 `~/Developer/wados-maa-deploy`（固定在 `main`）部署，流程见仓库根 `AGENTS.md`。定时任务每次都起新进程，部署后下一次就用新脚本；但守护进程本身 import 了 `maa_api` → `maa_action` / `maa_common` 等大部分模块，API 和调度逻辑要重启才换。重启不杀正在跑的场次（子进程 `start_new_session=True`，plist 里 `AbandonProcessGroup`）。

独立模式 `--check` **只读**，一行 JSON，`ok` 为假退出码 1：

| 键 | 内容 | 影响 `ok` |
| --- | --- | --- |
| `missing` | 不存在的：`deploy.SCRIPT_NAMES` 的全部脚本、`ocrbox` / `winmove` / `barkcrypt` / `wados-maa-launcher`、全部 maa-cli 配置、`daemon/` 下的 `daemon.json` / `rescue.html` / 隧道配置 / 隧道 plist | 非空即假 |
| `mismatched` | 与仓库字节不同的：脚本、maa-cli 配置（`tasks/daily.toml` 豁免）、`rescue.html`。编译产物只查存在 | 非空即假 |

脚本名单只在 `deploy.SCRIPT_NAMES` 一处，新增脚本要加进去（`test_script_names_match_the_repository_scripts`）。

**独立模式做的事**（`deploy_standalone()`）：拷脚本 → 合并状态（下文）→ maa-cli 配置 → 有 `SKLAND_HG_TOKEN` 就写森空岛 token → 编译 `ocrbox` / `winmove` / `barkcrypt` → 编译并用 Apple Development 身份签名 `wados-maa-launcher` → 渲染 `daemon/`：`daemon.json` 只在不存在时写默认值（`notify_backend: none`、`depot_enabled: false`），守护进程 plist、隧道 yml 和 plist 每次按当前配置重渲染，`rescue.html` 照拷。**不碰 `~/Library/LaunchAgents/`、不碰 `~/.hermes`**。

**新机器第一次装**：部署 → `python3 daemon/init_daemon.py`（生成证书、`full` / `resign_only` 两个 Token、配对二维码，改 `daemon.json` 的网络配置）→ 手动在 `daemon/secrets.json` 填 `bark_device_key` / `bark_aes_key`（没有命令写它们）、`daemon.json` 改 `notify_backend: bark` → 把 `~/.wados-maa/daemon/` 下两个 plist 拷进 `~/Library/LaunchAgents/` 并 `launchctl bootstrap gui/$(id -u) <plist>` → 系统设置里给 `wados-maa-launcher` 开辅助功能 → iPhone 扫码配对。证书轮换用 `daemon/rotate_tls.py`（§13）。

### 7.1 版本记录（`config/verified_versions.json`）
> 版本比对目前只在旧 Hermes 模式的 `--check` 里做（`versions` / `warnings`）；独立模式的 `--check` 还没接上，要看漂移暂时手动 `maa version` 对照。

记**最后一次真机跑通**时各组件的版本（`schema_version: 1`，每项 `version` + `verified_at` + `source`），只用于漂移检测：不一致只进 `warnings`，不让 `ok` 变假。不部署。

本机取值：`maa-cli` / `MaaCore` 由 `probe_maa_versions()` 跑 `maa version`（复用 `maa_plan_card.read_maa_versions()` / `parse_maa_versions()`）；`PlayCover` 取 `/Applications/PlayCover.app/Contents/Info.plist` 的 `CFBundleShortVersionString`（形如 `4.0.0.maa`，记录另有 `branch: "maa"`）；`Hermes` 取 `git -C ~/.hermes/hermes-agent rev-parse HEAD`（记录可以是 ≥7 位短 hash，按前缀比）；`BetterDisplay` / `Arknights` 取各自 `Info.plist`；`MaaTools` **只记录、不进 `--check`**（VERN 要游戏在跑才读得到，`checked_by_deploy: false`）。

**更新流程**（每次真机跑通一场之后）：① `--check` 看哪些 `match: false`；② 确认后把 `version` 改成 `installed`、`verified_at` 改成当天；③ 游戏开着时看`maatools_ready(config)` 的 `MaaTools v<N> 就绪`；④ 单独提交。真的锁版本（`brew pin`、关自动更新、不跑 `hermes update`）会改系统状态，由用户决定。

### 两种模式共用的部署步骤
1. **备份**：将被修改的文件先复制到 `<目标根目录>/backups/maa-setup/<YYYYMMDDTHHMMSS>/`（线上是 `~/.wados-maa/backups/maa-setup/`）。
2. **幂等写**：`write_bytes()` 内容一致就跳过，否则 `mkstemp + fsync + os.replace`，权限 0600/0700。
   **`tasks/daily.toml` 是唯一的内容比对豁免**（`RUNTIME_REWRITTEN_MAA_CONFIGS`，每场被 `render_daily_toml()` 重写），仍照常部署、查存在。其余一律比内容，尤其 `resource/tasks/tasks.json`（没有运行时逻辑重写它，漂移就是事故）。豁免名单加项必须说明「谁在运行时重写它」（#4）。
3. **状态**（`deploy_state()`）：
   - `config.json` **逐键合并**，仓库覆盖同名键、本地新增保留；例外是 `PRESERVED_RUNTIME_CACHE_KEYS`（`maa_core_version` / `maa_cli_version` / `activity_stages`）和 `config_meta` 里记过的键——线上有值一律保留，种子只在首次部署兜底（#25，[incidents/2026-09-02-deploy-overwrote-activity-stages.md](./incidents/2026-09-02-deploy-overwrote-activity-stages.md)）。丢掉退役键（`RETIRED_CONFIG_KEYS`）。
   - `channel_id`：仓库存占位符 `REPLACE_WITH_DISCORD_CHANNEL_ID`。独立模式按 `MAA_CHANNEL_ID` → 已部署 config 取，取不到就留空（不发 Discord）；旧 Hermes 模式由 `resolve_channel_id()` 解析，取不到报错终止。
   - `defaults.json` / `plan.json` / `last_run.json`：**只在不存在时**复制种子，之后强制 `defaults.stage="1-7"`、`medicine="expiring"`、`stone=0`，剥掉 `plan.json` 残留的 `medicine`/`stone`。
4. **只有旧 Hermes 模式**：给 Hermes 打 4 处补丁、部署 `SKILL.md`。下面这些到「cron」为止都只是旧环境的记录：

| 目标 | 改动 |
|---|---|
| `hermes-agent/plugins/platforms/discord/adapter.py` | 白名单加 `maa_action.py`；`_run_hermes_button_script` 加 `selected_values`；`select_args` 精确查表分支；调用处传 Discord 的 `values` |
| `hermes-agent/LOCAL_PATCHES.md` | 登记上述补丁 |
| `~/.hermes/.env` | `DISCORD_FREE_RESPONSE_CHANNELS` 追加频道 ID（免 @） |
| `~/.hermes/config.yaml` | 频道绑定 `maa-operator` 技能 + 频道提示词 |

- `patch_config_yaml_text()` 只认 `channel_prompts:` 这一行做锚点（缩进按块内实际缩进推导），**不许拿相邻顶层键当锚点**（键顺序归 Hermes 管）。要不要插入、要不要替换旧文案（`OLD_MAA_CHANNEL_PROMPTS`）都按 `yaml.safe_load` 的**解析值**判断；替换由 `_replace_channel_prompt()` 连同折行续行一起换成单行带引号条目。写盘前后各解析一次，顶层 `timezone` 丢失/被改、或 `platforms.discord.channel_prompts[<频道>]` 不等于目标文案就 `RuntimeError` 不落盘；打补丁前就解析不了也拒绝（§11 第 17、17b 条）。
- `patch_adapter_source()` 用**精确字符串匹配**，匹配不到就 `RuntimeError`。`hermes update` 之后 `deploy.py` 可能直接报错——刻意的，届时读新 adapter 源码更新 old/new 串。

**什么时候必须 `hermes gateway restart`**：改 `adapter.py`、`.env`、`config.yaml`、`SKILL.md`（技能在会话初始化时加载）时要；`scripts/*.py`、`state/*.json`、`config/maa-cli/**` 不用。

旧环境的 cron 只在首次创建时注册（切线时已全部停用；表达式是 **UTC**，`config.yaml: timezone: Etc/UTC`；脚本内部一律 `Asia/Shanghai`）：

```bash
hermes cron create "*/15 * * * *" --name "MAA 活动作业监控" --script maa_activity_watch.py --no-agent --deliver local
hermes cron create "30 20 * * *"  --name "MAA 仓库对表"     --script maa_depot.py --no-agent --deliver local
hermes cron create "50 23 * * *" --name "MAA 计划卡·早" --script maa_plan_card.py --no-agent --deliver local --workdir ~/.hermes/state/maa/am
hermes cron create "50 13 * * *" --name "MAA 计划卡·晚" --script maa_plan_card.py --no-agent --deliver local --workdir ~/.hermes/state/maa/pm
hermes cron create "0 0 * * *"   --name "MAA 日常·早" --script maa_daily.py --no-agent --deliver local --workdir ~/.hermes/state/maa/am
hermes cron create "0 14 * * *"  --name "MAA 日常·晚" --script maa_daily.py --no-agent --deliver local --workdir ~/.hermes/state/maa/pm
```

当时由 `maa_schedule.py` 对齐早晚场时间。当时在册：`3ba48fb85d0b`（活动作业监控）、`b2f15f13589f`（仓库对表）、`03d5e98ce8d4`（计划卡·早，**没有 workdir**，待 `hermes cron update` 补 `--workdir ~/.hermes/state/maa/am` 或重建；不改也能按小时兜底成 `am`）、`50cd1fb095f2`（日常早）、`4f48cf619d9f`（日常晚）。以 `hermes cron list` 为准。

## 8. 不可破坏的不变量
改任何代码前先读这张表；每一条都有单测，改坏会红。**编号固定**（代码、测试、GUI 和其他文档按编号引用），删掉的编号不复用。来由在 [incidents/](./incidents/README.md)，表里标「来由」的那一列。

### 8.1 日常执行与任务文件
| # | 不变量 | 落点 | 来由 |
|---|---|---|---|
| 1 | `stone = 0`，永不提供任何入口 | `render_daily_toml` 字面量 + `normalize_plan` 强制 + 技能第 3 条 | — |
| 2 | `medicine = 0`，只用 `medicine_expire_days` 吃临期药 | 同上；`set_medicine()` 返回 `ok:false` | — |
| 3 | `series = 0`（MaaCore 选当前理智支持的最大连战） | `render_daily_toml` 字面量 | — |
| 4 | 基建 `mode = 0` 实时排班、七类设施，不用无人机 / 不补碎片订单 / 宿舍不刷信赖；宿舍确认条由用户资源 `InfrastDormDoubleConfirmButton` 接管，所在的 `resource/tasks/tasks.json` 必须被 `--check` 逐字节守住、不得进豁免名单 | `render_daily_toml` + `infrast-smoke.toml` + `test_deploy_check_skips_daily_toml_but_still_guards_tasks_json` | [2026-09-01](./incidents/2026-09-01-infrast-dorm-confirm-unverified.md) |
| 5 | 截图在 `maa run` 之后、关游戏之前；CloseDown 不进任务链 | `execute()` 步骤 9/10 | — |
| 5b | 日常战报截图必须 OCR 确认在主页；抄作业不受此约束 | `capture_home_screenshot()` / `verify_home_screenshot()` | — |
| 5c | `Custom` 的 `task_names` 每项都带 `Home@` 前缀 | `HOME_TASK_NAMES` + `daily.toml` 注释 | [2026-08-02](./incidents/2026-08-02-home-quickswitch-custom-error.md) |
| 9 | 原始 CLI 文本不进 Discord | `progress_content` / `extract_summary` / `_copilot_summary` 是唯一出口 | — |
| 10 | 开跑后快照即冻结，改计划不影响本场 | `runs/<date>-<phase>.json` + 内存 plan | — |
| 11 | 所有 maa-cli 子进程显式注入 `MAA_CONFIG_DIR`（macOS 默认目录不是 `~/.config/maa-cli`） | `maa_subprocess_env()` | — |
| 12 | 日常 `maa run` 剔除代理；`maa update` / brew 保留代理 | `maa_subprocess_env(keep_proxy=…)` | [2026-08-16](./incidents/2026-08-16-maa-update-without-proxy.md) |
| 44 | `drops` 上限只在有实测缺口时写，itemId 过 `SAFE_ITEM_ID_RE`；第二个 Fight 块永不带 `drops`、只在第一块有上限时渲染；`medicine/stone/series` 由 `_fight_block()` 一处写死；战报第二块 key 是 `Fight2` | `render_daily_toml()` / `_drops_table()` / `_fight_block()` / `farming_sections()` + `FarmingDropsTests` | — |
| 51 | 配置里的字符串列表写进任务文件前必须过白名单（`SAFE_MALL_ITEM_RE`，不合规静默丢弃不抛）；布尔走 `_toml_bool()`。渲染器不接受没校验过的外部字符串 | `_mall_item_list()` / `_toml_bool()` + `AwardAndMallOptionTests` | — |
| 59 | 主页入口永不切界面主题，纯源石兑换弹窗只点 ✗：9 个 `<入口>-Entry` 的 `onErrorNext` 不含 `SwitchTheme`；`OriginiteExchangeCancel` 的 `specificRect` 整个在 x ≤ 940；`<入口>Sanrio` 带 `rectMove` 把点击收进模板中间、离边 ≥ 1/5（终端离上沿 ≥ 25px） | `config/maa-cli/resource/tasks/tasks.json` + `test_sanrio_theme_entries_never_switch_theme_and_ship_their_templates` / `test_originite_exchange_popup_is_only_ever_cancelled` | [2026-11-02](./incidents/2026-11-02-home-theme-template.md)、[2026-11-05](./incidents/2026-11-05-originite-exchange-popup.md)、[2026-11-10](./incidents/2026-11-10-sanrio-home-layout-shift.md) |
| 61 | 掉线后的自动重启只在 `never_logged_in()` 三条全满足时做；登录后才掉线只报红。撞上 `GameOffline` 的任务不得判完成；死掉那趟输出不交给战报；重启只有 `restart_game()` 一份 | `never_logged_in()` / `offline_tasks()` / `run_maa_resilient()` + `GameOfflineTests` / `OfflineRetryTests` / `OfflineExecuteTests` / `test_there_is_exactly_one_restart_implementation` | [2026-11-09](./incidents/2026-11-09-am-game-offline.md) |

### 8.2 计划与场次
| # | 不变量 | 落点 | 来由 |
|---|---|---|---|
| 5d | `skip` 只挡设它的那一场；`phase == "now"` 永远照跑 | `execute()` 的 `and phase != "now"` + `SessionDailyTests` | — |
| 39 | 计划覆盖按场次：`plan.json` 是 `{date, sessions: {am, pm}, updated_at}`，`effective_plan(at, phase)` 只叠 `sessions[phase]`；`now` 永远叠不到；旧的按天格式读成空、不迁移、不抛 | `plan_sessions()` / `effective_plan()` / `_today_override()` + `PlanTests` / `SessionDailyTests` | — |
| 40 | **保留核心**：晚场准备任务不跟随上游更新；无 Discord 时早/晚准备步骤（上游更新/活动探测/自动定关/清理/#56 体检）照常完成。**切线后退役**：计划卡两行 Discord 控件与登记表键 | `maa_plan_card.main()` / `build_components()` + `PlanCardPhaseTests` / `PlanCardNoDiscordTests` | — |
| 54 | **保留核心**：手动关不进 `plan.json`、不带 drops 和后备关；距开着的场次不足 `manual_run_blackout_minutes` 不发卡不派发（除非显式 `--force`）；`maa_daily.py now <token>` 核验 `manual_run.json`。**切线后退役**：`hermes:btn:maa-now:` 选关卡按钮链路 | `run_now()` / `run_local()` / `run_start()` / `manual_run_blackout_reason()` + `manual_run_stage()` + `ManualRunCardTests` | — |

### 8.3 Discord 与按钮（及解耦后通知出口）
| # | 不变量 | 落点 | 来由 |
|---|---|---|---|
| 6 | 按钮脚本必须 < 20s 返回 | `run_now()` / `copilot_*` 用 `Popen`；活动关探测 0.7s | — |
| 7 | **切线后退役（编号不复用）**：独立模式不再写 `buttons.json`；过渡期 `buttons.json` 只能 merge，计划卡只碰 `hermes:btn:maa:` 前缀 | `maa_plan_card.main()` | — |
| 8 | **切线后退役（改由结构化白名单替代，编号不复用）**：过渡期下拉值经 `select_args` 查表，不直通 argv；场次写死在登记表 argv 里 | adapter 补丁 + `_stage_select()` + `_copilot_card_components()` + `test_every_control_carries_its_own_phase` | — |
| 14 | **切线后退役（编号不复用）**：过渡期抄作业按钮前缀 `hermes:btn:maa-copilot:`，过期由 `prune_expired_searches()` 清 | `maa_copilot.BUTTON_PREFIX` | — |
| 14b | **切线后退役（编号不复用）**：过渡期抄作业卡前缀 `hermes:btn:maa-copilot:card:`，`card.json` 必须在 `copilot/` 而不是 `searches/`；保留 `PREVIEWS_DIR` 与 `SEARCHES_DIR` 隔离约束 | `CARD_BUTTON_PREFIX` / `CARD_PATH` + `copilot_card()` + `CopilotCardTests` | — |
| 41 | **保留核心**：抄作业轮只在 `scheduled` / `queued` 状态可取消。**切线后退役**：已排程卡的 Discord 按钮键约束 | `build_scheduled_card()` / `CANCELABLE_STATUSES` + `ButtonRegistryTests` | — |
| 63 | **扩展保留（覆盖 Bark + `maa_notify.py`）**：通知出口（Discord / Bark / `barkcrypt`）永远不是执行的前提：缺配置 / token / 密钥、加密失败、网络或 HTTP 错误、建子区失败都只记一行日志、永不抛给业务主流程；日常与抄作业照常跑完并落盘 `last_run.json` 与 `runs/<run_id>-report.json`。共用的 `report_game_busy()` / `report_lock_conflict()` 只在状态写不进去时抛 | `maa_notify.notify()` / `discord_outlet()` / `notify()` / `open_thread()` / `write_report_file()` + `test_notify.py` / `DiscordOptionalTests` / `CopilotReportOutletTests` | REVIEW_2026-11-09 §1.1 |
| 67 | **扩展保留（`ios` 与 `gui` 同等）**：回执三段：`maa_action.py` 每行回执都带 `ok` / `code` / `message`，`detail` 可选。GUI / iOS 会调到的命令每个 `return` 都用 `done()` / `refuse()` 写明 `code`（小写短码），`message` 只写给玩家看的一句话（过 `test_ui_copy`），异常文本与路径放 `detail`。`is_app_source()`（`gui` / `ios`）不把 `detail` 拼进 `message`；非 App 调用时 `emit()` 把 `detail` 接回 `message`，整行仍 ≤ 7900 字节 | `is_app_source()` / `Reply` / `done()` / `refuse()` / `emit()` / `main()` + `tests/test_receipts.py` / `test_gui_receipts_have_no_implementation_words` | REVIEW_2026-11-09 §3.5 |

### 8.4 锁、闸门与设备
| # | 不变量 | 落点 | 来由 |
|---|---|---|---|
| 13 | 抄作业与日常互斥（`run.lock`），场次前 `copilot_blackout_minutes` 内拒绝派发。闸门只有一份 `dispatch_blocker()`，三处各查一次：`start_copilot_search()`（被挡什么都不写）、`cmd_search()`（被挡改 `scheduled` 写原因）、`cmd_run_batch()`（抢到锁后只查三条时间闸门） | `dispatch_blocker()` + worker `run_lock(blocking=False)` + `test_the_gate_has_exactly_one_implementation` / `ManualCopilotPathTests` | — |
| 23 | Depot 不在计划卡链路内跑，独立定时任务只做 7 天到期检查；日常抢锁失败必须写 `last_lock_conflict_*`、发 Discord、返回失败；`merge_last_run()` 必须持专用锁 | `maa_depot.main()` / `report_lock_conflict()` / `last_run_lock()` | — |
| 24 | 每条自动链路在拿到锁之后、`launch_game()` 之前探测游戏进程，在跑就跳过并发 Discord、写 `last_run`（日常 `skipped`/`game_busy`；Depot `skipped_busy` 不动 `snapshot_at`；抄作业放回 `scheduled`）。`now` 永不跳过。探测永不抛、预算 `game_probe_timeout`，不复用 `wait_for_game()` / `settle_game_window()`，实现只有一份 | `game_is_online()` + `report_game_busy()` + `AUTO_PHASES` + `test_there_is_exactly_one_probe_implementation` | — |
| 36 | 每开新一关前查距下一场是否够 `auto_copilot_min_lead_minutes`；三条时间闸门（blackout / Depot 窗口 / 时间预算）只有一份，在 `maa_action.py` | `min_lead_reason()` / `_copilot_blackout_reason()` / `depot_window_reason()` + `CopilotTimeBudgetTests` | — |
| 60 | 上游更新只有一份（`maa_upstream.run_update()`），全库只有它调 `maa update` / `hot-update` / `brew upgrade`，期间持 `run.lock`。开跑前 `hard_block()` 只在钉住项被改、或上次更新不自洽时拒跑；开发副本只检查不更新 | `run_update()` / `hard_block()` / `update_gate()` + `tests/test_upstream.py` | [2026-08-26](./incidents/2026-08-26-maaresource-out-of-sync.md)、[2026-09-07](./incidents/2026-09-07-hot-update-libgit2-proxy.md) |
| 62 | 动游戏的流程（日常 `execute()`、抄作业 `_batch_run_locked()`）在拿到 `run.lock` 之后、`launch_game()` 之前 `pause_stage_manager()`，在 `finally` 里**关完游戏之后** `restore_stage_manager()`；成功、失败、`KeyboardInterrupt` 都要还原。关之前必须先把原状态落盘（`state/maa/stage_manager.json`），落盘失败就不关；原本关着就不动也不还原；遗留文件以它为准、不得被覆盖。两个函数永不抛。单测不许真的读写 `com.apple.WindowManager`（`_isolation` 审计钩子拦 `subprocess.Popen`，`guard_devices()` 默认把两个函数桩成空操作） | `pause_stage_manager()` / `restore_stage_manager()` + `StageManagerTests` / `StageManagerExecuteTests` / `test_stage_manager_is_paused_before_launch_and_restored` | [2026-11-08](./incidents/2026-11-08-am-window-shelved.md) |
| 64 | **扩展保留（补充 `--run-id` 校验）**：`run cancel [--run-id <run_id>]` 只给核对过的进程发 SIGINT：持有者必须是 `daily` / `copilot`，传入 `--run-id` 时必须严格匹配 `run.lock.run_id`（不一致返回 `run_changed` 拒绝），pid 的命令行必须真有 `maa_daily.py` / `maa_copilot_worker.py run-batch`（按文件名比，不按子串），否则 `ok=false` 什么都不发。被停的一方只让第一次 SIGINT 打断（`interrupt_once()`），不补跑、不截主页，照常关游戏、还原台前调度（#62）、发战报，终态 `last_run.status = cancelled`（抄作业的轮记 `canceled`、不记开打前失败），返回 130；放锁随进程收尾 | `run_cancel()` / `_is_run_process()` + `maa_common.interrupt_once()` / `CANCEL_EXIT_CODE` + `execute()` / `_batch_run_locked()` + `RunCancelTests` / `CancelledRunTests` / `test_run_cancel_checks_expected_run_id` | REVIEW_2026-11-09 §2.2 |

### 8.5 部署与状态文件
| # | 不变量 | 落点 | 来由 |
|---|---|---|---|
| 19 | 只有「查询成功且确实无活动」才清空活动关，格式不可辨认一律抛；闸门与解析器共用 `is_side_story_heading()`；`deploy.py` 不得用种子覆盖线上 `activity_stages` | `activity_snapshot()` + `test_snapshot_gate_and_parser_agree_on_what_a_heading_is`；`PRESERVED_RUNTIME_CACHE_KEYS` | [2026-09-02](./incidents/2026-09-02-deploy-overwrote-activity-stages.md) |
| 25 | 由线上进程写回的运行时缓存键必须列入 `PRESERVED_RUNTIME_CACHE_KEYS`（线上有值一律保留，种子只首次兜底）；新增此类键必须同步加 | `deploy_state()` + `test_every_known_runtime_cache_key_is_preserved_on_deploy` | [2026-09-02](./incidents/2026-09-02-deploy-overwrote-activity-stages.md) |
| 58 | 状态文件读时校验、写时带 `schema_version`（§6.1）；`config` / `plan` / `manual_run` 遇未知更高版本拒跑，`last_run` 告警宽读；所有读取都过 `check_schema()`；`schema_version` 不进 `PRESERVED_RUNTIME_CACHE_KEYS` | `check_schema()` / `*_SCHEMA_VERSION` + `migrate_live_config()` + `tests/test_state_schema.py` | — |
| 65 | **扩展保留（覆盖日常 + 抄作业与 `run_id` 命名）**：本场进度文件 `runs/<run_id>.progress.json`（日常 `kind="daily"`、抄作业 `kind="copilot"`，均含 `run_id`）：字段只增不改语义（改语义就升 `schema_version`）；写失败（含解析异常）只打一行 stderr，绝不影响跑场；`RunProgressFile` / `CopilotProgressFile` 的方法永不抛；GUI 只读不写。日常 `notes` 文本只来自 `PROGRESS_NOTES`、步骤名只来自 `PROGRESS_STEPS`，两者都在 `test_ui_copy` 的禁用词扫描里；只在恢复点加 note，不改控制流 | `RunProgressFile` / `CopilotProgressFile` / `run_maa()` / `_execute()` / `_batch_run_locked()` + `ProgressFileTests` / `CopilotBatchExecutionTests` | REVIEW_2026-11-09 §1.3 |
| 66 | **扩展保留（覆盖抄作业 `report`/`progress` 与 `run_id` 五类文件）**：场次索引 `runs/index.jsonl` 只追加：日常（含手动场）和抄作业每场结束写一行（`id == run_id`，带 `report`/`progress`/`log` 路径；五类产物均以 `run_id` 命名、互不覆盖，读取层兼容旧 `<日期>-<场次>` 命名）。一行一次 `O_APPEND` 写入、持 `runs/index.lock`；超过 `RUN_INDEX_TRIM_AT` 行才在同一把锁里裁到最近 `RUN_INDEX_KEEP` 行；`cleanup_run_files()` 不碰这两个文件。`append_run_index()` 永不抛，写不进去只打一行 stderr；日常一场只写一行。字段只增不改语义，读的一方跳过坏行和更高版本的行；GUI 只读不写。全库只有 `maa_daily.py` / `maa_copilot_worker.py` 调它 | `append_run_index()` / `read_run_index()` / `record_daily_run()` / `record_copilot_run()` / `resolve_run_artifact()` + `tests/test_run_index.py` / `DiscordOptionalTests` / `CopilotBatchExecutionTests` | REVIEW_2026-11-09 §1.2 |

### 8.6 材料推荐与自动定关
| # | 不变量 | 落点 | 来由 |
|---|---|---|---|
| 31 | 材料缺口是后台计算：`apply_auto_stage(result, phase)` 写那一场的 `stage`（同一字段）+ `stage_source="auto"` + `farming_drops` / `farming_fallback_stage`；用户手动选过的那一场当天不再自动改；`stage_source` 必须在 `PLAN_SESSION_FIELDS`；排序只用三项加权分；降级期照样定关但标出原因、不写 `drops` | `farming_result()` / `auto_stage()` / `apply_auto_stage()` + `FarmingScoreTests` / `FarmingAutoStageTests` | [2026-09-08](./incidents/2026-09-08-farming-select-removed.md) |
| 32 | 材料推荐每条降级路径都不抛且必须可见（`degraded_reasons`）；永不猜关 | `load_market_data()` / `farming_result()` / `farming_note()` / `consumption_rates_window()` + `FarmingScoreTests` / `FarmingFetchTests` | — |
| 38 | 材料 → 关卡以上游 `stages.json` 的 `NORMAL_DROP` 为主、手工表补充且优先（合并不是替换）；映射是有序候选列表、在候选集里取命中；有掉率按「理智/件」挑，否则启发式；没有主掉落的关也留在表里；读取失败降级成空表 | `stage_drops()` / `material_stage_candidates()` + `FarmingAutoStageTests` / `FarmingScoreTests` | — |
| 42 | 活动未结束时候选集只有 `activity_stages ∩ 导航键`，结束当天退回 `1-7` + 资源本；判「还在」优先看日历。只管自动定关 | `candidate_stages()` + `FarmingCandidateSetTests` | — |
| 43 | 外部数据抓取任何失败都不抛（缓存或空 + 原因）；缓存 0600、`matrix.json` 用 ETag；统一 UA，卡上带数据来源行；数据不 vendor 进仓库；单测一条都不许碰网 | `load_market_data()` / `_fetch_cached()` / `SOURCE_LINE` + `FarmingFetchTests` | [2026-09-02](./incidents/2026-09-02-unit-test-hit-prts.md) |
| 45 | 理智查表两级 fail-closed：上游 `stages.json` → 一图流 `stage/info` **本地缓存**（只读不发请求）；都没有返回 `None`、条目不入轮。第二级是为 EX 关加的 | `cost_lookup()` + `FarmingExCostFallbackTests` | — |

### 8.7 理智让路与 Depot
| # | 不变量 | 落点 | 来由 |
|---|---|---|---|
| 22 | Depot 只有退出成功、任务 Completed、有 `done=true` 非空库存且清理成功才替换真值 | `run_depot()` / `parse_depot_output()` | — |
| 26 | 刷理智与剿灭是两个独立开关；理智让路只摘刷理智、永远保留剿灭；估算失败照常刷 | `render_daily_toml` 的两个 `if` + `attach_sanity_yield()` + `SanityYieldTests` | — |
| 27 | 理智让路的判据只有「估算理智 < 默认关 `apCost`」；任何读不出 → `farming = True`；让路必须写明理由 | `attach_sanity_yield()` + `test_an_unreadable_estimate_farms_as_usual` / `test_a_throwing_probe_never_takes_the_farming_block_away` | — |
| 53 | 练度后备快照读不到的字段一律按「不满足」（`source == "operbox"` 时技能与模组记硬缺口）；落单独文件、取 `fetched_at` 新的一份；OperBox 失败不影响 Depot | `load_roster()` / `check_op_requirements()` / `skland_unavailable()` / `run_operbox()` + `OperBoxFallbackTests` / `OperBoxRosterTests` | — |

### 8.8 抄作业
| # | 不变量 | 落点 | 来由 |
|---|---|---|---|
| 15 | 三个降级开关（忽略练度 / 理智药 / 助战）一个都不许出现，连字面量都不许进脚本；只接受 `ratio == 1.0` 且无软硬缺口的作业 | `_fight_one()` + `pick_perfect_candidate()` + `CopilotDowngradeGuardTests` | — |
| 16 | 森空岛 / 鹰角 token 永不经 Discord、argv、agent；`copilot/` 下文件 0600 | `maa_skland.py` | — |
| 17 | 抄作业关卡只接受本地 `stage_index` 精确查表，不猜别名 | `valid_copilot_stage()` | — |
| 18 | 自动与手动都只接受完全满足的作业，搜索绕过 12h 缓存；每关开打前复核活动 key 与实时理智 | `pick_perfect_candidate()` + `_recheck_before_stage()` + `ManualCopilotPathTests` | — |
| 20 | 收掉未打完的一轮必须连续 2 次空快照，且必发通知 | `EMPTY_OBSERVATIONS_BEFORE_IDLE` + `test_the_activity_ending_needs_two_empty_snapshots` | — |
| 21 | 森空岛失败文案必须带原始错误 | `fetch_roster()` 的 `detail` + `test_link_guidance_keeps_the_original_failure_cause` | — |
| 28 | 排轮前先扣剿灭那份理智；理智未知一律 0；理智成本为 `None` 的条目不入轮 | `sanity_budget()` / `plan_round()` + `CopilotRoundPlanningTests` | — |
| 29 | 「已通关」两条独立判据（记账或 zone 全清）；`zone_fully_cleared()` 与 `zone_progress_warning()` 共用 `stage_zone()` 定位但绝不合并结论，后者永不当闸门 | `stage_zone()` / `zone_fully_cleared()` / `ledger_pending_modes()` + `test_zone_helpers_stay_two_separate_rules` | — |
| 30 | 只有 `won` 才写模式时间戳；突袭失败不算通关；换活动归档不删；种子只在前缀 `SR` 且未种过（`seeded`）时只补空位；同一 `(关, 模式)` 当天失败达上限后当天不再自动排 | `record_copilot_attempt()` / `ensure_ledger()` / `seed_ledger()` / `attempts_today()` / `daily_capped_modes()` + `LedgerTests` / `CopilotDailyAttemptCapTests` | [种子](./incidents/2026-09-09-ledger-seed-skipped.md)、[当日上限](./incidents/2026-09-09-copilot-log-marker-flush.md) |
| 33 | 只有退出码 0 且无失败标记且有 `Copilot Completed` 才算通关，否则 `unknown` 按失败处理；判据输入是「这一关自己的输出」：标记 flush 后按字节偏移切片 | `copilot_outcome()` + `_fight_one()` / `_log_since()` + `CopilotVictoryJudgementTests` / `CopilotLogMarkerTests`（真实子进程共享 fd） | [2026-09-09](./incidents/2026-09-09-copilot-log-marker-flush.md) |
| 34 | 突袭用 `#raid` 后缀，每关先普通后突袭；除 `--raid` 取值外一律用 `split_entry()` 去后缀；`--raid raid` 只挑作业不切难度，`copilot_raid_switch_task` 为空 = 突袭关闭 | `split_entry()` / `make_entry()` / `required_modes()` / `raid_enabled()` + `CopilotModeTests` 等 | [2026-09-09](./incidents/2026-09-09-raid-switch-failed.md) |
| 35 | 一关失败继续下一关，只有 `nav` 失败停整轮；战报逐关列结果；普通没过就跳过同关突袭 | `_batch_run_locked()` + `CopilotBatchExecutionTests` | — |
| 37 | 非当期活动的关只跑上游 `tasks/Stages/<前缀>.json` 有顶层键的；当期活动关只要这期有一个普通关键（锚点）且游戏数据有这关即可（导航见 #57）。都不读不建用户目录，读失败一律视为无键；导航不过去的关只在一览标 ⛔ | `copilot_nav_checker()` / `nav_checker()` / `read_nav_keys()` / `pick_anchor()` / `collect_targets()` + `CopilotTargetSetTests` / `CopilotListPrepTests` | — |
| 52 | 空 `activity_key` 永不动活动账本，非活动关记 `ledger-standalone.json`；`ledger_path()` 与 `ensure_ledger()` 用同一个 key | `ledger_path()` / `ensure_ledger()` / `_batch_run_locked()` + `LedgerTests` / `CopilotBatchExecutionTests` | [2026-09-09](./incidents/2026-09-09-standalone-ledger.md) |
| 55 | **保留核心**：森空岛读不到不自动排轮；开打前环境故障写 `prefight_error`，按北京日计数达 `auto_copilot_max_prefight_failures_per_day` 当天停排只发一条（理智不够不计）；暂停开关 `copilot/auto_pause.json` 只管 watcher 的轮、不中断正在打的那关；`copilot auto on` 清掉当天停排。**切线后退役**：固定 Discord 按钮 id | `run_once()` / `_count_prefight_failure()` / `_prefight_blocked()` + `PrefightError` + `copilot_auto()` + `ActivityWatchTickTests` / `CopilotAutoPauseCommandTests` | [2026-10-11](./incidents/2026-10-11-yw4-prefight-loop.md) |
| 56 | **完整保留**：森空岛每日体检挂在计划卡后（含无 Discord 独立模式）：每北京日探一次，失败一天最多一条、恢复前天天发，经 `maa_notify.py` 推送；发送失败不记「已查」；体检异常不许拖垮计划卡；`refresh_roster()` 成功就清 `last_error` | `daily_health_check()` / `_skland_health_notice()` + `SklandDailyHealthTests` / `PlanCardNoDiscordTests` | — |
| 57 | 当期活动关的导航只有三小步自写、都只写进 `_isolated_config()` 临时目录：借锚点进活动停在地图上；剧情关挡路点开跳过；EX / S 按 `zoneNameSecond` 找入口（相似度严格高于同活动其它区域名才点）。每步后要认出目标区域关卡代号（`CopilotZoneReady`）才算到位；够不着的关整轮截断（`plan_segments()` / `trim_unreachable()`） | `ActivityNavigator` / `_run_activity_round()` / `plan_segments()` / `zone_button()` + `CopilotListPlanTests` / `CopilotZoneEntryTests` / `CopilotListRoundTests` / `CopilotReachableTargetTests` | — |

`46–50`：原肉鸽的五条，2026-11-06 移除（K16），编号不复用。

## 9. 日常开发流程
```bash
python3 -m unittest discover -s tests -v              # 必须在 maa-remote/ 里
uvx ruff@0.17.3 check && uvx pyright@1.1.414          # 两条都必须 0 报错
swift test --package-path ../shared                   # 动了 shared/ 的模型时
```

开发副本 `~/Developer/forks/maa-remote-devhome` 的 `scripts` 软链到本工作区，改完不用部署。对它跑命令要显式带根目录，**否则默认落到线上 `~/.wados-maa`**：

```bash
export WADOS_MAA_HOME=~/Developer/forks/maa-remote-devhome
python3 scripts/maa_action.py plan today              # 只读
python3 scripts/maa_plan_card.py am                   # 真机：早场计划卡（会跑上游更新）
python3 scripts/maa_daily.py am                       # 完整早场（真的开游戏、耗理智）
python3 scripts/maa_daemon.py --once                  # 调度器只走一个 tick：到期的任务会真的派发
```

动游戏前先确认线上 `~/.wados-maa/state/maa/run.lock` 空闲、离早晚场和活动监控的整刻足够远：两边共用同一个游戏和 `~/.config/maa-cli`，开发副本自己的 `run.lock` 挡不住线上。开发副本的守护进程和线上抢同一个 18170 端口，线上在跑时只能用 `--once` / `--no-api`。不想让线上定时场插进来：`python3 ~/.wados-maa/scripts/maa_action.py schedule disable am|pm`，用完 `enable`。单测不能替代真机：图像识别、连战倍率、基建排班只有实机能验；`config/maa-cli/tasks/infrast-smoke.toml` 是单独验七类设施排班的诊断任务。

### 单测必须离线可跑
- **整套单测不许碰网络**。prts 网络层由 `tests/test_copilot.py: prts_http_stub()` 桩掉（[incidents/2026-09-02-unit-test-hit-prts.md](./incidents/2026-09-02-unit-test-hit-prts.md)）。
- 一图流 / 企鹅出口在每个模块的 `setUpModule()` 里封死（`_helpers.start_module_patches()` patch `maa_farming._http_json`，`maa_gamedata._fetch` / `load_layout` 同理）——抓取层默认写**线上** `~/.wados-maa/state/maa/farming/`，吞掉异常只降级，漏桩不会变红，所以这道模块级闸门是唯一防线。要造响应的用例在`with patch.object(maa_farming, "_http_json", …)` 里覆盖，其余传 `data=`。`_cache_age()` 把未来的 `fetched_at` 当不新鲜。
- `tests/_isolation.py` 装常驻审计钩子（`sys.addaudithook`）：解析或连接非回环地址抛 `RealNetworkTouched`（BaseException）；回环放行（`test_playcover.py` 的假 MaaTools 服务端）。
- 线上契约冒烟（默认跳过、不进 CI）：`MAA_LIVE_TESTS=1 python3 -m unittest tests.test_copilot -k LiveContract -v`，验 prts.plus 的信封与字段（`id` / `content` / `available` / `rating_ratio` / `views`、`content.stage_name`）。改了桩数据就跑一次。

### 单测碰不到真游戏
除 `test_playcover.py` / `test_state_schema.py` / `test_isolation.py` 外，每个模块的 `setUpModule()` 调 `_isolation.guard_devices()`，把 `maa_playcover.subprocess` / `socket` 换成一碰就抛 `RealGameTouched`（BaseException）的桩。设备层自己在 `test_playcover.py` 里对着本机假 MaaTools 测。**桩设备函数一律桩`maa_playcover.<函数>`**：调用方都写 `import maa_playcover` + `maa_playcover.launch_game(…)`；`scripts/` 禁止 `from maa_playcover import …`（`test_scripts_never_from_import_the_device_layer`）。见 [incidents/2026-11-04-unittest-touched-real-game.md](./incidents/2026-11-04-unittest-touched-real-game.md)。

### 单测必须和线上状态隔离
每个测试文件**第一个** import `_isolation`（先于任何 `scripts/` 模块，它们 import 时就按 HOME 算路径常量）：

- `HOME` / `WADOS_MAA_HOME` / `HERMES_HOME` / `MAA_CONFIG_DIR` 换成进程级临时目录，清掉 `MAA_CHANNEL_ID` / `SKLAND_HG_TOKEN`；设 `PYTHONDONTWRITEBYTECODE=1`。
- 审计钩子守住真实 home 下的 `.hermes` / `.wados-maa` / `.config/maa-cli` / `Library`：打开、列目录、建删改名、chmod 一律抛 `RealHomeTouched`。
- 没有 PyYAML 时 deploy 的 YAML 用例借 Hermes venv 的解释器只做解析，都没有就跳过（`needs_yaml`）；要 `tomllib` 的在 3.11 以下跳过（`needs_tomllib`）。
- **整套共用一个临时 HOME**（几十个路径常量 import 时算死，每用例换 HOME 不划算）。所以新用例的状态文件写进自己的 `tempfile.TemporaryDirectory()`（patch 对应常量，如 `maa_copilot.STAGE_INDEX_PATH`、`maa_common.PLAN_PATH`；`maa_daily.execute()` 的用例在 `setUp` 调 `isolate_stage_index(self)`）。每个模块的 `tearDownModule()` 调 `_isolation.assert_shared_home_clean()`（`test_isolation.py` 查每个文件都调了）：共享 HOME 里出现 `SHARED_HOME_ALLOWED`以外的文件（白名单只有几个空锁文件：`.wados-maa/state/maa/{run,state}.lock`，以及过渡期旧路径 `.hermes/state/maa/run.lock`、`.hermes/state/agent-book/state.lock`）就报错并列路径；看的是整个 HOME，前一个模块漏下的会在下一个模块收尾时抓到。

验收（干净 HOME 结果必须和真实 HOME 一致；系统 3.9 也要跑，且要在没设 `PYTHONDONTWRITEBYTECODE` 的 shell 里）：`HOME="$(mktemp -d)" python3 -m unittest discover -s tests`；`env -u PYTHONDONTWRITEBYTECODE /usr/bin/python3 -m unittest discover -s tests`。

来由见 [incidents/2026-11-04-unittest-isolation.md](./incidents/2026-11-04-unittest-isolation.md)。

**测试文件布局**：按领域一个文件。新模块照抄任一 `test_*.py` 开头：`sys.path` 加 `scripts/` 和 `tests/` → **第一个** `import _isolation` → `import _helpers`和 scripts 模块；`setUpModule()` 里 `guard_devices()` + `start_module_patches()`，`tearDownModule()` 反过来 `stop_patches()`、停设备桩、最后 `assert_shared_home_clean()`。两个以上模块用到的桩放 `_helpers.py`（`SR_INDEX` / `SR_LAYOUT` / `_nav_patch()` / `_offline_market()` / `needs_yaml` 等），只有一个用的留在原模块。跑单个文件：`python3 -m unittest discover -s tests -p test_daily.py`。

**脚本暂不拆**（2026-11-04 定）：入口文件名是对外契约（调度器按文件名跑，按钮白名单精确到 `maa_action.py`，worker 按路径 spawn，`deploy.py` 只拷不删）。真要拆有两条路：(B) 按接缝抽平铺模块，入口名不变、新文件进 `SCRIPT_NAMES`，测试里的 `patch.object` 目标跟着搬；(C) 包目录 `~/.hermes/scripts/maa_remote/`、入口仍平铺，最干净但 `deploy.py` 要学会删旧文件、`--check` 要跟着改。

### 静态检查（ruff + pyright）
运行脚本仍是纯标准库。配置在 `maa-remote/pyproject.toml`（只有 `[tool.ruff]` / `[tool.pyright]`），版本钉死、`uvx` 现下现跑；范围 `scripts/*.py`、`deploy.py`、`tests/*.py`。两条都必须 **0 报错**。升级版本号时连同本节和 CI 一起改。

- **ruff**：`E4` / `E7` / `E9` + `F` + `BLE`；不开 `E501`。
- **pyright**（3.11、basic）：状态文件形状写成 `TypedDict`（`total=False`：`Config` / `Plan` / `PlanFile` / `SessionOverride` / `LastRun`、`Ledger` / `LedgerStage` / `LedgerAttempt`），状态值是 `Literal`（`Phase`、`PlanPhase`、`RunStatus`、`ManualRunStatus`、`Outcome`、`SearchStatus`）。它们只描述「写进去应该长什么样」，`load_json()` 仍返回 `Any`，运行时校验一条都不能删；加新键要同步加 TypedDict。`str` 收窄成场次用 `is_phase()` / `is_plan_phase()`（`TypeGuard`，只在 `if TYPE_CHECKING:` 下 import）。
  **脚本必须能被系统 3.9 加载**（`maa_copilot_morning.sh` 用 `/usr/bin/env python3`），运行时类型构造只限 `TypedDict`、`Literal`、`cast`。`tests/` 关掉`reportTypedDictNotRequiredAccess` / `reportOptionalSubscript` / `reportOptionalMemberAccess`。故意喂坏值写 `# pyright: ignore[reportArgumentType]  # 故意传坏值`；别处的 ignore 必须带规则名和原因。
- **`except Exception`（BLE001）**：能说清会抛什么就只抓那几种（`OSError`、`subprocess.SubprocessError`、`ValueError`、`json.JSONDecodeError`、`RuntimeError`、`MaaToolsError`；MaaTools 操作用 `DEVICE_ERRORS`）。确实要兜住一切的只有三类，写 `except Exception as exc:  # noqa: BLE001 — (<类别>) <原因>`：(a) 进程顶层兜底 / 汇报路径；(b) 清理 / finally；(c) 尽力而为的辅助（watchdog、救场、截图、旁路信息）。拿不准归 (c)，别为过检查去收窄。`except Exception: pass` 不许出现（至少打一行日志）；`except BaseException` 一律不许。

### CI（GitHub Actions）
仓库根 `.github/workflows/tests.yml`：push 到 `main` 和 PR、且动了 `maa-remote/**` 才跑，`runs-on: macos-latest`。**unittest**：Python 3.11 / 3.12，每个版本runner HOME 和 `HOME="$(mktemp -d)"` 各跑一遍；**lint**：ruff + pyright（`pip install uv==<版本>`）。action 钉 commit SHA（行尾注释写 tag）。CI 上没有 PyYAML、Hermes venv、PlayCover、maa-cli：`needs_yaml` 的用例 skip，新用例不许因缺本机资源而红。本地模拟 CI：干净 HOME + `TZ=UTC`，discover 前把`_isolation.yaml_python` 换成 `lambda: None`，应是 `OK (skipped=10)`。推 `.github/workflows/` 要 token 带 `workflow` scope。

## 10. 排障：症状 → 看哪里
| 症状 | 先看 |
|---|---|
| 到点什么都没发生 | `launchctl print gui/$(id -u)/io.github.ffkiyo7.wados-maa.daemon` 看守护进程在不在；`daemon/scheduler.json` 看那条任务的状态（`missed` = 错过且超过 2 小时补跑窗）；`~/.wados-maa/logs/daemon.log`；`run.lock` 被占 → `pgrep -fl com.hypergryph.arknights.app`；`schedule show` 看那场是不是关着 |
| 不到 1 秒 `return_code=1`、`runs/` 没 `.log` | `require_executable()`（`config.maa_bin`）或 `verify_game_installed()`（MaaTools 被关 / 端口改了） |
| 有开跑消息，子区进度不动 | `runs/<date>-<phase>.log` 尾部；多半卡在更新 / 登录页，50 分钟后 124 终止 |
| 很快就红，一串 `ScreencapFailed` / `ConnectFailed` | 窗口不在台前或 MaaTools 没开（§0.5）。`BetterDisplay get -nameLike=MAA -connected`；`last_run.connect_retries`；日志「摆回台前」那行的 `[窗口 …；屏：…]` |
| 很快就红，一串 `GameOffline`，截图停在「获取网络配置失败」 | 没登录上（§4 恢复策略）。`last_run.offline_retries`、日志「连通性探测」行；`~/Library/Application Support/sparkle/logs/core-<日期>.log` 看连 `game-config` / `ak-conf` / `as.hypergryph.com` 的线路（正常登录会连到 `as`）。重启到底都没恢复多半是鹰角短时故障 |
| 战报 ❌ 但任务都是 ✅ | `cleanup_errors` 非空也判失败 |
| 点按钮 / 下拉没反应或报未登记 | 卡片过期（21:50 后早场卡必然点不动）；gateway 没重启；`buttons.json` 被别人覆盖 |
| 改一场把另一场也改了 | `plan.json` 的 `sessions` 是否被写成旧的顶层 `stage`。写路径只有 `_save_override(phase, …)` 和 `apply_auto_stage(result, phase)` |
| 卡片没有「活动截止」 | 设计：`StageActivityV2.json` 读不出来就不显示。跑一次 `maa activity Official` |
| 抄作业卡下拉是空的 | 一览全是「⛔ 上游无导航」（#37） |
| 报「明日方舟正在运行」 | 探测命中（#24）。看是不是残留进程；日常想强行跑就说「现在跑」 |
| 卡片写「⚠️ 降级：… 抓取失败」 | `ls -l ~/.wados-maa/state/maa/farming/`；`curl -sI https://cos.yituliu.cn/arknights/stage-drop/matrix.json`、`curl -sS -X POST https://backend.yituliu.cn/item/v7/value -H 'Content-Type: application/json' -d '{}' \| head -c 200`。不会让卡片消失 |
| 活动期卡片说资源本「不在本场候选集里」 | 设计（D5 / #42），手动选不受限 |
| 一场只看到一个 Fight 段 / 「刷理智·续」永远未执行 | `runs/<date>-<phase>.json` 的 `plan.farming_drops` 是空的就不渲染第二块（#44）；或第一块没打到上限理智就耗完，正常 |
| EX 关排不进自动轮 | 理智算不出（#28）。一图流也不收 EX 关（spike B §1），已知缺口 |
| 下拉里没有活动关 | `maa activity Official` 输出变了 → `activity_snapshot()` / `parse_activity_events()` |
| 新活动上线后没有自动排程 | `daemon/scheduler.json` 的 `activity_watch`；`activity_watch.json`：`done` 看 `excluded`，`waiting` 排不出条目，`scheduled` 闸门没过 |
| 「已排程」卡一直不开跑 | 按 `dispatch_blocker()` 顺序：没到 `scheduled_at` / blackout / Depot 窗口 / `run.lock` / 游戏在跑 |
| 某关一直不被自动抄 | 抄作业卡一览：⛔ 无导航、🚫 练度不满足、✅ 已通。`copilot/ledger.json` 是记账真值 |
| 战报某关 ❓ 未确认 | `copilot_outcome()` 返回 `unknown`，不记通关、下一轮重打。上游改措辞就改 `COPILOT_VICTORY_MARKERS` |
| 战报全 ❓、日志里却有 `Copilot Completed` | 标记行 `# <时刻> copilot <关> mode=…` 是否排在本关输出之后（§5.5 关键事实 9，[incidents](./incidents/2026-09-09-copilot-log-marker-flush.md)） |
| 自动作业反复开游戏几十秒就关 | 开打前环境故障（多半森空岛过期），#55：`activity_watch.json` 的 `status=blocked` / `blocked_reason` / `prefight_failures`；修好后「恢复自动作业」立即解除 |
| 想在 Discord 里叫停自动作业 | 卡上「⏸️ 暂停自动作业」或说「暂停自动作业」（`copilot auto off`） |
| 卡上「🚫 今日已尝试 N 次」 | 当日上限命中，次日恢复；想现在重打就从下拉手动选 |
| 突袭总是失败 | 活动关走 `copilot_list` 的 `is_raid`；逐关路径看 `runs/<date>-copilot-<token>.log` 的 `# raid-switch` 段有没有 `Custom Completed`（§5.5 第 3 条） |
| 卡上「✅ 已通（突袭功能未启用）」 | `copilot_raid_switch_task` 为空，只按普通判通关 |
| 理智读取失败 | 森空岛凭据过期或 API 变化；只在本机终端跑 `maa_skland.py link` |
| 森空岛挂了后作业全判练度不满足 | 设计（#53），练度退到了 operbox 后备。修好森空岛下次刷新自动退场 |
| 森空岛挂着，`roster-operbox.json` 不出现 | 只在 Depot 那趟跑。看 `last_run.depot_operbox_note` |
| 活动记账好像丢了 | `copilot/` 下是否多了 `ledger-<key>.json` 归档（#52） |
| 信用商店没按 `mall_buy_first` 买 | 渲染出的 `daily.toml` 里 `buy_first` 是否为空：白名单静默丢弃带引号、换行、>20 字的名字 |
| 聊天改计划无效 | agent 是否真调了 `maa_action.py`；`plan.json` 的 `date` 是否今天 |
| 战报步骤全是「未执行」 | maa-cli 输出格式变了 → `_task_state()` / `TASK_STEPS` |
| 截图失败 | MaaTools 没连上，或 `SCRN` 为空且 `screencapture` 没录屏权限（§0.5） |
| 「截图不是游戏主页」 | `runs/<date>-<phase>.png` 停在哪页；`last_run.home_verify_detail`。UI 改版误杀就调 `HOME_MARKERS` |
| `返回主界面` Error 但截图在主页 | `maa update` 后 QuickSwitch 任务图变了 → `asst.log` 里 `taskchain":"Custom"` 的 `to_be_recognized` 对照资源 json |
| 启动 / 商店 / 奖励 / 返回主界面一起 Error、截图在主页 | 主页标识 `SwitchTheme@ToggleSettingsMenu` 没命中（`match_templ` 分数卡 0.7 左右），MaaCore 太旧 → `maa update`（[2026-11-02](./incidents/2026-11-02-home-theme-template.md)） |
| 主页入口没命中，任务 Error | 用户资源层接管了 9 个 `<入口>-Entry`：`next` = 上游 Default + `<入口>Sanrio`（`resource/template/UiTheme/Sanrio/*.png`），`onErrorNext` 只剩 `<入口>OriginiteExchangeCancel`，不切主题。换了联动主题、或游戏热更新挪了首页面板（匹配分卡在 0.7 左右），就从 `debug/interface/*_raw.png` 截新模板（只截按钮上的字和图标，避开动画、角标和半透明处，见 [2026-11-10](./incidents/2026-11-10-sanrio-home-layout-shift.md)）并配 `rectMove`（#59） |
| 截图挂着「是否花费 1 纯源石兑换 180 合成玉」 | 点击落进顶栏触控区；看 `asst.log` 那次 `Click with scaled coordinates`（[2026-11-05](./incidents/2026-11-05-originite-exchange-popup.md)） |
| 基建停在「撤下宿舍锁定位置的干员」 | profile 的 `user_resource = true`、`~/.config/maa-cli/resource/tasks/tasks.json` 是否部署；诊断任务应出现 `InfrastDormDoubleConfirmed` 后到 `Infrast Completed` |
| 计划卡红「上游更新失败」，detail 是 `SecureTransport error … class=Net (12)` | 失败的是 `maa hot-update`（detail 里没有「MaaCore 更新失败，未更新热更新资源」）；查 `cli.toml` 的 `backend` 是否 `git`（§11 第 18 条）。复现：`MAA_CONFIG_DIR=~/.config/maa-cli maa hot-update --batch -vv` |
| `deploy.py` 报 “no longer matches baseline” | 忘了带 `--standalone`，跑成了旧 Hermes 模式（§7） |
| iPhone 连不上 | 局域网：`curl -k https://127.0.0.1:18170/healthz`；在外：`logs/cloudflared.log`、`launchctl print gui/$(id -u)/io.github.ffkiyo7.wados-maa.cloudflared`；指纹不对看 `daemon/active_tls.json`（§13） |
| 收不到 Bark | `daemon.json` 的 `notify_backend` 是不是 `bark`；`secrets.json` 有没有两把密钥；`scripts/barkcrypt` 在不在；脚本 stderr 里的 notify 行（#63 只记日志不报错）。可调 `POST /api/v1/notify/test` |

现场常用：`cat ~/.wados-maa/state/maa/last_run.json`、`ls -lt ~/.wados-maa/state/maa/runs/ | head`、`tail -100 ~/.wados-maa/state/maa/runs/<run_id>.log`、`tail -50 ~/.wados-maa/logs/daemon.log`、`cat ~/.wados-maa/daemon/scheduler.json`。

## 11. 已知坑
编号固定（代码和其他文档按 `§11.N` 引用）。

1. **游戏需要活跃图形会话和在线的 MAA-Game 虚拟屏**：注销、切换用户、BetterDisplay 没开都会失败（§0.5）。
2. （Hermes 时期）**`hermes update` 会覆盖 adapter 补丁**：升级后必须重跑 `deploy.py` 并复验按钮。
3. **Beta MaaCore 的连战重识别**：有限 `times` 下改倍率偶发识别不到、多起一批；生产用 `times=2147483647` + `series=0` 规避（README「本机落地状态」）。
4. （模拟器时期）ADB 路径不能带空格，见 [incidents/2026-11-03-adb-landship-path.md](./incidents/2026-11-03-adb-landship-path.md)。
5. **macOS 上 maa-cli 默认配置目录是 `~/Library/Application Support/com.loong.maa/config`**，所以子进程一律用 `maa_subprocess_env()` 注入 `MAA_CONFIG_DIR`，不要裸 `subprocess.run`（#11）。
6. **删子区要 bot 的 Manage Threads 权限**，没有就只能靠 `auto_archive_duration=1440` 归档。
7. **MaaCore 资源目录与配置目录不同**：资源在 `~/Library/Application Support/com.loong.maa/resource`（Tile-Pos / battle_data.json），与 `MAA_CONFIG_DIR` 无关；`maa_resource_dir` 配错抄作业关卡索引就是空的。
8. **maa-cli 任务文件是 `[[tasks]]` 数组**（不是 `[tasks.X]` map），0.7.5 会直接 TOML 报错。
9. **日常 `maa run` 剔除代理、`maa update` 必须带代理**：`maa_disable_proxy` 只对运行类子进程生效。手动复现日常用 `env -u ALL_PROXY -u HTTPS_PROXY -u HTTP_PROXY ... maa run ...`（否则 in-run hot update 连代理报错）。`maa hot-update` 带不带代理由 `cli.toml` 的 `backend` 决定（第 18 条）。见 [incidents/2026-08-16-maa-update-without-proxy.md](./incidents/2026-08-16-maa-update-without-proxy.md)。
10. **接管弹窗**：`maa copilot` 不处理「确认要接管作战吗？」，靠 watchdog；确认按钮在正文下方约 100px（1920×1080）。
11. **MAA 没为该关写导航定义**：上游每个活动只写几个推荐关，`Stages/<前缀>.json` 里没有的关进不去，**原因通常不是「未解锁」**。只在一览标 ⛔（#37）；出路是等热更新、手打、或改抄资源本 / 主线（2026-09-05 决定不自写导航定义；当期活动关另有 #57 的三小步导航）。
12. （模拟器时期）BlueStacks 清理脚本连坐删除，见 [incidents/2026-08-04-bluestacks-cleanup-wiped.md](./incidents/2026-08-04-bluestacks-cleanup-wiped.md)。
13. **代理指挥失误会被报成「掉落理智」且 Fight 仍判 Completed**；`Fight <关卡> N times` 的 N 是发起的批次不是打完的次数。处理见 §4「恢复策略」，见 [incidents/2026-08-07-proxy-failure-sanity-refund.md](./incidents/2026-08-07-proxy-failure-sanity-refund.md)、[incidents/2026-09-09-am-fight-dry-fallback.md](./incidents/2026-09-09-am-fight-dry-fallback.md)。
14. （模拟器时期）MaaTouch 握手超时 → SIGSEGV；**maa-cli 不看 `Controller::connect` 的返回值**，连不上照样跑。见 [incidents/2026-08-08-maatouch-sigsegv.md](./incidents/2026-08-08-maatouch-sigsegv.md)。
15. （模拟器时期）BlueStacks 更新弹窗卡死启动，见 [incidents/2026-08-26-bluestacks-upgrade-popup.md](./incidents/2026-08-26-bluestacks-upgrade-popup.md)。
16. **MaaCore 包与 MaaResource 热更新层必须同步更新**：MaaCore 启动时用 MaaResource 覆盖包内资源，只跑 `maa update` 可能留下引用已改名模板的旧资源、连设备前就退出。所以 Core 更新成功后紧接 `maa hot-update`，任一步失败都红卡，`hard_block()` 拒跑半更新状态（#60，[incidents](./incidents/2026-08-26-maaresource-out-of-sync.md)）。
17. （Hermes 时期）**不许拿相邻顶层键当 config.yaml 锚点**：写坏会让 Hermes 静默回退默认配置、cron 全提前 8 小时。判断是否中招：`hermes cron list` 的 `Next run` 带 `+08:00`而不是 `+00:00`（§7，[incidents/2026-09-03-config-yaml-anchor-cron-8h.md](./incidents/2026-09-03-config-yaml-anchor-cron-8h.md)）。
    - 17b. **Hermes 会把频道提示词重排成无引号、折行的 plain scalar**，比对和替换都要按解析值（§7，[incidents/2026-09-09-config-yaml-folded-prompt.md](./incidents/2026-09-09-config-yaml-folded-prompt.md)）。
18. **`maa hot-update` 的 libgit2 后端无视 `HTTP_PROXY` / `HTTPS_PROXY`**：`maa update` 走 reqwest 认代理；hot-update 走 `cli.toml` 的 `[resource] backend`。`config/maa-cli/cli.toml` 的 `backend` 必须是 `"git"`（合法值只有 `git` / `libgit2`，填别的 maa-cli 直接 panic；`git` 找不到时自己回落 libgit2）。改完必须`python3 deploy.py`（`cli.toml` 被 `--check` 逐字节守着）。见 [incidents/2026-09-07-hot-update-libgit2-proxy.md](./incidents/2026-09-07-hot-update-libgit2-proxy.md)。

## 12. 外部消费者契约（Mac App）
Mac App（同仓库 `gui/`）**只通过下面这些东西**和 maa-remote 打交道；iPhone App 走 §13 的 HTTP API，API 又是把同一套命令和状态文件包了一层。这里列出的字段、路径、命令和格式改了，两个 App 都可能坏：要改，就在同一个提交里改后端、`shared/` 和 App，并一起验证。

### 12.1 怎么调
- **入口**：`python3 $WADOS_MAA_HOME/scripts/maa_action.py <命令…>`（Mac App 同时设 `WADOS_MAA_HOME` 和 `HERMES_HOME`）。stdout 是一行回执 JSON（#67）：

  | 字段 | 含义 |
  |---|---|
  | `ok` | 成没成，含义不变 |
  | `code` | 稳定的短码（小写加下划线），给程序判断；GUI 要分支就比它，不比对 `message` 的措辞。没细分的旧命令是 `ok` / `failed`，进程顶层异常是 `error` |
  | `message` | 给玩家看的一句话，不超过 7900 字节，GUI 原样显示；不写异常、路径、命令名（`test_ui_copy` 守着） |
  | `detail` | 可选：给开发者的原始信息（异常文本、路径、`schedule` 的对齐细节、`upstream status` 的版本摘要）。GUI 不显示，只记进「复制诊断信息」；GUI 以外的调用方（`MAA_ACTION_SOURCE` 不是 `gui`）会在 `message` 末尾另起一行看到它 |
  | `data` | 只有 GUI 专用命令有（对象） |

  GUI 现在按码分支的：`run local` 的 `session_soon`（早晚场就要开始，可 `--force`）。其余常见码：`busy`（游戏正被占用）、`blocked`（抄作业闸门）、`update_blocked`、`not_installed`、`not_ready`、`bad_stage` / `bad_phase` / `bad_value` / `bad_args`、`preview_expired`、`roster_failed`、`cannot_reach`、`not_running` / `not_cancelable` / `already_finished`；成功码按命令（`stage_set`、`run_started`、`copilot_started`、`config_saved`、`schedule_saved`…），以 `maa_action.py` 里 `done()` / `refuse()` 的第一个参数为准。旧的 `data.blocked`（`locked` / `blackout`）照旧保留。
- **环境变量**：
  - `WADOS_MAA_HOME`（优先）→ `HERMES_HOME` → `~/.wados-maa`：运行数据根目录（开发期指向 `devhome` 副本）；
  - `MAA_ACTION_SOURCE=gui|ios`：原生 App 来源，改动记为 `gui` / `ios` 且 `emit()` 不把 `detail` 拼进 `message`；不传记为 `discord`；
  - PATH 至少要有 `/opt/homebrew/bin`（脚本也会自己补）。
- **GUI 专用命令**（`maa_action.dispatch_gui()`）**不进 Discord 的登记表，也不写进技能**。从 Discord 那条路（`dispatch()`）调它们一律返回失败。

| 命令 | 作用 | `data` |
|---|---|---|
| `config get` | 可改的配置项和当前值。`label` / `group` / `help` 原样上界面，按 REVIEW §3.5 词表写（`test_ui_copy` 扫）；`label` 末尾的括号是单位。分组：早晚场 / 日常 / 自动定关 / 抄作业 / 森空岛 / 运行，GUI「高级」按分组名排，改名两边一起改 | `fields`（`key` / `group` / `label` / `kind` / `default` / 范围）、`groups`、`values`、`meta` |
| `config set <键> <JSON>` / `config patch <JSON 对象>` | 改配置。按 `maa_settings.FIELDS` 白名单校验；`patch` 要么全改、要么全不改 | 同 `config get` |
| `defaults show` / `defaults set stage <关>` / `defaults set task <名> on\|off` | 持久默认值 | `defaults.json` 的内容 |
| `schedule show` / `set <am\|pm> <HH:MM>` / `enable <am\|pm\|depot>` / `disable <am\|pm\|depot>` / `depot on\|off` / `sync` | 早晚场时间、仓库对表开关与内置调度器热重载（不再调 `hermes cron`） | `maa_schedule.schedule_report()` |
| `run choices` | 一键长草页的选项：关卡（和选关卡同源 `_stage_choices()`）、环节开关、锁 / 定时场优先的现状 | `choices`、`switches`、`task_names`、`busy`、`blackout`；`activity`：此刻开放的活动（`maa_plan_card.current_activity()`，和抄作业认同一期，读 MaaCore 活动缓存）`{name, start_at, end_at, stages}`，时间是北京时间 ISO，`stages` 是缓存里排前三的活动关（首页前置用），没有活动是 `null` |
| `copilot stages` | 自动抄作业的关卡列表（和抄作业卡同源 `copilot_card_stages()`），只读本地。「已通」和 watcher 同一把尺子：记账，或森空岛区域进度按游戏数据的区域链精确到关（`maa_gamedata.skland_cleared()`，只算普通，森空岛不分突袭） | `stages`（每行 `stage` / `code` / `nav` / `reason` / `status` / `status_text` / `ledger_cleared`：本地记账里有通关记录，可撤销）、`in_activity` |
| `run local <关> <开关 JSON> [--force]` | 本机手动场：`--force` 只解除「定时场优先」，不解锁 | `token` 等 |
| `plan today` | 今天早场、晚场各打算做什么。只读本地（不联网、不重算自动定关、不写盘），首页场卡用 | `date`；`sessions[]`（按 am、pm）：`phase` / `name` / `time` / `enabled`（`session_schedule`）、`stage`、`stage_source`（`auto` / `discord` / 空 = 默认关）、`skip`、`tasks`（`effective_plan()` 的环节开关，`plan fight off` 后 `fight` 为假）、`drops`（`[{item_id, name, count}]`，自动定关的刷够即停上限，物品名读不出来就是 itemId）、`fallback_stage`、`source` / `updated_at`（这场覆盖最后是谁改的）、`choices`（可换的关，和计划卡下拉同源 `_stage_choices()`）；`task_names` |
| `plan refresh-card <场>` | 让 Discord 上的计划卡跟着刷新 | — |
| `copilot preview <关>` / `copilot go <token> [作业 id]` | 抄作业：先预览、再确认（K13）。`go` 只接受完全满足的候选，并且要过 `dispatch_blocker()` | 候选列表（带 `perfect`）、`best_id`、`token` |
| `upstream status [--online]` | 上游状态，默认离线、< 2 秒 | 见 12.3 |
| `upstream update` | 过闸门后派一个 worker，立即返回；GUI 每 2 秒轮询 `upstream status`，直到 `running` 变成 false | `started`，或 `blocked` |

**GUI 也用的通用命令**（在 `dispatch()` 里，Discord 和 GUI 走同一个入口，回执没有 `data`）：

- `plan set-stage <关> <场>` / `plan skip-today on|off <场>` / `plan fight on|off <场>`：首页场卡的换关、跳过 / 恢复、「刷理智」开关，点了就生效。成功时 GUI 不显示 `message`、重读 `plan today`；失败原样显示 `message`。带 `MAA_ACTION_SOURCE=gui` 时 `_save_override()` 会在脱离会话的子进程里调 `plan refresh-card`，Discord 上的计划卡跟着变。改计划不动游戏、不持锁；那一场开跑后改的不影响它（#10），所以 GUI 在那一场今天已开始后不再给改。
- `plan auto-stage <场>`（GUI 专用，`dispatch_gui`）：场卡下拉里的「自动选关」。马上按材料缺口算一次（`current_farming_result()` + `apply_auto_stage(force=True)`），把这一场的关写成 `stage_source = auto`（带 `farming_drops` / 后备关），用户之前手动选的关也让出来，之后建卡时自动定关可以继续改它。算不出来回 `auto_unavailable`、不动原来的关。`data = {"stage": 定下的关}`。
- `copilot auto on|off`：抄作业页「规则」弹窗顶上的「自动抄作业」开关（§5.5、#55），和 Discord 的暂停 / 恢复按钮同一个命令。GUI 显示的开关状态读 `copilot/auto_pause.json` 的 `paused`（文件不在 = 没暂停），点了调命令再重读；`by` 记谁改的（`MAA_ACTION_SOURCE`，GUI 是 `gui`）。暂停时这一关打完才停，回执里会说。
- `copilot mark-cleared <关> all` / `copilot unmark <关>`：抄作业页右栏的「我打过了」（普通 + 突袭都记上）/「撤销通关记录」（`ledger_cleared` 为真才显示），只改本地记账，做完 GUI 重读 `copilot stages`。
- `run cancel`：状态条的「停止」在 `run.lock` 持有者是 `daily` / `copilot` 时先弹确认、再调它，然后刷新状态；被停的那一场写 `last_run.status = cancelled`（#64）。

实现细节：`run local` 不发选关卡，关卡白名单 → 开关校验（`fight/infrast/recruit/mall/award/annihilation`，只认真布尔，五项全关拒绝）→ 锁 → 拒绝窗（`--force` 只跳过这一条，锁冲突永远不能强行）→ 预检 → 收掉 Discord 上没选的选关卡（`superseded`）→ 写 `manual_run.json`（`dispatched` + `tasks` / `annihilation` / `source` / `forced`）→ `Popen maa_daily.py now <token>`；`maa_daily.apply_local_switches()` 只把开关叠到这一场，不进 `plan.json`（M4）。`copilot preview` 要 5～20 秒、不走 Discord 的 20 秒路径（#6）：持 `copilot_search.lock`、森空岛刷新失败直接报错、绕过 12h 缓存搜全部候选，返回每份是否完全满足（`maa_copilot.is_perfect()`，与 `pick_perfect_candidate()` 同一判据）、缺什么，自动选中第一份完全满足的，存 `copilot/previews/<token>.json`（30 分钟，不在 `searches/` 下）。`copilot go` 被挡什么都不写，否则发「已排程」卡 → 写 `searches/<新 token>.json` 为 `queued` → `dispatch_batch()`；同一次预览只能派一次。

### 12.2 锁
- **路径**：`$WADOS_MAA_HOME/state/maa/run.lock`，用 `flock(LOCK_EX | LOCK_NB)`。GUI 只读它看谁在用游戏，自己不抢（2026-11-09 起 GUI 是纯前端，动游戏都走 maa-remote 的命令）。
- **持有者标记**（K15）：拿到锁后，把锁文件内容整个换成一行 JSON：`{"holder": 种类, "detail": 补充, "pid": 进程号, "since": ISO 时间, "run_id": 唯一场次ID}`。放锁前清空。
  - 种类：`daily` / `copilot` / `depot` / `update`。`gui` 是旧版 GUI 在进程内跑上游功能时写的，现在没有来源；`LOCK_HOLDER_LABELS` 里留着只为兼容。
  - 标记只在锁**确实被占着**时可信（`maa_common.run_lock_holder()`）。
- 日常发现持有者是 `update` 时会等它跑完（K17）。是别的持有者就按锁冲突上报（#23），消息里写明是谁。

### 12.3 状态文件（GUI 只读）
所有文件都带 `schema_version`。GUI 读到比自己认识的更高的版本，就只读不写，并给出提示。

| 文件 | GUI 用到的字段 |
|---|---|
| `config.json` | `session_schedule`、`config_meta`、`maa_core_version` / `maa_cli_version`，以及 `config get` 列出的键 |
| `last_run.json` | `status`、`phase`（`am` / `pm` / `now` / `copilot-<token>`）、`started_at` / `finished_at`、`summary`、`plan.stage` / `plan.tasks`（日常）、`stage`（抄作业）、`resource_update_*`、`log`（本场 maa-cli 日志的绝对路径。日常、手动场、抄作业**开跑那一笔就写上**，运行中逐行追加，GUI 只读新增部分、按 `<Task> Start` 显示当前阶段；文件可能还没建，或者在 maa run 开写前仍是同名旧场的内容——修改时间早于 `started_at` 的当没有，文件变短就从头读）。新一场开跑时只属于上一场的字段会被整批删掉（§6 `new_run`），读不到就当没有；判成败只看 `status`（`running` / `success` / `failed` / `skipped` / `cancelled`），不要读 `ok`。`thread_id` 可能是 `null`（Discord 不可用，#63），`report` 是本场战报文件 `runs/<场>-report.json` 的路径（日常才有）；`progress` 是本场进度文件的路径（日常开跑那一笔就写上；没有这个键 = 旧版 maa-remote 或抄作业，GUI 退回解析 `log`） |
| `runs/<场>.progress.json` | 见下表。GUI 正在跑时每秒读一次（`state/maa/` 的目录监听收不到 `runs/` 里的改动），跑完再读一次终态 |
| `runs/index.jsonl` | 场次索引，见下表。GUI 每次重读状态（`last_run.json` 一变）时整份读一遍，首页「最近几场」和「近 N 场成功」用它；文件不在或一行都读不出来就退回只显示 `last_run.json` 那一场 |
| `copilot/auto_pause.json` | `paused`（自动抄作业是否暂停）。`state/maa/` 的目录监听收不到子目录的改动，GUI 靠重读状态时顺带读它（60 秒兜底轮询） |
| `plan.json` / `defaults.json` | 本场关卡、跳过；默认关和默认任务 |
| `upstream.json` | 见下表 |

`progress.json` 的字段（#65：只增不改语义；原子写，读到半个文件不会发生）：

| 字段 | 含义 |
|---|---|
| `schema_version` | 现在是 1 |
| `kind` | `daily`；以后抄作业写 `copilot`（`steps` 换成一关一格，其余字段不变） |
| `phase` / `started_at` | 和 `last_run.json` 同一场；`started_at` 对不上就是同名旧场的文件，当没有 |
| `updated_at` | 最近一次写的时间 |
| `status` | `running` / `success` / `failed` / `cancelled` / `skipped` |
| `current` | 正在做的那一步的 `key`；没有或已结束是 `null` |
| `steps[]` | 固定 7 格、按执行顺序：`{key, label, state, started_at, finished_at}`。`key` ∈ `startup` / `annihilation` / `fight` / `infrast` / `recruit` / `mall` / `award`，`label` 是界面用词（启动游戏、剿灭、刷理智、基建、公招、商店、领奖）。`state` ∈ `pending` / `running` / `done` / `failed` / `skipped`：计划里没有的事一开始就是 `skipped`，结束时没轮到的也记 `skipped`。`fight` 合并两个刷理智块和后备关补跑 |
| `fight` | `{done, estimate, sanity, ap_cost, drops}`：已打把数；估计总把数（`done + 当前理智 ÷ ap_cost`，刷完后等于 `done`，算不出是 `null`）；`sanity` = `{current, max}` 或 `null`；`ap_cost` 每把理智或 `null`；`drops` = `[{name, count}]`，不含返还的理智 |
| `notes[]` | `{at, text}`，按时间追加：重试、重启、摆窗、补跑、改刷后备关、台前调度、超时、停下。`text` 是给玩家看的一句话，原样显示 |
| `eta` | 预计结束时间（ISO）。按 `runs/` 下最近 20 份旧进度文件里每步耗时的中位数推；还没做的步里有一步没历史就是 `null`；结束后是 `null` |

样例：`maa-remote/tests/fixtures/progress_sample.json`（`test_sample_fixture_matches_what_we_write` 守着字段集）。

ETA 仍按旧进度文件里**每一步**的耗时推：`index.jsonl` 只有整场耗时，换过去反而估不准，所以没改。

`runs/index.jsonl`（#66）：每场结束追加一行 JSON，最旧的在前；部署后从零开始积累，不回填旧场。写的时候持 `runs/index.lock`、一行一次 `O_APPEND`，所以读者要么看到整行、要么没有这行；但还是要**逐行解析、跳过解析不了的行**（例如手动改坏的）和 `schema_version` 比自己认识的高的行。行数超过 600 时裁到最近 500 行。正在跑的那一场还没有这一行，看 `last_run.json`。

| 字段 | 含义 |
|---|---|
| `schema_version` | 现在是 1 |
| `id` | `<日期>-<phase>-<HHMMSS>`（开始时间），同一天多次手动场也不重 |
| `kind` | `daily` / `copilot` |
| `phase` | 和 `last_run.json` 同一套：`am` / `pm` / `now`（手动日常）/ `copilot-<token>` |
| `stage` | 日常：本场要刷的关（不刷理智是空串）；抄作业：这一轮的第一关 |
| `started_at` / `finished_at` / `duration_seconds` | 起止时间（ISO）和整场耗时（秒） |
| `status` | `success` / `failed` / `cancelled` / `skipped`。成功率只算 `success` 和 `failed` |
| `failure` | 只在 `failed` 时有值，按先后取第一条：日常 `startup`（游戏没打开）/ `upstream`（上游状态不对，没开游戏）/ `offline` / `screen_lost` / `timeout` / `proxy` / `task_failed` / `not_home` / `cleanup` / `inventory` / `unknown`；抄作业 `prefight` / `stopped` / `cleanup` / `stage_failed` |
| `skip_reason` | 只在 `skipped` 时有值：`plan`（计划里跳过）/ `game_busy`（你在玩） |
| `retries` / `restarts` / `window_fixes` | 日常：拿不到画面重开 maa run 的次数 / 没登录上重启游戏的次数 / 画面丢了把窗口摆回来的次数；停在主流程外的那种停下是 `null`。抄作业没有这些计数，都是 `null` |
| `rescue` | 日常：`salvage`（代理失误后补跑基建等）/ `fallback`（改刷后备关）/ `null` |
| `won` / `total` | 只有抄作业：通过几项 / 一共几项 |
| `report` / `progress` / `log` | 战报文件、进度文件、maa-cli 日志的路径（没有就是 `null`；抄作业另有 `snapshot`） |

`upstream.json` 的字段：

| 字段 | 含义 |
|---|---|
| `state` | `running` / `done`。被跳过的那次不改它，只写 `last_skip` |
| `source` | `plan_card` / `gui` / `manual` |
| `ok` | 本次是否成功 |
| `started_at` / `finished_at` | 起止时间 |
| `last_success_at` | 最近一次成功的时间 |
| `steps.{cli,core,hot}.{ok,changed,detail}` | 每一步的结果 |
| `core_changed` / `hot_ok` | Core 有没有换、MaaResource 有没有跟上 |
| `cli_*` / `core_*` / `resource_head_*` | 前后版本 |
| `summary` / `detail` | 给人看的摘要和细节 |

`upstream status` 的 `data` 字段：

| 字段 | 含义 |
|---|---|
| `verdict` | `ok` / `stale` / `blocked` / `running` |
| `block_reason` | 被挡的原因 |
| `pinned.{ok,problems}` | `cli.toml` 的钉住项是否完好 |
| `consistent.{ok,reason}` | 上次更新是否自洽 |
| `fresh` | 本游戏日（北京时间 04:00 之后）是否成功更新过（K18） |
| `game_day_start` / `last_success_at` | 本游戏日的起点，最近一次成功的时间 |
| `lock.{held,holder,text}` | 锁有没有被占、被谁占 |
| `versions` | `maa_cli`、`maa_core`、`maa_core_recorded`、`resource_last_updated`、`maa_resource_head`、`beta_core_latest`、`beta_core_checked_at` |
| `update_blocked` | 现在为什么不能点「更新」 |
| `last` | `upstream.json` 原文 |
| `online` | 带 `--online` 时才有：`maa_cli_latest`、`maa_resource_remote_head`、`*_outdated`、`errors` |

### 12.4 GUI 自己要守的
- **不碎石、不吃药、不借助战**。`config get` 里本来就没有这几项（`SettingsTableTests` 守着）。
- **日常和抄作业只走 maa-remote 子进程**，GUI 不自己拼 maa-cli 的任务。
- **更新只调 `upstream update`**。GUI 自己不跑 brew / git / 下载。

## 13. 守护进程与 HTTP API（iPhone App）
`maa_daemon.py` 是唯一常驻进程，由 LaunchAgent `io.github.ffkiyo7.wados-maa.daemon` 经 `wados-maa-launcher` 拉起（`KeepAlive`）。配置在 `daemon/daemon.json`，密钥在 `daemon/secrets.json`（§6）。字段级契约见 [SPEC_DECOUPLE_AND_IOS.md §5](../../docs/SPEC_DECOUPLE_AND_IOS.md)，对不上时以 `maa_api.py` 为准。

### 13.1 调度器
- 6 条任务、北京时间：`plan_card_am` / `daily_am` / `plan_card_pm` / `daily_pm`（场前 10 分钟和开跑时刻，跟 `session_schedule`）、`depot`（04:30，`depot_enabled`）、`activity_watch`（每 15 分钟整刻）。
- 错过的一次性槽位，同一北京自然日、2 小时内、且不在另一场的 `manual_run_blackout_minutes` 保护窗里才补跑；同场先计划卡后日常。`activity_watch` 只跑当前槽位。
- 日常（含手动 `now`）1 小时硬超时：先 `SIGINT` 走 #64 的收尾，90 秒后才 `SIGKILL`；抄作业不设超时。防重入看 `run.lock` / `activity_watch.lock`。
- `SIGHUP` 或 `daemon/reload.flag` 热重载；`maa_schedule.py` 改完时间会自动发。状态写 `daemon/scheduler.json`，`schedule show` 读它。
- 调试：`--once` 只走一个 tick，`--no-api` 只跑调度器不起 API。

### 13.2 传输与鉴权
- HTTPS 监听 `api_host:api_port`（线上 `0.0.0.0:18170`），自签 ECDSA P-256 证书在 `daemon/tls/`。TLS 握手放到工作线程里做、带短超时，慢速半开连接不会卡住别的请求。
- 来源 IP 白名单 `allowed_cidrs`（默认本机和 `192.168.50.0/24`）。Cloudflare Tunnel（`maa.luxraykit.com`）从本机 cloudflared 进来，所以也放行。
- iPhone 按 SPKI SHA-256 固定证书，App 里可存一个备用指纹。轮换：`daemon/rotate_tls.py --stage` 先出新证书和新指纹，填进 App 的备用槽，再 `--activate` 换证书并重载 daemon 和 cloudflared。守护进程每天巡检证书，剩 `tls_warn_days` 天时发 Bark 告警。
- Bearer Token 分两种，`secrets.json` 只存 SHA-256：`full` 能调全部 `/api/v1/*`；`resign_only` 只能调 `POST /api/v1/ios/resign`，别的一律 403。`GET /healthz`、`GET /rescue`（应急停止页）免鉴权。
- 首次配对：`daemon/init_daemon.py` 在终端打印二维码（局域网地址、远程地址、SPKI 指纹、`full` Token）。Token 明文只在这时出现一次，`secrets.json` 里只有哈希。

### 13.3 接口
回执和 §12.1 一样是 `{ok, code, message, detail?, data?}`。写操作一律转成受控 argv 调 `maa_action.py`，注入 `MAA_ACTION_SOURCE=ios`。

| 方法与路径 | 对应 |
|---|---|
| `GET /api/v1/snapshot` | 首屏聚合：锁、`last_run`、进度、今天两场、时间表、上游、自动抄作业开关、活动、调度器、续签 |
| `GET /api/v1/events` | SSE：`progress` / `lock` / `last_run` / `today_plan` / `schedule` / `upstream` / `resign`，`sse_keepalive_seconds`（25）秒一次心跳，防 Cloudflare 100 秒断连 |
| `GET /api/v1/choices`、`/copilot/stages`、`/config`、`/defaults` | `run choices`、`copilot stages`、`config get`、`defaults show` 的 `data` |
| `GET /api/v1/history?limit&offset&kind` | 倒序读 `runs/index.jsonl` |
| `GET /api/v1/runs/<run_id>/{report,screenshot,log}` | 战报、截图（`?thumb=1` 出 JPEG 缩略图）、日志尾部（`?tail=200`）；按 `resolve_run_artifact()` 兼容旧命名 |
| `POST /api/v1/plan/{stage,skip,fight}` | `plan set-stage` / `plan auto-stage`、`plan skip-today`、`plan fight` |
| `POST /api/v1/run/local`、`/run/cancel` | `run local`；`run cancel --run-id`（body 必须带 `run_id`，对不上回 `run_changed`） |
| `POST /api/v1/copilot/preview`、`DELETE /api/v1/copilot/preview/<request_id>` | `copilot preview`，App 自带 `request_id`，可中途取消搜索子进程 |
| `POST /api/v1/copilot/{go,auto,mark}` | `copilot go`、`copilot auto`、`copilot mark-cleared` / `unmark` |
| `POST /api/v1/schedule`、`/defaults`、`/config` | `schedule *`、`defaults set *`、`config set` / `patch` |
| `POST /api/v1/upstream/update`、`/notify/test` | `upstream update`；发一条 Bark 测试推送 |
| `POST /api/v1/ios/resign[?if_due=1]` | 无线续签（§13.4）：没配 UDID 回 501 `not_configured`；带 `if_due` 且没到窗口回 200 `not_due`；正在续签、正在跑游戏回 409 `running` / `run_locked`；否则后台拉起 `maa_ios_resign.py run` 回 202 `started`。`full` Token 记为 App 触发，`resign_only` 记为快捷指令 |

### 13.4 iOS 无线续签（`maa_ios_resign.py`）
免费 Apple ID 的描述文件 7 天过期。状态在 `daemon/resign.json`：`last_signed_at`、`expiration_date`、`status`（`ok` / `due` / `running` / `failed`，快照里按锁现算）、`last_attempt_at`、`last_result`（`ok` / `skipped` / `failed`）、`last_error`、`last_probe_detail`、`log_summary`、`log_path`。

- **窗口**：距上次签名满 120 小时，或离 `ExpirationDate` 不足 48 小时。第一次没有 `resign.json` 时按本机缓存里本 App 最新的描述文件补一份。
- **自动**：守护进程每拍看一眼，在窗口内每 25 分钟拉起一次 `maa_ios_resign.py auto`（脱离会话的子进程）。四个守卫依次是：App 2 分钟内有 `full` Token 请求或开着 SSE（`--app-active`）、`run.lock` 被占、手机不在局域网（`ios_device_lan_ip` ping 不通且 62078 端口连不上）、`devicectl` 找不到 `ios_device_udid`。不满足就记 `last_probe_detail`，不打扰。
- **执行**：持 `daemon/resign.lock`；构建源固定 `~/Developer/wados-maa-deploy`，必须停在 `main` 且 `ios/`、`shared/` 没有未提交改动；先把 `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` 里本 App 的描述文件挪到 `logs/ios-resign/profiles-backup/`（不挪 Xcode 会复用旧文件，S0-1），再 `xcodebuild -allowProvisioningUpdates`（derivedData `~/Developer/forks/wados-maa-build/auto-resign`）。新 `embedded.mobileprovision` 的 `ExpirationDate` 必须严格晚于旧值，否则挪回旧文件、判失败、不安装。最后 `xcrun devicectl device install app` 无线覆盖安装。日志在 `logs/ios-resign/<时间>.log`，留最近 20 份。
- **通知**（`id=ios-resign`，点开到 App 的签名页）：成功发 `passive`；手机离线、安装没成功这类暂时失败不发；第 6.5 天（或离到期不足 12 小时）还没续上、Xcode 账号要重新登录、有效期没后移、部署目录不对，发 `timeSensitive`，同一原因一天最多一次。
- **命令**：`status` 看状态、`bootstrap` 补记录、`run --trigger cli` 立刻续签、`shortcut-token` 给快捷指令重新生成 `resign_only` Token（只显示一次，旧的作废）。快捷指令的配法见 [docs/IOS_RESIGN_SHORTCUT.md](../../docs/IOS_RESIGN_SHORTCUT.md)。

