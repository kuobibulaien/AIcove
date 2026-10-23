import 'package:aicove_agent_kernel/aicove_agent_kernel.dart' show ToolEffect;

import '../../chat/domain/conversation.dart';
import '../../plugins/domain/handlers/ai_tool.dart';
import '../../plugins/tts/tts_config.dart' show VoicePreset;
import '../../settings/app_settings.dart';
import '../domain/assistant_onboarding.dart' show kAicoveAssistantId;
import 'assistant_cards.dart';
import 'assistant_review.dart';
import 'assistant_tool_group.dart';
import 'assistant_write_tools.dart';

/// Built-in pictures a role can use, by the name the tools take.
const kAssistantBuiltinImages = <String, String>{
  'nahida': 'assets/characters/images/nahida.jpg',
  'aicove': 'assets/characters/images/aicove_assistant.png',
};

/// Image slots of a role card, by tool name.
const kAssistantImageSlots = <String, ({String field, String label})>{
  'avatar': (field: RoleField.avatarUrl, label: '头像'),
  'portrait': (field: RoleField.characterImage, label: '立绘'),
  'wallpaper': (field: RoleField.chatBackground, label: '聊天壁纸'),
};

/// The rest of a role card (ADR0073 full access, batch P3): pictures, voice,
/// thinking level, pin and mute, deleting and clearing. Undoable edits go
/// through [AssistantWriteTools.editRole]; deleting and clearing always ask.
class AssistantRoleTools extends AssistantToolGroup {
  AssistantRoleTools({
    required this.writes,
    required this.roles,
    required this.rolesNow,
    required this.settings,
    required this.voices,
    required this.cards,
    required this.deleteRole,
    required this.clearChat,
    this.drawingPresets,
    this.onChanged,
  });

  final AssistantWriteTools writes;

  /// Visible roles only.
  final Future<List<Conversation>> Function() roles;

  /// The role list without waiting, for naming the role on approval cards.
  final List<Conversation> Function() rolesNow;
  final Future<AppSettings> Function() settings;
  final List<VoicePreset> Function() voices;
  final AssistantCardsNotifier Function() cards;
  final Future<void> Function(String roleId) deleteRole;
  final Future<void> Function(String roleId) clearChat;

  /// Drawing presets by id and name; null where they cannot be read, and
  /// the drawing preset tool then refuses.
  final Future<List<({String id, String name})>> Function()? drawingPresets;
  final void Function()? onChanged;

  static const setLook = 'aicove_set_role_look';
  static const pickImage = 'aicove_pick_role_image';
  static const listVoices = 'aicove_list_voices';
  static const setVoice = 'aicove_set_role_voice';
  static const setDrawingPreset = 'aicove_set_role_drawing_preset';
  static const setThinking = 'aicove_set_role_thinking';
  static const setFlags = 'aicove_set_role_flags';
  static const setChatView = 'aicove_set_role_chat_view';
  static const deleteRoleTool = 'aicove_delete_role';
  static const clearChatTool = 'aicove_clear_role_chat';
  static const importCard = 'aicove_import_role_card';

  static const _roleId = {
    'type': 'string',
    'description': 'aicove_list_roles 给出的角色 id',
  };

  static final _imageSource = {
    'type': 'string',
    'description':
        '图片来源：builtin:名字（${kAssistantBuiltinImages.keys.join('、')}）、'
        'role:角色id:avatar|portrait|wallpaper（用另一个角色或同一角色另一处的图），空字符串表示清除',
  };

