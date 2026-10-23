import '../../../core/utils/markdown_fence.dart';
import 'ui_block.dart';
import 'ui_block_catalog.dart';
import 'ui_expression.dart';
import 'ui_state_context.dart';

/// Validation of what the user changed in a block against the block itself
/// (ADR0091). Saved state is untrusted: the message may have been edited
/// since, or the storage changed. The screen and `<ui_state>` both read
/// state through [uiCleanSavedState], so the model is told what the user
/// sees.

/// Whether a choice set offers 「其他」; on unless the block or the item
/// says `"other": false`.
bool uiOffersOther(Object? itemFlag, Object? blockFlag) => itemFlag != false && blockFlag != false;

/// Words that mark a secret. A heuristic, not a guarantee: it keeps the
/// obvious cases (Key, password, token) out of chat text and <ui_state>.
final _secretWords = RegExp(
  r'api[ _-]?key|access[ _-]?key|secret|token|password|passwd|密钥|密码|口令|令牌|私钥|\bkey\b',
  caseSensitive: false,
);

bool uiSecretWords(Iterable<Object?> words) => words.any((w) => w is String && _secretWords.hasMatch(w));

/// Whether a field takes free text that looks like a secret. Choice and
/// number fields never do (a choice field's 「其他」 is withheld instead,
/// see [uiFieldOffersOther]; a number field keeps only numbers).
bool uiFieldIsSecret({required String? type, required Iterable<Object?> words}) {
  if (const {'select', 'multiselect', 'number'}.contains(type)) return false;
  return type == 'password' || uiSecretWords(words);
}

Map<String, Object?>? _map(Object? value) =>
    value is Map ? {for (final e in value.entries) '${e.key}': e.value} : null;

List<Object?> _list(Object? value) => value is List ? value : const [];

int? _int(Object? value) => value is num && value.isFinite && value == value.truncate() ? value.toInt() : null;

String _fieldType(Map<String, Object?> field) => uiStringify(field['type']);

List<Object?> _fieldWords(Map<String, Object?> field) => [field['key'], field['label'], field['placeholder']];

/// Form fields as the form shows them (at most 8, each with a key).
List<Map<String, Object?>> uiFormFields(UiNode node) => [
      for (final raw in node.list('fields').take(8))
        if (_map(raw) case final field? when uiStringify(field['key']).isNotEmpty) field,
    ];

bool uiFormFieldIsSecret(Map<String, Object?> field) =>
    uiFieldIsSecret(type: _fieldType(field), words: _fieldWords(field));

/// 「其他」 on a choice field: not on fields whose words look secret, where
/// it would be a free-text box for the secret.
bool uiFieldOffersOther(Map<String, Object?> field, UiNode form) =>
    const {'select', 'multiselect'}.contains(_fieldType(field)) &&
    !uiSecretWords(_fieldWords(field)) &&
    uiOffersOther(field['other'], form.props['other']);

/// Quiz questions as the quiz shows them: entries that are objects.
List<Map<String, Object?>> uiQuizQuestions(UiNode node) => [for (final q in node.list('questions')) ?_map(q)];

/// State names bound by a panel `input` that the secret rule hides: their
/// values are never restored or reported. Judged as the screen judges them,
/// on the effective binding (including `"value": "{k}"`) and on label,
/// placeholder and type filled in from state, for every input, hidden ones
/// included. An input whose label, placeholder or type fails to evaluate
/// counts as secret: it cannot be shown to be safe.
Set<String> uiSecretBindings(UiProgram program, Map<String, Object?> state) => {
      for (final input in program.resolveEach('input', state, const {'label', 'placeholder', 'type'}))
        if (input.bind != null &&
            (input.failed ||
                uiFieldIsSecret(
                  type: input.props['type'] == null ? null : uiStringify(input.props['type']),
                  words: [input.bind, uiStringify(input.props['label']), uiStringify(input.props['placeholder'])],
                )))
          input.bind!,
    };

/// Decision-tree nodes by id.
Map<String, Map<String, Object?>> uiTreeNodes(UiNode node) => {
      for (final raw in node.list('nodes'))
        if (_map(raw) case final n? when uiStringify(n['id']).isNotEmpty) uiStringify(n['id']): n,
    };

String? uiTreeStart(UiNode node) {
  final nodes = uiTreeNodes(node);
  final start = node.text('start');
  if (start != null && nodes.containsKey(start)) return start;
  return nodes.keys.firstOrNull;
}

/// The longest start of [ids] that walks from the start node through
/// options that really link each step to the next; at least the start.
List<String> uiTreePath(UiNode node, List<Object?> ids) {
  final nodes = uiTreeNodes(node);
  final start = uiTreeStart(node);
  if (start == null) return const [];
  final path = [start];
  if (ids.isEmpty || uiStringify(ids.first) != start) return path;
  for (final raw in ids.skip(1)) {
    final id = uiStringify(raw);
    final linked = _list(nodes[path.last]!['options']).any((o) => uiStringify(_map(o)?['next']) == id);
    if (!linked || !nodes.containsKey(id)) break;
    path.add(id);
  }
  return path;
}

