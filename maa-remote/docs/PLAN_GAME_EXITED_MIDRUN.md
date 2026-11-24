# 规划：日常跑到一半游戏自己退出时，停下、重开、接着跑

状态：已实现（`dev`），未部署。§4 四个问题都按推荐定了。起因是 2026-11-25 00:23 的手动场（`2026-11-25-now-002300`）整场卡在「启动游戏」。时间一律北京时间。现行说明以 DEV_GUIDE §4「恢复策略」和不变量 #68 为准，事故经过见 `incidents/2026-11-25-now-game-exited.md`。

## 1. 事故复盘（2026-11-25 手动场）

| 时刻 | 事件 | 来源 |
|---|---|---|
| 00:23:00 | iOS 派发手动场（OS-9），抢到 `run.lock`；游戏原本就在跑，`maa run` 连上 PlayTools（「Game is already running!」） | `runs/2026-11-25-now-002300.log` |
| 00:23:09–00:23:23 | StartUp 正常点击：开始 → 开始唤醒 → 进入加载图标 | `asst.log` |
| 00:23:24 | **游戏进程自己退了**：MaaCore 读 1717 端口得到 `End of file`，随后 `Connection reset by peer` | `asst.log` |
| 00:23:24–00:23:31 | `run_maa()` 看到 `ScreencapFailed` → `settle_game_window()` → 找不到窗口 → `launch_game()`（`open -a`）。因为游戏已经不在了，这一步实际是**重新开游戏**（新 PID 10371，00:23:28 起来），并挪到 MAA-Game | 运行日志「摆窗：开始 → 没找到窗口」 |
| 00:23:31–00:28:59 | MaaCore 还拿着旧进程的连接，每次截图都 `write: Broken pipe`，**不会重连**。我们每 30 秒摆一次窗口，救不回来 | `asst.log` |
| 00:28:59 | 用户 `run cancel`，终态 `cancelled` | `runs/index.jsonl` |

能确定的：

1. **MAA 点过，是游戏退了。** 退出前 StartUp 已经点到加载界面。
2. **MaaCore 不会对新进程重连。** 窗口被收进侧边栏时 SCRN 回 0 字节，连接还在，摆回台前就好（这是现有救场逻辑的前提，见 `run_maa()` 注释和 `incidents/2026-11-05-pm-screencap-failed.md`）。进程换了以后连接断了，摆窗没有用。
3. **救场逻辑无意中把游戏重开了**，又没让 `maa run` 重连，结果最差：游戏好好的，`maa run` 却一直空转，直到超时（`maa_run_timeout` 默认 3000 秒）。
4. **战报原因写错了。** StartUp 一行写的是「没连上游戏（ScreencapFailed），检查 MaaTools 与 MAA-Game 虚拟屏」，真正的原因是游戏中途退出。

还不能确定的：游戏为什么退出。`~/Library/Logs/DiagnosticReports/` 没有崩溃报告，统一日志里也没查到。可能是客户端自己重启（比如热更后），也可能是被杀掉。本方案不追查原因，只把现场留下来（§2.4）。

## 2. 改法

### 2.1 认出「游戏进程换了」（`run_maa()`）

- `maa run` 拉起后，第一次拿到非空的 `maa_playcover.game_pids()` 时记作基线。
- 主循环每 `PROGRESS_INTERVAL_SECONDS`（5 秒）查一次 `game_pids()`；查询失败或超时都算「不知道」，不当作退出，也不抛异常。
- 结果为空，或者和基线没有交集，就算**游戏中途退出**：
  1. 先 `terminate` 掉 `maa run`（和熔断同一种写法），返回新的自写返回码 `GAME_EXITED_CODE = 126`，并加进 `SELF_ASSIGNED_CODES`。
  2. 运行日志写一行：退出时刻、旧 PID、新 PID（没有就写「无」）。
  3. 进度文件加 note `game_exited`。
- **摆窗救场前先看进程**：截图失败要摆窗之前，先按上面的规则判一次。游戏已经退了，就走上一条，**不再 `open -a`**，免得重演「悄悄重开、却不重连」。

### 2.2 重开、接着跑（`run_maa_resilient()`）

遇到 `GAME_EXITED_CODE` 时：

1. 次数和预算：`game_exit_retry_limit`（默认 1）用完，或者剩余预算扣掉 `RESTART_ALLOWANCE_SECONDS` 后不到 `MIN_RUN_TIMEOUT_SECONDS`，就放弃。说明里带固定词 `GAME_EXIT_GAVE_UP`，调用方据此跳过补跑。
2. 重开：`restart_game()`（全库唯一的重启实现，#61）→ `settle_game_window()`。上一步已经不再 `open -a`，这里通常是冷启动。
3. 重跑范围按死掉那一趟的输出决定（**待定，见 §4 问题 1**）：
   - **一件事都没做成**（没有任何 `<Task> Completed`，`_made_progress()` 为假）：原计划整场重跑。11-25 就是这种情况。
   - **做成了一部分**：只跑还没 Completed 的任务链。刷理智没 Completed 就照常再跑（理智花多少由游戏决定，`stone`、`medicine`、`series` 都不变）；剿灭只要开过头就不再进（避免重复消耗代理卡）；StartUp 每趟都跑。计划用 `salvage_plan()` 的方式只改 `tasks`，不改快照（#10）。
