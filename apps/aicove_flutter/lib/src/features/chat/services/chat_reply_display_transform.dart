import '../../agent_context/domain/silly_tavern_preset.dart';
import '../../agent_context/domain/silly_tavern_regex_processor.dart';
import '../../content_tags/domain/content_tag_registry.dart';
import '../../content_tags/domain/content_tag_scanner.dart';
import '../../content_tags/domain/content_tag_spec.dart';
import '../../plugins/plugin_content_tags.dart';
import '../../plugins/domain/plugin.dart' show PluginProcessResult;
import '../../agent_plugins/plugin_response.dart';

const _assistantDrawImageReviewPrefix = '__AICOVE_DRAW_IMAGE_REVIEW__';

/// Expand the current reply's character table only inside image visual prompts.
/// Dialogue after `Text:` stays literal until the next section marker.
({Map<String, String> identities, Map<String, String> outfits})
_comicPlanVariables(String text) {
  final identityParts = <String, List<String>>{};
  final initialOutfits = <String, String>{};
  final currentOutfits = <String, String>{};
  for (final plan in RegExp(
    r'<comic_plan\b[^>]*>([\s\S]*?)</comic_plan\s*>',
    caseSensitive: false,
  ).allMatches(text)) {
    int? tableIndent;
    String? character;
    for (final line in plan[1]!.split(RegExp(r'\r?\n'))) {
      final header = RegExp(r'^(\s*)(?:-\s*)?角色母表\s*[:：]').firstMatch(line);
      if (header != null) {
        tableIndent = header[1]!.length;
        character = null;
        continue;
      }
      if (tableIndent == null || line.trim().isEmpty) continue;
      final entry = RegExp(r'^\s*-\s*(C\d+)\s*[:：]').firstMatch(line);
      if (entry != null) {
        character = entry[1];
        identityParts[character!] = <String>[];
        continue;
      }
      if (line.length - line.trimLeft().length <= tableIndent) {
        tableIndent = null;
        character = null;
        continue;
      }
      if (character == null) continue;
      final field = RegExp(
        r'^\s*-\s*(固定身份词|固定外貌词|初始服装词|当前服装词)\s*[:：]\s*(.*?)\s*$',
      ).firstMatch(line);
      if (field == null || field[2]!.isEmpty) continue;
      final key = field[1]!;
      final value = field[2]!;
      if (key == '固定身份词' || key == '固定外貌词') {
        final parts = identityParts.putIfAbsent(character, () => <String>[]);
        if (!parts.contains(value)) parts.add(value);
      } else if (key == '当前服装词') {
        currentOutfits[character] = value;
      } else {
        initialOutfits[character] = value;
      }
    }
  }
  final identities = <String, String>{
    for (final entry in identityParts.entries)
      if (entry.value.isNotEmpty) entry.key: entry.value.join(', '),
  };
  final outfits = <String, String>{...initialOutfits, ...currentOutfits};
  return (identities: identities, outfits: outfits);
}

String _expandComicPrompt(
  String prompt,
  Map<String, String> identities,
  Map<String, String> outfits,
) {
  if (identities.isEmpty && outfits.isEmpty) return prompt;
  final variable = RegExp(r'@(C\d+)(?:_(id|identity|outfit|costume))?(?![\w])');
  final marker = RegExp(r'^\s*@[a-z_]+\b', caseSensitive: false);
  var inDialogue = false;
  return prompt
      .split('\n')
      .map((line) {
        if (marker.hasMatch(line)) inDialogue = false;
        if (inDialogue) return line;
        final dialogue = RegExp(
          r'\bText\s*[:：]',
          caseSensitive: false,
        ).firstMatch(line);
        final end = dialogue?.start ?? line.length;
        final visual = line.substring(0, end).replaceAllMapped(variable, (
          match,
        ) {
          final values = match[2] == 'outfit' || match[2] == 'costume'
              ? outfits
              : identities;
          return values[match[1]] ?? match[0]!;
        });
        if (dialogue != null) inDialogue = true;
        return visual + line.substring(end);
      })
      .join('\n');
}

({Map<String, String> identities, Map<String, String> outfits})
_resolveComicPlanVariables(String text) {
  final visible = _comicPlanVariables(extractAssistantThinking(text).text);
  if (visible.identities.isNotEmpty || visible.outfits.isNotEmpty) {
    return visible;
  }
  return _comicPlanVariables(text);
}

/// Expand a tool prompt using this turn's texts, ordered oldest to newest.
/// Later definitions override earlier values; omitted values remain available.
String expandComicPlanVariablesInPrompt(
  String prompt, {
  required Iterable<String> contextTexts,
}) {
  final identities = <String, String>{};
  final outfits = <String, String>{};
  for (final text in contextTexts) {
    final extracted = extractAssistantThinking(text);
    for (final source in [extracted.reasoning, extracted.text]) {
      final variables = _comicPlanVariables(source);
      identities.addAll(variables.identities);
      outfits.addAll(variables.outfits);
    }
  }
  return _expandComicPrompt(prompt, identities, outfits);
}

String expandComicPlanCharacterVariables(String text) {
  final variables = _resolveComicPlanVariables(text);
  return text.replaceAllMapped(
    RegExp(r'(<image\b[^>]*>)([\s\S]*?)(</image\s*>)', caseSensitive: false),
    (image) =>
        '${image[1]}${_expandComicPrompt(image[2]!, variables.identities, variables.outfits)}${image[3]}',
  );
}

