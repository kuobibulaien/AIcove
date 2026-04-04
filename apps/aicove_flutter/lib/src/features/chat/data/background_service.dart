// ignore_for_file: avoid_print
// 注意：此文件在后台 isolate 中运行，无法使用 AppLogger（依赖 Flutter framework）。
// 这里的 print 语句仅用于后台调试，在 release 模式下不会输出。
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:drift/drift.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../../../core/api/providers/provider_chat_api_path.dart';
import '../../../core/api/providers/provider_adapter_factory.dart';
import '../../../core/database/database.dart';
import '../../../core/database/repositories/repositories.dart';

// 任务名称常量
const String taskNameActiveReply = 'com.aicove.active_reply';
const String _uiModelsStoreKey = 'aicove.ui_models.v1';
const String _triggerStoreKey = 'aicove.auto_triggers.v1';

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
  final String triggerId = data['triggerId'] ?? '';
  final String apiKey = data['apiKey'] ?? '';
  final String apiBase = data['apiBase'] ?? '';
  final String model = data['model'] ?? '';
  final String requestFormat = data['requestFormat'] ?? '';
  final String apiPath = data['apiPath'] ?? '';
  final bool vertexExpress = data['vertexExpress'] == true;
  final String prompt = data['prompt'] ?? '';
  final String? contextSnapshot = data['contextSnapshot'] as String?;
  final String convId = data['convId'] ?? '';
  final String characterName = data['characterName'] ?? 'AIcove';

  if (apiKey.isEmpty || convId.isEmpty) {
    print('[Background] Missing config, aborting.');
    return;
  }

  final autoReplyEnabled = await _isAutoReplyEnabled();
  if (!autoReplyEnabled) {
    print('[Background] Auto-reply disabled, skip task.');
    return;
  }

  if (triggerId.isNotEmpty) {
    final active = await _isTriggerStillActive(triggerId, convId);
    if (!active) {
      print(
          '[Background] Trigger is no longer active, skip task. triggerId=$triggerId');
      return;
    }
  }

  // 1. 调用 LLM 生成回复
  final reply = await _fetchAiReply(
    apiKey,
    apiBase,
    model,
    prompt,
    requestFormat: requestFormat,
    apiPath: apiPath,
    vertexExpress: vertexExpress,
    contextSnapshot: contextSnapshot,
  );
  if (reply == null || reply.isEmpty) {
    print('[Background] AI returned empty reply.');
    return;
  }

  // 2. 发送系统通知
  await _showNotification(characterName, reply);

  // 3. 将消息写入本地存储 (兼容现有的 SharedPreferences 结构)
  await _saveMessageToStorage(convId, reply);

  if (triggerId.isNotEmpty) {
    await _markTriggerAsFired(triggerId);
  }
}

Future<String?> _fetchAiReply(
  String key,
  String base,
  String model,
  String systemPrompt, {
  String requestFormat = '',
  String apiPath = '',
  bool vertexExpress = false,
  String? contextSnapshot,
}) async {
  try {
    final split = model.split(':');
    final provider =
        split.length >= 2 ? split.first.trim() : requestFormat.trim();
    final modelName = split.length >= 2 ? split.sublist(1).join(':') : model;
    final baseUrl = base.isEmpty ? 'https://api.openai.com/v1' : base;
    final customConfig = <String, dynamic>{
      if (requestFormat.trim().isNotEmpty)
        'requestFormat': requestFormat.trim(),
      if (apiPath.trim().isNotEmpty) kProviderChatApiPathField: apiPath.trim(),
      if (vertexExpress) 'vertexExpress': true,
    };
    final adapter = ProviderAdapterFactory.getAdapter(
      provider.isEmpty ? 'openai' : provider,
      customConfig: customConfig,
      apiBaseUrl: baseUrl,
    );
    final requestCustomConfig =
        ProviderAdapterFactory.sanitizeRequestCustomConfig(customConfig);
    final endpoint = buildProviderChatEndpoint(
      provider: adapter.name,
      apiBaseUrl: baseUrl,
      model: modelName,
      customConfig: customConfig,
    );
    final contextMessages = _parseContextSnapshot(contextSnapshot);

    final body = adapter.buildRequestBody(
      model: modelName,
      messages: [
        {'role': 'system', 'content': systemPrompt},
        ...contextMessages,
      ],
      temperature: 0.7,
      customConfig: requestCustomConfig,
    );

    final response = await http.post(
      Uri.parse(endpoint),
      headers: {
        'Content-Type': 'application/json',
        ...adapter.buildHeaders(key),
      },
      body: jsonEncode(body),
    );

    if (response.statusCode == 200) {
      final json =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final result = adapter.parseResponse(json);
      return result.text;
    } else {
      print('[Background] API Error: ${response.statusCode} ${response.body}');
    }
  } catch (e) {
    print('[Background] Network Error: $e');
  }
  return null;
}

