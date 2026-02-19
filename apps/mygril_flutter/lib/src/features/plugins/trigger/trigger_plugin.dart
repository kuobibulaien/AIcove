// ignore_for_file: avoid_print
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/app_logger.dart';
import '../domain/index.dart';
import '../domain/handlers/ai_tool.dart';
import '../domain/handlers/tool_parameter.dart';
import 'trigger_config.dart';
import '../../chat/data/auto_reply_trigger.dart';
import '../../chat/data/auto_reply_trigger_controller.dart';
import '../../chat/conversation_providers.dart';
import '../../settings/app_settings.dart';

/// 鏅鸿兘瑙﹀彂鍣ㄦ彃浠?/// 鍏佽 AI 鏍规嵁瀵硅瘽璁剧疆瀹氭椂鎻愰啋
class TriggerPlugin extends BasePlugin {
  // ========== 鍏冩暟鎹畾涔?==========
  static final _metadata = PluginMetadata(
    id: 'trigger',
    name: '鏅鸿兘瑙﹀彂鍣?',
    description: '鍏佽AI鏍规嵁瀵硅瘽璁剧疆瀹氭椂鎻愰啋',
    version: '2.0.0',
    author: 'AIcove Team',
    icon: Icons.alarm,
    configSchema: {
      'enabled': ConfigField(
        type: ConfigFieldType.boolean,
        label: '鍚敤鎻掍欢',
        defaultValue: false,
      ),
    },
  );

  // ========== 鍐呴儴鐘舵€?==========
  TriggerConfig _triggerConfig;
  final Ref _ref;

  // ========== 鏋勯€犲嚱鏁?==========
  TriggerPlugin(this._triggerConfig, this._ref) : super(metadata: _metadata);

  // ========== 閲嶅啓 enabled getter ==========
  @override
  bool get enabled => _triggerConfig.enabled;

  // ========== 鐢熷懡鍛ㄦ湡鏂规硶 ==========

  @override
  Future<void> onInitialize() async {
    await super.onInitialize();
    debugPrint('[TriggerPlugin] 鍒濆鍖栧畬鎴?');
  }

  @override
  Future<void> onConfigChanged(Map<String, dynamic> newConfig) async {
    _triggerConfig = TriggerConfig.fromJson(newConfig);
    debugPrint('[TriggerPlugin] 閰嶇疆宸叉洿鏂?');
  }

  // ========== 鐜版湁鍔熻兘锛堜繚鐣欙級 ==========

  @override
  Map<String, dynamic> getConfig() => _triggerConfig.toJson();

  @override
  void updateConfig(Map<String, dynamic> config) {
    _triggerConfig = TriggerConfig.fromJson(config);
  }

  @override
  Future<String?> getSystemPrompt({String? userMessage, bool supportsToolCalling = false}) async {
    if (!enabled) return null;
    final lowerMsg = (userMessage ?? '').toLowerCase();
    final isReminderRelated = lowerMsg.contains('提醒') ||
        lowerMsg.contains('闹钟') ||
        lowerMsg.contains('取消') ||
        lowerMsg.contains('remind') ||
        lowerMsg.contains('alarm') ||
        lowerMsg.contains('reminder');
    if (!isReminderRelated) return null;

    if (!supportsToolCalling) {
      return _triggerConfig.logicSystemPrompt;
    }

    return '''
${_triggerConfig.logicSystemPrompt}

Use these tools for reminder management:
- create_reminder
- delete_reminder
- list_reminders
- search_reminders
''';
  }

  // ========== 鏂板锛氬伐鍏锋敞鍐?==========

  @override
  List<AITool> getTools() {
    if (!enabled) return [];

    return [
      _createReminderTool,
      _deleteReminderTool,
      _listRemindersTool,
      _searchRemindersTool,
    ];
  }

