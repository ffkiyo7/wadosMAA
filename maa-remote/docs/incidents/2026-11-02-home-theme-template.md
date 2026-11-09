# 游戏 26.11.1 主页改版，主页标识和入口全认不出

- 日期：2026-11-02
- 一句话：MaaCore 停在旧版、三丽鸥主题入口认不出就切主题；由用户资源层接管 9 个入口
- 相关不变量：#59
- 现行机制：DEV_GUIDE §10

以下是瘦身前 DEV_GUIDE（2026-11-09）里的原文，原样搬来，没有改写。文中的 §编号指 DEV_GUIDE 的章节（编号未变）。

---

**原文出处：§10 排障表这两行**

| 症状 | 先看 |
|---|---|
| 启动 / 信用商店 / 领取奖励 / 返回主界面一起 Error，截图在主页 | 主页标识 `SwitchTheme@ToggleSettingsMenu` 没命中：`asst.log` 里它的 `match_templ` 分数卡在 0.7 左右。2026-11-02 就是游戏 26.11.1 主页改版、MaaCore 还停在旧版（计划卡停着 = 没人跑 `maa update`）。先 `maa update` 到带新模板的版本 |
| 主页入口（信用商店 / 任务 / 好友…）没命中，任务 Error | 上游 26.11.1 起只认日间主题入口，认不出就走 `SwitchTheme` 把主题切回日间。用户资源层把 9 个 `<入口>-Entry` 整个接管：`next` = 上游 Default + 三丽鸥 `<入口>Sanrio`（`resource/template/UiTheme/Sanrio/*.png`），`onErrorNext` 只剩 `<入口>OriginiteExchangeCancel`（关掉「纯源石兑换合成玉」弹窗后重认一次），**不再切主题**，认不出就直接 Error。换了别的联动主题就照样从 `debug/interface/*_raw.png` 截新的入口模板（避开动画和角标），并给它配 `rectMove`（见不变量 #59） |