  @override
  List<AITool> tools() => [
    assistantTool(
      setLook,
      '设置角色的头像、立绘、聊天壁纸（只传要改的）。直接生效，可撤销。'
      '用户想用自己的图片时改用 aicove_pick_role_image。',
      {
        'role_id': _roleId,
        'avatar': _imageSource,
        'portrait': _imageSource,
        'wallpaper': _imageSource,
      },
      ['role_id'],
      ToolEffect.write,
      _setLook,
    ),
    assistantTool(
      pickImage,
      '在聊天页放一张「选图片」卡片：用户点一下选一张自己的图片，就会设为角色的头像（会先裁剪）、立绘或聊天壁纸。'
      '卡片选好之前什么都没改。',
      {
        'role_id': _roleId,
        'slot': {
          'type': 'string',
          'enum': kAssistantImageSlots.keys.toList(),
        },
      },
      ['role_id', 'slot'],
      ToolEffect.readDiagnostic,
      _pickImage,
    ),
    assistantTool(
      listVoices,
      '列出可以给角色用的音色（id、名字、来源）。',
      const {},
      const [],
      ToolEffect.readDiagnostic,
      (_) async => {
        'voices': [
          for (final voice in voices())
            {
              'id': voice.id,
              'name': voice.name,
              'provider': voice.providerType.name,
            },
        ],
      },
    ),
    assistantTool(
      setVoice,
      '给角色绑定音色（voice_id 来自 aicove_list_voices；空字符串表示解除绑定，用全局默认音色）。直接生效，可撤销。',
      {
        'role_id': _roleId,
        'voice_id': {'type': 'string'},
      },
      ['role_id', 'voice_id'],
      ToolEffect.write,
      _setVoice,
    ),
    assistantTool(
      setDrawingPreset,
      '给角色换绘图预设（preset_id 是绘图预设 id，见 aicove_list_prompt_packs 的 presets 里 plugin=image 的；'
      '空字符串表示跟随默认绘图预设）。直接生效，可撤销。',
      {
        'role_id': _roleId,
        'preset_id': {'type': 'string'},
      },
      ['role_id', 'preset_id'],
      ToolEffect.write,
      _setDrawingPreset,
    ),
    assistantTool(
      setThinking,
      '设置角色在某个模型上的思考档位（${ThinkingLevel.values.map((l) => l.name).join('、')}）；'
      'level 传空字符串表示跟随模型默认。model 不填就用当前默认聊天模型。直接生效，可撤销。',
      {
        'role_id': _roleId,
        'level': {'type': 'string'},
        'model': {'type': 'string', 'description': '「渠道 id:模型名」'},
      },
      ['role_id', 'level'],
      ToolEffect.write,
      _setThinking,
    ),
    assistantTool(
      setFlags,
      '置顶或取消置顶角色、开关免打扰（只传要改的）。直接生效，可撤销。',
      {
        'role_id': _roleId,
        'pinned': {'type': 'boolean'},
        'muted': {'type': 'boolean'},
      },
      ['role_id'],
      ToolEffect.write,
      _setFlags,
    ),
    assistantTool(
      setChatView,
      '设置和这个角色的聊天自己的样式（只传要改的）：display_style 是 bubble（气泡）、document（文档）或 follow／null（清除这里的选择，跟随默认）；'
      'wallpaper_mask（0～1）和 wallpaper_blur（0～$kMaxWallpaperBlur）调这个聊天专属壁纸的遮罩和模糊，传 null 恢复默认。'
      '没有专属壁纸时调不了（全局壁纸用 aicove_settings_set）。直接生效，可撤销。',
      {
        'role_id': _roleId,
        'display_style': {
          'type': ['string', 'null'],
          'enum': [
            'follow',
            for (final style in ChatDisplayStyle.values) style.name,
            null,
          ],
        },
        'wallpaper_mask': {
          'type': ['number', 'null'],
        },
        'wallpaper_blur': {
          'type': ['number', 'null'],
        },
      },
      ['role_id'],
      ToolEffect.write,
      _setChatView,
    ),
    assistantTool(
      deleteRoleTool,
      '删除角色和它的聊天记录，在 App 里找不回来，开启「修改前每次问我」后需确认。',
      {'role_id': _roleId},
      ['role_id'],
      ToolEffect.write,
      _delete,
    ),
    assistantTool(
      clearChatTool,
      '清空角色的全部聊天记录、对话摘要和自动整理的记忆（用户锁定的记忆保留），角色卡不变。'
      '在 App 里撤销不了，开启「修改前每次问我」后需确认。',
      {'role_id': _roleId},
      ['role_id'],
      ToolEffect.write,
      _clear,
    ),
    assistantTool(
      importCard,
      '导入酒馆角色卡（PNG 或 JSON）：在聊天页放一个按钮，用户点开就进入新建角色页并开始导入'
      '（有 url 时直接从链接下载，否则让用户选文件），核对后点创建。卡里的正则和世界书会放进角色专用预设。',
      {
        'url': {'type': 'string', 'description': '角色卡的下载链接，没有就不填'},
      },
      const [],
      ToolEffect.readDiagnostic,
      _import,
    ),
  ];

  @override
  AssistantRisk riskOf(String toolName, Map<String, dynamic> args) =>
      switch (toolName) {
        pickImage || listVoices || importCard => AssistantRisk.readOnly,
        deleteRoleTool || clearChatTool => AssistantRisk.major,
        _ => AssistantRisk.reversible,
      };

