# 规划：游戏一开就弹「获取网络配置失败」时自动重启重跑

状态：已实现（dev，未部署，真机未验）。起因是 2026-11-09 早场整场 `GameOffline`。时间一律北京时间。现行说明以 `DEV_GUIDE.md` §0.5 末尾和不变量 #61 为准。

## 1. 事故复盘（2026-11-09 早场）

| 时刻 | 事件 | 来源 |
|---|---|---|
| 07:50 | 早场卡更新上游：MaaCore v6.21.4 → v6.22.0-beta.2 | `last_run.resource_update_summary` |
| 08:00:59 | 开跑。探游戏不在线 → `launch_game()` 冷启动（maa 的「Game is already running!」指的就是这个进程） | `runs/2026-11-09-am.log` |
| 08:01:07–08:01:14 | 游戏连 `launcher` / `game-config` / `ak-conf` / `ak-webview.hypergryph.com`，全部走 DIRECT，TCP 都连上了，mihomo 没报错 | `sparkle/logs/core-2026-11-9.log` |
| 08:01:18 | 点「开始唤醒」后立刻弹「获取网络配置失败，请重新登录」 | `asst.log`：`StartUp@OfflineConfirm` 命中 0.996 |
| 08:01:18–08:01:44 | StartUp 点确认重来 6 次（`OfflineConfirmImpl.maxTimes = 6`），每次都弹回来；**之后游戏再没向配置服务器发过请求** | `asst.log` + mihomo 日志 |
| 08:01:45 | 6 次用完，MaaCore 照样报 `StartUp Completed` | `asst.log`：`TaskChainCompleted StartUp` |
| 08:01:45–08:02:59 | Fight / Infrast / Recruit 撞弹窗即停（Error）；Mall / Award 撞弹窗也停，但报 **Completed**；Custom Error | 运行日志 |
| 08:03:02 | `fight_failed_dry()` 成立 → 补跑后备关 TL-9。**没重启游戏**，弹窗还在，同样 6 次后失败 | `runs/2026-11-09-am-fallback.log` |
| 08:04:55 | 收尾截图停在弹窗上，主页 0/9，判红 | `last_run.json` |

对照 11-08 早场（成功）：连完 `ak-conf` 之后会连 `as.hypergryph.com`（账号认证）。今天一次都没连到 `as`，即**卡在拉网络配置那一步，还没到登录**。

能确定的：

1. **本机网络通路没断。** 游戏流量按 `GeoSite(cn)` 走 DIRECT，TCP 都建立了；09:16 复测 `ak-conf` / `as` 都通。失败出在配置服务器的应答上（或 TLS 层），从这台机器上看不到。更像服务端或线路的短时故障，不是我们的配置问题。
2. **点确认救不回来。** 弹窗后游戏不再重新拉配置，只有**重启游戏进程**才会重新拉。MaaCore 的 6 次重点和我们的补跑都是在同一个死掉的进程上空转。
3. **MaaCore 的口径会误报。** `OfflineConfirm`（v6.22.0-beta.2 资源里写着「掉线重连功能已移除」）对 StartUp 以外的任务是 `action: Stop`，被停掉的 Mall / Award 照样报 Completed，战报因此写成「🛒 信用商店 ✅ / 🎁 领取奖励 ✅」，实际上什么都没做。StartUp 用完 6 次也报 Completed。
4. **现有重开闸门接不住。** `connect_failed()` 只认 `ConnectFailed` / `ScreencapFailed` 一类标记，而且见到任何 `<Task> Completed` 就不重开。今天 StartUp / Mall / Award 都「Completed」，所以 `connect_retries: 0`。

还不能确定的：故障持续了多久。最后一次观察到失败是 08:03:52，09:16 已经正常，中间没有数据。

## 2. 改法

### 2.1 认出「从没登录上」（`maa_daily.py`）

新增纯函数 `never_logged_in(lines) -> bool`，三个条件缺一不可：

1. StartUp 那一段（`StartUp Start` 到 `StartUp Completed|Error`）里有 `GameOffline`；
2. StartUp 之后**第一条**任务链的那一段里也有 `GameOffline`（StartUp 用完重试仍在弹窗上）；
3. 日志里没有任何真实进展：没有作战批次（`_fight_times`）、没有掉落（`_drop_pairs`）、没有公招 / 基建计数。

第 3 条是安全闸门：没登录就点不到任何东西，但万一判据被新版输出骗了，有一点进展就不重开，免得重复已经做完的事。

### 2.2 重启游戏再整链重跑（`run_maa_resilient()`）

把现在的连接失败重开循环扩成两类可重开的失败，各有各的次数和等待：

| 类别 | 判据 | 重开前做什么 | 次数 / 等待 |
|---|---|---|---|
| 连接失败（现有） | `connect_failed()` | 摆窗，救不回来才重启 | `connect_retry_limit` 2 次 / `connect_retry_delay` 8s |
| 没登录上（新增） | `never_logged_in()` | **一律重启游戏**，然后摆窗 | `offline_retry_limit` 2 次 / `offline_retry_delays` `[120, 300]` 秒 |

