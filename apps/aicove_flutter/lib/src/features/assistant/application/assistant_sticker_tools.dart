import 'package:aicove_agent_kernel/aicove_agent_kernel.dart'
    show ReversibleChange, ToolEffect;

import '../../agent_plugins/file_change_journal.dart';
import '../../plugins/domain/handlers/ai_tool.dart';
import '../../stickers/sticker_library.dart';
import '../../stickers/sticker_web_import.dart';
import 'assistant_review.dart';
import 'assistant_tool_group.dart';

const assistantStickerImportKind = 'assistant.sticker_import';
const assistantStickerTagsKind = 'assistant.sticker_tags';

/// 表情包的两个工具：从网页导入一套表情，以及给表情改标签。
///
/// 导入会下载外部文件，所以开启「修改前每次问我」后需确认；改标签可撤销。
class AssistantStickerTools extends AssistantToolGroup {
  AssistantStickerTools({
    required this.library,
    required this.journal,
    this.onChanged,
    this.fetch = _fetchPublicPage,
  });

  /// 表情包库；测试可替换为临时目录下的库。
  final Future<StickerLibrary> Function() library;
  final FileChangeJournal journal;
  final void Function()? onChanged;

  /// 抓取网页；默认拒绝本机和内网地址，测试可替换。
  final Future<StickerWebPage> Function(Uri uri) fetch;

  static Future<StickerWebPage> _fetchPublicPage(Uri uri) =>
      fetchStickerPage(uri);

  static const importTool = 'aicove_sticker_import_url';
  static const tagsTool = 'aicove_sticker_set_tags';

  static const _maxTagEdits = 200;

  @override
  List<AITool> tools() => [
    assistantTool(
      importTool,
      '从一个网页链接导入表情包（例如公众号图片消息）：下载页面里的表情图，'
      '新建一套表情，图片暂时都是「未标注」，需要再用 $tagsTool 打标签才会被发出。'
      '会下载外部文件，默认直接执行；撤销会删除这套表情。',
      {
        'url': _string('网页链接，只支持 http 和 https'),
        'pack_name': _string('套组名字，不填则用网页标题'),
      },
      ['url'],
      ToolEffect.write,
      _import,
    ),
    assistantTool(
      tagsTool,
      '给已导入的表情改标签（一次最多 $_maxTagEdits 张）。标签 2～4 个字最好，'
      '写情绪或动作；不能含 < > 引号和方括号。传 tags 为空数组表示清空标签。'
      '会直接生效，可撤销。',
      {
        'pack_id': _string('套组 id'),
        'stickers': {
          'type': 'array',
          'description': '每项是 {id: 表情 id, tags: [标签]}',
          'items': {
            'type': 'object',
            'properties': {
              'id': {'type': 'string'},
              'tags': {
                'type': 'array',
                'items': {'type': 'string'},
              },
            },
            'required': ['id', 'tags'],
          },
        },
      },
      ['pack_id', 'stickers'],
      ToolEffect.write,
      _setTags,
    ),
  ];

  @override
  AssistantRisk riskOf(String toolName, Map<String, dynamic> args) =>
      toolName == importTool ? AssistantRisk.major : AssistantRisk.reversible;

  @override
  ApprovalPrompt describe(String toolName, Map<String, dynamic> args) {
    if (toolName == importTool) {
      return ApprovalPrompt(
        title: '从链接导入表情包',
        detail: '${args['url']}\n会下载页面里的图片，撤销会删除这套表情',
      );
    }
    final count = args['stickers'] is List ? (args['stickers'] as List).length : 0;
    return ApprovalPrompt(
      title: '修改 $count 张表情的标签',
      detail: '可以撤销',
    );
  }

