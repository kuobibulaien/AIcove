# 音频播放器测试指南

## 快速测试步骤

### 1. 启动项目

```bash
# 启动后端
cd backend
python -m uvicorn app.main:app --reload --host 0.0.0.0 --port 8000

# 启动Flutter前端（另一个终端）
cd apps/mygril_flutter
flutter run -d chrome  # Web版
# 或
flutter run -d windows  # Windows桌面版
```

### 2. 配置TTS工具

1. 打开设置页面
2. 进入 "MCP 设置"
3. 找到 "tts" 工具
4. 点击进入详情页
5. 配置：
   - API Token（必填）
   - 音色提示音频URL
   - 音色提示文本
   - 请求地址（可选）
   - 语速（可选）
6. 点击"测试"按钮验证配置

### 3. 启用TTS工具

1. 在 MCP 设置中，确保 "tts" 工具已启用
2. 或在聊天设置中启用 TTS

### 4. 发送消息测试

在聊天界面发送消息，例如：
```
你好
```

如果配置正确，AI回复时会：
1. 显示文本消息气泡
2. 显示语音消息气泡（带播放器）

### 5. 测试播放器功能

**基础功能**:
- ✅ 点击播放按钮，音频开始播放
- ✅ 再次点击，音频暂停
- ✅ 拖动进度条，跳转到指定位置
- ✅ 查看时间显示（当前/总时长）

**加载状态**:
- ✅ 音频加载时显示转圈动画
- ✅ 加载完成后显示播放按钮

**错误处理**:
- ✅ URL错误时显示错误提示
- ✅ 网络错误时显示错误信息

**文本显示**:
- ✅ 如果有对应文本，显示在播放器下方（斜体）

## 预期效果

### 正常流程

```
用户: 你好
  ↓
AI: 你好呀~
  ↓
显示两条消息:
1. 文本气泡: "你好呀~"
2. 语音气泡: [▶] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
              0:00                      0:03
              "你好呀~"
```

### UI 外观

**AI消息（左侧）**:
- 浅灰色背景
- 深色文字
- 播放器使用深色图标

**用户消息（右侧）**:
- 蓝色背景
- 白色文字
- 播放器使用白色图标

## 常见问题排查

### 问题1: 没有显示语音气泡

**检查清单**:
1. ✅ TTS工具是否已启用？
   - 设置 → MCP 设置 → tts → 启用
2. ✅ TTS配置是否正确？
   - 设置 → MCP 设置 → tts → 详情 → 测试
3. ✅ 后端是否返回了 tool_results？
   - 查看浏览器控制台网络请求
   - 查看后端日志

**调试方法**:
```dart
// 在 providers2.dart 的 send() 方法中添加日志
print('Tool results: $toolResults');
print('Audio message: $audioMsg');
```

### 问题2: 播放器显示但无法播放

**检查清单**:
1. ✅ 音频URL是否正确？
   - 检查控制台错误信息
2. ✅ 后端静态文件服务是否正常？
   - 访问 `http://localhost:8000/static/tts/xxx.wav`
3. ✅ API base URL 配置是否正确？
   - 设置 → 后端API地址

**调试方法**:
```dart
// 在 audio_player_widget.dart 的 _loadAudio() 中添加日志
print('Loading audio from: $fullUrl');
```

### 问题3: 进度条不动

**可能原因**:
- 音频文件格式不支持
- 音频时长未正确获取

**解决方法**:
1. 确认音频文件是标准格式（WAV/MP3）
2. 检查 `durationStream` 是否有值
3. 尝试其他音频文件

### 问题4: 多个音频同时播放

**说明**: 这是当前的设计行为，每个音频有独立的播放器

**如需改进**: 可以添加全局播放器管理器

## 高级测试

### 测试多条语音消息

发送多条消息，验证：
- ✅ 每条消息的播放器独立工作
- ✅ 可以同时播放多个音频（或实现互斥）
- ✅ 滚动聊天记录时播放器状态保持

### 测试长音频

发送长文本，生成长音频：
```
请给我讲一个故事，关于一只勇敢的小猫咪，它在森林里迷路了，最后找到回家的路。
```

验证：
- ✅ 进度条正常显示
- ✅ 时间格式正确（分:秒）
- ✅ 拖动跳转准确

### 测试网络异常

1. 断开网络
2. 发送消息
3. 验证错误提示是否友好

### 测试不同主题

切换应用主题（如果有），验证：
- ✅ 播放器颜色自适应
- ✅ 文字可读性良好

## 性能测试

### 内存泄漏测试

1. 发送大量包含语音的消息（50+）
2. 滚动聊天记录
3. 观察内存使用情况
4. 验证旧的播放器是否被正确释放

### 播放器切换测试

1. 播放第一条语音
2. 立即播放第二条语音
3. 验证第一条是否继续播放（当前行为）
4. 或验证第一条是否自动暂停（如果实现了互斥）

## 自动化测试建议

### Widget 测试

```dart
testWidgets('AudioPlayerWidget displays correctly', (tester) async {
  final block = AudioBlock(
    messageId: 'test',
    url: 'https://example.com/test.mp3',
    text: 'Test audio',
  );

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: AudioPlayerWidget(
            block: block,
            textColor: Colors.black,
          ),
        ),
      ),
    ),
  );

  // 验证播放按钮存在
  expect(find.byIcon(Icons.play_arrow), findsOneWidget);
  
  // 验证文本显示
  expect(find.text('Test audio'), findsOneWidget);
});
```

### 集成测试

```dart
testWidgets('Audio message flow', (tester) async {
  // 1. 启动应用
  await tester.pumpWidget(MyApp());
  
  // 2. 发送消息
  await tester.enterText(find.byType(TextField), '你好');
  await tester.tap(find.byIcon(Icons.send));
  await tester.pumpAndSettle();
  
  // 3. 验证语音消息显示
  expect(find.byType(AudioPlayerWidget), findsOneWidget);
  
  // 4. 点击播放
  await tester.tap(find.byIcon(Icons.play_arrow));
  await tester.pump();
  
  // 5. 验证播放状态
  expect(find.byIcon(Icons.pause), findsOneWidget);
});
```

## 反馈与改进

测试完成后，请记录：
1. ✅ 哪些功能正常工作
2. ❌ 哪些功能有问题
3. 💡 有哪些改进建议

**常见改进方向**:
- 添加播放速度控制
- 添加音量控制
- 添加波形可视化
- 实现播放器互斥（同时只能播放一个）
- 添加后台播放支持
- 添加音频缓存机制

