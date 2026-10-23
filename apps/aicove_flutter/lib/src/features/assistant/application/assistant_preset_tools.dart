import 'dart:convert';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart' show ToolEffect;
import 'package:http/http.dart' as http;

import '../../agent_context/domain/silly_tavern_preset.dart';
import '../../agent_context/domain/tavern_compatibility_port.dart';
import '../../plugins/domain/handlers/ai_tool.dart';
import 'assistant_cards.dart';
import 'assistant_review.dart';
import 'assistant_tool_group.dart';

/// The size limit the preset page uses for imported JSON.
const kAssistantImportBytes = 2 * 1024 * 1024;

/// Downloads a text resource of at most [kAssistantImportBytes], within a
/// minute in all.
Future<String> downloadAssistantText(String url, {http.Client? client}) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    throw const FormatException('链接要以 http:// 或 https:// 开头');
  }
  final own = client ?? http.Client();
  try {
    return await _download(own, uri).timeout(
      const Duration(minutes: 1),
      onTimeout: () => throw const FormatException('下载太慢，超过 1 分钟没下完'),
    );
  } finally {
    // Closing our own client also cancels a read the deadline cut off.
    if (client == null) own.close();
  }
}

Future<String> _download(http.Client client, Uri uri) async {
  final response = await client
      .send(http.Request('GET', uri))
      .timeout(const Duration(seconds: 30));
  if (response.statusCode != 200) {
    throw FormatException('下载失败：HTTP ${response.statusCode}');
  }
  if ((response.contentLength ?? 0) > kAssistantImportBytes) {
    throw const FormatException('文件超过 2 MB，没有导入');
  }
  // Counted while streaming, so an oversized body is never held whole.
  final bytes = <int>[];
  await for (final chunk in response.stream.timeout(
    const Duration(seconds: 30),
  )) {
    bytes.addAll(chunk);
    if (bytes.length > kAssistantImportBytes) {
      throw const FormatException('文件超过 2 MB，没有导入');
    }
  }
  return utf8.decode(bytes);
}

/// Tavern presets beyond switching items on and off (ADR0073 full access,
/// batch P4): importing presets, regex scripts and world books, the default
/// preset, per-preset options and deleting. Imports add, never replace.
class AssistantPresetTools extends AssistantToolGroup {
  AssistantPresetTools({
    required this.presets,
    required this.importPreset,
    required this.change,
    required this.deletePreset,
    required this.cards,
    this.download = downloadAssistantText,
  });

  final Future<List<SillyTavernPreset>> Function() presets;

  final Future<SillyTavernPreset> Function(String source, String fileName)
  importPreset;

  /// Runs [action] on the tavern port and refreshes what shows [presetId].
  final Future<void> Function(
    String? presetId,
    Future<void> Function(TavernCompatibilityPort port) action,
  )
  change;
  final Future<void> Function(String presetId) deletePreset;
  final AssistantCardsNotifier Function() cards;
  final Future<String> Function(String url) download;

  static const importPresetTool = 'aicove_import_preset';
  static const addRegex = 'aicove_add_preset_regex';
  static const addWorldBook = 'aicove_add_world_book';
  static const setOptions = 'aicove_set_preset_options';
  static const setDefault = 'aicove_set_default_preset';
  static const deletePresetTool = 'aicove_delete_preset';

  static const _presetId = {
    'type': 'string',
    'description': 'aicove_list_presets 给出的预设 id',
  };
  static const _url = {'type': 'string', 'description': '下载链接（JSON）'};