/// [saved] reduced to what [block] accepts: unknown names, wrong types and
/// out-of-range picks are dropped. Empty when nothing valid is left.
Map<String, Object?> uiCleanSavedState(UiBlock block, Map<String, Object?> saved) {
  if (kUiActionComponents.contains(block.component)) return uiCleanActionState(saved);
  final program = UiProgram.compile(block);
  if (!kUiCatalogNames.contains(block.component)) {
    final restored = uiRestoreState(program.initialState, saved);
    final hidden = uiSecretBindings(program, restored);
    return uiStateDiff(program.initialState, restored)..removeWhere((name, _) => hidden.contains(name));
  }
  final node = program.resolve(const {});
  switch (block.component) {
    case 'checklist':
      final count = node.list('items').length;
      final done = {
        for (final i in _list(saved['done']))
          if (_int(i) case final i? when i >= 0 && i < count) i,
      }.toList()
        ..sort();
      return done.isEmpty ? const {} : {'done': done};
    case 'steps':
      final step = _int(saved['step']);
      final count = node.list('items').length;
      return step != null && step > 0 && step < count ? {'step': step} : const {};
    case 'decision-tree':
      final path = uiTreePath(node, _list(saved['path']));
      return path.length > 1 ? {'path': path} : const {};
    case 'quiz':
      final questions = uiQuizQuestions(node);
      final answers = <String, Object?>{
        for (final e in (_map(saved['answers']) ?? const {}).entries)
          if ((int.tryParse(e.key), _int(e.value)) case (final q?, final a?)
              when q >= 0 && q < questions.length && a >= 0 && a < _list(questions[q]['options']).length)
            '$q': a,
      };
      return answers.isEmpty ? const {} : {'answers': answers};
    case 'form':
      final values = <String, Object?>{};
      final others = <String, Object?>{};
      final savedValues = _map(saved['values']) ?? const {};
      final savedOthers = _map(saved['other']) ?? const {};
      for (final field in uiFormFields(node)) {
        if (uiFormFieldIsSecret(field)) continue;
        final key = uiStringify(field['key']);
        final value = savedValues[key];
        final options = [for (final o in uiOptions(field['options'])) o.value];
        final ok = switch (_fieldType(field)) {
          'select' => options.any((o) => uiValuesEqual(o, value)),
          'multiselect' => value is List && value.every((v) => options.any((o) => uiValuesEqual(o, v))),
          'number' => value is num && value.isFinite,
          _ => value is String,
        };
        if (savedValues.containsKey(key) && ok) values[key] = value;
        if (uiFieldOffersOther(field, node) && savedOthers[key] is String) others[key] = savedOthers[key];
      }
      return {
        if (values.isNotEmpty) 'values': values,
        if (others.isNotEmpty) 'other': others,
      };
  }
  return const {};
}

const int kUiActionDidMax = 5;
const int kUiActionDidMaxRunes = 120;

const int kUiActionPickedMaxRunes = 256;

/// State of an action panel (ADR0094): the row the user picked (`picked`
/// id, `pickedName`) and what they did through it (`did`, newest last).
/// The list itself is read live, so nothing else is kept. An id is kept
/// whole or not at all: a cut one could name another row.
Map<String, Object?> uiCleanActionState(Map<String, Object?> saved) {
  String? text(Object? value, int max) {
    if (value is! String || value.trim().isEmpty) return null;
    final runes = value.trim().runes;
    return runes.length <= max ? value.trim() : String.fromCharCodes(runes.take(max));
  }

  final rawPicked = saved['picked'];
  final picked = rawPicked is String &&
          rawPicked.trim().isNotEmpty &&
          rawPicked.trim().runes.length <= kUiActionPickedMaxRunes
      ? rawPicked.trim()
      : null;
  final name = picked == null ? null : text(saved['pickedName'], 40);
  final did = [for (final item in _list(saved['did'])) ?text(item, kUiActionDidMaxRunes)];
  return {
    'picked': ?picked,
    'pickedName': ?name,
    if (did.isNotEmpty) 'did': did.length <= kUiActionDidMax ? did : did.sublist(did.length - kUiActionDidMax),
  };
}

/// The saved blocks of [messages] (raw message id and text, oldest first),
/// each cleaned against the block it belongs to. Saved state whose block is
/// no longer in its message is left out.
Map<String, UiSavedBlock> uiSavedBlocksInMessages(
  Map<String, UiSavedBlock> saved,
  List<({String id, String text})> messages,
) {
  if (saved.isEmpty) return const {};
  final result = <String, UiSavedBlock>{};
  for (final message in messages) {
    for (final fence in scanFencedCodeBlocks(message.text)) {
      if (!fence.closed || !uiIsBlockLanguage(fence.language)) continue;
      final block = UiBlock.parse(fence.code).block;
      if (block == null) continue;
      final key = uiSavedBlockKey(message.id, block.key);
      final entry = saved[key];
      if (entry == null) continue;
      final state = uiCleanSavedState(block, entry.state);
      if (state.isNotEmpty) result[key] = UiSavedBlock(state: state, title: entry.title);
    }
  }
  return result;
}
