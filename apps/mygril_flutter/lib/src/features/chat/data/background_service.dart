import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:drift/drift.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:workmanager/workmanager.dart';

import '../../../core/database/database.dart';
import '../../../core/database/repositories/repositories.dart';

// 任务名称常量
const String taskNameActiveReply = 'com.mygril.active_reply';

// 入口函数（必须是顶层函数）
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task == taskNameActiveReply && inputData != null) {
      print('[Background] Active Reply Task Started');
      try {
        await _handleActiveReplyTask(inputData);
      } catch (e) {
        print('[Background] Error: $e');
        return Future.value(false);
      }
    }
    return Future.value(true);
  });
}

// 具体的任务逻辑
Future<void> _handleActiveReplyTask(Map<String, dynamic> data) async {
  final String apiKey = data['apiKey'] ?? '';
  final String apiBase = data['apiBase'] ?? '';
  final String model = data['model'] ?? '';
  final String prompt = data['prompt'] ?? '';
  final String convId = data['convId'] ?? '';
  final String userTitle = data['userTitle'] ?? '女友';
  final String characterName = data['characterName'] ?? 'MyGril';
  
  if (apiKey.isEmpty || convId.isEmpty) {
    print('[Background] Missing config, aborting.');
    return;
  }

  // 1. 调用 LLM 生成回复
  final reply = await _fetchAiReply(apiKey, apiBase, model, prompt);
  if (reply == null || reply.isEmpty) {
    print('[Background] AI returned empty reply.');
    return;
  }

  // 2. 发送系统通知
  await _showNotification(characterName, reply);

  // 3. 将消息写入本地存储 (兼容现有的 SharedPreferences 结构)
  await _saveMessageToStorage(convId, reply);
}

Future<String?> _fetchAiReply(String key, String base, String model, String systemPrompt) async {
  try {
    // 简单的 OpenAI 格式调用，不依赖复杂的 AgentClient
    final baseUrl = base.isEmpty ? 'https://api.openai.com/v1' : base;
    final endpoint = baseUrl.endsWith('/') ? '${baseUrl}chat/completions' : '$baseUrl/chat/completions';
    
    final body = {
      'model': model,
      'messages': [
        {'role': 'system', 'content': systemPrompt},
        // 注意：这里为了省流量和复杂度，后台唤醒时不带历史记录，
        // 仅依靠 System Prompt (如 "现在是早上8点，请给用户发送一条早安问候") 让 AI 发挥。
        // 如果需要历史记录，inputData 需要传递进来，但这可能会超出 WorkManager 的数据大小限制 (10KB)。
      ],
      'temperature': 0.7,
    };

    final response = await http.post(
      Uri.parse(endpoint),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $key',
      },
      body: jsonEncode(body),
    );

    if (response.statusCode == 200) {
      final json = jsonDecode(utf8.decode(response.bodyBytes));
      return json['choices']?[0]?['message']?['content']?.toString();
    } else {
      print('[Background] API Error: ${response.statusCode} ${response.body}');
    }
  } catch (e) {
    print('[Background] Network Error: $e');
  }
  return null;
}

Future<void> _showNotification(String title, String body) async {
  final flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  const initSettings = InitializationSettings(android: androidSettings);
  
  // 重新初始化（因为是在后台 isolate）
  await flutterLocalNotificationsPlugin.initialize(initSettings);

  await flutterLocalNotificationsPlugin.show(
    Random().nextInt(100000), // ID
    title,
    body,
    const NotificationDetails(
      android: AndroidNotificationDetails(
        'active_reply_channel',
        'Active Reply',
        channelDescription: 'Notifications from your AI companion',
        importance: Importance.max,
        priority: Priority.high,
        styleInformation: BigTextStyleInformation(''), // 支持长文本
      ),
    ),
  );
}

/// 后台任务：将消息写入 SQLite 数据库
/// 注意：后台 isolate 中无法使用 Riverpod，需要创建独立的数据库实例
Future<void> _saveMessageToStorage(String convId, String text) async {
  final db = AppDatabase();
  try {
    final convRepo = ConversationRepository(db);
    final msgRepo = MessageRepository(db);

    // 检查会话是否存在
    final conv = await convRepo.getById(convId);
    if (conv == null) {
      print('[Background] Conversation not found: $convId');
      return;
    }

    // 插入消息
    final now = DateTime.now().millisecondsSinceEpoch;
    final msgId = 'bg_$now';
    await msgRepo.insert(MessagesCompanion(
      id: Value(msgId),
      conversationId: Value(convId),
      role: const Value('assistant'),
      content: Value(text),
      status: const Value('sent'),
      createdAt: Value(now),
    ));

    // 更新会话摘要（lastMessage, lastMessageTime, updatedAt）
    await convRepo.updateSummary(convId, text, now);

    // 增加未读数（需要单独更新）
    await (db.update(db.conversations)..where((t) => t.id.equals(convId)))
        .write(ConversationsCompanion(
      unreadCount: Value(conv.unreadCount + 1),
    ));

    print('[Background] Message saved to SQLite.');
  } catch (e) {
    print('[Background] SQLite Error: $e');
  } finally {
    await db.close();
  }
}

// 前台调用的初始化方法
class BackgroundService {
  static Future<void> initialize() async {
    await Workmanager().initialize(
      callbackDispatcher,
      isInDebugMode: false, // 生产环境改为 false
    );
  }

  static Future<void> scheduleOneOffTask({
    required String uniqueName,
    required Duration delay,
    required Map<String, dynamic> inputData,
  }) async {
    await Workmanager().registerOneOffTask(
      uniqueName,
      taskNameActiveReply,
      initialDelay: delay,
      inputData: inputData,
      constraints: Constraints(
        networkType: NetworkType.connected, // 必须有网
      ),
      existingWorkPolicy: ExistingWorkPolicy.replace, // 如果ID相同则替换
    );
  }
}
