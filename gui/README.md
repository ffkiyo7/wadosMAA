# Wado's MAA（Mac App）

maa-remote 的 macOS 前端：今天的早晚场、手动日常、自动抄作业、日常配置和日程。
所有动游戏、动 maa-cli 的事都交给 `$WADOS_MAA_HOME/scripts/maa_action.py`（线上是 `~/.wados-maa`），本 App 不链接 MaaCore。

- 源码：`MeoAsstMac/Remote/`，入口 `MeoAsstMac/MeoAsstMacApp.swift`；和 iPhone App 共用的模型在仓库根的 `shared/`。
- 构建、接口、切环境：见仓库根目录 `AGENTS.md`。
- `docs/archive/`：2026-11-06 起 fork 改造时的计划、简报、功能清单和 spike，只作历史记录。

起家于 [MaaMacGui](https://github.com/MaaAssistantArknights/MaaMacGui)（AGPL-3.0）的 fork，2026-11-09 起上游功能已全部删掉，不再合并上游。
