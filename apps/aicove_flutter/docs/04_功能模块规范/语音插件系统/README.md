# 语音插件（TTS）系统文档

> **架构更新（2026-09-06）**：目标设计以[插件预设与角色卡绑定规范](../../02_前后端分离与架构规范/插件预设与角色卡绑定规范.md)为准。音色预设统一包含渠道、模型、TTS 基本参数、音色 ID／文件等，角色卡绑定预设；未绑定时使用插件默认预设。当前正在改造，以下旧数据模型及全局选择字段仅作旧实现参考，不代表新架构已实现；新增／重构不得继续分散配置归属。

> 文档创建日期：2026-01-31
> 对应代码路径：`lib/src/features/plugins/tts/`

---

## 一、系统概述

语音插件（TTS）负责将 AI 回复中的文本自动转换为语音。AI 回复中用 `<tts>文本</tts>` 标记的内容会被提取出来，调用第三方 TTS 渠道商 API 转为音频播放。

**核心流程**：

```
AI 回复文本 → 解析 <tts> 标记 → 调用渠道 API → 获取音频 → 播放
```

---

## 二、目录结构

```
lib/src/features/plugins/tts/
│
├── 核心层（插件框架）
│   ├── tts_plugin.dart              # TTS 插件入口，注册到插件系统
│   ├── tts_config.dart              # 配置模型（TtsConfig、VoicePreset 等）
│   ├── tts_service.dart             # 核心合成服务，根据 requestFormat 分发到不同渠道
│   ├── tts_parser.dart              # 解析 <tts> 标记，提取文本片段
│   ├── tts_player_manager.dart      # 播放器管理，控制音频队列和播放
│   └── voice_manager_service.dart   # 音色管理（旧版，正在被 providers 层替代）
│
├── 渠道服务层（各厂商的 API 封装）
│   ├── siliconflow_tts_service.dart          # 硅基流动 API
│   ├── aliyun_voice_clone_service.dart       # 阿里云声音复刻（Qwen-TTS + CosyVoice）
│   ├── aliyun_qwen_tts_websocket.dart        # 阿里云 Qwen-TTS WebSocket 合成
│   └── minimax_tts_service.dart              # MiniMax API（新增）
│
└── providers/（统一抽象层，2026-01-31 新增）
    ├── index.dart                            # 统一导出
    ├── tts_voice_provider.dart               # 抽象接口 + 通用数据类
    ├── tts_provider_factory.dart             # 工厂类，根据渠道标识获取 Provider
    ├── siliconflow_voice_provider.dart       # 硅基流动适配器
    ├── aliyun_voice_provider.dart            # 阿里云适配器（Qwen-TTS + CosyVoice）
    └── minimax_voice_provider.dart           # MiniMax 适配器（新增）
```

---

## 三、已接入的 TTS 渠道

### 3.1 硅基流动（SiliconFlow）

| 项目 | 说明 |
|------|------|
| 代码文件 | `siliconflow_tts_service.dart` |
| 请求格式标识 | `siliconflow_indextts` |
| 支持模型 | `FunAudioLLM/CosyVoice2-0.5B`、`IndexTeam/IndexTTS-2` |
| 预置音色 | 有（alex、benjamin、charles、david、anna、bella、claire、diana） |
| 上传方式 | multipart 文件上传 |
| 音色创建后状态 | 立即可用 |
| 音色ID格式 | `speech:xxx:xxx`（URI 格式） |
| 特殊要求 | 需要提供参考文本（text 字段） |

### 3.2 阿里云 Qwen-TTS

| 项目 | 说明 |
|------|------|
| 代码文件 | `aliyun_voice_clone_service.dart` |
| 请求格式标识 | `aliyun_qwen_tts` |
| 支持模型 | `qwen3-tts-flash`、`qwen3-tts-vc-realtime-*` 等 |
| 预置音色 | 无 |
| 上传方式 | Base64 编码或公网 URL |
| 音色创建后状态 | 立即可用 |
| 音色ID格式 | 自定义名称（preferred_name） |
| 特殊功能 | 支持 WebSocket 实时合成（realtime 模型） |
| 特殊功能 | 支持本地文件 Base64 上传 |

### 3.3 阿里云 CosyVoice

| 项目 | 说明 |
|------|------|
| 代码文件 | `aliyun_voice_clone_service.dart`（与 Qwen-TTS 共用） |
| 请求格式标识 | `aliyun_cosyvoice` |
| 支持模型 | `cosyvoice-v3-plus`、`cosyvoice-v3-flash` 等 |
| 预置音色 | 无 |
| 上传方式 | 只支持公网 URL |
| 音色创建后状态 | **需要审核**（DEPLOYING → OK / UNDEPLOYED） |
| 音色ID格式 | 系统生成（voice_id） |
| 特殊功能 | 需要轮询状态等待审核通过 |

