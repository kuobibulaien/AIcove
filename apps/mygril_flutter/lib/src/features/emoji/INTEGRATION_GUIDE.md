# 表情包功能集成指南

## 功能概述

表情包功能使用 `<emo>` 标签实现，支持模糊匹配和语义匹配，类似语音插件的实现思路。

### 核心特性

- ✅ 混合匹配策略（精确、包含、模糊、语义）
- ✅ 多标签支持（tags + aliases）
- ✅ 本地存储 + 云端下载
- ✅ 用户自定义导入
- ✅ 使用频率统计
- ✅ 多模态 MessageBlock 集成

## 架构说明

```
lib/src/features/emoji/
├── domain/
│   └── emoji_model.dart          # 数据模型
├── data/
│   ├── emoji_manager.dart        # 表情包管理器
│   ├── emoji_matcher.dart        # 匹配器（混合策略）
│   └── emoji_parser.dart         # 标签解析器
└── presentation/
    └── emoji_widget.dart         # UI组件
```

## 快速开始

### 1. 初始化表情包管理器

在 app 启动时初始化：

```dart
// lib/src/app.dart 或 main.dart

import 'package:mygril_flutter/src/features/emoji/data/emoji_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // 初始化表情包管理器
  await EmojiManager().initialize();
  
  runApp(MyApp());
}
```

### 2. 集成到消息处理流程

在接收到AI回复时，解析 `<emo>` 标签：

```dart
// lib/src/features/chat/data/chat_repository.dart 或类似位置

import 'package:mygril_flutter/src/features/emoji/data/emoji_manager.dart';
import 'package:mygril_flutter/src/features/emoji/data/emoji_matcher.dart';
import 'package:mygril_flutter/src/features/emoji/data/emoji_parser.dart';

class ChatRepository {
  final EmojiManager _emojiManager = EmojiManager();
  late final EmojiMatcher _emojiMatcher;
  late final EmojiParser _emojiParser;

  ChatRepository() {
    _emojiMatcher = EmojiMatcher(_emojiManager, enableSemanticMatch: true);
    _emojiParser = EmojiParser(_emojiManager, _emojiMatcher);
  }

  /// 处理AI回复消息
  Message processAIResponse(String messageId, String content) {
    // 检查是否包含 <emo> 标签
    if (_emojiParser.containsEmoTags(content)) {
      // 解析并生成 Blocks
      final blocks = _emojiParser.parseMessageText(messageId, content);
      
      // 创建多模态消息
      return Message.fromBlocks(
        id: messageId,
        role: 'assistant',
        blocks: blocks,
      );
    } else {
      // 普通文本消息
      return Message.text(
        id: messageId,
        role: 'assistant',
        content: content,
      );
    }
  }
}
```

### 3. 渲染表情包

在消息气泡中渲染 EmojiBlock：

```dart
// lib/src/features/chat/presentation/widgets/message_bubble.dart

import 'package:mygril_flutter/src/core/models/message_block.dart';
import 'package:mygril_flutter/src/features/emoji/presentation/emoji_widget.dart';

class MessageBubble extends StatelessWidget {
  final Message message;

  @override
  Widget build(BuildContext context) {
    if (message.blocks != null) {
      return Column(
        children: message.blocks!.map((block) {
          if (block is TextBlock) {
            return Text(block.content);
          } else if (block is EmojiBlock) {
            return InteractiveEmojiWidget(
              block: block,
              size: 120,
            );
          } else if (block is AudioBlock) {
            return AudioPlayerWidget(block: block);
          }
          // ... 其他类型
          return const SizedBox.shrink();
        }).toList(),
      );
    }
    
    // 降级到纯文本
    return Text(message.content);
  }
}
```

## 使用示例

### AI输出示例

```
AI: "宝贝今天辛苦了<emo>抱抱</emo>，要早点休息哦<emo>亲亲</emo>"
```

### 匹配过程

1. **"抱抱"** → 精确匹配 → `hug_001.gif`
2. **"亲亲"** → 精确匹配 → `kiss_001.gif`

### 模糊匹配示例

