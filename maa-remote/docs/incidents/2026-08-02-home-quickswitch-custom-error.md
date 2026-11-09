# 早场「返回主界面」空转报 Custom Error

- 日期：2026-08-02
- 一句话：`Custom` 里裸写 `QuickSwitch@ToHome`，`#back` 被丢掉，回到主页也判不了成功
- 相关不变量：#5c
- 现行机制：DEV_GUIDE §4 第 7 步

以下是瘦身前 DEV_GUIDE（2026-11-09）里的原文，原样搬来，没有改写。文中的 §编号指 DEV_GUIDE 的章节（编号未变）。

---

**原文出处：§4 第 7 步**

   最后那个 `Custom` 的 `task_names` **每一项都必须带 `Home@` 前缀**（见
   `maa_daily.HOME_TASK_NAMES`）。MAA 的 `QuickSwitch` 是子程序，点完小房子里的首页图标
   之后只能靠 `next` 里的 `#back` 回到调用方来判定成功，而 `#back` 取的是任务名**第一个
   `@` 之前**的前缀。裸写 `"QuickSwitch@ToHome"` 时前缀是并不存在的 `QuickSwitch`，
   `#back` 被静默丢弃（asst.log 里 `to_be_recognized` 只剩 4 项，资源 json 里是 5 项），
   于是画面明明已经回到主页，却没有任何任务能判定成功，空转到 20 次重试耗尽报
   `Custom Error`——2026-08-02、08-03 两个早场都是这样红的。加前缀后 `#back` → `Home`
   （`action = Stop`），认出主页立即成功收尾。列表是 MAA 自己那套
   `["Home@QuickSwitch@ToHome#next", "Home@ReturnButtons#next"]` 手工展开的：顶层
   `task_names` 原样交给 `ProcessTask`，不走 `next` 列表那套 `#` 展开。