  AITool get _createReminderTool => AITool(
    name: 'create_reminder',
    description: '''
鍒涘缓涓€涓畾鏃舵彁閱掋€傚綋鐢ㄦ埛鏄庣‘瑕佹眰璁剧疆鎻愰啋銆侀椆閽熴€佸畾鏃朵换鍔℃椂璋冪敤姝ゅ伐鍏枫€?
浣跨敤鍦烘櫙锛?- "鏄庡ぉ鏃╀笂8鐐瑰彨鎴戣捣搴?
- "2灏忔椂鍚庢彁閱掓垜鍠濇按"
- "涓嬪崍3鐐规彁閱掓垜寮€浼?

涓嶈鍦ㄧ敤鎴锋病鏈夋槑纭姹傛椂璋冪敤姝ゅ伐鍏枫€?''',
    parameters: {
      'title': ToolParameter(
        type: 'string',
        description: '鎻愰啋鐨勬爣棰?鎻忚堪锛岀畝娲佽鏄庤繖涓彁閱掓槸骞蹭粈涔堢殑',
        required: true,
      ),
      'time': ToolParameter(
        type: 'string',
        description: '瑙﹀彂鏃堕棿銆傛敮鎸佹牸寮忥細ISO 8601锛?026-01-27T08:00:00锛夋垨绠€鍗曟椂闂达紙08:00锛屼細鑷姩鍒ゆ柇浠婂ぉ/鏄庡ぉ锛?',
        required: true,
      ),
      'prompt': ToolParameter(
        type: 'string',
        description: '瑙﹀彂鏃剁殑鎸囧鎻愮ず锛屽憡璇変綘鍒版椂鍊欒璇翠粈涔?',
        required: false,
      ),
    },
    handler: _handleCreateReminder,
  );

  AITool get _deleteReminderTool => AITool(
    name: 'delete_reminder',
    description: '''
鍒犻櫎涓€涓凡瀛樺湪鐨勬彁閱掋€傚綋鐢ㄦ埛瑕佹眰鍙栨秷銆佸垹闄ゆ煇涓彁閱掓椂璋冪敤銆?
浣跨敤鍦烘櫙锛?- "鍙栨秷鏄庡ぉ鐨勯椆閽?
- "涓嶇敤鎻愰啋鎴戜簡"
- "鎶婇偅涓彁閱掑垹鎺?

鍙傛暟瑙勫垯锛?- 浼樺厛浼?id锛堟渶鍑嗙‘锛?- 濡傛灉娌℃湁 id锛岃浼?query锛堜緥濡?鏄庡ぉ鏃╀笂鍙垜璧峰簥"/"璧峰簥闂归挓"锛夛紝宸ュ叿鍐呴儴浼?search
''',
    parameters: {
      'id': ToolParameter(
        type: 'string',
        description: '瑕佸垹闄ょ殑鎻愰啋ID锛堝鏋滃凡鐭ワ紝浼樺厛鎻愪緵锛?',
        required: false,
      ),
      'query': ToolParameter(
        type: 'string',
        description: '涓嶇煡閬?id 鏃朵娇鐢細鐢ㄤ竴鍙ヨ瘽鎻忚堪浣犺鍙栨秷鐨勬彁閱掞紙渚嬪"鏄庡ぉ鏃╀笂鍙垜璧峰簥"锛?',
        required: false,
      ),
    },
    handler: _handleDeleteReminder,
  );

  AITool get _listRemindersTool => AITool(
    name: 'list_reminders',
    description: '''
鍒楀嚭鎻愰啋鍒楄〃锛堣Е鍙戝櫒鍒楄〃锛夈€傚綋鐢ㄦ埛闂?鎴戞湁鍝簺鎻愰啋/闂归挓/寰呭姙"鏃惰皟鐢ㄣ€?杩斿洖 JSON 鏁扮粍锛屽寘鍚瘡鏉℃彁閱掔殑 id/title/next_fire_at/status/priority 绛夈€?''',
    parameters: {
      'include_completed': ToolParameter(
        type: 'boolean',
        description: '鏄惁鍖呭惈宸插畬鎴?宸蹭綔搴熺殑鎻愰啋锛堥粯璁?false锛?',
        required: false,
      ),
      'limit': ToolParameter(
        type: 'integer',
        description: '鏈€澶氳繑鍥炲灏戞潯锛堥粯璁?20锛?',
        required: false,
      ),
    },
    handler: _handleListReminders,
  );

  AITool get _searchRemindersTool => AITool(
    name: 'search_reminders',
    description: '''
鎼滅储鎻愰啋鍒楄〃銆傞€傜敤浜庯細鐢ㄦ埛璇?鎶婇偅涓捣搴婃彁閱掑垹鎺?鍙栨秷鏄庡ぉ鐨勯椆閽?浣嗘病鏈?id銆?杩斿洖 JSON 鏁扮粍锛屽寘鍚€欓€夋彁閱掔殑 id/title/next_fire_at 绛夈€?''',
    parameters: {
      'query': ToolParameter(
        type: 'string',
        description: '鎼滅储鍏抽敭璇?鑷劧璇█鎻忚堪锛堜緥濡?璧峰簥""鏄庡ぉ鏃╀笂8鐐?"寮€浼氭彁閱?锛?',
        required: true,
      ),
      'include_completed': ToolParameter(
        type: 'boolean',
        description: '鏄惁鍖呭惈宸插畬鎴?宸蹭綔搴熺殑鎻愰啋锛堥粯璁?false锛?',
        required: false,
      ),
      'limit': ToolParameter(
        type: 'integer',
        description: '鏈€澶氳繑鍥炲灏戞潯锛堥粯璁?5锛?',
        required: false,
      ),
    },
    handler: _handleSearchReminders,
  );

