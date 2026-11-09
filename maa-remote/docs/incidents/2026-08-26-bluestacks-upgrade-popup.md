# BlueStacks「有可用更新」弹窗卡死自动启动（模拟器时期）

- 日期：2026-08-26
- 一句话：弹窗不关 Android VM 就不启动，ADB 一直拒绝连接
- 相关不变量：—
- 现行机制：DEV_GUIDE 已不适用（设备层已换成 PlayCover）

以下是瘦身前 DEV_GUIDE（2026-11-09）里的原文，原样搬来，没有改写。文中的 §编号指 DEV_GUIDE 的章节（编号未变）。

---

**原文出处：§11 第 15 条**

15. **（BlueStacks 时期）BlueStacks 的“有可用更新”弹窗会卡死自动启动**——宿主进程已经打开，`open -a`
    也返回成功，但弹窗关闭前 Android 虚拟机根本不会启动，ADB 5555 因而持续拒绝连接。
    `Player.log` 的本次 session 会停在 `/bs3/check_upgrade`，看不到正常启动必有的
    `[QTUI] Start Virtual Machine`。`maa_daily.py` 超时后会据此给出明确诊断，并把原始
    启动错误写入 `last_run.startup_error`；关闭弹窗后 VM 会立即继续启动，无需重装实例。
