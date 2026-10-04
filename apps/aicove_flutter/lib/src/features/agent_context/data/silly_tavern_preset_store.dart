library;

import '../../../core/sync/cloud_local_write.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/app_logger.dart';
import '../../content_tags/domain/tag_presentation.dart';
import '../domain/preset_tag_mapping.dart';
import '../domain/silly_tavern_preset.dart';
import '../domain/silly_tavern_preset_parser.dart';
import '../domain/silly_tavern_world_book.dart';
import '../domain/tavern_compatibility_port.dart';

typedef PresetDocumentsDirectoryResolver = Future<Directory> Function();

/// 没有外部提示词预设时使用的最小组合：只装配人设、场景、世界书与聊天记录。
const String kBasicContextPresetSource =
    '''{"name":"基础上下文","prompts":[
      {"identifier":"worldInfoBefore","name":"世界书：角色定义前","marker":true},
      {"identifier":"charDescription","name":"角色定义","marker":true},
      {"identifier":"scenario","name":"场景","marker":true},
      {"identifier":"worldInfoAfter","name":"世界书：角色定义后","marker":true},
      {"identifier":"chatHistory","name":"聊天记录","marker":true}],
      "prompt_order":[{"identifier":"worldInfoBefore","enabled":true},
      {"identifier":"charDescription","enabled":true},
      {"identifier":"scenario","enabled":true},
      {"identifier":"worldInfoAfter","enabled":true},
      {"identifier":"chatHistory","enabled":true}]}''';

/// 角色卡资源并入专用组合的结果。
class CardPresetImportResult {
  const CardPresetImportResult({
    required this.preset,
    required this.baseName,
    required this.addedRegexCount,
    required this.skippedRegexCount,
    required this.worldEntryCount,
    required this.warnings,
  });

  final SillyTavernPreset preset;

  /// 复制来源；null 表示以内置「基础上下文」为底。
  final String? baseName;
  final int addedRegexCount;

  /// 与底预设同 ID 或缺少 findRegex 而跳过的卡内正则。
  final int skippedRegexCount;
  final int worldEntryCount;

  /// 副本装配缺口：缺启用的人设／聊天记录／世界书节点等，供界面提示。
  final List<String> warnings;
}

/// 酒馆预设本地仓库。原始 JSON 是持久真相源，运行时模型由统一解析器重建。
class SillyTavernPresetStore implements TavernCompatibilityPort {
  // 同一进程不同仓库实例也串行写，防止连续点开关相互覆盖。
  // 串行链按 Zone 隔离：在已被销毁的 zone（如测试 fake-async）里注册的
  // 续接不会再执行，共用一条链会让后续所有写入永久排队。
  static final Expando<Future<void>> _writes = Expando<Future<void>>();
  Future<T> _serialized<T>(Future<T> Function() work) async {
    final zone = Zone.current;
    final previous = _writes[zone];
    final done = Completer<void>();
    _writes[zone] = done.future;
    try {
      if (previous != null) await previous;
      return await work();
    } finally {
      if (identical(_writes[zone], done.future)) _writes[zone] = null;
      done.complete();
    }
  }

  static const String _logTag = 'SillyTavernPresetStore';
  static const String _directoryName = 'aicove/sillytavern_presets';

  SillyTavernPresetStore({
    SillyTavernPresetParser parser = const SillyTavernPresetParser(),
    PresetDocumentsDirectoryResolver? documentsDirectoryResolver,
  }) : _parser = parser,
       _documentsDirectoryResolver =
           documentsDirectoryResolver ?? getApplicationDocumentsDirectory;

  final SillyTavernPresetParser _parser;
  final PresetDocumentsDirectoryResolver _documentsDirectoryResolver;

  SillyTavernPreset previewSource(
    String source, {
    required String sourceFileName,
  }) => _parser.parseSource(source, sourceFileName: sourceFileName);

