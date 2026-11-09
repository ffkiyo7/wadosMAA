# 整套单测真的开关了一次游戏

- 日期：2026-11-04
- 一句话：Depot 用例桩在 `maa_daily.launch_game` 上，实际调的是 `maa_playcover.launch_game`
- 相关不变量：—
- 现行机制：DEV_GUIDE §9「单测碰不到真游戏」

以下是瘦身前 DEV_GUIDE（2026-11-09）里的原文，原样搬来，没有改写。文中的 §编号指 DEV_GUIDE 的章节（编号未变）。

---

**原文出处：§0.5「单测碰不到真游戏」**

**单测碰不到真游戏**：除 `test_playcover.py` / `test_state_schema.py` / `test_isolation.py`
以外，每个 `tests/test_*.py` 的 `setUpModule()` 都调 `_isolation.guard_devices()`，把 `maa_playcover.subprocess` /
`socket` 换成一碰就抛 `RealGameTouched`（BaseException，`except Exception` 吞不掉）的桩。
2026-11-04 就是 Depot 用例桩了 `maa_daily.launch_game`、实际调的是 `maa_playcover.launch_game`，
整套单测真的开关了一次游戏。设备层自己的行为在 `tests/test_playcover.py` 里对着一个本机
假 MaaTools 服务端测。**桩设备函数一律桩 `maa_playcover.<函数>`**（如
`patch.object(maa_playcover, "launch_game")`）：所有调用方（日常 / Depot / action / 两个 worker）
都写 `import maa_playcover` + `maa_playcover.launch_game(…)`，不留自己的同名引用，所以桩在
`maa_daily` 之类调用方模块上不会生效。`scripts/` 里禁止 `from maa_playcover import …`，
有 AST 用例守着（`test_scripts_never_from_import_the_device_layer`）。
