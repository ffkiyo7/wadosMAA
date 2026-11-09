# 单测靠真实 `~/.hermes` 才绿，还往线上状态里写东西

- 日期：2026-11-04
- 一句话：干净 HOME 下红 24 条、留下几百个备份目录、拿真 token 打森空岛；共享临时 HOME 互相污染；系统 3.9 写 pycache
- 相关不变量：—
- 现行机制：DEV_GUIDE §9「单测必须和线上状态隔离」

以下是瘦身前 DEV_GUIDE（2026-11-09）里的原文，原样搬来，没有改写。文中的 §编号指 DEV_GUIDE 的章节（编号未变）。

---

**原文出处：§9 起因**

起因（2026-11-04 用干净 HOME 复核）：开发机上的「全绿」靠真实 `~/.hermes`，换台机器
就红 24 条；用例每跑一次往 `~/.hermes/backups/maa-setup/` 留一个目录（当时 361 个里
271 个是单测留的）；计划卡用例走到森空岛体检，北京时间 07:50 前跑会拿真 token 打森空岛、
并把当天记成「已体检」，真计划卡那天就不再提醒过期。

---

**原文出处：§9「共享临时 HOME 里不许留状态文件」**

**共享临时 HOME 里不许留状态文件。** 整套单测共用**一个**进程级临时 HOME，不做每用例一个：
`maa_common.STATE_DIR`、`deploy.HERMES_HOME`、`maa_copilot.COPILOT_DIR` 等几十个路径常量在
import 时就算死了，每用例换 HOME 得有一个 helper 统一重绑全部常量、再维护一张常量清单，
收益相对有限。代价是用例能经这个共享 HOME 互相影响——2026-11-04 实测整套跑完里面留着
`state/maa/copilot/stage_index.json`：`maa_daily.execute()` 的用例（`GameProbeTests` /
`LockConflictTests` / `SessionDailyTests`）走到「理智不够让出刷理智」时建了这份关卡索引缓存，
后面的用例读到的就是前一个用例建的。现在这几个类在 `setUp` 里调 `isolate_stage_index(self)`
把它 patch 进自己的临时目录。

---

**原文出处：§9 子进程写 pycache**

用例起的 Python 子进程（`sys.executable`）同样会往共享 HOME 写东西：macOS 自带的 3.9 按 `$HOME`
算 `sys.pycache_prefix`，子进程继承临时 HOME 后把标准库 `.pyc` 写进
`Library/Caches/com.apple.python/`（2026-11-04 系统 `python3` 跑整套报 11 个 `tearDownModule` 错误，
3.11 / 3.12 不受影响，所以只跑这两个版本的验收和 CI 都发现不了）。`_isolation` 因此设了
`PYTHONDONTWRITEBYTECODE=1`。**验收时系统 `python3` 也要跑一遍**，且要在没设这个变量的 shell 里跑
（有的工具链会预先设上它，那样就测不出来）：

```bash
env -u PYTHONDONTWRITEBYTECODE /usr/bin/python3 -m unittest discover -s tests
```