  Future<SillyTavernPreset> importSource(
    String source, {
    required String sourceFileName,
    bool regexAuthorized = false,
  }) => _serialized(
    () => _importSource(
      source,
      sourceFileName: sourceFileName,
      regexAuthorized: regexAuthorized,
    ),
  );

  Future<SillyTavernPreset> _importSource(
    String source, {
    required String sourceFileName,
    required bool regexAuthorized,
  }) async {
    final preview = previewSource(source, sourceFileName: sourceFileName);
    final preset = _parser.parseMap(
      preview.rawPreset,
      sourceFileName: sourceFileName,
      storedId: preview.id,
      storedName: preview.name,
      importedAt: preview.importedAt,
      regexAuthorized: regexAuthorized,
    );
    final directory = await _ensureDirectory();
    final target = File('${directory.path}/${preset.id}.json');
    if (await target.exists()) {
      final existing = await get(preset.id);
      if (existing != null) {
        if (existing.regexAuthorized != regexAuthorized) {
          await _setRegexAuthorization(preset.id, regexAuthorized);
          return (await get(preset.id)) ?? preset;
        }
        return existing;
      }
      final corruptBackup = File(
        '${target.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}',
      );
      await target.rename(corruptBackup.path);
    }

    await _writePreset(target, preset, regexAuthorized: regexAuthorized);
    return preset;
  }

  Future<bool> setRegexAuthorization(String id, bool authorized) =>
      _serialized(() => _setRegexAuthorization(id, authorized));

