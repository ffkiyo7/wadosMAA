# 规划：游戏窗口在 MAA-Game 上被收进侧边栏时救不回来

状态：已实现（dev，未部署）。起因是 2026-11-08 早场全程 `ScreencapFailed`。现行说明以 `DEV_GUIDE.md` §0.5 为准。

## 1. 事故复盘（2026-11-08 早场，北京时间）

| 时刻 | 事件 | 来源 |
|---|---|---|
| 08:00:56 | `launch_game()` 冷启动游戏（pid 52955）。maa 日志里的「Game is already running!」指的是我们刚拉起的这个进程 | `/usr/bin/log`：WindowManager `Connection activated` |
| 08:00:58 | 窗口按窗口恢复开在 MAA-Game 台前，存着的位置是 `2141 111 1478 859`，没问题 | 游戏偏好设置 `NSWindow Frame MainSceneWindow` |
| 08:01:02.753 | 游戏被重新激活一次（WindowServer 键盘焦点链刷新），推测是 `settle_game_window()` 的 `open -a` | WindowServer `chain did update` |
| 08:01:02.965 | 台前调度触发 `StageManagerStripStageTransition` 和 `desktopPeekMonitorStateDidChange`，窗口缩成 143×124 的缩略图，收进 **MAA-Game 自己的**侧边栏，位置 (1936, 493) | WindowManager |
| 08:01–08:06 | 摆窗 8 次，全部失败；游戏**一直是前台 App**（`UserInteractiveFocal`） | 运行日志、runningboardd |

当时显示器 Q24G2 没接，系统只认到「无名主屏 (0,0)」和 MAA-Game 两块屏。

能确定的三个问题：

1. **激活对这种状态无效。** `settle_game_window()` 的救法只有 `open -a`，可游戏本来就是前台，再激活一次什么也不会发生。11-05 晚场也是这样：游戏一直在前台，摆了 7 次都没救回来。
2. **重开闸门被 `AllTasksCompleted` 挡死。** PlayCover 下每条任务链都报 Error，MaaCore 照样打印 `AllTasksCompleted`，而 `connect_failed()` 把它当成「有任务跑完」，于是 `run_maa_resilient()` 一趟也没重开（`connect_retries: 0`）。这条判据是模拟器时期加的（`test_a_run_that_completed_any_task_is_never_retried`）。
3. **补跑跟着白跑。** 补跑（只刷后备关 TL-9）没换任何救法，又是 2 分钟的 `ScreencapFailed`。

还没确定的一点：08:01:02 到底是哪一步触发了收缩。`settle_game_window()` 只在失败时留告警，**不记录自己做了什么**（挪没挪、激活没激活、前后窗口状态），日志里看不出来。

## 2. 改法

### 2.1 摆窗留痕（`maa_playcover.py`）

`settle_game_window()` 每做一步就记一条：进来时的窗口状态、挪屏（目标坐标、winmove 退出码）、激活、激活后的窗口状态、耗时。返回值不再只有告警文本，改成告警加步骤列表；调用方把步骤写进运行日志，不进 Discord（不变量 #9）。下次再出事就能直接看出是哪一步。

### 2.2 换救法：按代价逐级升级（`maa_playcover.py`）

按 §3 的 spike 结果定。窗口被收进侧边栏（`window_shelved()`）时，依次尝试，前一级没救回来才进下一级：

1. **激活**：保留现有的 `open -a`。游戏不在前台时 1 秒内就能救回来（spike 实测）。
2. **切走再切回**：游戏**已经是前台**还被收进侧边栏（今天的状态）时，先激活访达，再 `open -a` 游戏。依据是：spike 里只要游戏不在前台，任何一种激活都能把它请回台前；先切走，就把今天的状态变成了已证实能救的状态。会短暂抢一下焦点。今天的状态没能复现，所以这一级是推断，没有实测。
3. **重启游戏**：`close_game()`（TERM）→ `launch_game()`（窗口恢复会开回 MAA-Game）→ `wait_for_game()` → 再查一次。spike 实测约 36 秒（TERM 退出约 30 秒），重启后窗口回到 MAA-Game 台前，截图正常。

第 3 级只能在**一个键都没点过**的时候做：开跑前，或者 `run_maa_resilient()` 重开前。跑到一半时的那次摆窗（`run_maa()` 主循环里，30 秒节流一次）只做第 1、2 级。

AX `kAXRaiseAction` 加 `kAXMainAttribute` 实测无效，不做，`winmove.swift` 不用改。

### 2.3 重开闸门认清「从头到尾没拿到过画面」（`maa_daily.py`）

