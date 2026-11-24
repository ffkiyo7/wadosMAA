# Wado's MAA

明日方舟自动化：Mac mini 上常驻的 maa-remote 后端，加一个 Mac App 和一个 iPhone App。

| 目录 | 内容 |
|---|---|
| `maa-remote/` | 后端：日常、抄作业、活动监控等脚本，加守护进程（内置调度器 + HTTPS API），部署到 `~/.wados-maa/` |
| `gui/` | Mac App，本机直接调后端脚本。MaaMacGui 的 fork，上游功能已删光 |
| `ios/` | iPhone App，经 HTTPS API 远程查看和操作 |
| `shared/` | 两个 App 共用的 Swift 包 |

开发、构建、部署见 [AGENTS.md](./AGENTS.md)；规划与进度见 [docs/specs/](./docs/specs/README.md)。

许可证：`maa-remote/`、`ios/`、`shared/` 是 MIT（见各自的 `LICENSE`）；`gui/` 跟随上游 MAA 的 AGPL-3.0。
