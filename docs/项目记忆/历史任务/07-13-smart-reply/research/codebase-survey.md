# Smart Reply 代码库调研报告

> 调研日期：2026-07-13  
> 范围：`apps/aicove_flutter/`（只读）  
> 目的：为「智能回复建议」功能设计提供可落地的代码锚点  
> 约束：本报告仅写入 `.trellis/tasks/07-13-smart-reply/research/`，未改业务代码

---

## 1. 聊天界面结构

### 1.1 「回到底部」按钮

| 项 | 锚点 |
|---|---|
| 按钮 UI 构建 | `apps/aicove_flutter/lib/src/ui/features/chat/widgets/chat_message_list_presentation.dart:284-314`（`_buildJumpToBottomButton`） |
| Tooltip 文案 | 同文件 `:288`（`'回到底部'`） |
| 点击行为 | 同文件 `:293` → `widget.viewportController.onJumpToLatest` |
| 尺寸常量 | `.../chat_message_list.dart:51`（`_kJumpToBottomButtonSize = 44.0`） |
| 显示阈值 | 同文件 `:50`（`_kJumpToBottomVisibilityThreshold = 120.0` 逻辑像素） |
| 显示/隐藏判定 | `.../chat_message_list_viewport.dart:540-545`（`_shouldShowJumpToBottomButton`） |
| 叠放位置 | `.../chat_message_list.dart:616-621`（`Stack` 内 `Positioned(right: 14, bottom: jumpToBottomBottomOffset)`） |
| bottom 偏移计算 | 同文件 `:539-542`（`bottomOverlayHeight` 或 `safeBottom` + 14） |
| 视窗模式控制 | `.../chat_viewport_controller.dart:3-94` |

**显示逻辑（可操作摘要）：**

1. 视窗进入 `ChatViewportMode.detached`（用户手势上滑 / 历史分页）时才可能显示按钮（`chat_viewport_controller.dart:36-47`、`chat_message_list_viewport.dart:541`）。
2. 距底部距离 `_manualDetachedDistanceToBottom >= 120` 才显示（`:544`）。
3. 无时间线内容时不显示（`:541` 的 `!_hasTimelineContent`）。
4. 点击调用 `onJumpToLatest()` → 切回 `followLatest` + 递增 `scrollToBottomRequestSerial` 触发动画贴底（`chat_viewport_controller.dart:61-67`）。

**文件结构说明：** `chat_message_list.dart` 通过 `part` 拆分 presentation / timeline / viewport（`chat_message_list.dart:36-38`），按钮方法在 presentation part 中，判定在 viewport part 中，同属 `_ChatMessageListState`。

### 1.2 Composer 如何填入文本

| 项 | 锚点 |
|---|---|
| `TextEditingController` 持有者 | `apps/aicove_flutter/lib/src/features/chat/presentation/widgets/composer.dart:120`（`_ComposerState._ctrl`，**私有**） |
| 跨组件填入通道 | `apps/aicove_flutter/lib/src/features/chat/chat_actions.dart:1239-1240`（`editingTextProvider = StateProvider<String?>`） |
| 首帧检查填入 | `composer.dart:238-248`（`_checkEditingText`：读 provider → `_ctrl.text = ...` → 清空 provider → 弹键盘） |
| 运行时监听填入 | `composer.dart:885-893`（`ref.listen(editingTextProvider, ...)` 同样写 `_ctrl` 并弹键盘） |
| 草稿恢复写控制器 | `composer.dart:355-369`（`_applyDraftText`） |
| 编辑消息触发填入 | `chat_page.dart:1344-1350`（`onEditMessage` → `editingTextProvider.notifier.state = text`） |

**结论：** 没有公开的 `ComposerController`。往输入框塞文本的既有模式是：

```dart
ref.read(editingTextProvider.notifier).state = candidateText;
```

Composer 内部监听后写入私有 `_ctrl` 并请求焦点/键盘。Smart Reply 点候选应复用此通道，**不要**试图拿到 `_ctrl` 引用。