  // ========== 宸ュ叿澶勭悊鍑芥暟 ==========

  Future<String?> _handleCreateReminder(Map<String, dynamic> args) async {
    final settings = await _ref.read(appSettingsProvider.future);
    if (!settings.autoReplySettings.enabled) {
      return jsonEncode({'ok': false, 'error': '主动回复已关闭，无法创建提醒'});
    }

    final title = args['title'] as String? ?? '';
    final timeStr = args['time'] as String? ?? '';
    final prompt = args['prompt'] as String?;

    if (title.isEmpty || timeStr.isEmpty) {
      return jsonEncode({'ok': false, 'error': '缂哄皯蹇呰鍙傛暟 title 鎴?time'});
    }

    // 瑙ｆ瀽鏃堕棿
    final scheduledTime = _parseTime(timeStr);
    if (scheduledTime == null) {
      return jsonEncode({'ok': false, 'error': '鏃犳硶瑙ｆ瀽鏃堕棿鏍煎紡锛?timeStr'});
    }

    // 鑾峰彇褰撳墠浼氳瘽淇℃伅
    final convId = _ref.read(activeConversationIdProvider);
    if (convId == null || convId.isEmpty) {
      return jsonEncode({'ok': false, 'error': '褰撳墠娌℃湁娲昏穬鐨勪細璇?'});
    }

    // 鑾峰彇浼氳瘽涓渶鍚庝竴鏉＄敤鎴锋秷鎭紙鐢ㄤ簬浣滃簾鍒ゆ柇锛?
    final conversations = _ref.read(conversationsProvider).valueOrNull ?? [];
    final conv = conversations.where((c) => c.id == convId).firstOrNull;

    String? lastUserMsgId;
    DateTime? lastUserMsgAt;
    if (conv != null) {
      for (final m in conv.messages.reversed) {
        if (m.role == 'user') {
          lastUserMsgId = m.id;
          lastUserMsgAt = m.createdAt;
          break;
        }
      }
    }

    // 鍒涘缓瑙﹀彂鍣?
    final trigger = await _ref.read(autoReplyTriggersProvider.notifier).createTrigger(
      title: title,
      type: AutoReplyTriggerType.fixed,
      nextFireAt: scheduledTime,
      allowNight: true,
      requireExact: false,
      delayMinutes: 0,
      prompt: prompt,
      priority: AutoReplyTriggerPriority.high, // 鐢ㄦ埛瑕佹眰 = 楂樹紭鍏堢骇
      source: TriggerSource.userRequest,
      conversationId: convId,
      contextLastUserMessageId: lastUserMsgId,
      contextLastUserMessageAt: lastUserMsgAt,
    );

    AppLogger.info('TriggerPlugin', '閫氳繃宸ュ叿璋冪敤鍒涘缓瑙﹀彂鍣?', metadata: {
      'title': title,
      'time': scheduledTime.toIso8601String(),
      'triggerId': trigger.id,
    });

    return jsonEncode({
      'ok': true,
      'result': {
        'id': trigger.id,
        'title': trigger.title,
        'time': _formatTime(scheduledTime),
        'message': '濂界殑锛屾垜浼氬湪 ${_formatTime(scheduledTime)} 鎻愰啋浣狅綖',
      },
    });
  }