  @override
  ApprovalPrompt describe(String toolName, Map<String, dynamic> args) {
    final id = '${args['role_id']}';
    final role = rolesNow()
        .where((r) => r.id == id && !r.isHidden)
        .firstOrNull;
    final name = role == null ? '角色 $id' : role.displayName;
    return switch (toolName) {
      deleteRoleTool => ApprovalPrompt(
        title: '删除角色「$name」',
        detail: '角色和聊天记录都会删除，在 App 里找不回来',
      ),
      clearChatTool => ApprovalPrompt(
        title: '清空「$name」的聊天记录',
        detail: '聊天记录、对话摘要和自动整理的记忆都会清空，在 App 里撤销不了',
      ),
      _ => ApprovalPrompt(title: '修改角色「$name」', detail: '可以在聊天页撤销'),
    };
  }

  Future<Conversation> _role(Object? id) async {
    final role =
        (await roles()).where((r) => r.id == '$id' && !r.isHidden).firstOrNull ??
        (throw StateError('没有 id 为「$id」的角色'));
    return role;
  }

  Future<Map<String, Object?>> _guard(
    Future<Map<String, Object?>> Function() body,
  ) async {
    try {
      return await body();
    } on StateError catch (error) {
      return assistantToolError(error.message);
    } on FormatException catch (error) {
      return assistantToolError(error.message);
    }
  }

  Future<Map<String, Object?>> _setLook(Map<String, dynamic> args) =>
      _guard(() async {
        final role = await _role(args['role_id']);
        final all = await roles();
        final fields = <String, Object?>{};
        for (final MapEntry(:key, value: slot) in kAssistantImageSlots.entries) {
          if (!args.containsKey(key)) continue;
          final source = _resolveImage('${args[key] ?? ''}', all);
          final image = source is Map ? source['image'] as String : source;
          fields[slot.field] = slot.field != RoleField.chatBackground
              ? image
              // A wallpaper taken from a wallpaper keeps its framing; any
              // other picture starts unframed.
              : source is Map
              ? source
              : image == null
              ? null
              : {'image': image, 'framing': null};
        }
        if (fields.isEmpty) throw const FormatException('没有要改的图片');
        return writes.editRole(setLook, role.id, fields);
      });

  /// A picture path, a wallpaper with its framing (from a wallpaper slot),
  /// or null to clear.
  static Object? _resolveImage(String source, List<Conversation> roles) {
    final text = source.trim();
    if (text.isEmpty) return null;
    if (text.startsWith('builtin:')) {
      return kAssistantBuiltinImages[text.substring(8)] ??
          (throw FormatException('没有这张内置图片：$text'));
    }
    final parts = text.split(':');
    if (parts.length == 3 && parts.first == 'role') {
      final from =
          roles.where((r) => r.id == parts[1] && !r.isHidden).firstOrNull ??
          (throw FormatException('没有 id 为「${parts[1]}」的角色'));
      final slot =
          kAssistantImageSlots[parts[2]] ??
          (throw FormatException('图片位置只能是 avatar、portrait、wallpaper'));
      final value = RoleField.read(from, slot.field);
      if (value == null) {
        throw FormatException('「${from.displayName}」没有${slot.label}');
      }
      return value;
    }
    throw FormatException('看不懂的图片来源：$text');
  }

  Future<Map<String, Object?>> _pickImage(Map<String, dynamic> args) =>
      _guard(() async {
        final role = await _role(args['role_id']);
        final slot = '${args['slot']}';
        if (!kAssistantImageSlots.containsKey(slot)) {
          throw FormatException('图片位置只能是 ${kAssistantImageSlots.keys.join('、')}');
        }
        cards().pickRoleImage(role.id, role.displayName, slot);
        return {'ok': true, 'card': '已在聊天页放了一张选图片卡片，用户选好图片后才会生效'};
      });

  Future<Map<String, Object?>> _setVoice(Map<String, dynamic> args) =>
      _guard(() async {
        final role = await _role(args['role_id']);
        final id = '${args['voice_id'] ?? ''}'.trim();
        if (id.isNotEmpty && !voices().any((v) => v.id == id)) {
          throw FormatException('没有这个音色：$id，先用 $listVoices 查');
        }
        return writes.editRole(setVoice, role.id, {
          RoleField.voiceFile: id.isEmpty ? null : id,
        });
      });

  Future<Map<String, Object?>> _setDrawingPreset(Map<String, dynamic> args) =>
      _guard(() async {
        final role = await _role(args['role_id']);
        final id = '${args['preset_id'] ?? ''}'.trim();
        final list = drawingPresets;
        if (list == null) throw StateError('现在读不到绘图预设');
        if (id.isNotEmpty) {
          final presets = await list();
          if (!presets.any((p) => p.id == id)) {
            throw FormatException(
              '没有这个绘图预设：$id；可用：${[for (final p in presets) '${p.id}（${p.name}）'].join('、')}',
            );
          }
        }
        return writes.editRole(setDrawingPreset, role.id, {
          RoleField.drawingPreset: id.isEmpty ? null : {'id': id},
        });
      });