### 1.3 聊天页布局层级

入口：`apps/aicove_flutter/lib/src/ui/features/chat/pages/chat_page.dart`。

```
Scaffold
└ body: _buildConversationBackground
   └ Stack                              // :1310
      ├ Column                          // 消息区
      │  ├ [可选 top spacing]
      │  └ Expanded → ChatMessageList   // :1331-1368
      │       └ Stack（列表内部）
      │            ├ CustomScrollView（reverse）
      │            ├ 历史加载 overlay
      │            └ 「回到底部」Positioned  // 列表 Stack 内右下
      └ Positioned(left/right/bottom:0) // :1374-1378
         └ Composer                     // 贴底输入区
```

关键耦合：

| 项 | 锚点 |
|---|---|
| Composer 高度 → 列表底部留白 | `chat_page.dart:336-339`（`_handleComposerHeightChanged` → `_composerOverlayHeight`） |
| 传给列表 | `chat_page.dart:1338`（`bottomOverlayHeight: _composerOverlayHeight`） |
| 列表用其做 padding / 按钮 bottom | `chat_message_list.dart:508-510, 539-542` |
| ViewportController 生命周期 | chat_page 持有，传给 `ChatMessageList`（`:1339`） |
| Composer 点击 → 视窗回调 | `chat_page.dart:1381` / `:342-343`（`onInputTap` → `onComposerTapped`，当前实现为空操作） |

**对 Smart Reply 的布局含义：**

- 「回到底部」在 **ChatMessageList 内部 Stack**，不是 chat_page 顶层。
- 开关/气泡若要「在回到底部旁」，最自然的挂载点是同一 `Stack` 的 `Positioned`（与 `:616-621` 并列），或把两个按钮包成右侧浮动按钮组。
- 需要考虑：回到底部仅在 detached 时出现；Smart Reply 开关可能要常驻（开启后气泡常显），二者可见性策略不同。

---

## 2. AI 生成链路

### 2.1 调用栈总览

```
UI / UseCase
  → ChatSendUseCase / BackgroundAgentService / MultimodalAssistantService
    → ChatSendApiRunner.executeApiCall          // chat_send_api_runner.dart:61
      → ProviderAdapterFactory.getAdapter       // :122-126
      → AgentApiClient.sendMessageRich          // 非流式 :217-235
        或 sendMessageRichStream                // 流式 :244-269
          → 各 ProviderAdapter 拼 body / 解析
```

| 层 | 职责 | 锚点 |
|---|---|---|
| `ProviderAdapter` | 端点/Header/Body/解析抽象 | `lib/src/core/api/providers/provider_adapter.dart:100-135` |
| 具体适配器 | openai/claude/gemini/minimax/zai… | 同目录 `*_adapter.dart` |
| `AgentApiClient` | HTTP 客户端门面 | `lib/src/core/api/agent_api.dart:71+` |
| 非流式入口 | `sendMessage` / `sendMessageRich` | `agent_api.dart:700-820` |
| 流式入口 | `sendMessageRichStream` / `sendMessageStream` | `agent_api.dart:827+`、`agent_api_stream_support.dart` |
| 主链路 runner | 流式/非流式选择 + tool 多轮 | `chat_send_api_runner.dart:61-269`（`enableStreaming` 控制） |
| 请求配置 | modelFullId / apiBase / key / temp | `chat_request_config.dart:292-357`（`buildRequestConfig`） |

### 2.2 一次性非流式先例（重点复用）

#### A. BackgroundAgentService（最贴近 Smart Reply）

| 项 | 锚点 |
|---|---|
| Provider | `background_agent_service.dart:42-69` |
| 执行入口 | `:175-287`（`run({ definition, conversationId, ... })`） |
| 上下文加载 | `:289-301` → 默认 `chatHistoryStore.loadCanonicalContextMessages`（`:45-48`） |
| 消息组装 | `:304-324`（system + `Message.toHistoryJsonList`） |
| 执行器 | 委托 `ChatSendApiRunner.executeApiCall`，**无 streaming**（`:52-66`） |
| 定义模型 | `background_agent/domain/background_agent_definition.dart:3-22` |
| 窗口规格 | `background_context_spec.dart:1-29`（`lastMessages`、角色过滤、时间戳） |

