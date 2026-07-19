# 执行计划：时间线缓存图片尺寸升级修复

> v4（2026-07-19）：按 codex 终审修订——统一来源状态表、resolved 写入时机唯一化、
> T4/T6/T9 补边界断言、Web 硬门堵完成定义降级口。
> 前置：`prd.md` v4、`design.md` v4。全部改动在 `apps/aicove_flutter` 内。

## 有序清单

### 步骤 1：复现测试先行（红）

主文件：`test/features/chat/services/conversation_short_window_store_test.dart`。
约定：异步断言用 `Completer`/显式计数＋有界超时，不用固定延迟轮询；探测经 `imageDimensionProbeProvider` override 注入 fake（design §5）；CAS 经 `MessageBlockRepository.updateDataIfUnchanged` 窄接口 spy/override；观测点：`debugMaintenanceEnqueueCount`（实际入队数）、`debugProbeCount`、`debugStaleWriteBackSkipCount`。

- [ ] **T1 收敛矩阵**：仅 `https`（探测数恒 0）；localPath 丢失（恰 1 次探测→attempted，无快照替换/无 DB 写/无通知）；损坏本地图（同上）；成功（1×1 PNG 临时文件，快照得宽高＋恰一次通知）；部分成功（单次通知，好块更新坏块 attempted）；**多来源回退**（失效 localPath＋有效 base64 同块：命中 base64，快照得宽高）；重投影同来源不同块 UUID：attempted 命中不重试。
- [ ] **T2 `peekWindow` 纯读**（复审修订：不触碰私有集合）：用 `replaceMessagesTransient` 安装含候选的快照（该路径不调度），随后多次 `peekWindow`，断言 `debugMaintenanceEnqueueCount` 与 `debugProbeCount` 均不变。
- [ ] **T3 热首值＋无丢通知**：fake repo 首次 seed 正常；用 Completer 挂起占队任务，新订阅 `watchWindow` 断言首值在释放前产出（热旁路）；控制时序使变更恰在「首值已 yield、监听未消费」间完成，释放后断言订阅必收到新窗口；visibility 变体（挂起期间 `hideMessages`）。
- [ ] **T4 来源身份/持久化矩阵**：普通 DB 行（写回后 JSON 其余键逐一原样；新缓存实例装载后探测数 0）；导入场景（DB 行 id ≠ data.id，同来源命中写回）；投影合成块（无行：跳过写回、内存生效、attempted 收敛）；**同 raw 消息、同长度、不同内容的两个 base64**：互不污染（精确校验门）；localPath 与等价 `file://` URI 得同一指纹（规范化）；**同一 payload 在 data URL／裸 base64／含空白包装间切换重投影**：sourceKey 与精确门结论一致，回放成功不丢宽高（终审 N1）。
- [ ] **T5 内容路径调度＋不 await 探测**：分别经 `upsertMessages`/`replaceMessages`/`loadOlderMessages`/`reloadConversationFromRawStore` 引入候选，断言各产生一次**实际入队**；注入挂起 fake probe，断言内容 API Future 先完成；`replaceMessagesTransient` 断言不入队。
- [ ] **T6 CAS 竞态**（复审修订：制造真实新快照）：挂起 probe；期间改 DB 行 A→B **并排队 cache 层 `reloadConversationFromRawStore`**（模拟外部写路径完整时序）；释放后断言：B 行未得 A 尺寸（stale 计数 +1）、reload 安装的新快照未被旧结果覆盖、无多余通知、**全部 stale 后状态表无该来源尺寸**（终审 N3）。变体：软删除行不写回；两行中第二行 CAS 抛错→第一行保留、任务无未处理异常。
- [ ] **T7 映射语义**：几何维护轮前后投影映射仓储零调用（spy）；既有 upsert/replace 映射测试保持绿。
- [ ] **T8 批次接力**（新增）：≥5 个候选、前 4 全败→第 5 个最终被探测（尾处理接力）；前 4 部分成功变体；接力期间排入的内容任务先于下一维护批次执行（顺序断言）。
- [ ] **T9 状态表回放**：无 DB 行来源探测成功→同生命周期重投影/reload 后新块**直接带宽高且不再探测**；DB 写回抛异常变体同样复用；**超容量逐出变体**（注入小上限）：被逐出来源的 attempted 与尺寸同进同出，重投影后允许重新探测一次，不出现「不探测且丢宽高」（终审 N2）。
- [ ] **T10 在途失效**（新增）：probe 挂起时 `clearConversation`/`dispose`→释放后无 DB 写、无安装、无通知、无重排队。
- [ ] probe 单测（`image_dimension_probe_test.dart`，VM）：头信息路径、整图回退、损坏返 null、`File.length()` 超限预检（注入小 byteLimit）、base64 估算预检＋二次校验。
- [ ] 运行：`flutter test test/features/chat/services/` 确认新增红、存量绿。

### 步骤 2：实现（绿）

