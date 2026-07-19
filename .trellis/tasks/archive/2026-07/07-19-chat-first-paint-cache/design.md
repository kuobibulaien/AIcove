# 技术设计：时间线缓存图片尺寸升级修复

> v4（2026-07-19）：按 codex 终审（`scratch/diagnostics/方案终审_chat-first-paint_20260719.md`）
> 落实 N1-N4 四项修正（base64 精确门口径、attempted/resolved 合一状态表、resolved 写入时机唯一化、
> Web 硬门完成定义）；均为终审处方的照单采纳。v3 已闭合项不变。
> 对应 PRD：`prd.md` v4。诊断依据：`scratch/diagnostics/聊天首屏加载慢_codex诊断_20260716.md`。

## 改动边界

- 核心：`apps/aicove_flutter/lib/src/features/chat/services/conversation_short_window_store.dart`
- 新增：`apps/aicove_flutter/lib/src/features/chat/services/image_dimension_probe/`
  - `probe_types.dart`（`ImageDimensionProbeInput`／`ImageDimensions`／`typedef ImageDimensionProbe`，与平台实现解耦）
  - `image_dimension_probe.dart`（门面：条件 export 实现＋`imageDimensionProbeProvider`）
  - `probe_io.dart`（原生：`Isolate.run`）、`probe_stub.dart`（Web：恒 null）
- 辅助：`message_block_repository.dart` **确定新增**窄接口：
  `Future<int> updateDataIfUnchanged({required String id, required String expectedData, required String newData})`
  （where：id＋`deletedAt` null＋`data` 等于原文；返回受影响行数；测试可 override/spy）
- 测试：`test/features/chat/services/conversation_short_window_store_test.dart`（主）＋
  `test/features/chat/services/image_dimension_probe_test.dart`（VM）＋
  `test/features/chat/services/image_dimension_probe_web_test.dart`（chrome 平台）

明确不动：providers（时间线 provider 本体）、`chat_page.dart`、列表侧组件、投影服务本体、DB 表结构（无迁移）。

## 关键设计

### 1. 来源身份（B3 修订：复合指纹＋精确校验双层）

**身份 key**（用于来源状态表、调度判定——允许极小概率碰撞，碰撞后果仅为多一次/漏一次探测，绝不参与「写哪个行/给哪个块」的正确性决策）：

```text
sourceKey = '<rawMessageId>|<composite fingerprint>'
rawMessageId       = message.sourceMessageId 非空取之，否则 message.id（与既有 _messageRawSourceId 一致）
composite fingerprint = 按固定顺序拼接块上**全部**非空来源：
  localPath 部分:  'lp:' + _normalizeLocalPath(localPath)
  file:// url 部分: 归入 lp（toFilePath 后同一规范）
  http(s) url 部分: 'url:' + url.trim()
  base64 部分:     'b64:' + <规范化 payload 长度> + ':' + <FNV-1a 64（规范化 payload 的前 4096＋后 4096 code unit＋长度）>
任一来源变化 ⇒ key 变化 ⇒ 重新成为候选。
```

