# MaaTouch 握手超 3 秒，MaaCore SIGSEGV，早场 35 秒暴毙（模拟器时期）

- 日期：2026-08-08
- 一句话：模拟器冷启抖动让握手超时，maa-cli 不看 connect 返回值继续跑到段错误；由此加了连接阶段重开
- 相关不变量：—
- 现行机制：DEV_GUIDE §4「恢复策略」（连接阶段重开仍在用；`settle_android_runtime()` 已随模拟器删除）

以下是瘦身前 DEV_GUIDE（2026-11-09）里的原文，原样搬来，没有改写。文中的 §编号指 DEV_GUIDE 的章节（编号未变）。

---

**原文出处：§11 第 14 条**

14. **MaaTouch 握手超 3 秒 → MaaCore SIGSEGV，整场 35 秒暴毙**——这一条和代理失误
    （§11.13）毫无关系，是连模拟器都没连上，游戏里一个键都没点过。

    MaaCore 起 MaaTouch 用的是 `app_process`，等于在安卓里现开一个 ART 虚拟机，
    而它给这次握手的窗口**写死 3 秒**（`call_and_hup_minitouch`）。超时就写
    `unable to find $ from pipe_str:`、抛 `TouchModeNotAvailable`，`Controller::connect`
    返回 false。真正致命的是下一步：**maa-cli 不看这个返回值**，照样
    `Assistant::start()`，`StartUpTask` 拿着没连上的 controller 直接
    `SIGSEGV (Segmentation Fault)`，`maa run` 退 1。

    2026-08-08 早场就是这样没的：08:00:41.105 起 MaaTouch → 3.001s 没回话 →
    08:00:44.106 `TouchModeNotAvailable` + `connect failed` + SIGSEGV，35 秒结束，
    截图停在 BlueStacks 的应用商店首页（游戏根本没启动）。

    - **判据**：`runs/<date>-<phase>.log` 只有五行且含 `TouchModeNotAvailable`，
      没有任何 `X Completed`；`~/Library/Application Support/com.loong.maa/crash.log`
      多出一对 `SIGSEGV` / `Unhandled exception`；截图是模拟器桌面而不是游戏。
      MaaCore 的原始现场在 `debug/asst.log` 里搜 `probe_minitouch | leave`。
    - **它确实是偶发**：整份 asst.log 里历史握手全在 165–395 ms，只有出事那次是
      3001 ms，而 6 秒后同一台机器上 `maa closedown` 的握手只花了 166 ms。
    - **触发条件是模拟器冷启**：`sys.boot_completed=1` 只代表系统起来了，不代表安静。
      2026-08-08 实测冷启：`boot_completed` 在 +7.5s，`app_process` 探针在 +0…+4.3s
      全是 35 ms，**+5.4s 突然卡 2.8s**，+9.2s 恢复；而当天 runner 正好在
      `boot_completed` 后约 5.5s 把场子交给了 MaaCore。同一天二次热启则全程无抖动。
    - **两层修法**（`maa_daily.py`）：
      1. `settle_android_runtime()`——`verify_game_installed` 之后、`maa run` 之前，
         用同样走 `app_process` 的只读命令 `am get-current-user` 探路，要求连着
         `emulator_settle_quiet_seconds`（默认 8s）都快过
         `emulator_settle_slow_seconds`（默认 1.0s）才放行。**卡一次就把安静计时清零**
         ——只数「连着几次快」会正好在抖动前开门。`emulator_settle_timeout`（默认 40s）
         用尽也不阻断，只在战报备注里留一句，因为下面那层兜得住。
      2. `run_maa_resilient()`——`connect_failed()` 认出这一类失败就重开 `maa run`，
         默认 `connect_retry_limit: 2` 次、间隔 `connect_retry_delay: 8` 秒。
         安全闸门是**日志里没有任何一条任务链 Completed**：只要有任务真跑过就绝不重开，
         免得把已经做完的事再做一遍。124/125/130 是我们自己写的返回码，一律不重试。
         所有重试共用同一个 `maa_run_timeout` 预算，日志**追加**进同一个
         `runs/<date>-<phase>.log`，不覆盖上一趟的现场。
    - **实机验收（2026-08-08）**：冷启下 `wait_for_android` 在 +9.2s 返回，闸门又花
      8.5s，+17.7s 才交给 MaaCore，此后探针稳定在 40 ms——正好跨过了那个抖动窗口。
      重试那一层只有单元测试（`ConnectFailureTests`、`ConnectRetryTests`，用当天的真实
      五行日志回放），因为这个崩溃没法按需复现；下次再撞上要盯一眼第二趟是否接上。