- [ ] 2.1 `image_dimension_probe/`：`probe_types.dart`（输入含全部来源＋可注入 byteLimit；输出含命中来源）、`probe_io.dart`（`Isolate.run`＋顶层 `_probeSync`：length/估算预检→读取→头信息→整图回退→异常 null；按 localPath→file://→base64 顺序）、`probe_stub.dart`（恒 null）、门面条件 export＋`imageDimensionProbeProvider`。
- [ ] 2.2 来源身份：`_normalizeLocalPath`（design §1：package:path＋Windows 规则＋file:// 归一）、复合指纹（FNV-1a 64 采样 8KB，作用于规范化 payload）、sourceKey；`_isDimensionUpgradeCandidate`；重写 `_snapshotNeedsImageDimensionUpgrade`。
- [ ] 2.3 统一来源状态表 `_sourceProbeStates`（design §2：attempted＋尺寸单表单 LRU，每会话 512 上限、同进同出；尺寸仅在 §4 分类后写入；clear/delete/dispose 清理；上限可注入供 T9 逐出变体）＋ `_installSnapshot` 安装前回放（规范化精确门）。
- [ ] 2.4 唯一安装入口 `_installSnapshot(..., {required bool scheduleMaintenance})` 替换全部 map 写点（参数表见 design §3）；`_expandSnapshotFromDb` 保持纯计算；`peekWindow` 去副作用；`_persistSnapshotUnlocked` 移除内联升级并按职责拆分/改名。
- [ ] 2.5 调度器 `_requestMaintenance`（在途→置 rerun 位）＋维护任务 `whenComplete` 标记移除后的唯一尾处理（接力）。
- [ ] 2.6 维护单轮（design §4）：候选截 4→预标记→解析 backing rows（精确匹配、捕获原文）→注入 probe→全败静默→成功者 CAS 先行（独立原子、无外层事务）→按分类提交内存＋写状态表尺寸（design §2 N3 口径）→单次通知；epoch/_disposed 四处校验；全程 try/catch；不触映射同步。
- [ ] 2.7 `message_block_repository.updateDataIfUnchanged` 窄接口（返回受影响行数）。
- [ ] 2.8 `watchWindow` 重构（design §7：先订阅缓冲＋onError/onDone→首值→缓冲流重读→finally 清理）；`_resolveWindow` 热旁路。
- [ ] 2.9 观测计数器三枚（`@visibleForTesting`）。

### 步骤 3：验证

- [ ] `cd apps/aicove_flutter && flutter analyze`（无新增错误/警告）
- [ ] `flutter test test/features/chat/services/ test/features/chat/conversation_timeline_paging_test.dart test/features/chat/short_window_frontend_boundary_test.dart test/ui/features/chat/pages/chat_page_lifecycle_test.dart`
- [ ] **硬门** `flutter build web`：必须执行且通过；环境缺失 ⇒ 该项验收记「未完成」如实上报，不得降级为 analyze、不得勾选。
- [ ] **硬门** `flutter test --platform chrome test/features/chat/services/image_dimension_probe_web_test.dart`：断言 Web 门面返回 null、无异常、缓存一次 attempted 后静默；该测试文件必须 browser-safe（不得 import `package:drift/native.dart` 等 VM-only 依赖，与主测试文件分离）；chrome 缺失 ⇒ 同上如实上报。
- [ ] 有条件时真机/桌面 `flutter run --no-resident` 冒烟：进入含历史图片消息的会话，首屏即出、无反复刷新；无设备则注明降级为测试验证。

### 步骤 4：审查门（review gate）

- [ ] 全量 diff 交 codex 审查（手动触发），对照复审 6 项必须修订逐一复核闭合。
- [ ] 审查问题修完并复跑步骤 3 后，方可进入收尾。

## 回滚点

- 本任务改动独立成 commit；回滚＝反向应用该 commit（`git revert` 或反向补丁），不得对共享文件 `git checkout --`；回滚前检查工作树并征得用户确认。
- 无 schema 迁移；已写回的 `width/height` 为向后兼容元数据，回滚后保留并可能进入导出/备份（有意行为，见 PRD Q2 决策）。

## 完成定义

PRD 验收标准全部勾选＋两项 Web 硬门**实际执行且通过**＋步骤 4 审查通过。任一 Web 硬门因环境缺失未执行 ⇒ 任务停在 blocked/未完成状态如实上报，**不得进入收尾**（终审 N4：完成定义不留降级口）。桌面/真机冒烟保持软门。

> **2026-07-20 用户裁决**：项目当前不需要直接兼容 Web 端，`flutter build web` 硬门豁免
> （其失败根因为存量 `database.dart` 无条件 import `drift/native`，与本任务无关，改动前即无法 Web 编译）。
> chrome 运行态测试（4/4 通过）保留为探测层平台安全性的常规回归。
> 冒烟软门因本机无 Xcode、真机未连接而降级为测试验证，待真机补验。