- `_normalizeLocalPath`：trim → `file://` 先 `Uri.parse().toFilePath()`（含 percent-decode）→ `package:path` 按当前平台 `p.normalize(p.absolute(...))` → Windows 额外统一分隔符为 `\`、盘符大写、整体按不区分大小写折叠比较；**不**解析符号链接。原始值保留用于精确校验。
- base64 规范化：剥 `data:` 前缀、去空白，得到**规范化 payload**；指纹与精确门都作用于规范化 payload。FNV 采样只扫 8KB，主 isolate 上开销可忽略（回应复审 S4 对主线程扫整串的担忧）。
- **精确校验层**（正确性决策必经）：内存应用与 DB 行匹配一律用来源值的精确相等——localPath 用规范化路径全等；base64 用**完整规范化 payload 全等**（N1：同一 payload 在 data URL／裸 base64／含空白等不同包装间切换时，指纹与精确门结论一致；可先走 `identical` 快路径）。原始未规范化值仅供实际 probe 读取。同长度不同内容的 base64 因此不可能互相污染。

**候选判定** `_isDimensionUpgradeCandidate`：已有正数宽高→否；无任何本地类来源（仅 http(s)）→否；来源状态表（§2）中已 attempted→否；状态表中有成功尺寸可回放→否（回放即可，无需探测）；其余→是。判定与执行同源，无空转轮。

### 2. 统一来源状态表（N2：attempted 与 resolved 合一）

`_sourceProbeStates: Map<conversationId, LinkedHashMap<sourceKey, _SourceProbeState>>`，
`_SourceProbeState = { attempted: bool, dimensions: ({int w, int h})?, normalizedSource: String }`：

- **单表单 LRU**：每会话上限 512，超限逐出最早条目——attempted 与成功尺寸**同进同出**，被逐出的来源重新成为候选（最多多付一次探测），结构上排除「attempted 残留而 resolved 已逐出」的失忆错位（N2）。
- **回放时机**：`_installSnapshot` 安装任何快照前，对快照内缺尺寸的图片块按 sourceKey 查表→有尺寸且**规范化 payload/路径精确校验**通过则直接补上宽高（纯同步内存操作）。覆盖：无 DB 行的投影来源、DB 写回失败的来源，在重投影/reload 后既不重探测、也不丢宽高。
- **写入时机（N3，唯一口径）**：`attempted` 在探测前原子预标记；`dimensions` **仅在 §4 分类完成后写入**——「≥1 行 CAS 成功」「有行但仅异常而无成功行（内存降级）」「无 backing row」三种情形写入；**全部 stale、epoch/_disposed 失效、probe 失败一律不写**。不存在「探测成功即写入」的路径。
- 生命周期：`clearConversation`/`deleteConversation`/`dispose` 清理整表。

### 3. 唯一安装入口与批次接力（B2/S1 修订）

**`_installSnapshot(conversationId, next, {required bool scheduleMaintenance})` 是唯一的 `_snapshotsByConversation` 写入口**：

1. §2 回放 resolved 尺寸 → 2. 赋值 map → 3. `scheduleMaintenance` 为 true 且存在候选 → 调用调度器。
- 调用点与参数：`_loadSnapshotUnlocked`（true）、`_ensureConversationReadyUnlocked`（true，expand 结果由它统一安装）、`upsertMessages`（true）、`replaceMessages` 持久路径（true）、`loadOlderMessages`（true）、`reloadConversationFromRawStore`（true）、`clearConversation`（false）、`replaceMessagesTransient`（false，PRD 非目标）。
- `_expandSnapshotFromDb` 保持**纯计算**返回快照，不安装、不调度（复审新问题 4：消除重复安装点）。
- 维护任务自身安装升级结果时用 `scheduleMaintenance: false`（接力由尾处理负责，不经安装点，避免被去重吞掉）。

**调度器与接力**（关键修订，防第 5 个候选饿死）：

```dart
void _requestMaintenance(String id) {
  if (_disposed) return;
  if (_snapshotUpgradeTasks.containsKey(id)) {
    _maintenanceRerunRequested.add(id);   // 在途任务存在：只置位，不入队
    return;
  }
  _enqueueMaintenanceTask(id);            // debugMaintenanceEnqueueCount++（观测点计实际入队数）
}
```

维护任务的 `whenComplete`（即 `_snapshotUpgradeTasks.remove(id)` **之后**）执行唯一尾处理：若 `_maintenanceRerunRequested` 置位**或**当前快照仍有候选（本轮截断的剩余），清位并 `_requestMaintenance(id)`。全败、部分成功、异常退出都必经此尾处理。由于下一轮是重新入队，期间已排队的内容任务先执行（内容插队保证）。

### 4. 维护单轮流程（B4 修订：CAS 先行、分类提交；S2 修订：epoch 失效）

失效控制：`bool _disposed`；`Map<String, int> _maintenanceEpoch`。`clearConversation`/`deleteConversation` 在自身入队**前**递增 epoch；`dispose` 置 `_disposed`。**epoch 条目只递增、永不删除或重置**（清缓存时保留该 map 条目，否则旧任务捕获值可能与重建后的默认值再次相等——终审第 4 项提醒，T10 需有对应断言）。维护任务开始时捕获 epoch，在**每次 probe await 后、每次 CAS 前、内存提交前、尾处理前**校验 `_disposed`/epoch；失效即放弃（不写 DB、不安装、不 notify、不重排队、不写状态表尺寸）。不强杀 isolate，只丢弃结果。

单轮（仍经 `_runConversationTask` 串行；整体 try/catch，绝不抛未处理异常）：

1. 从当前快照收集候选，截前 N＝4；剩余交尾处理接力；
2. 对每个候选：预标记 attempted（探测前原子写入）→ 解析 backing rows：`getByMessage(rawMessageId)` 未删 image 行中**精确匹配**来源的行，捕获 `(row.id, row.data 原文)`，分类「有行/无行」；
3. `probe(input)`（§5；`ImageDimensionProbeInput` 携带块上全部来源，probe 按 localPath→file://→base64 优先级尝试，返回尺寸＋实际命中来源；保持现实现的多来源回退语义——复审新问题 3）；
4. 全部候选失败 → 直接进尾处理（不替换快照、不写 DB、不 notify）；
5. 有成功，逐来源提交（顺序固定：**先 CAS，后内存**）：
   - 有 backing row：逐行独立 CAS（`updateDataIfUnchanged`；**无外层事务**，行间互不回滚，成功行保留——与 T6 一致；merge contract 见 §6）；
     - ≥1 行成功 → 内存提交＋写状态表尺寸；
     - 全部行 stale（受影响 0）→ **丢弃**：不进内存、不写状态表尺寸、不计成功（`debugStaleWriteBackSkipCount`++）；来源已被外部换掉，新来源随其内容安装自成候选；
     - CAS 抛异常（非 stale）→ 该行计失败继续；若该来源无任何成功行且至少一行是异常（而非 stale）→ 仍做内存提交＋写状态表尺寸（内存尺寸正确；下次冷启动对该行重探测一次即收敛）；
   - 无 backing row（投影/raw payload 来源）→ 直接内存提交＋写状态表尺寸（Q1 范围）；
6. 存在内存提交 → 对照**当前**快照按精确来源校验应用 → `_installSnapshot(..., scheduleMaintenance: false)` → `_notifyConversationChanged` 一次；无内存提交 → 静默；
7. 尾处理（§3）。

竞态论证：内存快照在任务内不被并发修改（队列串行）；DB 行可能被外部事务替换——CAS 原文比对保证不污染（B4 缺口 1 的顺序问题由「CAS 先行、stale 即丢弃」消除：stale 结果永远进不了内存，也不会 notify）。

### 5. 平台条件探测（B5/S4 修订）

- `probe_types.dart`：输入携带全部来源＋`byteLimit`（默认 32MB，`@visibleForTesting` 可注入小值）；输出 `ImageDimensions{width,height,hitSource}`。
- `probe_io.dart`：`Isolate.run` 包裹顶层 `_probeSync`：
  - localPath/file://：先 `File.length()` **预检**超限→跳过该来源；再 `readAsBytes`；
  - base64：先按规范化 payload 长度估算解码后大小（`len * 3 / 4`）**预检**→超限跳过；decode 后二次校验；
  - 字节 → `img.findDecoderForData` → `startDecode` 头信息 → 无效再 `img.decodeImage` 整图回退 → 全部异常返 null；按来源优先级依次尝试，命中即返回。
- `probe_stub.dart`：恒 null（Web 禁用回填；候选一次探测即 attempted，静默收敛，无 `Isolate.run` 路径）。
- 注入：`imageDimensionProbeProvider = Provider<ImageDimensionProbe>((_) => probeImageDimensions)`；`conversationTimelineCacheProvider` 构造时读取注入缓存；测试 override 该 provider（B6 注入点唯一化）。
- **验证硬门**：`flutter build web` 必须执行且通过，不得降级为 analyze；另有 chrome 平台运行态测试断言 stub 返回 null 且缓存静默收敛。任一硬门因环境缺失未执行 ⇒ 任务停在 blocked/未完成并如实上报，不得进入收尾（N4）。

### 6. DB 写回 merge contract（S3，已闭合，保持）

在 backing row `data` 原文解出的 Map 上仅覆盖 `width`/`height` 两键为正整数；其余键（含未知键）原样保留；不改 `status/type/messageId/sortOrder` 等 DB 列；软删除行不写（窄接口 where 已含 `deletedAt` null）；CAS 用 data 原文，受影响行数为 0 视为 stale skip。

### 7. `watchWindow` 无丢通知首值旁路（B1，已闭合，保持）

```dart
final changes = StreamController<void>();
final sub = _controllerFor(id).stream.listen(changes.add,
    onError: changes.addError, onDone: changes.close);   // 复审建议：补 onError/onDone