`connect_failed()` 只改 `AllTasksCompleted` 这一条：日志里**每一行**都在白名单内时，`AllTasksCompleted` 不算「有任务跑完」，可以重开。白名单是：连接失败标记、`<任务> Start`、`<任务> Error`、`AllTasksCompleted`、Summary 那几行、我们自己追加的说明，以及启动前的热更新 / `Detected connection` / `Using platform` / `Game is already running!`。

`<任务> Completed` 的判据不变；只要出现过一行白名单之外的输出（识别结果、`Fight ... times` 等），`AllTasksCompleted` 就照旧挡住重开。安全闸门还是「没碰过游戏」，只是不再被 MaaCore 那句收尾话骗过去。

现有用例都不用改：`CONNECT_CRASH_LOG` 里有 `Connected`，不在白名单内，所以加上 `AllTasksCompleted` 仍然返回 `""`；不带 `AllTasksCompleted` 的那条照旧返回标记。新增两条用例：用今天日志的原文（全程 `ScreencapFailed` 加 `AllTasksCompleted`）断言**会**重开；同样的日志里夹一行识别输出，断言**不会**重开。

### 2.4 连接失败就不补跑（`maa_daily.py`）

主跑经过 2.3 的重开（含 2.2 的第 3 级）以后，如果仍然判成连接阶段失败，就跳过补跑，战报写一句「游戏画面一直拿不到，补跑跳过」。补跑本身只是换个关卡，救不了截图。

## 3. 真机 spike（2026-11-08 18:46–18:51，持 `run.lock`，holder = `spike`）

当时显示器 Q24G2 开着，三块屏都在。用的是线上 `~/.hermes/scripts` 的设备层函数，外加两个临时 Swift 小工具（AX raise、AX 设前台）。

| 实验 | 结果 |
|---|---|
| 拉起游戏 | 窗口恢复在 MAA-Game (2141, 110)，`SCRN` 正常 |
| 把计算器挪到 MAA-Game 上并激活它 | 游戏被收成 **143×124 @ (1936, 493)** 的缩略图，和今天早场一模一样，`SCRN` 回 0 字节 |
| AX：`kAXMainAttribute = true` 加 `kAXRaiseAction` | 两个调用都返回成功，但窗口仍是缩略图。**无效** |
| `settle_game_window()`（`open -a`，当时计算器在前台） | 1.0 秒救回，截图正常 |
| AX 把游戏设为前台（`kAXFrontmostAttribute`） | 救回 |
| 退出计算器（前台自然落回游戏） | 救回 |
| 只用 winmove 把计算器挪进 MAA-Game、不激活它 | 游戏不会被收走 |
| 「显示桌面」（CoreDock `showdesktop`） | 窗口被推到屏幕边缘 (3828, 97)，不是缩略图，截图照常。**不是**今天的机制 |
| `close_game()` → 等 2 秒 → `launch_game()` → `wait_for_game()` → `settle_game_window()` | 共约 36 秒，窗口回到 MAA-Game，之后 15 秒内一直截图正常 |

**没复现的部分**：今天那种「游戏是前台、却被收进侧边栏」的状态。显示器开着时找不到触发路径。今天和 spike 最明显的差别是 Q24G2 当时没接，主屏是 BetterDisplay 的无名屏；拔显示器会打断正在用电脑的人，这次没试。

实验结束后已关掉游戏（不然 22:00 晚场会按「用户正在玩」跳过），并释放了锁。结果要同步写进 `DEV_GUIDE.md` §0.5。

## 4. 验证与部署

- 单测：`python3 -m unittest discover -s tests`、`uvx ruff@0.17.3 check`、`uvx pyright@1.1.414`。`test_playcover.py` 里补 2.1、2.2 的分支（桩 `subprocess`，按惯例桩 `maa_playcover.<函数>`）。
- 文档：`DEV_GUIDE.md` §0.5 的「三道防线」改成新流程，§11 记今天这次事故。
- 部署按 AGENTS.md 的流程走。`winmove.swift` 改了要由 `deploy.py` 重新编译，`--check` 要过。
- 线上验证：部署后观察下一个早场 / 晚场的运行日志里有没有 2.1 的留痕。真机没验过的部分在提交说明里写明。

## 5. 不做的事

- 不关台前调度：那是用户的桌面习惯，而且 MAA-Game 独占一块屏的方案本来就是为了和它共存。
- 不点缩略图（合成鼠标点击）：会动用户的鼠标；只有 2.2 的三级都不行时才考虑。