### 3.4 MiniMax（新增，2026-01-31）

| 项目 | 说明 |
|------|------|
| 代码文件 | `minimax_tts_service.dart` |
| 请求格式标识 | 尚未接入 tts_service.dart 的 switch |
| 支持模型 | `speech-2.8-hd`、`speech-2.8-turbo`、`speech-2.6-hd`、`speech-2.6-turbo` 等 |
| 预置音色 | 有（系统音色列表） |
| 上传方式 | 文件上传（两步：先传文件获取 file_id，再调用复刻） |
| 音色创建后状态 | 立即可用 |
| 音色ID格式 | 用户自定义（8-256字符，字母开头） |
| 过期策略 | **7天临时音色**，首次使用后永久保留 |
| 特殊功能 | 支持示例音频增强复刻效果 |

---

## 四、核心数据模型

### 4.1 VoicePreset（音色预设）

位于 `tts_config.dart`，是所有渠道共用的音色数据模型。

```
VoicePreset
├── id                    # 唯一标识
├── name                  # 音色名称
├── sourceType            # 来源类型（url / local / preset）
├── providerType          # 来源渠道（custom / aliyun / siliconFlow）
├── promptAudioUrl        # 参考音频 URL
├── promptText            # 参考文本
├── emoText               # 情感参考文本
├── useEmoText            # 是否使用情感控制
├── source                # 来源说明
├── isBuiltIn             # 是否内置音色
├── aliyunVoiceId         # 阿里云音色 ID
├── aliyunTargetModel     # 阿里云目标模型
├── aliyunVoiceStatus     # 阿里云音色状态
├── siliconFlowVoiceUri   # 硅基流动音色 URI
├── siliconFlowModel      # 硅基流动模型
└── localAudioPath        # 本地音频文件路径
```

### 4.2 TtsConfig（TTS 插件配置）

位于 `tts_config.dart`，存储 TTS 插件的完整配置。

```
TtsConfig
├── enabled               # 是否启用
├── selectedProviderId    # 选中的渠道 ID
├── selectedModelId       # 选中的模型 ID
├── voicePresets          # 音色预设列表
├── selectedVoicePresetId # 当前选中的音色
├── speed                 # 语速
├── maxCharsPerChunk      # 最大字数/片段
├── voiceFrequency        # 语音使用频率 (0-100)
└── systemPromptTemplate  # 系统提示词模板
```

---

## 五、统一 Provider 抽象层（2026-01-31 新增）

### 5.1 设计背景

之前每接入一个新渠道，需要改动多个文件：
- 写一个 `XxxTtsService` 类
- 在 `TtsService` 的 switch-case 中加分支
- 在 `VoiceManagerService` 中加对应方法
- 每个服务都有自己的数据类

新的 Provider 抽象层将「获取音色列表 → 创建音色 → 删除音色」这套流程标准化。

### 5.2 核心接口

```dart
abstract class TtsVoiceProvider {
  String get providerId;          // 渠道标识
  String get displayName;         // 渠道名称
  TtsCapabilities get capabilities; // 能力描述

  Future<VoiceListResult> listVoices({required String apiKey});
  Future<VoiceCreateResult> createVoice({required String apiKey, required VoiceCreateRequest request});
  Future<void> deleteVoice({required String apiKey, required String voiceId, VoicePreset? voice});
  Future<VoicePreset?> queryVoiceStatus({required String apiKey, required String voiceId}); // 审核状态查询
}
```

### 5.3 TtsCapabilities（能力描述）

UI 根据此信息动态控制显示：

| 字段 | 说明 | 硅基流动 | 阿里云 Qwen | 阿里云 Cosy | MiniMax |
|------|------|---------|-----------|-----------|---------|
| hasPresetVoices | 有预置音色 | ✅ | ❌ | ❌ | ✅ |
| canUploadFile | 支持文件上传 | ✅ | ✅ | ❌ | ✅ |
| canUploadUrl | 支持 URL 上传 | ❌ | ✅ | ✅ | ❌ |
| needsPromptText | 需要参考文本 | ✅ | ❌ | ❌ | ❌ |
| needsApproval | 需要审核 | ❌ | ❌ | ✅ | ❌ |
| hasExpirationPolicy | 有过期策略 | ❌ | ❌ | ❌ | ✅(7天) |
| supportsPromptAudio | 支持示例音频 | ❌ | ❌ | ❌ | ✅ |

### 5.4 工厂类

```dart
// 按渠道标识获取
final provider = TtsProviderFactory.getProvider('siliconflow');

// 按 API URL 自动识别
final provider = TtsProviderFactory.getProviderByUrl('https://api.siliconflow.cn/v1/audio');

// 获取所有可用渠道
final allProviders = TtsProviderFactory.getAllProviders();
```

### 5.5 新接入一个渠道的步骤