  Future<bool> _setRegexAuthorization(String id, bool authorized) async {
    final normalizedId = id.trim();
    if (!RegExp(r'^st_preset_[a-f0-9]{24}$').hasMatch(normalizedId)) {
      return false;
    }
    final directory = await _directory();
    final file = File('${directory.path}/$normalizedId.json');
    if (!await file.exists()) return false;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return false;
      final envelope = Map<String, dynamic>.from(decoded);
      envelope['schemaVersion'] = 2;
      envelope['regexAuthorized'] = authorized;
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(jsonEncode(envelope), flush: true);
      await cloudLocalWrite(() => temp.rename(file.path));
      return true;
    } catch (error) {
      AppLogger.warning(
        _logTag,
        '更新酒馆预设 regex 授权失败',
        metadata: <String, dynamic>{
          'presetId': normalizedId,
          'errorType': error.runtimeType.toString(),
        },
      );
      return false;
    }
  }

  /// 删除一套预设文件；同时清掉指向它的默认选择。角色绑定由调用方先行拦截。
  Future<void> deletePreset(String id) => _serialized(() async {
    final normalizedId = id.trim();
    if (!RegExp(r'^st_preset_[a-f0-9]{24}$').hasMatch(normalizedId)) {
      throw StateError('预设编号无效');
    }
    final directory = await _directory();
    final file = File('${directory.path}/$normalizedId.json');
    final settingsFile = File('${directory.path}/plugin_settings.json');
    await cloudLocalWrite(() async {
      if (await settingsFile.exists()) {
        final data = jsonDecode(await settingsFile.readAsString());
        if (data is Map && data['defaultPresetId'] == normalizedId) {
          final temp = File('${settingsFile.path}.tmp');
          await temp.writeAsString(
            jsonEncode(const TavernPluginSettings().toJson()),
            flush: true,
          );
          await temp.rename(settingsFile.path);
        }
      }
      if (await file.exists()) await file.delete();
    });
  });

  Future<SillyTavernPreset?> get(String id) async {
    final normalizedId = id.trim();
    if (!RegExp(r'^st_preset_[a-f0-9]{24}$').hasMatch(normalizedId)) {
      return null;
    }
    final directory = await _directory();
    final file = File('${directory.path}/$normalizedId.json');
    if (!await file.exists()) return null;
    try {
      return await _readFile(file);
    } catch (error) {
      AppLogger.warning(
        _logTag,
        '读取酒馆预设失败',
        metadata: {
          'presetId': normalizedId,
          'errorType': error.runtimeType.toString(),
        },
      );
      return null;
    }
  }

  Future<List<SillyTavernPreset>> list() async {
    final directory = await _directory();
    if (!await directory.exists()) return const [];
    final files = await directory
        .list()
        .where(
          (entity) =>
              entity is File &&
              RegExp(
                r'^st_preset_[a-f0-9]{24}\.json$',
              ).hasMatch(entity.uri.pathSegments.last),
        )
        .cast<File>()
        .toList();
    final presets = <SillyTavernPreset>[];
    for (final file in files) {
      try {
        presets.add(await _readFile(file));
      } catch (error) {
        AppLogger.warning(
          _logTag,
          '已跳过损坏的酒馆预设文件',
          metadata: {
            'fileName': file.uri.pathSegments.last,
            'errorType': error.runtimeType.toString(),
          },
        );
      }
    }
    presets.sort((a, b) => b.importedAt.compareTo(a.importedAt));
    return List.unmodifiable(presets);
  }

  Future<SillyTavernPreset> _readFile(File file) async {
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) {
      throw const FormatException('Preset envelope must be an object');
    }
    final envelope = Map<String, dynamic>.from(decoded);
    final expectedId = file.uri.pathSegments.last.replaceFirst(
      RegExp(r'\.json$'),
      '',
    );
    if (envelope['id'] != expectedId) {
      throw const FormatException('预设信封与文件ID不一致');
    }
    final rawPreset = envelope['rawPreset'];
    if (rawPreset is! Map) {
      throw const FormatException('Missing rawPreset');
    }
    return _parser.parseMap(
      Map<String, dynamic>.from(rawPreset),
      sourceFileName: envelope['sourceFileName']?.toString() ?? 'preset.json',
      storedId: envelope['id']?.toString(),
      storedName: envelope['name']?.toString(),
      importedAt: DateTime.tryParse(envelope['importedAt']?.toString() ?? ''),
      regexAuthorized: envelope['regexAuthorized'] == true,
      compatibilityData: Map<String, dynamic>.from(
        envelope['compatibilityData'] as Map? ?? const {},
      ),
    );
  }

  Future<void> _writePreset(
    File target,
    SillyTavernPreset preset, {
    required bool regexAuthorized,
  }) async {
    final envelope = <String, dynamic>{
      'schemaVersion': 2,
      'id': preset.id,
      'name': preset.name,
      'sourceFileName': preset.sourceFileName,
      'importedAt': preset.importedAt.toIso8601String(),
      'regexAuthorized': regexAuthorized,
      'rawPreset': preset.rawPreset,
      'compatibilityData': preset.compatibilityData,
    };
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(jsonEncode(envelope), flush: true);
    await cloudLocalWrite(() => temp.rename(target.path));
  }

  Future<void> _mutate(
    String id,
    void Function(Map<String, dynamic> data, SillyTavernPreset preset) change,
  ) => _serialized(() async {
    final preset = await get(id);
    if (preset == null) throw StateError('酒馆预设不存在或损坏，请重新绑定');
    final data = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(preset.compatibilityData)) as Map,
    );
    change(data, preset);
    if (utf8.encode(jsonEncode(data)).length > 16 * 1024 * 1024) {
      throw const FormatException('此组合资源超过 16 MB，请拆分预设');
    }
    final updated = _parser.parseMap(
      preset.rawPreset,
      sourceFileName: preset.sourceFileName,
      storedId: preset.id,
      storedName: preset.name,
      importedAt: preset.importedAt,
      regexAuthorized: preset.regexAuthorized,
      compatibilityData: data,
    );
    final directory = await _ensureDirectory();
    await _writePreset(
      File('${directory.path}/${preset.id}.json'),
      updated,
      regexAuthorized: preset.regexAuthorized,
    );
  });

  @override
  Future<void> setPromptEnabled(
    String presetId,
    String promptId,
    bool enabled,
  ) => _mutate(presetId, (data, preset) {
    if (!preset.selectedOrder.entries.any((e) => e.identifier == promptId)) {
      throw StateError('提示词条目不存在');
    }
    (data.putIfAbsent('promptEnabled', () => <String, dynamic>{})
            as Map)[promptId] =
        enabled;
  });

  @override
  Future<void> setRegexEnabled(
    String presetId,
    String scriptId,
    bool enabled,
  ) => _mutate(presetId, (data, preset) {
    if (!preset.regexScripts.any((s) => s.id == scriptId)) {
      throw StateError('正则条目不存在');
    }
    (data.putIfAbsent('regexEnabled', () => <String, dynamic>{})
            as Map)[scriptId] =
        enabled;
  });

  @override
  Future<void> setUserNameMacroEnabled(String presetId, bool enabled) =>
      _mutate(presetId, (data, _) {
        if (enabled) {
          data.remove(presetUserNameMacroKey);
        } else {
          data[presetUserNameMacroKey] = false;
        }
      });

  @override
  Future<void> setTagPresentation(
    String presetId,
    String tagName,
    TagPresentation? presentation,
  ) => _mutate(presetId, (data, _) {
    final name = tagName.trim().toLowerCase();
    if (name.isEmpty) throw StateError('标签名为空');
    final overrides =
        data.putIfAbsent(
              presetTagDisplayOverridesKey,
              () => <String, dynamic>{},
            )
            as Map;
    if (presentation == null) {
      overrides.remove(name);
    } else {
      overrides[name] = presentation.name;
    }
  });

  dynamic _decodeResource(String source) {
    if (utf8.encode(source).length > SillyTavernPresetParser.maxSourceBytes) {
      throw const FormatException('资源超过 2 MB，已拒绝导入');
    }
    return jsonDecode(source);
  }

  /// 角色专用组合的复制来源：显式绑定→默认预设→内置基础上下文。
  /// 显式绑定缺失或损坏时报错，不回退（ADR0010）。
  Future<SillyTavernPreset> resolveCardPresetBase(String? explicitBaseId) async {
    final settings = await loadPluginSettings();
    final baseId = explicitBaseId?.trim().isNotEmpty == true
        ? explicitBaseId!.trim()
        : settings.defaultPresetId;
    if (baseId == null) {
      return previewSource(
        kBasicContextPresetSource,
        sourceFileName: '基础上下文.json',
      );
    }
    final found = await get(baseId);
    if (found == null) throw StateError('绑定的酒馆预设不存在或损坏，请重新选择');
    return found;
  }

  /// 以 [resolveCardPresetBase] 的结果为底建立角色专用组合副本，
  /// 并把卡内正则与世界书一次写入。底预设本身不被修改。
  /// [regexAuthorized] 为 null 时沿用底预设的授权（基础上下文为未授权）。
  Future<CardPresetImportResult> createCardPreset({
    required String? explicitBaseId,
    required String name,
    required List<Map<String, dynamic>> regexScripts,
    required Map<String, dynamic>? characterBook,
    bool? regexAuthorized,
  }) => _serialized(() async {
    final base = await resolveCardPresetBase(explicitBaseId);
    final fromTemplate = !(await _exists(base.id));
    final authorized = regexAuthorized ?? (!fromTemplate && base.regexAuthorized);

    final data = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(base.compatibilityData)) as Map,
    );
    final knownIds = {for (final script in base.regexScripts) script.id};
    final imported =
        data.putIfAbsent('importedRegex', () => <dynamic>[]) as List;
    var added = 0;
    var skipped = 0;
    for (final script in regexScripts) {
      final find = script['findRegex'];
      final rawId = script['id']?.toString().trim() ?? '';
      // 无 ID 时与解析器同样按内容哈希生成，避免误把不同规则当成同一条。
      final id = rawId.isNotEmpty
          ? rawId
          : 'regex_${sha256.convert(utf8.encode(jsonEncode(script))).toString().substring(0, 24)}';
      if (find is! String || find.isEmpty || !knownIds.add(id)) {
        skipped++;
        continue;
      }
      imported.add(script);
      added++;
    }
    if (imported.length > 1000) throw const FormatException('正则超过 1000 条，已拒绝导入');
    if (imported.isEmpty) data.remove('importedRegex');

    var worldEntryCount = 0;
    if (characterBook != null) {
      final source = <String, dynamic>{'character_book': characterBook};
      final fileName = '$name.json';
      final book = TavernWorldBook.parse(source, fileName);
      worldEntryCount = book.entries.length;
      final books = data.putIfAbsent('worldBooks', () => <dynamic>[]) as List;
      if (books.length >= 32) throw const FormatException('每套预设最多 32 本世界书');
      books.add({
        'id': book.id,
        'fileName': fileName,
        'source': source,
        'enabled': true,
        'entryEnabled': <String, dynamic>{},
      });
    }
    if (utf8.encode(jsonEncode(data)).length > 16 * 1024 * 1024) {
      throw const FormatException('此组合资源超过 16 MB，请拆分预设');
    }
    final resourceBytes = utf8.encode(
      jsonEncode({'r': regexScripts, 'b': characterBook}),
    ).length;
    if (resourceBytes > SillyTavernPresetParser.maxSourceBytes) {
      throw const FormatException('卡内资源超过 2 MB，已拒绝导入');
    }

    final now = DateTime.now();
    final seed =
        '${base.id}|$name|${now.microsecondsSinceEpoch}|${Random.secure().nextInt(1 << 32)}';
    final id =
        'st_preset_${sha256.convert(utf8.encode(seed)).toString().substring(0, 24)}';
    final preset = _parser.parseMap(
      base.rawPreset,
      sourceFileName: base.sourceFileName,
      storedId: id,
      storedName: name,
      importedAt: now,
      regexAuthorized: authorized,
      compatibilityData: data,
    );
    final directory = await _ensureDirectory();
    await _writePreset(
      File('${directory.path}/$id.json'),
      preset,
      regexAuthorized: authorized,
    );
    return CardPresetImportResult(
      preset: preset,
      baseName: fromTemplate ? null : base.name,
      addedRegexCount: added,
      skippedRegexCount: skipped,
      worldEntryCount: worldEntryCount,
      warnings: _cardPresetWarnings(preset, hasWorldBook: characterBook != null),
    );
  });

  @override
  Future<void> importRegex(String presetId, String source) async {
    final decoded = _decodeResource(source);
    final scripts = decoded is List
        ? decoded
        : decoded is Map
        ? decoded['regex_scripts'] ??
              (decoded['findRegex'] != null ? [decoded] : null)
        : null;
    if (scripts is! List ||
        scripts.isEmpty ||
        scripts.length > 1000 ||
        scripts.any(
          (s) =>
              s is! Map ||
              s['findRegex'] is! String ||
              (s['findRegex'] as String).isEmpty,
        )) {
      throw const FormatException('请选择正则脚本对象、数组或 regex_scripts JSON');
    }
    await _mutate(presetId, (data, preset) {
      final imported =
          data.putIfAbsent('importedRegex', () => <dynamic>[]) as List;
      for (final script in scripts) {
        if (!imported.any((s) => jsonEncode(s) == jsonEncode(script))) {
          imported.add(script);
        }
      }
    });
    // 导入不是授权；首次运行必须由用户明确开启授权开关。
  }

  @override
  Future<void> importWorldBook(
    String presetId,
    String source,
    String fileName,
  ) async {
    final decoded = _decodeResource(source);
    if (decoded is! Map) throw const FormatException('世界书 JSON 必须是对象');
    final book = TavernWorldBook.parse(
      Map<String, dynamic>.from(decoded),
      fileName,
    );
    await _mutate(presetId, (data, preset) {
      final books = data.putIfAbsent('worldBooks', () => <dynamic>[]) as List;
      if (books.any((b) => b['id'] == book.id)) return;
      if (books.length >= 32) throw const FormatException('每套预设最多 32 本世界书');
      books.add({
        'id': book.id,
        'fileName': fileName,
        'source': decoded,
        'enabled': true,
        'entryEnabled': <String, dynamic>{},
      });
    });
  }

  @override
  Future<void> setWorldBookEnabled(
    String presetId,
    String bookId,
    bool enabled,
  ) => _mutate(presetId, (data, preset) {
    final books = data['worldBooks'] as List? ?? const [];
    final book = books.where((b) => b['id'] == bookId).firstOrNull;
    if (book == null) throw StateError('世界书不存在');
    book['enabled'] = enabled;
  });

  @override
  Future<void> setWorldEntryEnabled(
    String presetId,
    String bookId,
    String entryId,
    bool enabled,
  ) => _mutate(presetId, (data, preset) {
    final parsed = preset.worldBooks.where((b) => b.id == bookId).firstOrNull;
    if (parsed == null || !parsed.entries.any((e) => e.id == entryId)) {
      throw StateError('世界书条目不存在');
    }
    final book =
        (data['worldBooks'] as List).firstWhere((b) => b['id'] == bookId)
            as Map;
    (book.putIfAbsent('entryEnabled', () => <String, dynamic>{})
            as Map)[entryId] =
        enabled;
  });

  @override
  Future<TavernPluginSettings> loadPluginSettings() async {
    final directory = await _directory();
    final file = File('${directory.path}/plugin_settings.json');
    if (!await file.exists()) return const TavernPluginSettings();
    final data = jsonDecode(await file.readAsString());
    if (data is! Map ||
        (data['defaultPresetId'] != null &&
            data['defaultPresetId'] is! String)) {
      throw const FormatException('酒馆插件配置损坏，请在插件页重新保存');
    }
    // 全局开关已移除，常开；是否生效取决于角色绑定或默认预设
    return TavernPluginSettings(
      enabled: true,
      defaultPresetId: data['defaultPresetId'] as String?,
    );
  }

  @override
  Future<void> savePluginSettings(TavernPluginSettings settings) =>
      _serialized(() async {
        // 读取端恒为启用，坏引用一旦写入就会在每次请求时抛错，必须无条件拦截
        if (settings.defaultPresetId != null &&
            await get(settings.defaultPresetId!) == null) {
          throw StateError('默认预设不存在或已损坏');
        }
        final directory = await _ensureDirectory();
        final target = File('${directory.path}/plugin_settings.json');
        final temp = File('${target.path}.tmp');
        await temp.writeAsString(jsonEncode(settings.toJson()), flush: true);
        await cloudLocalWrite(() => temp.rename(target.path));
      });

  @override
  Future<SillyTavernPreset?> resolvePreset(String? explicitId) =>
      _serialized(() async {
        final settings = await loadPluginSettings();
        if (!settings.enabled) return null;
        final id = explicitId?.trim().isNotEmpty == true
            ? explicitId!.trim()
            : settings.defaultPresetId;
        if (id == null) return null;
        final preset = await get(id);
        if (preset == null) throw StateError('绑定的酒馆预设不存在或损坏，请在角色或插件设置中重新选择');
        return preset;
      });

  static List<String> _cardPresetWarnings(
    SillyTavernPreset preset, {
    required bool hasWorldBook,
  }) {
    bool enabled(String id) => preset.selectedOrder.entries.any(
      (entry) => entry.identifier == id && entry.enabled,
    );
    return [
      if (!enabled('charDescription')) '预设未启用「角色定义」节点，人设可能不会发给模型',
      if (!enabled('chatHistory')) '预设未启用「聊天记录」节点，开场白和聊天历史不会发给模型',
      if (hasWorldBook &&
          !enabled('worldInfoBefore') &&
          !enabled('worldInfoAfter'))
        '预设未启用世界书节点，只有按深度注入的条目会生效',
    ];
  }

  Future<bool> _exists(String id) async =>
      File('${(await _directory()).path}/$id.json').exists();

  Future<Directory> _directory() async {
    final root = await _documentsDirectoryResolver();
    return Directory('${root.path}/$_directoryName');
  }

  Future<Directory> _ensureDirectory() async {
    final directory = await _directory();
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }
}