final _thinkingScanner = ContentTagScanner(
  ContentTagRegistry(const [
    StaticContentTagProvider(
      providerId: 'assistant-thinking',
      tagSpecs: [
        ContentTagSpec(name: 'think', ownerId: ContentTagSpec.builtinOwnerId),
      ],
    ),
  ]),
);

/// Inline thinking belongs to reasoning, never to the display regex input.
/// Native provider reasoning takes precedence over an inline duplicate.
({String text, String reasoning}) extractAssistantThinking(
  String text, {
  String reasoning = '',
}) {
  final visible = StringBuffer();
  final thoughts = <String>[];
  for (final segment in _thinkingScanner.scan(maskCode(text))) {
    switch (segment) {
      case ContentTagText():
        visible.write(text.substring(segment.start, segment.end));
      case ContentTagElement():
        final inner = unmaskCode(segment.inner).trim();
        if (inner.isNotEmpty) thoughts.add(inner);
      case ContentTagOrphanClose():
        break;
    }
  }
  return (
    text: visible.toString().trim(),
    reasoning: reasoning.trim().isNotEmpty
        ? reasoning.trim()
        : thoughts.join('\n\n'),
  );
}

/// Normalize transport-only markers before producing the display copy.
String normalizeAssistantReplyText(String text) {
  var cleaned = extractAssistantThinking(text).text;
  cleaned = cleaned.replaceAll(
    RegExp(r'\[(图片|image)\s*:\s*[^\]]*?\]', caseSensitive: false),
    '<image></image>',
  );
  cleaned = cleaned.replaceAll(
    RegExp(r'<image>\s*</image>', caseSensitive: false),
    '<image></image>',
  );
  cleaned = cleaned.replaceAll(
    RegExp(
      '${RegExp.escape(_assistantDrawImageReviewPrefix)}[^\\r\\n]*(?:\\r?\\n)?',
    ),
    '',
  );
  return cleaned.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}

/// Display regex may move or remove plugin elements, but cannot rewrite their
/// payload or duplicate a side effect by copying an element's placeholder.
Future<SillyTavernRegexApplyResult> applyAssistantDisplayRegex({
  required String text,
  required List<SillyTavernRegexScript> scripts,
  required bool authorized,
}) async {
  var prefix = '\uE000';
  while (text.contains(prefix)) {
    prefix += '\uE000';
  }
  final originals = <String, String>{};
  final protected = StringBuffer();
  for (final segment in firstPartyContentTagScanner.scan(text)) {
    if (segment is ContentTagText) {
      protected.write(segment.raw);
      continue;
    }
    // Every code unit is private-use, so ordinary word/number substitutions
    // cannot accidentally edit an element's identity.
    final index = originals.length
        .toRadixString(16)
        .codeUnits
        .map((unit) => String.fromCharCode(0xE100 + unit))
        .join();
    final token = '$prefix$index\uE001';
    originals[token] = segment.raw;
    protected.write(token);
  }
  final result = await const SillyTavernRegexProcessor().applyToDisplayText(
    text: protected.toString(),
    scripts: scripts,
    authorized: authorized,
  );
  final restored = <String>{};
  final displayText = originals.isEmpty
      ? result.text
      : result.text.replaceAllMapped(
          RegExp('${RegExp.escape(prefix)}[\uE100-\uE1FF]+\uE001'),
          (match) {
            final token = match.group(0)!;
            final original = originals[token];
            if (original == null) return token;
            return restored.add(token) ? original : '';
          },
        );
  return SillyTavernRegexApplyResult(
    text: displayText,
    warnings: result.warnings,
    traces: result.traces,
  );
}

/// The normalized semantic source, before any display-only transformation.
/// Request callers supply snapshots; cached/background callers supply live
/// regex and processor configuration when projecting this source.
class AssistantReplyDisplaySource {
  factory AssistantReplyDisplaySource(String text, {String reasoning = ''}) {
    final extracted = extractAssistantThinking(
      expandComicPlanCharacterVariables(text),
      reasoning: reasoning,
    );
    return AssistantReplyDisplaySource._(
      normalizeAssistantReplyText(extracted.text),
      extracted.reasoning,
    );
  }

  const AssistantReplyDisplaySource._(this.text, this.reasoning);
  final String text;
  final String reasoning;

  Future<AssistantReplyDisplayProjection> project({
    required List<SillyTavernRegexScript> scripts,
    required bool authorized,
  }) async => AssistantReplyDisplayProjection._(
    await applyAssistantDisplayRegex(
      text: text,
      scripts: scripts,
      authorized: authorized,
    ),
  );
}

/// Regex output and plugin output are distinct display stages; keeping the
/// stages separate lets the kernel trace and join them without flattening
/// tool rounds or running processors for intermediate tool snapshots.
class AssistantReplyDisplayProjection {
  const AssistantReplyDisplayProjection._(this.regexResult);
  final SillyTavernRegexApplyResult regexResult;

  Future<PluginProcessResult> process({
    required List<PluginResponseProcessor> processors,
    required String logTag,
    String failureMessage = '插件响应处理失败',
    bool skipEmpty = false,
  }) async => skipEmpty && regexResult.text.trim().isEmpty
      ? PluginProcessResult(processedText: '', events: const [])
      : runResponseProcessors(
          processors,
          regexResult.text,
          logTag: logTag,
          failureMessage: failureMessage,
        );
}