  Future<String?> _handleDeleteReminder(Map<String, dynamic> args) async {
    final id = (args['id'] as String?)?.trim();
    final query = (args['query'] as String?)?.trim();

    final convId = _ref.read(activeConversationIdProvider);

    // 1) 浼樺厛鎸?id 鍒犻櫎锛堟渶鍑嗙‘锛?
    if (id != null && id.isNotEmpty) {
      final allTriggers =
          _ref.read(autoReplyTriggersProvider).valueOrNull ?? const <AutoReplyTrigger>[];
      final target = allTriggers.where((t) => t.id == id).firstOrNull;
      if (target == null) {
        return jsonEncode({'ok': false, 'error': '未找到该提醒'});
      }
      if (convId != null && convId.isNotEmpty && target.conversationId != convId) {
        return jsonEncode({'ok': false, 'error': '只能删除当前会话的提醒'});
      }
      await _ref.read(autoReplyTriggersProvider.notifier).deleteTrigger(id);
      AppLogger.info('TriggerPlugin', '通过工具调用删除触发器', metadata: {'id': id});
      return jsonEncode({
        'ok': true,
        'result': {'message': '好的，已经取消了这个提醒'},
      });
    }

    // 2) 鍚﹀垯鎸?query 鍒犻櫎锛氬厛鍦ㄥ綋鍓嶄細璇濋噷鎼滅储鍖归厤鐨勬彁閱?
    if (query == null || query.isEmpty) {
      return jsonEncode({'ok': false, 'error': '璇峰憡璇夋垜瑕佸彇娑堝摢涓彁閱掞紙渚嬪"璧峰簥闂归挓"锛?'});
    }

    final candidates = _ref.read(autoReplyTriggersProvider.notifier).searchTriggers(
      query: query,
      conversationId: convId,
      includeCompleted: false,
      limit: 5,
    );

    if (candidates.isEmpty) {
      return jsonEncode({'ok': false, 'error': '娌℃壘鍒板尮閰? \"$query\" 鐨勬彁閱?'});
    }

    if (candidates.length > 1) {
      final preview = candidates
          .take(3)
          .map((t) => '${t.title} (id: ${t.id})')
          .join(', ');
      return jsonEncode({
        'ok': false,
        'error': '鎵惧埌澶氭潯鍖归厤鎻愰啋锛? $preview 銆傝鎸囧畾瑕佸彇娑堢殑 id銆?',
        'candidates': candidates.map((t) => {
          'id': t.id,
          'title': t.title,
          'next_fire_at': t.nextFireAt.toIso8601String(),
        }).toList(),
      });
    }

    final target = candidates.first;
    await _ref.read(autoReplyTriggersProvider.notifier).deleteTrigger(target.id);
    AppLogger.info('TriggerPlugin', '閫氳繃宸ュ叿璋冪敤鍒犻櫎瑙﹀彂鍣?query)', metadata: {
      'query': query,
      'id': target.id,
    });

    return jsonEncode({
      'ok': true,
      'result': {'message': '濂界殑锛屽凡鍙栨秷锛?{target.title}'},
    });
  }

  Future<String?> _handleListReminders(Map<String, dynamic> args) async {
    final includeCompleted = args['include_completed'] as bool? ?? false;
    final limit = (args['limit'] as num?)?.toInt() ?? 20;

    final convId = _ref.read(activeConversationIdProvider);
    final triggers = _ref.read(autoReplyTriggersProvider).valueOrNull ?? [];

    final filtered = triggers
        .where((t) {
          if (convId != null && t.conversationId != convId) return false;
          if (!includeCompleted && !t.isActive) return false;
          return true;
        })
        .take(limit)
        .map((t) => {
          'id': t.id,
          'title': t.title,
          'next_fire_at': t.nextFireAt.toIso8601String(),
          'status': t.status.name,
          'priority': t.priority.name,
        })
        .toList();

    return jsonEncode({
      'ok': true,
      'result': filtered,
    });
  }

  Future<String?> _handleSearchReminders(Map<String, dynamic> args) async {
    final query = args['query'] as String? ?? '';
    final includeCompleted = args['include_completed'] as bool? ?? false;
    final limit = (args['limit'] as num?)?.toInt() ?? 5;

    if (query.isEmpty) {
      return jsonEncode({'ok': false, 'error': '璇锋彁渚涙悳绱㈠叧閿瘝'});
    }

    final convId = _ref.read(activeConversationIdProvider);
    final candidates = _ref.read(autoReplyTriggersProvider.notifier).searchTriggers(
      query: query,
      conversationId: convId,
      includeCompleted: includeCompleted,
      limit: limit,
    );

    return jsonEncode({
      'ok': true,
      'result': candidates.map((t) => {
        'id': t.id,
        'title': t.title,
        'next_fire_at': t.nextFireAt.toIso8601String(),
        'status': t.status.name,
        'priority': t.priority.name,
      }).toList(),
    });
  }

  // ========== 淇濈暀鍏煎锛歑ML 鏍囩瑙ｆ瀽锛堟爣璁板簾寮冿級 ==========

