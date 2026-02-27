# Provider 抽象层详细设计

> 2026-01-31 创建
> 对应代码：`lib/src/features/plugins/tts/providers/`

---

## 一、设计动机

### 旧方案的问题

每接入一个新的 TTS 渠道商，需要在 **4 个地方** 做改动：

1. 新建 `xxx_tts_service.dart`（封装 HTTP 调用）
2. 在 `tts_service.dart` 的 `_buildRequestBodyAsync()` 加 switch 分支
3. 在 `voice_manager_service.dart` 加 `getXxxVoices()`、`uploadToXxx()` 等方法
4. 在 `tts_settings_form.dart` 等 UI 中加渠道特定的逻辑

**核心痛点**：音色管理逻辑（获取列表、上传音色、删除音色）散落在多个文件中，重复代码多。

### 新方案的思路

把所有渠道的音色管理抽象成一套接口：

```
获取音色列表 → 创建音色 → 删除音色
```

各渠道只需实现这套接口，对外暴露统一的输入输出。**UI 不需要知道底层是哪个渠道**，根据 `TtsCapabilities` 动态适配即可。

---

## 二、接口定义

### 2.1 TtsVoiceProvider（核心接口）

```dart
abstract class TtsVoiceProvider {
  /// 渠道标识，如 'siliconflow'、'aliyun_qwen'、'minimax'
  String get providerId;

  /// 渠道显示名称，如 '硅基流动'、'阿里云 Qwen-TTS'
  String get displayName;

  /// 渠道能力描述，UI 根据此动态渲染
  TtsCapabilities get capabilities;

  /// 获取所有可用音色（返回预置音色和用户音色）
  Future<VoiceListResult> listVoices({
    required String apiKey,
    String? targetModel,
  });

  /// 创建/上传音色
  Future<VoiceCreateResult> createVoice({
    required String apiKey,
    required VoiceCreateRequest request,
  });

  /// 删除音色
  Future<void> deleteVoice({
    required String apiKey,
    required String voiceId,
    VoicePreset? voice,
  });

  /// 查询音色状态（用于需要审核的渠道，如 CosyVoice）
  Future<VoicePreset?> queryVoiceStatus({
    required String apiKey,
    required String voiceId,
    VoicePreset? voice,
  });
}
```

### 2.2 TtsCapabilities（能力描述）

```dart
class TtsCapabilities {
  final bool hasPresetVoices;       // 有系统预置音色？
  final bool canUploadFile;         // 支持文件上传？
  final bool canUploadUrl;          // 支持 URL 上传？
  final bool needsPromptText;       // 需要参考文本？
  final bool needsApproval;         // 需要审核？
  final bool hasExpirationPolicy;   // 有过期策略？
  final String? expirationDescription; // 过期说明
  final bool supportsPromptAudio;   // 支持示例音频？
  final List<String> supportedFormats; // 支持的音频格式
  final String? audioDurationLimit;  // 音频时长限制
  final int? maxAudioSizeBytes;      // 音频大小限制
}
```

**UI 适配逻辑**：

```
if capabilities.hasPresetVoices → 显示"系统音色"Tab
if capabilities.canUploadFile   → 显示"选择文件"按钮
if capabilities.canUploadUrl    → 显示"输入URL"输入框
if capabilities.needsPromptText → 显示"参考文本"输入框
if capabilities.needsApproval   → 显示"审核状态"指示器
if capabilities.hasExpirationPolicy → 显示过期提示
if capabilities.supportsPromptAudio → 显示"示例音频"上传
```

### 2.3 VoiceCreateRequest（创建请求）

```dart
class VoiceCreateRequest {
  final String name;               // 音色名称
  final Uint8List? audioBytes;     // 文件二进制
  final String? fileName;          // 文件名
  final String? audioUrl;          // URL
  final String? promptText;        // 参考文本
  final String? targetModel;       // 目标模型
  final Uint8List? promptAudioBytes; // 示例音频（MiniMax）
  final String? promptAudioUrl;    // 示例音频 URL
  final String? language;          // 语言
  final String? customVoiceId;     // 自定义 ID（MiniMax）
}
```

### 2.4 返回结果

```dart
class VoiceListResult {
  final List<VoicePreset> presetVoices; // 预置音色
  final List<VoicePreset> userVoices;   // 用户音色
}

class VoiceCreateResult {
  final VoicePreset voice;        // 创建的音色
  final bool needsApproval;       // 是否需要等待审核
  final String? statusMessage;    // 状态提示
}
```

---

## 三、各渠道适配器实现要点

### 3.1 SiliconFlowVoiceProvider

- `listVoices()`: 预置音色从硬编码列表读取，用户音色调 `GET /audio/voice/list`
- `createVoice()`: 调 multipart 上传 `POST /uploads/audio/voice`，必须有 promptText
- `deleteVoice()`: 调 `POST /audio/voice/deletions`，参数是 voiceUri

### 3.2 AliyunQwenVoiceProvider

- `listVoices()`: 调 `POST action=list` 获取已创建音色
- `createVoice()`: 文件模式用 Base64 编码上传，URL 模式优先客户端下载再 Base64 上传（避免阿里云拉取超时）
- `deleteVoice()`: 调 `POST action=delete`

### 3.3 AliyunCosyVoiceProvider

- `listVoices()`: 调 `POST action=list_voice`
- `createVoice()`: 只支持 URL，调 `POST action=create_voice`，返回 DEPLOYING 状态
- `deleteVoice()`: 调 `POST action=delete_voice`
- `queryVoiceStatus()`: 调 `POST action=query_voice`，轮询等待 OK

### 3.4 MinimaxVoiceProvider

- `listVoices()`: 调 `POST /get_voice`，返回 system_voice 和 voice_cloning 两个列表
- `createVoice()`: 两步流程
  1. `POST /files/upload` 上传音频获取 file_id
  2. `POST /voice_clone` 带 file_id + voice_id 执行复刻
- `deleteVoice()`: 调 `POST /voice/delete`

---

## 四、工厂类使用方式

```dart
import 'providers/index.dart';

// 方式1：按渠道标识获取
final provider = TtsProviderFactory.getProvider('minimax');
if (provider != null) {
  final voices = await provider.listVoices(apiKey: apiKey);
  print('预置音色: ${voices.presetVoices.length}');
  print('用户音色: ${voices.userVoices.length}');
}

// 方式2：按 API URL 自动识别
final provider = TtsProviderFactory.getProviderByUrl(
  'https://api.siliconflow.cn/v1/audio',
);

// 方式3：获取所有渠道信息供 UI 展示
final infos = TtsProviderFactory.getProviderInfoList();
for (final info in infos) {
  print('${info.name}: 预置音色=${info.capabilities.hasPresetVoices}');
}
```

---

## 五、与旧代码的关系

| 旧代码 | 新代码 | 关系 |
|--------|--------|------|
| `voice_manager_service.dart` | `providers/` 目录 | 新代码是旧代码的替代方案，目前共存 |
| `tts_service.dart` | 不变 | Provider 层只管音色管理，合成仍由 TtsService 负责 |
| `siliconflow_tts_service.dart` | `siliconflow_voice_provider.dart` | Provider 内部调用 Service |
| `aliyun_voice_clone_service.dart` | `aliyun_voice_provider.dart` | Provider 内部调用 Service |

**迁移路线**：
1. ✅ 创建 Provider 抽象层（当前阶段）
2. 🔲 UI 层从直接调 Service 改为通过 Provider 调用
3. 🔲 废弃 `voice_manager_service.dart`
