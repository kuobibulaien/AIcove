# 音频播放器组件使用指南

## 概述

已完成 AudioBlock 的完整渲染组件，支持在聊天界面中播放 TTS 生成的语音消息。

## 实现的功能

### 1. 音频播放器组件 (`AudioPlayerWidget`)

**位置**: `lib/src/features/chat/presentation/widgets/audio_player_widget.dart`

**功能特性**:
- ✅ 播放/暂停控制
- ✅ 进度条显示和拖动跳转
- ✅ 时间显示（当前位置/总时长）
- ✅ 加载状态指示
- ✅ 错误提示
- ✅ 显示对应的文本内容（如果有）
- ✅ 自动加载音频
- ✅ 支持相对URL和绝对URL

**设计原则**:
- **KISS**: 简洁的UI设计，只包含必要的播放控制
- **SOLID**: 单一职责，只负责音频播放UI
- **DRY**: 使用 Riverpod 的 family provider 为每个音频创建独立的控制器

### 2. 状态管理

使用 `StateNotifierProvider.family` 为每个音频URL创建独立的播放器实例：

```dart
final audioPlayerControllerProvider = StateNotifierProvider.family<
    AudioPlayerController, AudioPlayerState, String>(
  (ref, audioUrl) => AudioPlayerController(audioUrl),
);
```

**优势**:
- 每个音频消息有独立的播放状态
- 自动内存管理（组件销毁时自动释放）
- 支持多个音频同时存在（但只有一个播放）

### 3. UI 设计

**样式特点**:
- 圆形播放按钮，带半透明背景
- 可点击的进度条，支持拖动跳转
- 柔和的颜色，适配消息气泡的文字颜色
- 显示音频对应的文本内容（斜体，半透明）

**布局**:
```
┌─────────────────────────────────────┐
│ [▶] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ │
│     0:05                      0:12  │
│                                     │
│ "你好呀~"（文本内容）                │
└─────────────────────────────────────┘
```

## 使用方法

### 在消息气泡中自动渲染

已集成到 `MessageBubble` 组件中，当消息包含 `AudioBlock` 时会自动渲染播放器：

```dart
// 创建包含音频的消息
final audioMsg = Message.fromBlocks(
  id: 'msg_123',
  role: 'assistant',
  blocks: [
    AudioBlock(
      messageId: 'msg_123',
      url: '/static/tts/abc123.wav',  // 相对URL
      text: '你好呀~',  // 可选的文本内容
    ),
  ],
  createdAt: DateTime.now(),
  status: 'sent',
);
```

### 手动使用播放器组件

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'audio_player_widget.dart';

class MyWidget extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final audioBlock = AudioBlock(
      messageId: 'msg_123',
      url: 'https://example.com/audio.mp3',
      text: '这是语音内容',
    );

    return AudioPlayerWidget(
      block: audioBlock,
      textColor: Colors.black,
    );
  }
}
```

## 技术细节

### 依赖包

- `just_audio`: 音频播放核心库
- `audio_session`: 音频会话管理
- `flutter_riverpod`: 状态管理

### URL 处理

播放器会自动处理URL：
- **相对URL**: `/static/tts/xxx.wav` → 自动拼接 API base URL
- **绝对URL**: `https://example.com/audio.mp3` → 直接使用

### 状态流

```
初始化 → 加载音频 → 准备就绪 → 播放/暂停 → 完成
   ↓         ↓          ↓           ↓          ↓
 loading   loading   ready      playing    completed
```

### 内存管理

- 每个播放器在组件销毁时自动释放
- 使用 `StateNotifier.dispose()` 清理资源
- 避免内存泄漏

## 后续优化建议

### 短期优化
1. **播放速度控制**: 添加 0.5x, 1x, 1.5x, 2x 速度选项
2. **音量控制**: 添加音量滑块
3. **波形可视化**: 显示音频波形动画

### 长期优化
1. **缓存机制**: 缓存已下载的音频文件
2. **后台播放**: 支持应用切换到后台时继续播放
3. **播放列表**: 支持连续播放多条语音消息
4. **语音识别**: 显示语音转文字结果

## 测试建议

### 单元测试
- 测试 URL 拼接逻辑
- 测试状态转换
- 测试错误处理

### 集成测试
- 测试播放/暂停功能
- 测试进度条拖动
- 测试多个音频消息的独立性

### UI 测试
- 测试不同主题下的显示效果
- 测试长文本的显示
- 测试加载和错误状态的UI

## 故障排查

### 问题1: 音频无法播放
**可能原因**:
- URL 不正确
- 后端服务未启动
- 音频文件不存在

**解决方法**:
1. 检查控制台错误信息
2. 验证 API base URL 配置
3. 测试音频URL是否可访问

### 问题2: 进度条不更新
**可能原因**:
- 音频时长未正确获取
- 状态监听未正常工作

**解决方法**:
1. 检查 `durationStream` 是否正常
2. 确认音频文件格式正确

### 问题3: 多个音频同时播放
**说明**: 这是正常行为，每个音频有独立的播放器实例

**如需单例播放**:
可以添加全局播放器管理器，在播放新音频时暂停其他音频。

## 示例代码

### 完整的消息发送流程

```dart
// 1. 发送消息
await chatActions.send('你好');

// 2. 后端返回包含 TTS 结果
// {
//   "text": "你好呀~",
//   "tool_results": [
//     {
//       "name": "tts",
//       "payload": {
//         "audio_url": "/static/tts/abc123.wav"
//       }
//     }
//   ]
// }

// 3. 前端自动创建 AudioBlock 消息
final audioMsg = Message.fromBlocks(
  id: _genId('msg'),
  role: 'assistant',
  blocks: [
    AudioBlock(
      messageId: audioId,
      url: '/static/tts/abc123.wav',
      text: '你好呀~',
    ),
  ],
  createdAt: DateTime.now(),
  status: 'sent',
);

// 4. MessageBubble 自动渲染 AudioPlayerWidget
// 用户可以点击播放按钮播放语音
```

## 更新日志

### 2025-01-XX
- ✅ 创建 `AudioPlayerWidget` 组件
- ✅ 集成到 `MessageBubble` 中
- ✅ 支持播放/暂停、进度条、时间显示
- ✅ 支持错误处理和加载状态
- ✅ 自动URL处理（相对/绝对）