  @override
  List<AITool> tools() => [
    assistantTool(
      importPresetTool,
      '导入一套酒馆预设（SillyTavern 预设 JSON）：有 url 就直接下载导入；'
      '没有就在聊天页放一个按钮，让用户选文件。导入的正则默认不运行，要用 aicove_authorize_regex 授权。',
      {'url': _url},
      const [],
      ToolEffect.write,
      _import,
    ),
    assistantTool(
      addRegex,
      '往预设里加正则脚本：scripts 是酒馆正则 JSON（单个对象或数组，字段 scriptName、findRegex、'
      'replaceString、placement 等），可以是你自己写的，也可以给 url 下载。已有的同样脚本会跳过。'
      '预设的正则要授权后才运行。',
      {
        'preset_id': _presetId,
        'scripts': {'type': 'string', 'description': '正则 JSON 文本'},
        'url': _url,
      },
      ['preset_id'],
      ToolEffect.write,
      _addRegex,
    ),
    assistantTool(
      addWorldBook,
      '往预设里加一本世界书：book 是酒馆世界书 JSON（含 entries，每条有 key、content 等），'
      '可以是你自己写的，也可以给 url 下载。同 id 的世界书不会重复导入。',
      {
        'preset_id': _presetId,
        'name': {'type': 'string', 'description': '世界书名字'},
        'book': {'type': 'string', 'description': '世界书 JSON 文本'},
        'url': _url,
      },
      ['preset_id', 'name'],
      ToolEffect.write,
      _addWorldBook,
    ),
    assistantTool(
      setOptions,
      '设置预设选项（只传要改的）：user_name_macro（用「我的名字」替换 {{user}}）、mvu（MVU 变量系统）。',
      {
        'preset_id': _presetId,
        'user_name_macro': {'type': 'boolean'},
        'mvu': {'type': 'boolean'},
      },
      ['preset_id'],
      ToolEffect.write,
      _setOptions,
    ),
    assistantTool(
      setDefault,
      '设置全局默认酒馆预设（没绑定预设的角色用它）；preset_id 传空字符串表示不用默认预设。'
      'enabled=false 会整体关闭酒馆兼容。',
      {
        'preset_id': {'type': 'string'},
        'enabled': {'type': 'boolean'},
      },
      ['preset_id'],
      ToolEffect.write,
      _setDefault,
    ),
    assistantTool(
      deletePresetTool,
      '删除一套酒馆预设（提示词、正则、世界书一起删），不能撤销，开启「修改前每次问我」后需确认。还有角色绑定着的删不了。',
      {'preset_id': _presetId},
      ['preset_id'],
      ToolEffect.write,
      _delete,
    ),
  ];

  @override
  AssistantRisk riskOf(String toolName, Map<String, dynamic> args) =>
      switch (toolName) {
        deletePresetTool => AssistantRisk.major,
        importPresetTool when '${args['url'] ?? ''}'.trim().isEmpty =>
          AssistantRisk.readOnly,
        _ => AssistantRisk.review,
      };

  /// Reads the preset first: a card must name what it deletes, and a
  /// preset that cannot be found is said so plainly.
  @override
  Future<ApprovalPrompt> describe(
    String toolName,
    Map<String, dynamic> args,
  ) async {
    final id = '${args['preset_id'] ?? ''}';
    final found = (await presets()).where((p) => p.id == id).firstOrNull;
    final name = found?.name ?? '找不到的预设 $id（同意也不会执行）';
    return switch (toolName) {
      deletePresetTool => ApprovalPrompt(
        title: '删除酒馆预设「$name」',
        detail: '提示词、正则和世界书会一起删除，不能撤销',
      ),
      importPresetTool => ApprovalPrompt(
        title: '导入酒馆预设',
        detail: '从 ${args['url']} 下载',
      ),
      addRegex => ApprovalPrompt(title: '给预设「$name」加正则', detail: '加完要授权才运行'),
      addWorldBook => ApprovalPrompt(
        title: '给预设「$name」加世界书「${args['name'] ?? ''}」',
        detail: '世界书的内容会在聊天时按关键词注入',
      ),
      _ => ApprovalPrompt(title: '修改预设设置', detail: jsonEncode(args)),
    };
  }

  Future<Map<String, Object?>> _guard(
    Future<Map<String, Object?>> Function() body,
  ) async {
    try {
      return await body();
    } on FormatException catch (error) {
      return assistantToolError(error.message);
    } on StateError catch (error) {
      return assistantToolError(error.message);
    }
  }

  Future<SillyTavernPreset> _preset(Object? id) async {
    final preset =
        (await presets()).where((p) => p.id == '$id').firstOrNull ??
        (throw StateError('没有 id 为「$id」的预设'));
    return preset;
  }