try {
  yield await _resolveWindow(id, limit: limit);   // 热旁路（纯读不入队）／冷 seed（入队）
  yield* changes.stream.asyncMap((_) => _resolveWindow(id, limit: limit));
} finally { await sub.cancel(); await changes.close(); }
```

`_resolveWindow`：内存快照命中 → 直接 `_buildWindow`；缺失 → 入队 `_loadSnapshot`。`peekWindow` 删除调度调用，严格纯读。

### 8. 兼容与回滚（S5，已闭合，保持）

对外 API 签名不变。回滚＝反向应用本任务的独立 commit（不用 `git checkout --`），回滚前检查工作树并征得用户确认。已写回的 `width/height` 为可再生、向后兼容元数据，允许随导出/备份/同步传播（Q2），回滚不清除。

## 观测点（仅计数器，`@visibleForTesting`）

- `debugMaintenanceEnqueueCount`：维护任务**实际入队**次数（非调度请求次数，B6 修订）；
- `debugProbeCount`：探测执行次数（含注入 fake 的调用）；
- `debugStaleWriteBackSkipCount`：CAS stale 跳过次数。

## 风险与化解

| 风险 | 化解 | 验证 |
|---|---|---|
| 首值/监听间丢通知（B1） | §7 先订阅后首值＋缓冲 | T3 |
| 安装点遗漏/重复（B2、新 4） | §3 唯一入口＋expand 纯化 | T5＋enqueue 计数 |
| >4 候选饿死/接力被去重吞（B2、新 1） | §3 rerun 置位＋标记移除后的尾调度 | T8 |
| 指纹碰撞/路径漂移（B3） | §1 双层：采样 FNV 索引＋精确相等正确性门 | T4/T9 |
| 成功结果失忆（新 2、终审 N1/N2） | §2 统一状态表＋规范化精确门＋安装回放 | T4/T9 |
| 多来源回退丢失（新 3） | §5 probe 多来源按序尝试＋返回命中来源 | T1 变体 |
| stale 结果进内存（B4） | §4 CAS 先行、stale 丢弃 | T6 |
| 在途任务失效后提交（S2） | §4 epoch/_disposed 四处校验 | T10 |
| Web 假验证（B5） | §5 build 硬门＋chrome 运行态测试 | 步骤 3 |
| 峰值内存（S4） | §5 length/估算预检在分配前 | probe 单测 |
| 维护占用内容队列（S1 范围取舍） | 单轮 N=4＋接力重入队（内容天然插队） | T8 |
