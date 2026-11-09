# 晚场全程 ScreencapFailed：游戏从物理屏台前挪走后截不到

- 日期：2026-11-05
- 一句话：显示器开着，游戏开在 Q24G2 上，winmove 挪向 MAA-Game 后台前调度把它收走；由此加了窗口恢复和缩略图识别
- 相关不变量：—
- 现行机制：DEV_GUIDE §0.5

以下是瘦身前 DEV_GUIDE（2026-11-09）里的原文，原样搬来，没有改写。文中的 §编号指 DEV_GUIDE 的章节（编号未变）。

---

**原文出处：§0.5（窗口恢复、挪屏、侧边栏缩略图的实测记录与事故时间线）**

**截图为空 = 窗口不在台前**。`SCRN` 只在游戏窗口在某块屏的台前时有画面；最小化、隐藏、
被台前调度收进侧边栏时回 0 字节，MaaCore 只会刷 `ScreencapFailed`。游戏**不需要是前台
App**。所以运行环境给它一块 BetterDisplay 虚拟屏（`MAA-Game`，1920×1080）独占；台前调度
开着时，**任何别的窗口开到这块屏上都会把游戏挤走**。

**让游戏直接开在虚拟屏上：窗口恢复**（2026-11-05 实测）。游戏把窗口位置存在自己容器的偏好
设置里（`NSWindow Frame MainSceneWindow`），但默认按「新开窗口」启动，**无视存着的位置**，
总开在当前主屏正中 (234, 89)：显示器开着是物理屏 Q24G2，关着是 BetterDisplay 的「主屏」。
启动前把鼠标挪到 MAA-Game 上**没用**（实测两次）。给游戏打开 `NSQuitAlwaysKeepsWindows`
后它按「恢复上次的窗口」启动，直接回到上次关闭时的位置：窗口在 MAA-Game 上时用
`close_game()` 的 TERM 关掉，再拉起两次都直接开在 (2141, 110)、截图正常。所以
`launch_game()` 在游戏**没在跑**时先调 `ensure_window_restore()`：`defaults read` 游戏容器的
偏好设置域（`game_prefs_domain()`），不是 1 就 `defaults write … -bool true`；失败只往 stderr
打一行，不阻断。游戏在跑时（`settle_game_window()` 借 `launch_game()` 激活）不碰设置。
不论显示器开没开，MAA-Game 都在 x=1920，存着的坐标两种布局下都对。显示器关着时的恢复还没实测。

**挪屏是兜底**（2026-11-04 实测）：没恢复成功时 `open -a` 拉起的游戏开在当前主屏上；
11-04 记录的「偶尔直接开在虚拟屏上、偏到右下 (2630, 290)」其实是旧版摆窗按 500×500 空窗口
算坐标挪出来的位置，下次启动恰好被恢复了（见下一段）。`settle_game_window()` 先
`move_to_game_display()`：JXA 读 `NSScreen` 找到 `game_display_name`（默认 `MAA-Game`）的范围，
窗口没有**整个**落在里面就调 `~/.hermes/scripts/winmove
<pid> <x> <y>`（`scripts/winmove.swift`，`deploy.py` 编译，AX `kAXPositionAttribute`）挪过去居中。
winmove 要调用方有**辅助功能**权限，线上是 Hermes gateway 那个 Python；没有就退出码 3、
只记一条警告，不阻断。System Events / JXA 直接设 AX 位置都不行（前者要自动化权限，
后者 `AXValueCreate` 的结构体桥接回 -25200）。

**侧边栏缩略图也算「在屏」**（2026-11-05 复现）：游戏开在你正在用的主屏上，前台一切走，
台前调度就把它缩成约 144×149 的缩略图收进侧边栏——`kCGWindowIsOnscreen` 仍是真，`SCRN`
却回 0 字节。进程另外挂着几条不在屏的 1920×30 横条和一个 500×500 的空窗口。以前
`game_window()` 只认宽 ≥ 300 的窗口，缩略图被滤掉、挑中那个空窗口，按它的尺寸算居中坐标
（winmove 挪的却是真窗口，于是落到 (2630, 290)）；激活后只要「在屏」就返回，不再挪屏。
现在：`game_window()` 只滤两边都 < 100 的横条，`window_shelved()`（在屏且宽 <
`MIN_GAME_WIDTH`）认缩略图，`window_usable()` = 在屏且不是缩略图；`settle_game_window()`
不挪缩略图（AX 挪缩略图没验证过），激活后每 0.5 秒看一次、最多 5 秒，**一回到屏上就马上再挪
一次虚拟屏并居中**；摆不回来时告警里带上窗口尺寸、位置、状态和各块屏的位置（`describe_window()`）。
窗口一旦在 `MAA-Game` 上，主屏怎么切前台都不影响截图（同晚实测）。

**2026-11-05 22:00 晚场事故**（全程 `ScreencapFailed`，补跑同样失败）。系统日志
（`/usr/bin/log show`——zsh 里裸写 `log` 是内建命令，什么也查不到）给出的时间线：21:08
用户打开显示器电源，物理屏 Q24G2 接入成为 (0,0) 主屏、BetterDisplay「主屏」挪到 -1920；
22:00:48 游戏启动，22:00:51 窗口出现在 Q24G2 台前；22:00:55.166 winmove 把它挪向 MAA-Game，
0.37 s 后台前调度触发一次 `desktopPeekMonitorStateDidChange`，此后窗口一直截不到；之后每 ~30 s
摆一次窗（激活 + winmove 到 (2630, 290)）都没救回来。**游戏从启动到收尾一直是前台**
（runningboardd 的 `UserInteractiveFocal` 只有它，22:05:35 才轮到别的 app），所以**不是**有人
操作抢了焦点。根因没定位到：11-04 晚场显示器同样开着、winmove 后 0.08 s 同样有一次桌面窥视，
那场却全部完成；按同样时序真机复现两次也都正常。能确定的只有「从 Q24G2 的台前挪走」这一步
有风险，所以上面的窗口恢复让游戏直接开在 MAA-Game，绕开这一步。
