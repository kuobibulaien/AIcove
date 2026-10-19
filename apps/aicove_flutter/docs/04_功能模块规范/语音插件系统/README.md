# 语音插件（TTS）系统文档

> 更新日期：2026-10-16（按当时代码重写；旧版写于 2026-01，硅基流动渠道已于 10-14 下线）
> 对应代码路径：`lib/src/features/plugins/tts/`
> 相关决策：ADR0008（插件预设与角色绑定）、ADR0081（语音渠道只认请求格式）。语音通话另见 [语音通话](../语音通话/README.md)。

## 一、做什么

AI 回复里用 `<tts>文本</tts>` 标记的内容会被提取出来，调用第三方渠道合成音频并播放。

```text
AI 回复 → TtsParser 解析 <tts> → TtsService 按渠道请求格式合成 → TtsPlayerManager 排队播放
```

## 二、渠道请求格式（ADR0081）

合成只认渠道的 `customConfig.requestFormat`，不再按地址或模型名猜厂商。所有格式登记在 `tts_request_format.dart` 的 `TtsRequestFormat` 注册表，添加页、详情页、存储规整与合成路由都从这里取：

| 格式 | `requestFormat` 值 | 合成方式 |
|---|---|---|
| OpenAI | `openai_tts` | `synthesis/openai_compatible_tts_synthesis_adapter.dart`（`/audio/speech`） |
| MiniMax | `minimax` | `synthesis/minimax_tts_synthesis_adapter.dart` |
| 阿里云 | `aliyun` | 按模型名分流：含 `qwen` 走 Qwen-TTS（含 Realtime WebSocket，`aliyun_qwen_tts_websocket.dart`），其余走 CosyVoice |
| Fish Audio | `fish_audio` | `synthesis/configurable_tts_synthesis_adapter.dart` |
| 自定义 REST | `custom_rest` | 同上，路径、请求头、请求体由 `customConfig.tts_template` 描述 |

旧数据里的别名（`siliconflow_indextts`、`aliyun_cosyvoice`、`minimax_tts`、`template` 等）由 `TtsRequestFormat.fromRaw` 规整；硅基流动的旧渠道迁到 OpenAI 格式。Fish Audio 与自定义 REST 的模型名看不出是不是语音模型，渠道内模型一律按语音处理（`forcesTtsModels`）。

**新增语音协议**：只往 `TtsRequestFormat` 注册表加一项，并在 `synthesis/` 下实现或复用合成适配器。不要在路由里按网址或模型名加判断。

## 三、音色预设与角色绑定（ADR0008）

音色预设包含渠道、模型、合成参数和音色 ID／文件，角色卡绑定预设，未绑定时用插件默认预设。请求时固定 owner 与供应商快照。

| 文件 | 职责 |
|---|---|
| `voice_synthesis_settings.dart` | 一个完整音色预设的合成参数（凭据不在这里） |
| `voice_preset_runtime.dart`、`voice_preset_application.dart` | 按角色解析出本次请求用的预设 |
| `voice_request.dart` | 只存在内存里的单次请求上下文，凭据不序列化 |
| `voice_preset_migration.dart` | 旧配置转换（先备份再转换的预演计划） |
| `tts_config.dart` | 插件配置模型 |

实现与迁移细节见 [音色预设实现与迁移](音色预设实现与迁移.md)。

## 四、音色管理（声音复刻）

创建、列出、删除音色走 `providers/` 下的统一抽象 `TtsVoiceProvider`，由 `TtsProviderFactory` 按渠道选择。目前有适配器的只有阿里云（`aliyun_voice_provider.dart`，Qwen-TTS 与 CosyVoice 复刻）和 MiniMax（`minimax_voice_provider.dart`）。接口说明见 [Provider 抽象层设计](Provider抽象层设计.md)。

## 五、文件速查

| 文件 | 职责 |
|---|---|
| `tts_agent_plugin.dart` | 在内核 v2 上注册语音插件 |
| `tts_plugin.dart` | 插件实现：提示词、`<tts>` 标签声明 |
| `tts_parser.dart` | 解析 `<tts>` 标记 |
| `tts_service.dart` | 合成服务：解析请求格式，选合成适配器 |
| `tts_request_format.dart` | 请求格式注册表 |
| `synthesis/` | 各格式的合成适配器 |
| `tts_player_manager.dart` | 播放队列 |
| `tts_model_probe.dart`、`tts_available_models.dart` | 模型测活与可用模型 |
| `tts_voice_catalog_service.dart`、`voice_manager_service.dart` | 音色目录与音色管理 |
| `factory_nahida_voice_update.dart` | 内置纳西妲音色的一次性更新 |

## 六、现状

- 五种请求格式离线测试通过；真机与真实付费渠道未全部验证（见项目记忆 README「语音通话」行）。
- 渠道里的语音识别模型另有 `AsrRequestFormat` 注册表（ADR0082），代码在 `features/voice_call/`。
