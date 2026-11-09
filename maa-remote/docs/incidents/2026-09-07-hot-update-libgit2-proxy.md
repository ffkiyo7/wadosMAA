# `maa hot-update` 的 libgit2 后端无视代理，07:50 连续两天红卡

- 日期：2026-09-07
- 一句话：hot-update 走 `cli.toml` 的 backend，libgit2 直连 GitHub；改成 `git` 后端
- 相关不变量：#60
- 现行机制：DEV_GUIDE §3 第 1 步、§11 第 18 条

以下是瘦身前 DEV_GUIDE（2026-11-09）里的原文，原样搬来，没有改写。文中的 §编号指 DEV_GUIDE 的章节（编号未变）。

---

**原文出处：§11 第 18 条**

18. **`maa hot-update` 的 libgit2 后端完全无视 `HTTP_PROXY` / `HTTPS_PROXY`**——
    §11.9 只说对了一半：`maa update` 走 reqwest，认代理；`maa hot-update` 走
    `cli.toml` 的 `[resource] backend`，而 **libgit2 后端既不读环境变量代理、也没有
    git config 代理可读**（`MaaResource` 仓库和全局 git config 里都没有 `http.proxy`），
    于是直连 `github.com/MaaAssistantArknights/MaaResource.git`。本机网络下这条直连
    时好时坏，坏的时候就是
    `Error: SecureTransport error: connection closed via error; class=Net (12)`。

    2026-09-07、09-08 连着两天的 07:50 红卡就是这个：`maa-cli 已是最新` + `maa update`
    静默成功（退出码 0、零输出），只有 hot-update 这一步炸了。**辨认方法**：
    `check_and_update_upstream()` 在 core 失败时会把「MaaCore 更新失败，未更新热更新资源」
    写进 detail；detail 里没有这句，失败的就是 hot-update。

    **2026-09-09 实测判据**（把代理指到一个关闭的端口 `127.0.0.1:9`）：

    | backend | 假代理 | 真代理 |
    |---|---|---|
    | `libgit2` | 照样 `Already up-to-date`（**说明压根没走代理**） | 成功 |
    | `git` | 秒失败 `Failed to connect to 127.0.0.1 port 9` | `Already up to date.` |

    **修法**：`config/maa-cli/cli.toml` 的 `backend` 改成 `"git"`（合法取值只有
    `git` / `libgit2`，填别的 maa-cli 直接 panic）。`git` 后端 shell out 到 `git`
    二进制，环境变量代理照单全收；`git` 找不到时 maa-cli 会自己回落到 libgit2
    （字符串 `Failed to execute git, falling back to libgit2 backend`），不会更糟。
    **改完必须 `python3 deploy.py`**：`cli.toml` 是 `--check` 逐字节守住的文件之一，
    不部署就一直 `mismatched`，而且线上跑的仍是旧的 libgit2。

---

**原文出处：§10 排障表这一行**

| 症状 | 先看 |
|---|---|
| 计划卡红「MAA 上游更新失败」，`last_run.resource_update_detail` 里是 `SecureTransport error: connection closed via error; class=Net (12)` | 失败的是 `maa hot-update`（MaaResource 的 git fetch），不是 `maa update`——判据：detail 里**没有**「MaaCore 更新失败，未更新热更新资源」那一行，说明 core 那步过了。根因见 §11.18：`cli.toml` 的 `backend` 必须是 `git`，`libgit2` 会绕开代理直连 GitHub。手动复现：`MAA_CONFIG_DIR=~/.config/maa-cli maa hot-update --batch -vv` |