4. 输出拼接：沿用连接重开的做法，几趟的输出拼在一起交回去。战报对每条任务链取**最后一趟**的状态；死掉那一趟没有收尾汇总，它的进行中任务不能判成完成，要补单测。

### 2.3 战报、索引和 App

- `daily_failure()` 增加 `game_exited`，排在 `offline` 之后、`screen_lost` 之前，只在放弃重开（或补跑那一趟退出）时用；重开后别的任务没跑完照旧是 `task_failed`。重开后跑完了就照常成功，只在说明里加一句「游戏中途退出过，已重开接着跑」。
- `report_payload()` 的说明和 StartUp 那一行都改成「游戏中途退出（时刻）」，不再写「检查 MaaTools 与 MAA-Game 虚拟屏」。
- `PROGRESS_NOTES` 增加 `game_exited`（「游戏中途退出了，重开后接着跑（{n}/{limit}）」）和 `game_exit_gave_up`，两条都过 `test_ui_copy` 的禁用词扫描。
- `last_run` 和 `index.jsonl` 增加 `game_exits` 次数。只增字段（#65、#66），`schema_version` 不变。
- `shared/RunHistory.failureText` 增加 `"game_exited": "游戏中途退出了"`。和后端放在同一个提交里，Mac、iOS 两个 App 都要能编过。

### 2.4 留现场

检测到退出时，在 `~/Library/Logs/DiagnosticReports/` 里找本场开始后、文件名以 `Arknights` 开头的 `.ips`，找到就把路径写进运行日志（只写路径，不读内容）。找不到就写「无崩溃报告」。

### 2.5 不变量与文档

- 新增 **#68**：游戏中途退出由 `game_pids()` 认出，认出后立刻停掉 `maa run`、返回 `GAME_EXITED_CODE`；摆窗救场前必须先判进程，游戏不在就不得 `open -a`；重启只走 `restart_game()`；重跑范围按 §2.2 第 3 条决定；查进程永不抛。来由：`incidents/2026-11-25-now-game-exited.md`（新增）。
- DEV_GUIDE §4「恢复策略」加一段，§10 排障表加一行「`asst.log` 刷 Broken pipe」。
- `run_maa()` 里「MaaCore 会自己重连」那句注释改成只适用于窗口被收走的情况。

## 3. 单测

- `run_maa`：用假 `game_pids` 序列模拟 PID 变化或变空 → 返回 126、写 note、`maa run` 被 terminate；`game_pids` 抛异常或超时 → 不当作退出。
- 摆窗救场：游戏不在时不调 `launch_game()`。
- `run_maa_resilient`：一件事没做成 → 整场重跑一趟；做成一部分 → 计划只剩没完成的链；次数或预算用完 → 带 `GAME_EXIT_GAVE_UP` 放弃；重启调的是 `restart_game()`（沿用 `test_there_is_exactly_one_restart_implementation`）。
- 战报：死掉那一趟的进行中任务不判完成；两趟拼接后取最后状态；`daily_failure` 返回 `game_exited`。
- `swift test --package-path shared`：新增 failureText 后两个 App 都能编过。

## 4. 待你决定

1. **做成一部分时怎么办？** 推荐：只跑没完成的任务链（§2.2 第 3 条）。另一种做法是只在一件事都没做成时整场重跑，做成一部分就停下报红，代码更简单，但做到一半退出的那场后半段就丢了。
2. **最多重开几次？** 推荐 1 次。连着退两次多半不是偶发，再重开也是空转。
3. **抄作业要不要一起管？** 推荐这次只给抄作业加检测：认出退出就停掉这一关，按失败记账、结束这一轮，不自动重开。抄作业的补救规则（#35）和日常不同，自动重开另行规划。
4. **退出原因要不要追查？** 推荐先只留现场（§2.4），等再出现一次、有了崩溃报告或日志再查。

实现完的验证：单测和静态检查；部署前在开发副本手动杀一次游戏进程，确认 5 秒内停下、重开后接着跑，战报写的是「游戏中途退出」。开发副本的 `run.lock` 和线上不是同一个文件，挡不住线上的场次，所以要挑一个前后都没有线上场次、也没有抄作业的时间段，先和你约好再做。

## 5. 实现时的取舍

- `run_maa_resilient()` 仍返回五元组；退出次数从日志行数出来（`game_exit_count()`），免得改动所有桩。
- 掉线重开（#61）原本丢掉此前全部输出；游戏中途退出过时改成只丢掉线那一趟，退出前真跑完的链留给战报。
- `_named_task_section()` 遇到 maa-cli 的分隔线也会结束一段；新增 `_named_task_sections()` 取每一趟的段，刷理智的次数、临期药按段相加，掉落合并统计（`farming_sections()` 也用它记仓库）。
- 抄作业的 `_fight_one()` 多了结论 `exited`，和 `nav` 一样停这一轮、不做战后收尾，记账算失败。