List<Map<String, dynamic>> _parseContextSnapshot(String? contextSnapshot) {
  if (contextSnapshot == null || contextSnapshot.trim().isEmpty) {
    return const <Map<String, dynamic>>[];
  }
  try {
    final decoded = jsonDecode(contextSnapshot);
    if (decoded is! List) return const <Map<String, dynamic>>[];
    final messages = <Map<String, dynamic>>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item.cast<String, dynamic>());
      final role = map['role'];
      final content = map['content'];
      if (role is! String) continue;
      if (content == null) continue;
      messages.add({
        'role': role,
        'content': content,
      });
    }
    return messages.take(10).toList();
  } catch (_) {
    return const <Map<String, dynamic>>[];
  }
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

Future<bool> _isAutoReplyEnabled() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_uiModelsStoreKey);
    if (raw == null || raw.isEmpty) return false;
    final data = jsonDecode(raw);
    if (data is! Map) return false;
    final settings = data['auto_reply_settings'];
    if (settings is! Map) return false;
    return settings['enabled'] == true;
  } catch (e) {
    print('[Background] Failed to read auto-reply setting: $e');
    return false;
  }
}

Future<bool> _isTriggerStillActive(
    String triggerId, String conversationId) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_triggerStoreKey);
    if (raw == null || raw.isEmpty) return false;
    final decoded = jsonDecode(raw);
    if (decoded is! List) return false;

    for (final item in decoded) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item.cast<String, dynamic>());
      if ((map['id'] as String?) != triggerId) continue;
      final convId = (map['conversation_id'] as String?) ?? '';
      if (conversationId.isNotEmpty && convId != conversationId) {
        return false;
      }
      final status = (map['status'] as String?) ?? '';
      return status == 'created' ||
          status == 'preparing' ||
          status == 'prepared' ||
          status == 'pending';
    }
    return false;
  } catch (e) {
    print('[Background] Failed to inspect trigger state: $e');
    return false;
  }
}

Future<void> _markTriggerAsFired(String triggerId) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_triggerStoreKey);
    if (raw == null || raw.isEmpty) return;
    final decoded = jsonDecode(raw);
    if (decoded is! List) return;

    var changed = false;
    final nowIso = DateTime.now().toIso8601String();
    final updated = decoded.map((item) {
      if (item is! Map) return item;
      final map = Map<String, dynamic>.from(item.cast<String, dynamic>());
      if ((map['id'] as String?) != triggerId) return map;
      final status = (map['status'] as String?) ?? '';
      final isActive = status == 'created' ||
          status == 'preparing' ||
          status == 'prepared' ||
          status == 'pending';
      if (!isActive) return map;
      changed = true;
      map['status'] = 'fired';
      map['last_fired_at'] = nowIso;
      map['expire_reason'] = null;
      return map;
    }).toList();

    if (changed) {
      await prefs.setString(_triggerStoreKey, jsonEncode(updated));
    }
  } catch (e) {
    print('[Background] Failed to mark trigger fired: $e');
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

  static Future<void> cancelTaskByTriggerId(String triggerId) async {
    if (triggerId.isEmpty) return;
    await Workmanager().cancelByUniqueName('trigger_$triggerId');
  }
}
