# 剥掉代理后 `maa update` 连不上 GitHub

- 日期：2026-08-16
- 一句话：日常要剔代理、更新要带代理，两者混了导致更新超时、拖到下一周
- 相关不变量：#12
- 现行机制：DEV_GUIDE §3 第 1 步、§11 第 9 条

以下是瘦身前 DEV_GUIDE（2026-11-09）里的原文，原样搬来，没有改写。文中的 §编号指 DEV_GUIDE 的章节（编号未变）。

---

**原文出处：§11 第 9 条**

9. **日常 `maa run` 要剔除代理；`maa update` 必须带着代理**：
   `maa_disable_proxy` 只对脚本的运行类子进程生效。手动复现日常任务时用
   `env -u ALL_PROXY -u HTTPS_PROXY -u HTTP_PROXY ... maa run ...`，否则 in-run hot update
   连代理会报错。计划卡的 `maa update` 相反，要走本机常开代理访问 GitHub——2026-08-16
   那次就是剥掉代理后 `github.com` 超时，失败还按 7 天间隔算一次，拖到下一周才重试。
   **注意这条只覆盖 `maa update`**：紧跟其后的 `maa hot-update` 是 git fetch，
   带不带代理由 `cli.toml` 的 `backend` 决定，与环境变量无关，见 §11.18。
