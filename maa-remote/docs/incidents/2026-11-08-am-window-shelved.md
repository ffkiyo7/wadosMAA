# 早场全程 ScreencapFailed：游戏在 MAA-Game 上被收成侧边栏缩略图

- 日期：2026-11-08
- 一句话：游戏一直是前台，`open -a` 无效，摆窗 8 次全失败，重开闸门又被 `AllTasksCompleted` 骗过
- 相关不变量：—
- 现行机制：DEV_GUIDE §0.5「截不到时怎么救」

以下是瘦身前 DEV_GUIDE（2026-11-09）里的原文，原样搬来，没有改写。文中的 §编号指 DEV_GUIDE 的章节（编号未变）。

---

**原文出处：§0.5 事故与 spike**

**2026-11-08 早场事故**（全程 `ScreencapFailed`，后备关补跑同样失败）。这次显示器没接，
主屏是 BetterDisplay 的无名屏。08:00:56 游戏冷启动，窗口按窗口恢复开在 MAA-Game 台前；
08:01:02.753 游戏被激活一次，0.2 s 后台前调度把它收成 **143×124 @ (1936, 493)** 的缩略图，
收进 **MAA-Game 自己的**侧边栏。此后游戏一直是前台（`UserInteractiveFocal`），所以每次
`open -a` 都什么也没发生，摆窗 8 次全失败。同时重开闸门被 MaaCore 那句 `AllTasksCompleted`
骗过，一趟都没重开。

当晚真机 spike（显示器开着）的结论：激活一个**不在前台**的游戏，1 秒内就能把它请回台前，
`open -a`、AX 设前台、关掉挡路的窗口都行；AX 的 `kAXRaiseAction` 加 `kAXMainAttribute`
**无效**；「显示桌面」只把窗口推到屏边，不是这个机制；重启游戏约 36 s，会开回 MAA-Game。
「前台却被收进侧边栏」的状态没能复现。详见 `docs/PLAN_SHELVED_WINDOW.md`。