**Memory 总结如何调用（完整先例）：**  
`memory_service.dart:854-899`：

1. 构造 `BackgroundAgentDefinition`（id/name/objectivePrompt/contextSpec/modelRef/temperature/maxRounds:1）
2. `backgroundAgentService.run(...)`，可传入 `contextMessages` 与 `extraInstruction`
3. 取 `result.text`，再 `_parseSummaryPayload` 解析 JSON（`memory_service.dart:1192+`）

这是 Smart Reply「一次调用、结构化多候选」最该抄的路径。

#### B. MultimodalAssistantService（轻量一次性）

| 项 | 锚点 |
|---|---|
| 服务 | `lib/src/core/services/multimodal_assistant_service.dart` |
| 非流式调用 | `:346-361`（`_runAssistantRequest` → `AgentApiClient.sendMessageRich`） |
| 组消息 | `:365+` 附近 `buildImageAssistantMessages`（system + user） |
| 用途 | 图片描述 / 音视频辅助，**不经过** BackgroundAgent 的 canonical 历史窗口 |

适合「极简 one-shot」参考，但 **不适合** 直接当聊天上下文 Agent（缺 raw 历史装配）。

#### C. 聊天主链路 nonStreaming

| 项 | 锚点 |
|---|---|
| 命令形态 | `chat_turn_command.dart:8, 21-28`（`ChatTurnExecutionMode.nonStreaming`） |
| 图片发送 | `chat_actions.dart:858+`（`ChatTurnCommand.nonStreaming`） |
| 结果 | 仍走 `StandardChatAgent` → `ChatSendUseCase` → 投递到会话消息 |

**不要**用这条路径做 Smart Reply：它会写入会话、走插件/TTS/分段投递，语义是「正式回复」，不是「候选建议」。

### 2.3 当前会话模型 / 供应商如何取

| 来源 | 字段 / 方法 | 锚点 |
|---|---|---|
| 会话实体 | `Conversation.defaultProvider` / `sessionProvider` | `conversation.dart:25-26`；Drift 列 `database.dart:35-36` |
| Agent 定义 modelRef | `sessionProvider ?? defaultProvider` | `standard_chat_agent.dart:35` |
| 实际发送模型队列 | `AppSettings.defaultChatModels`（有序 failover） | `chat_actions.dart:537-538`；`chat_send_use_case.dart:113+` |
| 解析成 API 配置 | `ChatRequestConfigBuilder.buildRequestConfig(settings, modelRef:)` | `chat_request_config.dart:292-357` |
| 输出 | `modelFullId`（`provider:model`）、apiBase、apiKey、temp、topP、context limit | 同文件 `:342-356` |
| Composer 模型选择 UI | 改的是全局 `defaultChatModels` / `defaultModelName` | `composer_model_picker_sheet.dart:35+`、`default_model_settings_page.dart` |

**实务建议：** Smart Reply 默认用 `settings.defaultChatModels.first`（或 `defaultModelName`）经 `buildRequestConfig` 解析；若 PRD 要求「当前会话配置」，读 `conversation.sessionProvider ?? conversation.defaultProvider`，为空再回退全局队列。BackgroundAgent 的 `modelRef` 就是这条解析链（`background_agent_service.dart:164-172`）。

### 2.4 Agent Runtime 契约现状

契约文件：`lib/src/features/agent_context/domain/agent_runtime_contracts.dart`。