  /// The JSON from [args]' text field or its url.
  Future<String> _source(Map<String, dynamic> args, String field) async {
    final text = '${args[field] ?? ''}'.trim();
    final url = '${args['url'] ?? ''}'.trim();
    if (text.isNotEmpty) {
      if (utf8.encode(text).length > kAssistantImportBytes) {
        throw const FormatException('内容超过 2 MB');
      }
      return text;
    }
    if (url.isNotEmpty) return download(url);
    throw FormatException('要给 $field 或 url');
  }

  Future<Map<String, Object?>> _import(Map<String, dynamic> args) =>
      _guard(() async {
        final url = '${args['url'] ?? ''}'.trim();
        if (url.isEmpty) {
          cards().importPreset();
          return {'ok': true, 'card': '已在聊天页放了一个「导入预设」按钮，用户选文件后导入'};
        }
        final name = Uri.parse(url).pathSegments.lastOrNull ?? 'preset.json';
        final preset = await importPreset(await download(url), name);
        return {
          'ok': true,
          'preset_id': preset.id,
          'name': preset.name,
          'regex_count': preset.regexScripts.length,
          if (preset.warnings.isNotEmpty) 'warnings': preset.warnings.take(5).toList(),
        };
      });

  Future<Map<String, Object?>> _addRegex(Map<String, dynamic> args) =>
      _guard(() async {
        final preset = await _preset(args['preset_id']);
        final source = await _source(args, 'scripts');
        await change(preset.id, (port) => port.importRegex(preset.id, source));
        final after = await _preset(preset.id);
        return {
          'ok': true,
          'change': '给「${preset.name}」加了 '
              '${after.regexScripts.length - preset.regexScripts.length} 条正则',
          'authorized': after.regexAuthorized,
        };
      });

  Future<Map<String, Object?>> _addWorldBook(Map<String, dynamic> args) =>
      _guard(() async {
        final preset = await _preset(args['preset_id']);
        final source = await _source(args, 'book');
        final name = '${args['name'] ?? ''}'.trim();
        if (name.isEmpty) throw const FormatException('世界书要有名字');
        await change(
          preset.id,
          (port) => port.importWorldBook(preset.id, source, '$name.json'),
        );
        return {'ok': true, 'change': '给「${preset.name}」加了世界书「$name」'};
      });

  Future<Map<String, Object?>> _setOptions(Map<String, dynamic> args) =>
      _guard(() async {
        final preset = await _preset(args['preset_id']);
        final macro = args['user_name_macro'];
        final mvu = args['mvu'];
        if (macro is! bool && mvu is! bool) {
          throw const FormatException('没有要改的选项');
        }
        await change(preset.id, (port) async {
          if (macro is bool) await port.setUserNameMacroEnabled(preset.id, macro);
          if (mvu is bool) await port.setMvuEnabled(preset.id, mvu);
        });
        return {'ok': true, 'change': '改了「${preset.name}」的选项'};
      });

  Future<Map<String, Object?>> _setDefault(Map<String, dynamic> args) =>
      _guard(() async {
        final id = '${args['preset_id'] ?? ''}'.trim();
        final chosen = id.isEmpty ? null : await _preset(id);
        final enabled = args['enabled'];
        await change(null, (port) async {
          final current = await port.loadPluginSettings();
          await port.savePluginSettings(
            TavernPluginSettings(
              enabled: enabled is bool ? enabled : current.enabled,
              defaultPresetId: id.isEmpty ? null : id,
            ),
          );
        });
        return {
          'ok': true,
          'change': chosen == null ? '取消了默认预设' : '默认预设改成了「${chosen.name}」',
        };
      });

  Future<Map<String, Object?>> _delete(Map<String, dynamic> args) =>
      _guard(() async {
        final preset = await _preset(args['preset_id']);
        try {
          await deletePreset(preset.id);
        } on StateError {
          // The store names every bound role, roles in the privacy space
          // included; none of those names may reach the model.
          return assistantToolError(
            '还有角色绑定着这个预设，删不了。先用 aicove_bind_preset 给它们换预设或解除绑定',
          );
        }
        return {'ok': true, 'change': '删除了预设「${preset.name}」'};
      });
}
