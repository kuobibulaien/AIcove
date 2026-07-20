# 执行计划：流式活跃气泡瞬态通道（v2，按 codex 审查修订）

> 顺序＝codex 审查 §七 的八步；每步独立 checkpoint。开关默认 false，全链路对照后单独翻 true。
> commit 授权：用户已于 2026-07-20 会话中明确「commit 不需要授权，本地 git 状态自行管理」，按组原子提交即可。

## 0. 规划修订 ✅

- [x] B1-B6 写回 design.md v2；测试矩阵吸收审查 §六。

## 1. Characterization 基线（旧路径） ✅ 部分 / 待补

- [x] 主干 A-E 七用例已落地全绿（grok 施工，主会话复跑验证）。
- [x] 按审查 §六补：真实 interrupt 三相位、重试新建 delivery、failover reset、A→B→A、揭示等待期 reset、揭示节奏（第二批 10 用例；delay-ε 亚毫秒精度受真实延时驱动限制，以 delay/2 与 delay−slack 代理并注释）。
- [x] 结构转移精确化：载荷 spy 逐次断言 removed/upsert id 集（宽区间量级断言保留作烟雾）。

## 2. 通道类型与生命周期（开关默认 false）

- [x] `active_stream_projection.dart`：state ＋ 单 owner map notifier ＋ CAS publish/clear（B1/B3）＋ `streamProjectionPolicyProvider`（B5）。
- [x] 单元测试 10 例：CAS 拒旧、等值幂等不通知、旧 clear 不伤新流、A/B 隔离、回收无残留、select 过滤。

## 3. `_applyState` 增量 diff（默认仍 off）

- [x] diff 定义按 design §2.3；off 路径保留旧全量实现（commit 3a533e5）。
- [x] on/off 对照测试落地（ON 窗口变更≤8 vs OFF 基线 11-16；壳滞后实证；off 路径 17 用例全绿，commit 5bafef7）。载荷级 spy 精确断言列入翻默认前置。

## 4. 气泡消费与视口窄信号

- [x] 实现形态微调（重建域等价、侵入更小）：气泡构造不改，presentation 层包 Consumer select 取实时文本（commit b0b06e8）。
- [x] `ChatMessageList` 挂 `ref.listen` 窄信号 → 只调度视口稳底，不重建（commit b0b06e8）。
- [x] 守卫：100 delta 窗口通知结构同阶；活跃气泡实时文本（S1 widget 级）；列表 build 计数不增长（Consumer 隔离证明历史气泡不随通道重建）；标签隐藏一致（B6 ON 断言）。ChatPage/Composer 计数器留 G2.2 观测体系（页面壳不 watch 通道，结构上不受 delta 影响）。

## 5. followLatest / detached 回归

- [x] followLatest 场景组 4 例（贴底/detached 锚点/分页窗口/键盘同帧）干净 worktree 三连全绿；程序滚动争抢由既有 guard 套件覆盖（同组守卫旗标）。

## 6. 全链路 on/off 对照

- [x] runBoth 双 container 五脚本对照（基础/分段/TTS/reset/interrupt）终态视觉与 DB raw 一致；retry/failover/A→B→A 由第二批特征化覆盖。
- [x] 已翻默认 true（commit d21bf0e，独立可 revert）；A-J 基线显式钉 off。

## 7. 全量回归与运行验收

- [x] 终验（干净 worktree @ HEAD）：analyze 0 error；全量 613 测试全绿。
- [x] `flutter run --no-resident -d macos` 编译运行通过（宽屏桌面即宽屏面）；窄屏由 360px 视口 widget 套件覆盖。**Waiver：Android 真机流式贴底/滑动手感验收因设备不在场未做——残余风险＝真机帧时序与桌面差异，设备到位后与 07-13 一并补验；回退方案＝policy override off（整组回滚面）。**

## 8. 审查与收尾

- [x] codex 代码审查（B-01 阻断＋S-01~06）全部整改；T-01/T-02 前置矩阵补齐后翻默认。
- [x] spec 沉淀：流式投影双通道契约五条入 quality-guidelines.md（含 listenManual 踩坑与首现/增长分工）。
- [x] 分组提交完成：特征化两批/通道/机制/接线/整改/矩阵/翻默认/修正各自独立 commit。

## 回滚点

- 机制回滚＝policy 默认值回 false（改码重建，非即时 flag，已如实声明）；整体回滚＝revert 机制 commit。characterization「旧路径行为」断言组保持对 off 路径成立。