| 概念 | 是否已有类型 | 锚点 / 说明 |
|---|---|---|
| `AgentKind` | ✅ | `:8-15`（含 `chat` / `background` / `analyzer` / `summarizer`…） |
| `AgentDefinition` | ✅ | `:391-461` |
| `ContextProfile` | ✅ | `:321-388`（预设 `standardChat`、`backgroundAnalyzer`） |
| `AgentOutputContract` | ✅ | `:281-318`（`standardChat`、`analyzerJson`） |
| `AgentRunRequest` / `AgentRunResult` | ✅ | `:468+` / `:542+` |
| `AgentRuntime` / `AgentScheduler` | ✅ 接口 + `DirectAgentScheduler` | `:566-587` |
| `AgentContextAssembly` 等数据结构 | ✅ | `:800-863` |
| **`ContextAssembler` 接口/实现** | ❌ 仅文档规划 | 架构文 `Agent上下文管理总架构.md:172-197` |
| **`OutputNormalizer` 接口/实现** | ❌ 仅文档规划 | 同上；现有解析散落在 memory 的 `_parseSummaryPayload` 等 |

**已按契约落地（部分）的 Agent：**

1. **StandardChatAgent**（`standard_chat_agent.dart:14-157`）  
   - 提供完整 `AgentDefinition` + `StandardChatAgentRunRequest`  
   - `StandardChatAgentRuntime` 仍委托 `ChatSendUseCase`（外壳迁移，未真正 ContextAssembler）

2. **BackgroundAgent**（并行旧体系）  
   - 用 `BackgroundAgentDefinition` + `BackgroundAgentService`，**尚未**映射为 `AgentDefinition`  
   - 但行为上已是「定义 + 上下文规格 + 非流式 run + 结果」

3. **Memory summarizer**  
   - 通过 BackgroundAgent 跑，`AgentKind.summarizer` 枚举存在，但未单独实现 `AgentRuntime`

**宪法要求 vs 代码现实：**  
README / 项目宪法要求新增 Agent 定义 `AgentDefinition` / `ContextProfile` / `ContextAssembler` / `OutputNormalizer`。当前仓库：

- 前两项有类型可填；
- 后两项**尚无可实现接口**，实现阶段应：
  1. 在 `agent_runtime_contracts.dart`（或邻域）补最小 `ContextAssembler` / `OutputNormalizer` 接口；或
  2. 先用 BackgroundAgent 路径交付，同时用 `AgentDefinition` + 注释/文档标明后续迁移点。

**新增「建议生成」能力建议清单：**

| 工件 | 建议值 |
|---|---|
| `AgentDefinition.id` | 如 `smart_reply_suggester` |
| `agentKind` | `AgentKind.analyzer` 或新增 `toolAgent`/`background`（更贴近「非前台投递」） |
| `triggerKind` | `AgentTriggerKind.userMessage` 或 `stateChange`（用户点气泡） |
| `contextProfile` | 仿 `ContextProfile.backgroundAnalyzer`：identity + conversationWindow + outputContract，**不含完整 memory/tool 权限** |
| `outputContract` | 新建 `smartReplyJson`：仅 `AgentOutputChannel.json`（或 text + 强制 JSON 指令） |
| `deliveryChannel` | **不要** `foregroundConversation`；用 `backgroundTraceOnly` 或未来扩展 `triggerCandidateStore` 语义的 UI 本地缓存 |
| `ContextAssembler` | 输入：`conversationId` + limit；内部只调 `loadCanonicalContextMessages` |
| `OutputNormalizer` | 解析为 `List<String>` 长度 3；容错：markdown fence、缺条数时 pad/截断 |
| 运行路径（现阶段） | `BackgroundAgentService.run` + `maxRounds: 1` + 结构化 prompt |

### 2.5 聊天上下文真相源