  Future<Map<String, Object?>> _import(Map<String, dynamic> args) async {
    final raw = args['url'];
    final uri = raw is String ? Uri.tryParse(raw.trim()) : null;
    if (uri == null) return assistantToolError('链接格式不对');

    final StickerWebPage page;
    try {
      page = await fetch(uri);
    } on StickerWebException catch (error) {
      return assistantToolError('抓取失败：${error.message}');
    } on Object {
      return assistantToolError('抓取失败，请确认链接能在浏览器里打开');
    }
    if (page.images.isEmpty) {
      return assistantToolError(
        '页面里没找到可用的表情图（小图 ${page.smallCount} 张，失败 ${page.failedCount} 张）',
      );
    }

    final requested = args['pack_name'];
    final name = requested is String && requested.trim().isNotEmpty
        ? requested.trim()
        : (page.title.isNotEmpty ? page.title : '网页导入');
    final lib = await library();
    final result = await lib.importFiles(page.images, packName: name);
    final packId = result.packIds.first;
    final pack = lib.packById(packId)!;

    await journal.append(
      importTool,
      ReversibleChange(
        kind: assistantStickerImportKind,
        description: '从链接导入了套组「${pack.name}」',
        before: {'packId': packId, 'present': false},
        after: {'packId': packId, 'present': true},
      ),
    );
    onChanged?.call();
    return {
      'ok': true,
      'pack_id': packId,
      'pack_name': pack.name,
      'added': result.added,
      'untagged': result.untagged,
      'skipped': result.skipped + page.smallCount + page.failedCount,
      'stickers': [
        for (final sticker in pack.stickers) {'id': sticker.id},
      ],
      'note': '这些表情还没有标签，用 $tagsTool 打标签后才会被发出',
      'undo': '用户可以在聊天页撤销，撤销会删除这套表情',
    };
  }

  Future<Map<String, Object?>> _setTags(Map<String, dynamic> args) async {
    final packId = args['pack_id'];
    final lib = await library();
    final pack = packId is String ? lib.packById(packId) : null;
    if (pack == null) {
      return assistantToolError('没有这个套组');
    }
    final entries = args['stickers'];
    if (entries is! List || entries.isEmpty || entries.length > _maxTagEdits) {
      return assistantToolError('stickers 应为 1～$_maxTagEdits 项的数组');
    }

    final byId = {for (final sticker in pack.stickers) sticker.id: sticker};
    final before = <Map<String, Object?>>[];
    final after = <Map<String, Object?>>[];
    for (final entry in entries) {
      if (entry is! Map || entry['id'] is! String || entry['tags'] is! List) {
        return assistantToolError('每项应为 {id, tags}');
      }
      final id = entry['id'] as String;
      final sticker = byId[id];
      if (sticker == null) return assistantToolError('这套表情里没有 id：$id');
      final tags = normalizeStickerTags(
        (entry['tags'] as List).whereType<String>(),
      );
      if (_sameTags(sticker.tags, tags)) continue;
      before.add({'id': id, 'tags': sticker.tags});
      after.add({'id': id, 'tags': tags});
    }
    if (after.isEmpty) return {'ok': true, 'change': '没有变化'};

    await journal.commit(
      tagsTool,
      ReversibleChange(
        kind: assistantStickerTagsKind,
        description: '修改了 ${after.length} 张表情的标签',
        before: {'stickers': before},
        after: {'stickers': after},
      ),
    );
    onChanged?.call();
    return {
      'ok': true,
      'changed': after.length,
      'undo': '用户可以在聊天页撤销这次修改',
    };
  }

  bool _sameTags(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// 撤销导入：删除这套表情。`present` 为 true 的状态（再次执行）什么也不做。
class AssistantStickerImportApplier implements ChangeApplier {
  AssistantStickerImportApplier(this.library);

  final Future<StickerLibrary> Function() library;

  @override
  Future<void> apply(Map<String, Object?> state) async {
    if (state['present'] == true) return;
    final packId = state['packId'];
    if (packId is! String) return;
    final lib = await library();
    if (lib.packById(packId) == null) return;
    await lib.deletePack(packId);
  }
}

/// 撤销或重做改标签：把每张表情的标签写回状态里的值。
class AssistantStickerTagsApplier implements ChangeApplier {
  AssistantStickerTagsApplier(this.library);

  final Future<StickerLibrary> Function() library;

  @override
  Future<void> apply(Map<String, Object?> state) async {
    final lib = await library();
    final entries = state['stickers'];
    if (entries is! List) return;
    for (final entry in entries) {
      if (entry is! Map) continue;
      final id = entry['id'];
      final tags = entry['tags'];
      if (id is! String || tags is! List) continue;
      await lib.updateSticker(id, tags: tags.whereType<String>().toList());
    }
  }
}

Map<String, Object> _string(String description) => {
  'type': 'string',
  'description': description,
};
