import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../../../core/app_logger.dart';
import '../../../core/database/database.dart' as db;
import '../../../core/database/repositories/message_repository.dart';
import '../../chat/services/chat_message_projection_codec.dart';
import '../domain/conversation_state_port.dart';
import '../domain/mvu_engine.dart';

typedef MvuSourceResolver =
    Future<MvuSourceSnapshot?> Function(String conversationId);

/// `message_states` 的专用 Adapter（ADR0071，参数化 SQL，不走 Drift 表定义）。
///
/// 读链、校验缓存、重算与写回在同一事务内完成，并按会话加进程内锁；
/// 校验只读元数据列，整次读取只解码一份状态 JSON。
class SqliteConversationStateStore implements ConversationStatePort {
  SqliteConversationStateStore(
    this.database, {
    required this.resolveSources,
    required this.greetingMessageId,
    MvuEngine engine = const MvuEngine(),
    DateTime Function()? now,
  }) : _engine = engine,
       _now = now ?? DateTime.now;

  final db.AppDatabase database;
  final MvuSourceResolver resolveSources;
  final String Function(String conversationId) greetingMessageId;
  final MvuEngine _engine;
  final DateTime Function() _now;
  final Map<String, Future<void>> _locks = {};

  static const String kind = 'mvu';
  static const String initAnchor = '__init__';
  static const String _logTag = 'ConversationState';
  static const int _batch = 200;

  @override
  Future<ConversationStateView> read(
    String conversationId, {
    MvuSourceSnapshot? sources,
  }) async {
    final snapshot = sources ?? await resolveSources(conversationId);
    if (snapshot == null) return const ConversationStateView.inactive();
    return _locked(
      conversationId,
      () => database.transaction(() => _compute(conversationId, snapshot)),
    );
  }

  @override
  Future<void> refresh(String conversationId) async {
    try {
      await read(conversationId);
    } catch (error, stack) {
      AppLogger.warning(
        _logTag,
        '会话状态刷新失败，下次读取时重算',
        metadata: {'errorType': error.runtimeType.toString()},
      );
      AppLogger.debug(_logTag, '$error\n$stack');
    }
  }

  Future<T> _locked<T>(String id, Future<T> Function() body) async {
    final previous = _locks[id];
    final gate = Completer<void>();
    _locks[id] = gate.future;
    try {
      if (previous != null) await previous;
      return await body();
    } finally {
      gate.complete();
      if (identical(_locks[id], gate.future)) _locks.remove(id);
    }
  }

  Future<ConversationStateView> _compute(
    String conversationId,
    MvuSourceSnapshot snapshot,
  ) async {
    final chain = await MessageRepository(
      database,
    ).getSentAssistantChainStable(conversationId);
    final raws = [for (final message in chain) _rawText(message)];
    final greetingId = greetingMessageId(conversationId);
    final greetingIndex = chain.indexWhere((m) => m.id == greetingId);
    final greetingRaw = greetingIndex < 0 ? null : raws[greetingIndex];
    final expand = snapshot.expandMacros ?? (String text) => text;

    var baseline = await _row(conversationId, initAnchor);
    if (baseline == null &&
        snapshot.sources.isEmpty &&
        !_hasMvuMarkup(greetingRaw ?? '')) {
      // 卡片没有用 MVU：不建基线，不写任何行。
      return const ConversationStateView.inactive();
    }

    final sourcesFp = _hash(
      jsonEncode([
        for (final source in snapshot.sources)
          [source.name, expand(source.content)],
      ]),
    );
    final greetingFp = _hash(greetingRaw ?? '');
    final stored = baseline == null
        ? const <String, Object?>{}
        : _decodeMap(baseline.readNullable<String>('sources_json'));
    final failed = baseline?.read<String>('status') == 'init_failed';
    final needInit = baseline == null;
    final retry = failed && stored['sources'] != sourcesFp;
    final greetingChanged =
        baseline != null && stored['greeting'] != greetingFp;
    if (needInit || retry || greetingChanged) {
      final result = _engine.initialize(
        sources: snapshot.sources,
        greetingRaw: greetingRaw,
        expandMacros: expand,
      );
      final values = [
        conversationId,
        initAnchor,
        kind,
        null,
        sourcesFp,
        MvuEngine.version,
        result.ok ? 'ready' : 'init_failed',
        result.ok ? jsonEncode(result.state!.toJson()) : null,
        jsonEncode([
          if (result.failure != null) result.failure,
          ...result.diagnostics,
          if (greetingChanged) '开场白已变化，已按当前来源重新初始化',
        ]),
        jsonEncode({'sources': sourcesFp, 'greeting': greetingFp}),
        _now().millisecondsSinceEpoch,
      ];
      if (needInit) {
        // 并发首次初始化：先写入的保留。
        await database.customStatement(_insertIgnore, values);
      } else {
        await database.customStatement(_upsert, values);
        await database.customStatement(
          'DELETE FROM message_states WHERE conversation_id = ? AND kind = ? '
          'AND anchor_id != ?',
          [conversationId, kind, initAnchor],
        );
      }
      baseline = await _row(conversationId, initAnchor);
    }
    final baseDiagnostics = _decodeList(
      baseline!.read<String>('diagnostics_json'),
    );
    if (baseline.read<String>('status') == 'init_failed') {
      return ConversationStateView.inactive(diagnostics: baseDiagnostics);
    }

    final meta = await database
        .customSelect(
          'SELECT anchor_id, prev_anchor_id, raw_hash, engine_version '
          'FROM message_states WHERE conversation_id = ? AND kind = ? '
          'AND anchor_id != ?',
          variables: [
            Variable(conversationId),
            const Variable(kind),
            const Variable(initAnchor),
          ],
        )
        .get();
    final byAnchor = {
      for (final row in meta) row.read<String>('anchor_id'): row,
    };
    final hashes = [for (final raw in raws) _hash(raw)];
    var firstInvalid = -1;
    var prev = initAnchor;
    for (var i = 0; i < chain.length; i++) {
      final row = byAnchor[chain[i].id];
      if (row == null ||
          row.readNullable<String>('prev_anchor_id') != prev ||
          row.read<String>('raw_hash') != hashes[i] ||
          row.read<int>('engine_version') != MvuEngine.version) {
        firstInvalid = i;
        break;
      }
      prev = chain[i].id;
    }

    if (firstInvalid < 0) {
      final last = chain.isEmpty
          ? null
          : await _row(conversationId, chain.last.id);
      return ConversationStateView(
        active: true,
        mvu: await _stateAt(conversationId, chain, chain.length - 1, baseline),
        anchorMessageId: chain.isEmpty ? null : chain.last.id,
        status: last?.read<String>('status') ?? 'ready',
        diagnostics: [
          ...baseDiagnostics,
          if (last != null)
            ..._decodeList(last.read<String>('diagnostics_json')),
        ],
      );
    }

    var state = await _stateAt(
      conversationId,
      chain,
      firstInvalid - 1,
      baseline,
    );
    var status = 'ready';
    var diagnostics = const <String>[];
    for (var i = firstInvalid; i < chain.length; i++) {
      final step = _engine.apply(state, raws[i]);
      final changed =
          step.status != StateStepStatus.noOps &&
          step.status != StateStepStatus.parseError;
      await database.customStatement(_upsert, [
        conversationId,
        chain[i].id,
        kind,
        i == 0 ? initAnchor : chain[i - 1].id,
        hashes[i],
        MvuEngine.version,
        step.status.wire,
        // 状态没变时不重复存，读取时向前找最近一份。
        changed ? jsonEncode(step.state.toJson()) : null,
        jsonEncode(step.diagnostics),
        null,
        _now().millisecondsSinceEpoch,
      ]);
      state = step.state;
      status = step.status.wire;
      diagnostics = step.diagnostics;
    }
    return ConversationStateView(
      active: true,
      mvu: state,
      anchorMessageId: chain.last.id,
      status: status,
      diagnostics: [...baseDiagnostics, ...diagnostics],
    );
  }