| 规则 | 锚点 |
|---|---|
| 项目宪法 / 架构 | `.trellis/spec/project/overview.md`；`docs/.../聊天请求上下文真相源与组装规范.md`；`前后端架构与通信规范.md:19` |
| 规范表述 | DB **raw message** 是唯一真相源；**禁止** UI 投影 / 气泡缓存喂模型 |
| 正确 API | `ChatHistoryStore.loadCanonicalContextMessages`：`chat_history_store.dart:196-208` |
| 实现细节 | 先 `loadAllRawMessages`（`:188-194` → `MessageRepository.getAllByConversationOrderedStable`）再按 `contextStartMessageId` + limit 切片 |
| 投影 API（**勿用于喂模型**） | `loadRecentProjectedMessages` / `loadProjectedMessagesFromRawStore`（`:181-186, 210-221`） |
| UI 时间线 | `conversationMessagesProvider` 等是 read model，含分段/占位/前端删除隐藏 |
| 转 API 历史格式 | domain `Message.toHistoryJsonList`（`message.dart:100+`） |
| BackgroundAgent 已正确接入 | `background_agent_service.dart:45-48` 默认 loadCanonical |

**Smart Reply 硬约束：** 上下文只允许 `loadCanonicalContextMessages`（或等价 raw 路径），再 `toHistoryJsonList`；禁止把 `ChatMessageList` 的 `messages` / timeline 缓存直接塞给模型。

---

## 3. 状态管理与持久化

### 3.1 Riverpod 模式

| 项 | 结论 | 锚点 |
|---|---|---|
| 依赖 | `flutter_riverpod: ^2.5.1` | `apps/aicove_flutter/pubspec.yaml:15` |
| Codegen | **未使用** `riverpod_annotation` / `@riverpod` | pubspec 无该依赖；手写 Provider |
| 常见形态 | `Provider` / `StateProvider` / `AsyncNotifierProvider` | 例：`chat_actions.dart:1233, 1240`；`app_settings.dart:406-410` |
| build_runner | 有（Drift 等），非 Riverpod codegen | `pubspec.yaml:67` |
| 其他持久化依赖 | `shared_preferences`、`drift` | `pubspec.yaml:17, 44` |

### 3.2 用户偏好 / 功能开关如何持久化

两层机制并存：

1. **全局 AppSettings（主路径）**  
   - 内存：`AppSettings` + `AppSettingsNotifier`（`app_settings.dart:406+`）  
   - 写入：`notifier.setXxx` → `_api.updatePartial({...})`（例 `:1015-1018`）  
   - 门面：`UiModelsApi.fetchAll` / `updatePartial`（`ui_models_api.dart:20-28`）  
   - 本地实现（文档口径）：`UiModelsStoreLocalDataSource` 基于 **SharedPreferences**（`docs/后端公共服务库.md:428-441`）  
   - **仓库现状备注：** `features/settings/data/local/ui_models_store_local_data_source.dart` 等文件在**当前工作树中缺失**（`ui_models_api.dart:6-8` 仍 import），以文档 + 门面 API 为准；实现时若编译失败需先恢复该 data 层。

2. **轻量 SharedPreferences 直写**  
   - 例：`direct_mode.dart:23-48`（`prefs.getBool` / `setBool`）  
   - Composer 草稿：`composer.dart` + `shared_preferences`（`composerLegacyDraftStorageKey` 等）

3. **业务 DB（Drift）**  
   - 消息 / 会话字段（含 `sessionProvider`）走 `AppDatabase`，不是设置开关。

### 3.3 完整开关例子：`preferVisionAssistant`

端到端链路（定义 → 读写 → UI）：

| 步骤 | 说明 | 锚点 |
|---|---|---|
| 1. 模型字段 | `AppSettings.preferVisionAssistant` | `settings_models.dart:1004-1005, 1050` |
| 2. 反序列化 | `data['prefer_vision_assistant'] == true` | `app_settings.dart:354, 396` |
| 3. 写入 API | `AppSettingsNotifier.setPreferVisionAssistant` → `updatePartial` | `app_settings.dart:1015-1018` |
| 4. UI 读取 | `settings.preferVisionAssistant` + 本地乐观状态 | `default_model_settings_page.dart:71-72` |
| 5. UI 绑定 | `MoeSettingsRow(trailingType: switchControl, switchValue:, onSwitchChanged:)` | 同文件约 `:129-134` |
| 6. UI 回调 | `_togglePreferVisionAssistant` → `ref.read(appSettingsProvider.notifier).setPreferVisionAssistant(value)` | 同文件 `:390-405` |
| 7. 业务消费 | 发送链路判断该开关 | `chat_send_service.dart:74, 88` |