```dart
// AI 输出: "抱抱宝宝<emo>抱抱宝宝</emo>"
// 匹配流程：
// 1. 精确匹配: 失败（没有 "抱抱宝宝" 标签）
// 2. 包含匹配: 成功（"抱抱宝宝" 包含 "抱抱"） ✓
// 结果: hug_001.gif

// AI 输出: "贴贴<emo>贴贴</emo>"
// 匹配流程：
// 1. 精确匹配: 失败
// 2. 包含匹配: 成功（"贴贴" 在 aliases 中） ✓
// 结果: hug_001.gif

// AI 输出: "求抱抱<emo>求抱抱</emo>"
// 匹配流程：
// 1. 精确匹配: 失败
// 2. 包含匹配: 成功（"求抱抱" 包含 "抱抱"） ✓
// 结果: hug_001.gif
```

## 高级功能

### 1. 用户导入表情包

```dart
import 'dart:io';
import 'package:image_picker/image_picker.dart';

Future<void> importEmojiFromGallery() async {
  final picker = ImagePicker();
  final image = await picker.pickImage(source: ImageSource.gallery);
  
  if (image != null) {
    final emoji = EmojiModel(
      id: 'user_${DateTime.now().millisecondsSinceEpoch}',
      filename: '${DateTime.now().millisecondsSinceEpoch}.gif',
      tags: ['自定义'],
      aliases: [],
      category: '用户导入',
      source: 'user',
    );
    
    final success = await EmojiManager().addEmoji(
      emoji,
      File(image.path),
    );
    
    if (success) {
      print('导入成功');
    }
  }
}
```

### 2. 修改表情包标签

```dart
Future<void> editEmojiTags(String emojiId) async {
  await EmojiManager().updateEmojiTags(
    emojiId,
    ['新标签1', '新标签2'],
    ['新别名1', '新别名2'],
  );
}
```

### 3. 查看热门表情包

```dart
final popularEmojis = EmojiManager().getPopularEmojis(limit: 10);
```

### 4. 搜索表情包

```dart
final results = EmojiManager().searchEmojis('抱');
```

## 数据库格式

表情包数据库位于 `assets/emoji/emoji_database.json`：

```json
{
  "emojis": [
    {
      "id": "hug_001",
      "filename": "hug_001.gif",
      "tags": ["抱抱", "抱", "拥抱"],
      "aliases": ["抱抱宝宝", "贴贴", "搂搂"],
      "category": "亲密",
      "emotion": "温柔",
      "priority": 10,
      "usageCount": 0,
      "source": "local"
    }
  ],
  "semanticGroups": [
    {
      "name": "拥抱类",
      "keywords": ["抱抱", "贴贴", "抱", "拥抱"]
    }
  ]
}
```

## 云端同步（TODO）

未来可扩展云端功能：

1. 从云端下载热门表情包
2. 上传用户自定义表情包
3. 表情包推荐系统

## 性能优化建议

1. **图片缓存**：使用 `cached_network_image` 包缓存网络图片
2. **懒加载**：仅在需要时加载表情包
3. **压缩**：使用压缩后的 GIF/WebP 格式
4. **预加载**：对高频表情包进行预加载

## 测试

```dart
void main() {
  test('表情包匹配测试', () async {
    await EmojiManager().initialize();
    final matcher = EmojiMatcher(EmojiManager());
    
    // 精确匹配
    expect(matcher.match('抱抱')?.id, equals('hug_001'));
    
    // 包含匹配
    expect(matcher.match('抱抱宝宝')?.id, equals('hug_001'));
    
    // 别名匹配
    expect(matcher.match('贴贴')?.id, equals('hug_001'));
  });
}
```

## 故障排查

### 问题1：表情包不显示

- 检查 `assets/emoji/` 目录是否存在
- 检查 `pubspec.yaml` 中是否配置了 assets
- 检查图片文件是否存在

### 问题2：匹配失败

- 检查标签是否正确
- 检查数据库是否加载成功
- 启用 debug 日志查看匹配过程

### 问题3：性能问题

- 减少表情包数量
- 使用压缩格式
- 启用图片缓存