  @override
  @Deprecated('璇蜂娇鐢ㄥ師鐢熷伐鍏疯皟鐢紝姝ゆ柟娉曚粎浣滀负鍏滃簳鍏煎')
  Future<PluginProcessResult> processResponse(String text) async {
    if (!enabled) {
      return PluginProcessResult(processedText: text, events: []);
    }

    // 妫€娴嬫槸鍚︿娇鐢ㄤ簡搴熷純鐨?XML 鏍囩鏍煎紡
    if (text.contains('<create_trigger') || text.contains('<delete_trigger')) {
      AppLogger.warning('TriggerPlugin', 'AI 浣跨敤浜嗗簾寮冪殑 XML 鏍囩鏍煎紡锛屽簲浣跨敤鍘熺敓宸ュ叿璋冪敤');
    }

    final events = <PluginEvent>[];
    String processedText = text;

    // Handle <create_trigger>
    final createRegex = RegExp(r'<create_trigger\s[^>]*?>', caseSensitive: false);
    final createMatches = createRegex.allMatches(text);
    for (final match in createMatches) {
      final attrString = match.group(0) ?? '';
      final timeMatch = RegExp(r'time="([^"]+)"').firstMatch(attrString);
      final titleMatch = RegExp(r'title="([^"]+)"').firstMatch(attrString);
      final promptMatch = RegExp(r'prompt="([^"]+)"').firstMatch(attrString);
      final contactIdMatch = RegExp(r'contact_id="([^"]+)"').firstMatch(attrString);

      if (timeMatch != null) {
        final timeStr = timeMatch.group(1)!;
        final title = titleMatch?.group(1) ?? 'Active Reply';
        final prompt = promptMatch?.group(1);
        final contactId = contactIdMatch?.group(1);

        final scheduledTime = _parseTime(timeStr);

        if (scheduledTime != null) {
          final convId = contactId ?? _ref.read(activeConversationIdProvider) ?? '';
          AppLogger.info('TriggerPlugin', 'Creating trigger (XML fallback): $title at $scheduledTime');
          await _ref.read(autoReplyTriggersProvider.notifier).createTrigger(
            title: title,
            type: AutoReplyTriggerType.fixed,
            nextFireAt: scheduledTime,
            allowNight: true,
            requireExact: false,
            delayMinutes: 0,
            prompt: prompt,
            priority: AutoReplyTriggerPriority.high,
            source: TriggerSource.userRequest,
            conversationId: convId,
          );

          events.add(PluginEvent(
            pluginId: id,
            type: 'trigger_created',
            data: {
              'time': scheduledTime.toIso8601String(),
              'title': title,
            },
          ));
        }
      }
    }

    // Handle <delete_trigger>
    final deleteRegex = RegExp(r'<delete_trigger\s[^>]*?>', caseSensitive: false);
    final deleteMatches = deleteRegex.allMatches(text);
    for (final match in deleteMatches) {
      final attrString = match.group(0) ?? '';
      final idMatch = RegExp(r'id="([^"]+)"').firstMatch(attrString);

      if (idMatch != null) {
        final triggerId = idMatch.group(1)!;
        AppLogger.info('TriggerPlugin', 'Deleting trigger (XML fallback): $triggerId');
        await _ref.read(autoReplyTriggersProvider.notifier).deleteTrigger(triggerId);

        events.add(PluginEvent(
          pluginId: id,
          type: 'trigger_deleted',
          data: {'id': triggerId},
        ));
      }
    }

    // Remove tags from text
    processedText = text.replaceAll(createRegex, '').replaceAll(deleteRegex, '').trim();

    return PluginProcessResult(
      processedText: processedText,
      events: events,
    );
  }

  // ========== 杈呭姪鏂规硶 ==========

  DateTime? _parseTime(String timeStr) {
    // 灏濊瘯 ISO 8601 鏍煎紡
    try {
      return DateTime.parse(timeStr);
    } catch (_) {}

    // 灏濊瘯 HH:mm 鏍煎紡
    try {
      final parts = timeStr.split(':');
      if (parts.length >= 2) {
        final h = int.parse(parts[0]);
        final m = int.parse(parts[1]);
        final now = DateTime.now();
        var d = DateTime(now.year, now.month, now.day, h, m);
        if (d.isBefore(now)) {
          d = d.add(const Duration(days: 1));
        }
        return d;
      }
    } catch (_) {}

    return null;
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final isToday = time.day == now.day && time.month == now.month && time.year == now.year;
    final isTomorrow = time.day == now.day + 1 && time.month == now.month && time.year == now.year;

    final timeStr = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

    if (isToday) return '浠婂ぉ $timeStr';
    if (isTomorrow) return '鏄庡ぉ $timeStr';
    return '${time.month}鏈?{time.day}鏃?$timeStr';
  }
}

