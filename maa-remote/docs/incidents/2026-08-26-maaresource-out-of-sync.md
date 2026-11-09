# 只跑 `maa update` 留下旧 MaaResource，MaaCore 启动即退

- 日期：2026-08-26
- 一句话：MaaCore 包与热更新层必须一起前进
- 相关不变量：#60
- 现行机制：DEV_GUIDE §3 第 1 步、§11 第 16 条

以下是瘦身前 DEV_GUIDE（2026-11-09）里的原文，原样搬来，没有改写。文中的 §编号指 DEV_GUIDE 的章节（编号未变）。

---

**原文出处：§11 第 16 条**

16. **MaaCore 包与 MaaResource 热更新层必须同步更新**——MaaCore 启动时会用
    `MaaResource` 覆盖包内资源。只跑 `maa update` 可能留下旧 `infrast.json`，它再
    引用新包中已经改名的模板，导致 MaaCore 在真正连模拟器前直接退出。
    计划卡因此在 MaaCore 更新成功后紧接着跑 `maa hot-update --batch`；任一步
    失败都会红卡报错，不再把半更新状态当成可用。