  /// 链上第 [index] 条消息之后的状态；-1 表示基线。向前找最近一份存了数据的行。
  Future<MvuState> _stateAt(
    String conversationId,
    List<db.Message> chain,
    int index,
    QueryRow baseline,
  ) async {
    for (var end = index; end >= 0; end -= _batch) {
      final start = end - _batch + 1 < 0 ? 0 : end - _batch + 1;
      final ids = [for (var i = start; i <= end; i++) chain[i].id];
      final rows = await database
          .customSelect(
            'SELECT anchor_id, data_json FROM message_states '
            'WHERE conversation_id = ? AND kind = ? AND data_json IS NOT NULL '
            'AND anchor_id IN (${List.filled(ids.length, '?').join(',')})',
            variables: [
              Variable(conversationId),
              const Variable(kind),
              for (final id in ids) Variable(id),
            ],
          )
          .get();
      if (rows.isEmpty) continue;
      final found = {
        for (final row in rows)
          row.read<String>('anchor_id'): row.read<String>('data_json'),
      };
      for (var i = end; i >= start; i--) {
        final data = found[chain[i].id];
        if (data != null) return MvuState.fromJson(_decodeMap(data));
      }
    }
    return MvuState.fromJson(
      _decodeMap(baseline.readNullable<String>('data_json')),
    );
  }

  Future<QueryRow?> _row(String conversationId, String anchor) => database
      .customSelect(
        'SELECT * FROM message_states WHERE conversation_id = ? AND anchor_id = ? '
        'AND kind = ?',
        variables: [
          Variable(conversationId),
          Variable(anchor),
          const Variable(kind),
        ],
      )
      .getSingleOrNull();

  static String _rawText(db.Message message) {
    final payload = message.rawPayload;
    if (payload != null && payload.isNotEmpty) {
      try {
        final decoded = jsonDecode(payload);
        if (decoded is Map<String, dynamic>) {
          final raw = ChatMessageProjectionCodec.rawReplyText(decoded);
          if (raw != null) return raw;
        }
      } on FormatException {
        // 原始负载损坏时退回正文。
      }
    }
    return message.content;
  }

  static bool _hasMvuMarkup(String text) => RegExp(
    r'<\s*(?:initvar|updatevariable|variableupdate|json_?patch)\b',
    caseSensitive: false,
  ).hasMatch(text);

  static String _hash(String text) =>
      sha256.convert(utf8.encode(text)).toString().substring(0, 32);

  static Map<String, Object?> _decodeMap(String? text) {
    if (text == null || text.isEmpty) return const {};
    final decoded = jsonDecode(text);
    return decoded is Map<String, Object?> ? decoded : const {};
  }

  static List<String> _decodeList(String? text) {
    if (text == null || text.isEmpty) return const [];
    final decoded = jsonDecode(text);
    return decoded is List
        ? [for (final item in decoded) item.toString()]
        : const [];
  }

  static const _columns =
      '(conversation_id, anchor_id, kind, prev_anchor_id, raw_hash, engine_version, '
      'status, data_json, diagnostics_json, sources_json, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)';
  static const _insertIgnore = 'INSERT OR IGNORE INTO message_states $_columns';
  static const _upsert = 'INSERT OR REPLACE INTO message_states $_columns';
}