**另一完整开关：`AutoReplySettings.enabled`**

| 步骤 | 锚点 |
|---|---|
| 模型 | `settings_models.dart:344-345, 362` |
| 持久化 | `app_settings.dart:931-933`（`updateAutoReplySettings` → `auto_reply_settings` JSON） |
| UI 页 | `auto_reply_settings_page.dart:84-93`（draft + `updateAutoReplySettings`） |
| 卡片组件 | `auto_reply_settings_cards.dart`（含 Analyzer 模型/提示词卡片） |

**Smart Reply 持久化建议：**

- **全局开关**（用户是否启用功能）：仿 `preferVisionAssistant`，在 `AppSettings` 加 `smartReplyEnabled` + `setSmartReplyEnabled`。  
- **会话级缓存**（某条 AI 消息的 3 候选）：可先内存 Map / 进程内 cache；若需跨重启，再考虑 Drift 表或 SharedPreferences key（非首要）。

---

## 4. 可复用公共组件

### 4.1 FrostedGlassContainer

文件：`lib/src/ui/shared/effects/frosted_glass_card.dart:157-201`

```dart
const FrostedGlassContainer({
  super.key,
  required this.child,
  this.borderRadius = 12,
  this.padding,
  this.width,
  this.height,
});
```

- **不做** `BackdropFilter`（注释说明避免与背景二次模糊叠加）。  
- 半透明底色 + 描边，G2 圆角。  
- 适合 Smart Reply **候选面板外壳** / 小气泡底。

### 4.2 MoePopupMenu

文件：`lib/src/ui/shared/widgets/menus/moe_popup_menu.dart`

```dart
class MoePopupMenuItem {
  const MoePopupMenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });
}

// 显示
static Future<void> show(
  BuildContext context, {
  required RenderBox targetBox,
  required List<MoePopupMenuItem> items,
});
```

- 使用 **OverlayEntry**（`:91-105`），避免 `showGeneralDialog` 收起键盘。  
- 锚定 `RenderBox`，优先上方，带箭头。  
- 先例：消息长按 `message_action_sheet.dart:39+`。  
- **限制：** 菜单项是 icon+label 横排固定高度，**不适合**直接承载 3 段长候选文案；交互模式（Overlay + 点外关闭）可借鉴。

### 4.3 MoeSwitch

文件：`lib/src/ui/shared/widgets/form/moe_switch.dart:32-49`

```dart
const MoeSwitch({
  required this.value,
  required this.onChanged,
  this.size = MoeSwitchSize.md, // sm | md
  this.enabled = true,
  this.enableHaptics = true,
  this.semanticLabel,
  // 可选色：activeColor / activeTrackColor / inactiveColor / ...
});
```

- 设置页更多用 `MoeSettingsRow` 的 `switchControl` 尾件（见 default_model_settings），聊天浮层可用裸 `MoeSwitch`。

### 4.4 类似交互先例

| 先例 | 模式 | 锚点 |
|---|---|---|
| 回到底部按钮 | 列表内 `Stack` + `Positioned` 圆形按钮 | `chat_message_list.dart:616-621` + presentation `:284-314` |
| MoePopupMenu | Overlay 浮层 + 锚点定位 + 点外关闭 | `moe_popup_menu.dart:43-106` |
| MoeToast | 全局 OverlayEntry 单例 | `moe_toast.dart:40-67` |
| 历史加载条 | 列表顶部 IgnorePointer overlay | `chat_message_list.dart:604-614` |
| FAB（其它页） | `FloatingActionButton` | `auto_reply_trigger_list_page.dart:44`（聊天页未用） |

**Smart Reply UI 组合建议：**

