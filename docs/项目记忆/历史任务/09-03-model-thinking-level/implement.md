# Implement: 模型思考档位

路径基准 `apps/aicove_flutter/`。每步完成后跑对应测试，全部完成后 `/codex:review`。

## 前置
- [ ] 读 `.trellis/spec/guides/cross-layer-thinking-guide.md`、`.trellis/spec/backend/database-guidelines.md`、`.trellis/spec/frontend/state-management.md`
- [ ] 读 research/codebase-survey.md 第 1、2、5 节

## Step 1 领域模型 + 目录表（纯 Dart，无依赖）
- [ ] 新建 `lib/src/core/api/thinking/thinking_level.dart`（enum、Options、resolve、coerce）
- [ ] 新建 `lib/src/core/api/thinking/thinking_level_catalog.dart`（design.md §1 表）
- [ ] 新建 `lib/src/core/api/thinking/thinking_level_labels.dart`（中文文案）
- [ ] 测试 `test/core/api/thinking/thinking_level_test.dart`：AC4 全部模型样例 + AC5 降级
- 验证：`flutter test test/core/api/thinking`

## Step 2 请求选项 + 三家适配器
- [ ] `provider_adapter.dart`：`ProviderChatRequestOptions` 加 `thinkingLevel`/`thinkingScheme`；trace 白名单与 `toTraceJson`
- [ ] `openai_adapter.dart` `_applyRequestOptions`：按 design §3.3 翻译，保留 `reasoningEffort` 回退
- [ ] `claude_adapter.dart`：effort / budget 两路；写在 customConfig 展开之后
- [ ] `gemini_adapter.dart`：thinkingConfig 合并，互斥两键，`includeThoughts: true`
- [ ] 测试：扩展 `test/core/api/openai_adapter_request_test.dart`、`test/core/api/providers/claude_adapter_test.dart`、`gemini_adapter_test.dart`、`provider_adapter_test.dart`（AC6）
- 验证：`flutter test test/core/api`

## Step 3 数据层
- [ ] `settings_models.dart` `ModelConfig.thinkingLevel`（json/copyWith/isDefault）；`ui_models_store_support.dart` normalize 非法值
- [ ] `database.dart`：加列 + schemaVersion 15 + 迁移；`dart run build_runner build --delete-conflicting-outputs`
- [ ] `conversation.dart`、`database_converters.dart`、`sync_service.dart:187`
- [ ] 会话 repository 增 `updateConversationThinkingLevel`
- [ ] 测试：`test/features/settings/settings_models_test.dart` 加 ModelConfig 往返；迁移回归测试（AC8，参考现有 database 测试写法）
- 验证：`flutter test test/features/settings test/core/database`

## Step 4 发送链路注入
- [ ] `chat_request_config.dart`：读 `modelConfig.thinkingLevel`，`ChatRequestConfig` 加字段
- [ ] `chat_types.dart` 如需透传字段
- [ ] `chat_send_backend_service.dart:650`：总是构造 options；优先级解析 + coerce（design §3.2）
- [ ] 测试：`test/features/chat/services/` 新增 `chat_send_thinking_level_test.dart` 覆盖 AC3（会话覆盖 > 模型默认 > 预设 > 无）
- 验证：`flutter test test/features/chat/services`

## Step 5 流式解析
- [ ] `agent_api_stream_support.dart` Gemini thought part → reasoning
- [ ] 测试：`test/core/api/agent_api_stream_test.dart` 加 fixture（AC7）

## Step 6 UI
- [ ] 新建 `thinking_level_sheet.dart`
- [ ] `composer_model_picker_sheet.dart` tile 徽标 + 点按写会话覆盖
- [ ] `composer.dart` 模型名旁档位入口
- [ ] `model_row_tile.dart` 编辑弹层默认档位下拉
- [ ] widget 测试：sheet 渲染选项与来源标签（`test/features/chat/presentation/`）
- 验证：`flutter test test/features/chat/presentation test/ui`

## Step 7 全量校验 + 审查
- [ ] `flutter analyze`（零新增）
- [ ] `flutter test`
- [ ] 真机/模拟器手测 AC1、AC2（三家各一个模型，看 trace payload）
- [ ] `/codex:review`
- [ ] 更新 spec：`.trellis/spec/backend/` 新增「thinking 参数翻译约定」小节；`decisions/` 若认为静态目录表达 ADR 门槛则立卡

## 回滚点
- Step 2 各 adapter `_applyRequestOptions` 段可独立还原
- Step 3 迁移仅加列，可留空不回退
- 风险文件：`chat_send_backend_service.dart`（去掉 `boundPreset == null ? null` 短路会让所有会话都带 options，注意其他字段默认值不改变请求体——用现有 `provider_adapter_test` 的 isDefault 逻辑保证）