1. 在 `tts/` 下创建 `xxx_tts_service.dart`（封装该渠道的 HTTP API）
2. 在 `tts/providers/` 下创建 `xxx_voice_provider.dart`（实现 `TtsVoiceProvider` 接口）
3. 在 `tts_provider_factory.dart` 的 `_providers` 中注册
4. 如果需要语音合成，在 `tts_service.dart` 的 switch 中添加请求格式分支

---

## 六、语音合成流程（TtsService）

`tts_service.dart` 是语音合成的核心调度类，根据 `requestFormat` 分发到不同的请求构建方法：

```
TtsService.convert(text)
  │
  ├─ requestFormat = 'openai_tts'
  │     → _buildOpenAiTtsBody()  → POST → 返回音频
  │
  ├─ requestFormat = 'siliconflow_indextts'
  │     → _buildSiliconFlowIndexTtsBody()  → POST → 返回音频
  │
  ├─ requestFormat = 'aliyun_cosyvoice'
  │     → _buildAliyunCosyVoiceBodyAsync()  → POST → 返回音频
  │
  └─ requestFormat = 'aliyun_qwen_tts'
        ├─ 普通模型 → _buildAliyunQwenTtsBodyAsync() → POST → 返回音频
        └─ realtime 模型 → WebSocket 合成 → PCM → WAV → 返回音频
```

**注意**：MiniMax 的语音合成尚未接入 `TtsService`，目前只完成了 Provider 层（音色管理）。

---

## 七、文件职责速查表

| 文件 | 负责什么 | 什么时候去找它 |
|------|---------|--------------|
| `tts_plugin.dart` | 插件入口，注册到插件系统 | 插件开关、插件元数据 |
| `tts_config.dart` | 配置模型、音色预设模型 | 修改配置字段、音色数据结构 |
| `tts_service.dart` | 语音合成调度 | 添加新合成格式、修改合成逻辑 |
| `tts_parser.dart` | 解析 `<tts>` 标记 | 修改标记解析规则 |
| `tts_player_manager.dart` | 播放队列管理 | 播放问题 |
| `voice_manager_service.dart` | 音色管理（旧版） | 正在被 providers 层替代 |
| `siliconflow_tts_service.dart` | 硅基流动 API 封装 | 硅基流动接口问题 |
| `aliyun_voice_clone_service.dart` | 阿里云声音复刻 API | 阿里云接口问题 |
| `aliyun_qwen_tts_websocket.dart` | 阿里云 WebSocket 合成 | WebSocket 合成问题 |
| `minimax_tts_service.dart` | MiniMax API 封装 | MiniMax 接口问题 |
| `providers/tts_voice_provider.dart` | 统一抽象接口 | 修改 Provider 契约 |
| `providers/tts_provider_factory.dart` | 工厂类 | 注册新渠道 |
| `providers/*_voice_provider.dart` | 各渠道适配器 | 修改特定渠道的音色管理逻辑 |

---

## 八、当前状态与待办

### 已完成
- [x] 硅基流动全流程（音色管理 + 语音合成）
- [x] 阿里云 Qwen-TTS 全流程（音色管理 + 语音合成 + WebSocket）
- [x] 阿里云 CosyVoice 全流程（音色管理 + 语音合成 + 审核轮询）
- [x] 统一 Provider 抽象层设计与实现
- [x] MiniMax 服务层 API 封装（`minimax_tts_service.dart`）
- [x] MiniMax Provider 适配器（`minimax_voice_provider.dart`）
- [x] TTS 设置页接入 `TtsProviderContext + TtsVoiceCatalogService`
- [x] `tts_settings_form.dart` 等 UI 组件按 `TtsCapabilities` 动态渲染

### 待完成
- [ ] MiniMax 语音合成接入 `TtsService`（添加 requestFormat 分支）
- [ ] `VoicePreset` 添加 MiniMax 专用字段（目前用 extension 临时存储）
- [ ] `VoiceProviderType` 枚举添加 `minimax` 选项
- [ ] 旧的 `voice_manager_service.dart` 逐步迁移到 providers 层


## 音色预设第一批实现（2026-09-06）

完整预设模型、角色请求纯解析端口及旧配置转换预演已完成，**尚未接入实际聊天、试听和前端**。实现边界、验证与第二批入口见[音色预设实现与迁移](音色预设实现与迁移.md)。


## 音色预设第二批完成（2026-09-06）

角色完整预设已接通实际请求与播放器，插件页改为完整分组搜索预设库，独立编辑/试听/音色创建与角色绑定复用同一套解析端口。旧配置先备份再转换，未知归属保留待完善。范围114项测试通过，固定快照110项复核并在PKX110安装运行；未实测付费供应商声音，不能称全仓测试通过。最新入口与限制见[音色预设实现与迁移](音色预设实现与迁移.md)。