  Future<Map<String, Object?>> _setThinking(Map<String, dynamic> args) =>
      _guard(() async {
        final role = await _role(args['role_id']);
        final s = await settings();
        final model = '${args['model'] ?? ''}'.trim().isEmpty
            ? s.defaultModelName.trim()
            : '${args['model']}'.trim();
        if (model.isEmpty) throw const FormatException('还没有默认聊天模型');
        final level = '${args['level'] ?? ''}'.trim();
        if (level.isNotEmpty &&
            !ThinkingLevel.values.any((l) => l.name == level)) {
          throw FormatException('没有这个档位：$level');
        }
        final levels = {
          ...RoleField.read(role, RoleField.thinkingLevels)! as Map,
        };
        if (level.isEmpty) {
          levels.remove(model);
        } else {
          levels[model] = level;
        }
        return writes.editRole(setThinking, role.id, {
          RoleField.thinkingLevels: levels,
        });
      });

  Future<Map<String, Object?>> _setFlags(Map<String, dynamic> args) =>
      _guard(() async {
        final role = await _role(args['role_id']);
        final fields = <String, Object?>{
          if (args['pinned'] is bool) RoleField.pinned: args['pinned'],
          if (args['muted'] is bool) RoleField.muted: args['muted'],
        };
        if (fields.isEmpty) throw const FormatException('没有要改的项');
        return writes.editRole(setFlags, role.id, fields);
      });

  Future<Map<String, Object?>> _setChatView(Map<String, dynamic> args) =>
      _guard(() async {
        final role = await _role(args['role_id']);
        final fields = <String, Object?>{};
        if (args.containsKey('display_style')) {
          final style = '${args['display_style'] ?? 'follow'}';
          if (style != 'follow' &&
              !ChatDisplayStyle.values.any((s) => s.name == style)) {
            throw FormatException('聊天样式只能是 follow、bubble、document：$style');
          }
          fields[RoleField.displayStyle] = style == 'follow' ? null : style;
        }
        for (final (key, field, max) in [
          ('wallpaper_mask', RoleField.wallpaperMask, 1.0),
          ('wallpaper_blur', RoleField.wallpaperBlur, kMaxWallpaperBlur),
        ]) {
          if (!args.containsKey(key)) continue;
          final value = args[key];
          if (value != null &&
              (value is! num || !value.isFinite || value < 0 || value > max)) {
            throw FormatException('$key 应为 0～$max 的数');
          }
          if (role.chatBackgroundImage?.trim().isNotEmpty != true) {
            throw const FormatException(
              '这个聊天没有专属壁纸，遮罩和模糊不会生效；先用 aicove_set_role_look 设一张，或用 aicove_settings_set 调全局壁纸',
            );
          }
          fields[field] = (value as num?)?.toDouble();
        }
        if (fields.isEmpty) throw const FormatException('没有要改的项');
        final result = await writes.editRole(
          setChatView,
          role.id,
          fields,
          guarded: true,
        );
        // The assistant's own chat shows documents unless the user picks
        // otherwise; say so when clearing the choice there.
        if (fields.containsKey(RoleField.displayStyle) &&
            fields[RoleField.displayStyle] == null &&
            role.id == kAicoveAssistantId) {
          return {...result, 'note': '你自己的聊天不选样式时固定用文档模式'};
        }
        return result;
      });

  Future<Map<String, Object?>> _delete(Map<String, dynamic> args) =>
      _guard(() async {
        final role = await _role(args['role_id']);
        await deleteRole(role.id);
        onChanged?.call();
        return {'ok': true, 'change': '删除了角色「${role.displayName}」'};
      });

  Future<Map<String, Object?>> _clear(Map<String, dynamic> args) =>
      _guard(() async {
        final role = await _role(args['role_id']);
        await clearChat(role.id);
        onChanged?.call();
        return {'ok': true, 'change': '清空了「${role.displayName}」的聊天记录'};
      });

  Future<Map<String, Object?>> _import(Map<String, dynamic> args) async {
    final url = '${args['url'] ?? ''}'.trim();
    if (url.isNotEmpty && Uri.tryParse(url)?.hasScheme != true) {
      return assistantToolError('链接不对：$url');
    }
    cards().importRoleCard(url.isEmpty ? null : url);
    return {'ok': true, 'card': '已在聊天页放了一个「导入角色卡」按钮'};
  }
}
