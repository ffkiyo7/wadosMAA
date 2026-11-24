# 手动场卡在「启动游戏」：游戏中途退出，MaaCore 不会重连

- 日期：2026-11-25
- 一句话：StartUp 点到加载界面时游戏进程退了，摆窗救场用 `open -a` 把游戏重新拉起来，但 MaaCore 还连着旧进程，之后截图全是 `Broken pipe`，一下也点不了
- 相关不变量：#68
- 现行机制：DEV_GUIDE §4「恢复策略」；方案见 `PLAN_GAME_EXITED_MIDRUN.md`

## 经过

| 时刻 | 事件 | 来源 |
|---|---|---|
| 00:23:00 | iOS 派发手动场（OS-9），`run_id = 2026-11-25-now-002300`。游戏原本在跑，`maa run` 连上 PlayTools（「Game is already running!」） | `runs/2026-11-25-now-002300.log` |
| 00:23:09–00:23:23 | StartUp 正常点击：开始 → 开始唤醒 → 加载图标 | `asst.log` |
| 00:23:24 | 游戏进程退出：MaaCore 读 1717 端口得到 `End of file`，随后 `Connection reset by peer` | `asst.log` |
| 00:23:24–00:23:31 | `run_maa()` 看到 `ScreencapFailed` → `settle_game_window()` 找不到窗口 → `launch_game()`。游戏已经不在了，这一步其实是重新开游戏（新 PID 10371，00:23:28 起来），然后挪到 MAA-Game | 运行日志「摆窗：开始 → 没找到窗口」 |
| 00:23:31–00:28:59 | MaaCore 每次截图都 `write: Broken pipe`，不会重连新进程；我们每 30 秒摆一次窗，救不回来。游戏停在登录页，画面正常 | `asst.log`、窗口截图 |
| 00:28:59 | 用户 `run cancel`，终态 `cancelled`，战报 StartUp 一行写的是「没连上游戏（ScreencapFailed），检查 MaaTools 与 MAA-Game 虚拟屏」 | `runs/index.jsonl` |

## 结论

1. MAA 点过，是游戏自己退了。退出原因没查到：`~/Library/Logs/DiagnosticReports/` 没有崩溃报告，统一日志里也没有记录。
2. 截图失败的现有救法只对「窗口被收进侧边栏」有效：那时连接还在，摆回台前就能接着截。进程换了以后旧连接断了，MaaCore 不会重连，摆窗没有用。
3. 救场逻辑无意中把游戏重开了，却没让 `maa run` 重连，结果 `maa run` 一直空转到超时（默认 3000 秒）。
4. 战报的原因写错了，把人引去查 MaaTools 和虚拟屏。

## 改了什么

见 DEV_GUIDE §4「恢复策略」中「游戏中途退出」一行和不变量 #68：跑 maa run 时盯住游戏进程，进程没了或换了就立刻停掉，重启游戏后去掉已跑完的任务链接着跑（最多 1 次）；摆窗救场前先判进程；战报写「游戏中途退出」；抄作业认出退出就停这一轮。退出时会记下本场之后的崩溃报告路径，原因等再出现时再查。