- 重启抽成 `maa_playcover.restart_game(config, trail)`（`close_game()` → `launch_game()` → `wait_for_game()` → 摆窗），`settle_game_window()` 的第 3 级改为调用它，实现只留一份。
- 等待放在重启**之前**：给故障留时间恢复。两次合计约 7 分钟等待，加上每次重启约 40 秒、每趟 maa run 约 2 分钟，最坏多花约 14 分钟，仍在 `maa_run_timeout`（3000s）预算内；预算不够就不重开（沿用 `MIN_RUN_TIMEOUT_SECONDS` 的判法）。
- 每次重开前往运行日志写一行连通性探测：`curl -m 5 https://ak-conf.hypergryph.com/` 的状态码和耗时。只能说明「连得上」，今天这种连上了却拿不到配置的情况它照样显示通，所以只当排障线索，不当闸门。
- 放弃时的说明里带固定词（例：`仍未登录上`），调用方据此跳过补跑，同 `CONNECT_GAVE_UP`。
- 重开的日志追加进同一个 `runs/<date>-<phase>.log`，不覆盖上一趟的现场。

### 2.3 补跑跳过（`execute()`）

`never_logged_in` 重开到底还是没登录上时，`fight_failed_dry()` 那条后备关补跑和熔断补跑都跳过，写一句「游戏一直没登录上，补跑跳过。」。今天 08:03 那趟就是白跑。

### 2.4 战报如实（`extract_summary()` / `progress_content()`）

- **只用最后一趟的输出判各任务状态。** 重开后 `stdout_all` 是几趟拼起来的，`_named_task_section()` 取的是**第一次**出现的 `[名字]`，会读到第一趟的假 Completed。重开时记下最后一趟在 `stdout_all` 里的起点，判状态只切那一段；连接失败的重开同样受益（现在是碰巧没出事：那种情况下每段都是 Error）。
- **撞上掉线的任务一律判失败。** 按 `<Task> Start … <Task> Completed|Error` 切出流式段，段里有 `GameOffline` 就写「❌ 未完成（游戏掉线）」，不管汇总里是不是 Completed。三个 Fight 块共用 `Fight Start`，按出现顺序和汇总的 `[名字]` 配对。
- StartUp 在 `never_logged_in` 成立时写「❌ 没登录上（获取网络配置失败）」。
- 重开过就在备注里写一句：「游戏没登录上，已重启 N 次后登录成功」或「……重启 N 次仍未登录上」。
- `last_run.json` 加 `offline_retries`（int），和 `connect_retries` 并列。GUI 不读它，§12 不用改。

### 2.5 配置

`offline_retry_limit`（int，默认 2，范围 0–5）、`offline_retry_delays`（int 列表，默认 `[120, 300]`；比次数短时，不够的用最后一个值补）。两个键都进 `state/config.json` 种子和 `maa_common` 的 `Config` TypedDict；`maa_settings.py` 的字段表（「运行环境」组，GUI 配置页可改）只放次数——字段表没有整数列表这种类型，等待时间和 `connect_retry_delay` 一样只在配置文件里改。它们不是运行时缓存，不进 `PRESERVED_RUNTIME_CACHE_KEYS`。

### 2.6 不变量（新增 #61）

> 掉线后的自动重启**只在「从没登录上」时做**（`never_logged_in()` 三条全满足）；登录之后才掉线的不重启、不整链重跑，只如实报红。撞上 `GameOffline` 的任务不得判成完成。重开共用 `maa_run_timeout` 预算。

## 3. 这次不做

- **登录后中途掉线**（比如刷到一半断网）：已经花了理智、做了一半基建，整链重跑会重复剿灭入场之类的动作，需要另外设计「从哪接着跑」。这次只保证战报不误报。
- **发现没登录上就提前掐掉 maa run**：剩下的任务撞弹窗几秒就停，整趟约 2 分钟，省下的时间不值得在主循环里再加一个熔断。
- 改 MaaCore 资源层的 `OfflineConfirm`：上游明确移除了重连，覆盖它等于跟上游对着干，而且点确认本来就救不回来。

## 4. 测试

- 把今天两份运行日志原样放进测试数据（`runs/2026-11-09-am.log`、`-fallback.log`），断言：`never_logged_in` 为真；战报里信用商店 / 领取奖励是「游戏掉线」而不是 ✅；StartUp 是「没登录上」。
- 反例：StartUp 段有 `GameOffline`、点确认后登录成功、后面任务正常 → 为假，不重开。
- 反例：登录后某个任务中途 `GameOffline`、前面已有作战批次 → 为假，不重开，只把那条任务判失败。
- `run_maa_resilient`：桩 `run_maa` 第一趟没登录上、第二趟正常 → 重启 1 次、等待取 `offline_retry_delays[0]`、只用第二趟判状态；连续没登录上 → 重开 2 次后放弃，说明带固定词；预算不够 → 不重开。
- `execute`：放弃后不进后备关补跑。
- `restart_game` 只有一份实现：`settle_game_window()` 第 3 级改调它，加一条 grep 断言。
- 跑全量单测 + `ruff` + `pyright`。

## 5. 真机验证

掉线不好造。可选做法：开一场手动场前，在 mihomo 里临时加一条 `DOMAIN,game-config.hypergryph.com,REJECT`，看到第一趟没登录上、日志里写了重启之后撤掉规则，确认第二趟登录成功、战报写「重启 1 次后登录成功」。要动代理配置，**做之前单独确认**。不做的话就等下一次真实故障。

## 6. 待定

1. 重试次数和等待：推荐 2 次、等 120s / 300s。今天的故障至少持续了 2 分 44 秒，第二次等 5 分钟能覆盖大多数短时故障，又不至于拖到撞上别的排程。
2. 真机验证用不用 §5 的 REJECT 规则造故障：推荐做，只影响那一场手动场，做完立刻撤。
3. 第 3 节的「中途掉线接着跑」要不要排进下一步：推荐先不做，等真遇到一次再按现场设计。