1. **开关 / 入口按钮**：与「回到底部」同级 `Positioned`（右下），样式可抄 `_buildJumpToBottomButton` 的 `MoeG2Decoration` + `InkWell` + 44px。  
2. **开启后的小气泡**：`FrostedGlassContainer` 或同款 surface 容器。  
3. **展开 3 候选**：自建 Overlay / 锚定 `CompositedTransformFollower`，或局部 `Stack` 上展卡片；勿硬套 `MoePopupMenu` 的 item 布局。  
4. **点候选**：`editingTextProvider` 填入；`MoeToast.brief` 可选反馈。

---

## 5. 对 Smart Reply 方案的启示

1. **UI 挂载点明确：改 `ChatMessageList` 内部 Stack，而非只改 chat_page**  
   与「回到底部」并列 `Positioned(right: 14, bottom: jumpToBottomBottomOffset)`。开关可常驻；回到底部仍按 detached 逻辑显隐。注意 `bottomOverlayHeight` 同步，避免被 Composer 挡住。

2. **填入输入框只走 `editingTextProvider`，不要碰私有 `_ctrl`**  
   候选 `onTap`：`ref.read(editingTextProvider.notifier).state = text;` 即可复用编辑消息链路（自动弹键盘、光标到末尾）。

3. **生成链路优先复用 `BackgroundAgentService` + canonical raw 消息，禁止 UI 投影**  
   - 上下文：`chatHistoryStore.loadCanonicalContextMessages(conversationId, limit: N)`  
   - 调用：`BackgroundAgentDefinition(maxRounds: 1, temperature: 偏低, allowedToolNames: [])` + 结构化 JSON prompt（3 条候选）  
   - 解析：仿 `memory_service._parseSummaryPayload`（去 fence → `jsonDecode` → 校验 3 条）  
   - 模型：`settings.defaultChatModels.first` / `defaultModelName`，经现有 `modelRef` 解析；会话 `sessionProvider` 作可选覆盖。

4. **契约上补齐「建议 Agent」定义，交付通道勿走前台会话**  
   最少声明 `AgentDefinition` + `ContextProfile`（可基于 `backgroundAnalyzer`）+ `AgentOutputContract`（JSON 三候选）。现阶段无 `ContextAssembler`/`OutputNormalizer` 类时，用 BackgroundAgent 实现体 + 独立 normalizer 函数，并在 PRD/design 标明与宪法契约的映射，避免以后双轨难收。

5. **开关持久化抄 `preferVisionAssistant` 全链路；缓存按 PRD 做「按消息」内存缓存即可**  
   `AppSettings.smartReplyEnabled` + `setSmartReplyEnabled` + 聊天页本地读取。候选缓存 key 建议：`conversationId + lastAssistantRawMessageId`，点气泡时 miss 再生成，避免每条 AI 消息预扣 token。

---

## 附录：关键路径速查

```
chat_page.dart
chat_message_list.dart (+ presentation/viewport parts)
chat_viewport_controller.dart
composer.dart + editingTextProvider (chat_actions.dart)
background_agent_service.dart + BackgroundAgentDefinition
chat_history_store.loadCanonicalContextMessages
chat_send_api_runner / AgentApiClient.sendMessageRich
agent_runtime_contracts.dart + standard_chat_agent.dart
app_settings.dart + settings_models.dart + default_model_settings_page.dart
frosted_glass_card.dart / moe_popup_menu.dart / moe_switch.dart
```

## 调研局限

- 当前工作树中 `features/settings/data/**`、`features/auto_reply/data/**`（含文档与 import 引用的 `analyzer_scheduler`、`UiModelsStoreLocalDataSource`）**文件缺失**，Analyzer 调度实现无法逐行锚点；设置落盘细节以 `docs/后端公共服务库.md` 与 `UiModelsApi` 门面为准。  
- 未跑 `flutter analyze` / 运行时验证（任务为只读调研）。  
- 行号基于 2026-07-13 工作区快照，后续重构可能漂移，请以符号名为准二次定位。
