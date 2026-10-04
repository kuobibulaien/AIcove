import '../../content_tags/domain/tag_presentation.dart';
import 'silly_tavern_preset.dart';

/// 映射来源，界面用于说明“为什么是这样”。
enum PresetTagSource { regex, prompt, builtin, user }

class PresetTagRule {
  const PresetTagRule({
    required this.name,
    required this.display,
    required this.title,
    required this.source,
  });

  /// 小写标签名（可为中文）。
  final String name;
  final TagPresentation display;

  /// 折叠气泡标题。
  final String title;
  final PresetTagSource source;

  PresetTagRule copyWith({TagPresentation? display, PresetTagSource? source}) =>
      PresetTagRule(
        name: name,
        display: display ?? this.display,
        title: title,
        source: source ?? this.source,
      );

  TagPresentationEntry get entry => TagPresentationEntry(display, title);
}

class PresetTagMapping {
  const PresetTagMapping({
    required this.rules,
    required this.supersededScriptIds,
    this.hiddenScriptIds = const {},
    this.candidates = const [],
  });

  static const empty = PresetTagMapping(rules: [], supersededScriptIds: {});

  /// 按标签名排序的映射。
  final List<PresetTagRule> rules;

  /// 提示词要求模型用来包裹输出、但看不出该如何呈现的标签：只在标签页
  /// 提示“待确认”，不自动生效。
  final List<String> candidates;

  /// 被界面组件接管、不再执行的显示美化正则 id：它们输出的 HTML 界面无法渲染。
  final Set<String> supersededScriptIds;

  /// [supersededScriptIds] 中只是把占位符换成网页、不用原文的规则：
  /// 显示时把匹配内容换成空，而不是露出占位符。
  final Set<String> hiddenScriptIds;

  /// 本轮显示用的呈现映射：内置常用名打底，预设推断与用户覆盖优先。
  /// 写入助手 rawPayload 作为显示快照。
  TagPresentationMap get presentationMap => {
        for (final rule in builtinPresetTagMapping.rules) rule.name: rule.entry,
        for (final rule in rules) rule.name: rule.entry,
      };

  /// 只执行未被接管的显示正则；占位网页规则改为替换成空。
  List<SillyTavernRegexScript> displayScripts(
    List<SillyTavernRegexScript> scripts,
  ) =>
      supersededScriptIds.isEmpty
          ? scripts
          : [
              for (final script in scripts)
                if (hiddenScriptIds.contains(script.id))
                  script.withReplacement('')
                else if (!supersededScriptIds.contains(script.id))
                  script,
            ];
}

/// 用户覆盖存放在 `SillyTavernPreset.compatibilityData` 的这个键下：
/// `{tagName: 'body' | 'fold' | 'options'}`。
const String presetTagDisplayOverridesKey = 'tagDisplay';

class _BuiltinTag {
  const _BuiltinTag(this.display, this.title);
  final TagPresentation display;
  final String title;
}

/// 常用标签名：模型或预设约定俗成的写法，不依赖某一份预设。
const Map<String, _BuiltinTag> _builtinTags = {
  'thinking': _BuiltinTag(TagPresentation.fold, '思考'),
  'think': _BuiltinTag(TagPresentation.fold, '思考'),
  'thought': _BuiltinTag(TagPresentation.fold, '思考'),
  'cot': _BuiltinTag(TagPresentation.fold, '思考'),
  'reasoning': _BuiltinTag(TagPresentation.fold, '思考'),
  '思考': _BuiltinTag(TagPresentation.fold, '思考'),
  '思维链': _BuiltinTag(TagPresentation.fold, '思考'),
  'details': _BuiltinTag(TagPresentation.fold, '详情'),
  'options': _BuiltinTag(TagPresentation.options, '选项'),
  'branches': _BuiltinTag(TagPresentation.options, '选项'),
  'choices': _BuiltinTag(TagPresentation.options, '选项'),
  '选项': _BuiltinTag(TagPresentation.options, '选项'),
  'zw': _BuiltinTag(TagPresentation.body, '正文'),
  '正文': _BuiltinTag(TagPresentation.body, '正文'),
  'content': _BuiltinTag(TagPresentation.body, '正文'),
  'maintext': _BuiltinTag(TagPresentation.body, '正文'),
};

/// 没有预设时（旧消息、未绑定预设）使用的内置映射。
final PresetTagMapping builtinPresetTagMapping = PresetTagMapping(
  rules: [
    for (final entry in _builtinTags.entries)
      PresetTagRule(
          name: entry.key,
          display: entry.value.display,
          title: entry.value.title,
          source: PresetTagSource.builtin,
        ),
  ],
  supersededScriptIds: const {},
);

/// HTML 结构名与插件自有标签不作为预设语义标签；`summary`、`details` 这类
/// 双用途名不在此列，由它在正则里的结构位置决定（ADR0048）。
const Set<String> _ignoredTagNames = {
  ...htmlStructureTagNames,
  'tts',
  'image',
  'option',
};

final RegExp _optionalGroupPattern = RegExp(r'\(\?:([^()|]*)\)\?');

/// 未转义时结束标签名的正则元字符与分隔符。
const String _nameTerminators = ' \t\r\n<>/\\()[]{}|^\$*+?."\'=';
final RegExp _htmlOutputPattern = RegExp(
  r'```\s*html\b|<(?:div|span|style|details|summary|button|table|html|!doctype|ruby|p|br|svg|img|section|body|head|script|iframe|link|meta|canvas|video|audio|form|input)\b',
  caseSensitive: false,
);

/// 替换结果引用了匹配原文（`$1`、`$&`、`$<名>`、`{{match}}`）。
final RegExp _captureReferencePattern = RegExp(
  r'\$(?:\d|&|<)|\{\{\s*match\s*\}\}',
  caseSensitive: false,
);

/// 查找规则里的捕获组 `(...)`（不含 `(?:` 等非捕获写法）：作者要取用原文。
final RegExp _captureGroupPattern = RegExp(r'(?<!\\)\((?!\?)');

/// 只把占位符（无成对标签、无捕获组、不引用原文）换成网页：网页显示不了，
/// 占位符本身也没有可读内容，显示时整段隐藏。
bool _isPlaceholderWebpage(SillyTavernRegexScript script) =>
    !_captureReferencePattern.hasMatch(script.replaceString) &&
    !_captureGroupPattern.hasMatch(script.findRegex) &&
    !script.findRegex.contains('</') &&
    !script.findRegex.contains(r'<\/');
final RegExp _summaryPattern = RegExp(
  r'<summary[^>]*>([\s\S]*?)</summary>',
  caseSensitive: false,
);
final RegExp _markupPattern = RegExp(r'<[^>]*>');

/// 从预设的显示正则推断语义标签映射（ADR0046）。
///
/// 预设作者已经用正则声明了每个标签的意图：“只作用于显示且改写为折叠 HTML”
/// 即折叠，“生成按钮”即选项。能匹配到标签的美化正则由界面组件接管；
/// 其余输出 HTML 的显示正则同样不再执行（界面不渲染 HTML，执行只会露出源码）。
/// 替换为空的显示正则照常执行，负责隐藏。
PresetTagMapping inferPresetTagMapping(SillyTavernPreset preset) {
  final rules = <String, PresetTagRule>{};
  final superseded = <String>{};
  final hidden = <String>{};

  void put(
    String name,
    TagPresentation display,
    String title, {
    PresetTagSource source = PresetTagSource.regex,
  }) {
    final existing = rules[name];
    // 选项、折叠证据优先于正文（正文只由名称判断）。
    if (existing != null && existing.display != TagPresentation.body) return;
    rules[name] = PresetTagRule(
      name: name,
      display: display,
      title: title,
      source: source,
    );
  }

  for (final script in preset.regexScripts) {
    if (script.disabled) continue;
    final names = _rootTagNames(script.findRegex);
    if (!script.markdownOnly || script.promptOnly) {
      // 请求侧或双向规则：只说明这些标签存在；显示方式按名称兜底。
      for (final name in names) {
        final builtin = _builtinTags[name] ?? _builtinByNameHint(name);
        if (builtin != null) put(name, builtin.display, builtin.title);
      }
      continue;
    }
    final replacement = script.replaceString;
    if (replacement.trim().isEmpty) continue;
    if (!_htmlOutputPattern.hasMatch(replacement)) continue;
    superseded.add(script.id);
    if (_isPlaceholderWebpage(script)) {
      hidden.add(script.id);
      continue;
    }
    // 预设作者给正则起的名字（“行动选项”“正文美化”“思维链折叠”）是标签意图
    // 的直接说明，比替换结果里的按钮、样式更可靠。
    final declared = _classifyByWords(script.name);
    for (final name in names) {
      final builtin = _builtinTags[name] ?? _builtinByNameHint(name);
      final display =
          builtin?.display ?? declared?.$1 ?? TagPresentation.fold;
      put(
        name,
        display,
        builtin?.title ?? _summaryTitle(replacement) ?? declared?.$2 ?? name,
      );
    }
  }

  // 提示词里明确的输出指令（“正文要用<game></game>包上”）补足没有正则的标签。
  final candidates = <String>{};
  for (final declared in _promptOutputTags(preset)) {
    if (rules.containsKey(declared.name)) continue;
    final display = declared.display;
    if (display == null) {
      candidates.add(declared.name);
      continue;
    }
    put(
      declared.name,
      display,
      _builtinTags[declared.name]?.title ?? declared.title ?? declared.name,
      source: PresetTagSource.prompt,
    );
  }

  final overrides =
      preset.compatibilityData[presetTagDisplayOverridesKey] as Map? ??
          const {};
  for (final entry in overrides.entries) {
    final name = entry.key.toString().toLowerCase();
    final display = TagPresentation.values
        .where((value) => value.name == entry.value)
        .firstOrNull;
    if (display == null) continue;
    final base = rules[name];
    rules[name] = base == null
        ? PresetTagRule(
            name: name,
            display: display,
            title: _builtinTags[name]?.title ?? name,
            source: PresetTagSource.user,
          )
        : base.copyWith(display: display, source: PresetTagSource.user);
  }

  final sorted = rules.values.toList()
    ..sort((a, b) => a.name.compareTo(b.name));
  return PresetTagMapping(
    rules: sorted,
    supersededScriptIds: superseded,
    hiddenScriptIds: hidden,
    candidates: (candidates..removeAll(rules.keys)).toList()..sort(),
  );
}

class _TagToken {
  const _TagToken(this.name, this.closing, this.start, this.end);
  final String name;
  final bool closing;
  final int start;
  final int end;
}

/// 正则真正处理的外层标签（ADR0048）：成对、且不被另一对标签包住的标签；
/// 没有成对标签时才取单独出现的开／闭标签（如预填充正则 `^…<\/thinking>`）。
/// 逐个顶层分支、逐个可选写法分析；先去掉前后查找断言里的标签。
Set<String> _rootTagNames(String findRegex) {
  final names = <String>{};
  final body = _stripRegexDelimiters(findRegex);
  for (final branch in _splitTopLevelAlternation(_stripLookarounds(body))) {
    for (final variant in _expandOptionalGroups(branch)) {
      final tokens = _tagTokens(variant);
      final spans = <(int, int, String)>[];
      final open = <_TagToken>[];
      final paired = <_TagToken>{};
      for (final token in tokens) {
        if (!token.closing) {
          open.add(token);
          continue;
        }
        final index = open.lastIndexWhere((t) => t.name == token.name);
        if (index < 0) continue;
        final opener = open[index];
        open.removeRange(index, open.length);
        paired
          ..add(opener)
          ..add(token);
        spans.add((opener.start, token.end, token.name));
      }
      // 没写闭标签的开标签（如 `<branches>…A\.…`）同样是外壳，
      // 它之后的成对标签都算内部结构。
      final unclosedOpeners =
          tokens.where((t) => !t.closing && !paired.contains(t)).toList();
      final roots = [
        for (final span in spans)
          if (!unclosedOpeners.any((opener) => opener.start < span.$1) &&
              !spans.any((other) =>
                  other.$1 <= span.$1 &&
                  other.$2 >= span.$2 &&
                  (other.$1 != span.$1 || other.$2 != span.$2)))
            span.$3,
        for (final opener in unclosedOpeners)
          if (spans.any((span) => opener.start < span.$1)) opener.name,
      ];
      if (roots.isNotEmpty) {
        names.addAll(roots);
      } else if (unclosedOpeners.isNotEmpty) {
        // 没有成对标签：最先出现的开标签是外壳，后面的都在它里面。
        names.add(unclosedOpeners.first.name);
      } else {
        // 只有闭标签：预填充写法（`^…<\/thinking>`），闭标签就是外壳。
        names.addAll(tokens.where((t) => t.closing).map((t) => t.name));
      }
    }
  }
  return names..removeWhere(_ignoredTagNames.contains);
}

/// `/…/flags` 形式去掉分隔符。
String _stripRegexDelimiters(String source) {
  final match = RegExp(r'^/([\s\S]*)/[a-z]*$').firstMatch(source);
  return match?.group(1) ?? source;
}

/// 去掉 `(?=…)`、`(?!…)`、`(?<=…)`、`(?<!…)`：断言里的标签只是匹配条件。
String _stripLookarounds(String source) {
  final output = StringBuffer();
  var i = 0;
  while (i < source.length) {
    final isLookaround = source.startsWith('(?=', i) ||
        source.startsWith('(?!', i) ||
        source.startsWith('(?<=', i) ||
        source.startsWith('(?<!', i);
    if (!isLookaround) {
      if (source[i] == r'\' && i + 1 < source.length) {
        output.write(source.substring(i, i + 2));
        i += 2;
      } else {
        output.write(source[i]);
        i++;
      }
      continue;
    }
    var depth = 0;
    var inClass = false;
    for (; i < source.length; i++) {
      final char = source[i];
      if (char == r'\') {
        i++;
        continue;
      }
      if (inClass) {
        if (char == ']') inClass = false;
        continue;
      }
      if (char == '[') {
        inClass = true;
      } else if (char == '(') {
        depth++;
      } else if (char == ')') {
        depth--;
        if (depth == 0) {
          i++;
          break;
        }
      }
    }
  }
  return output.toString();
}

/// 按顶层 `|` 切分（括号、字符类、转义内的不算）。
List<String> _splitTopLevelAlternation(String source) {
  final parts = <String>[];
  var depth = 0;
  var inClass = false;
  var start = 0;
  for (var i = 0; i < source.length; i++) {
    final char = source[i];
    if (char == r'\') {
      i++;
      continue;
    }
    if (inClass) {
      if (char == ']') inClass = false;
      continue;
    }
    if (char == '[') {
      inClass = true;
    } else if (char == '(') {
      depth++;
    } else if (char == ')') {
      depth--;
    } else if (char == '|' && depth == 0) {
      parts.add(source.substring(start, i));
      start = i + 1;
    }
  }
  parts.add(source.substring(start));
  return parts;
}

List<_TagToken> _tagTokens(String variant) {
  final tokens = <_TagToken>[];
  for (var i = variant.indexOf('<'); i >= 0; i = variant.indexOf('<', i)) {
    final start = i;
    // `(?<name>` 是命名分组，不是标签；`*?<tag>` 里的 `?` 是懒惰量词，不算。
    final isRegexSyntax = i > 1 && variant.startsWith('(?', i - 2);
    i++;
    var closing = false;
    if (variant.startsWith(r'\/', i)) {
      closing = true;
      i += 2;
    } else if (variant.startsWith('/', i)) {
      closing = true;
      i++;
    }
    final name = StringBuffer();
    while (i < variant.length) {
      final char = variant[i];
      if (char == r'\' && i + 1 < variant.length) {
        final next = variant[i + 1];
        // `\~`、`\:` 等转义符号属于名字；`\s`、`\w` 等类名结束名字。
        if (RegExp(r'[A-Za-z0-9]').hasMatch(next)) break;
        name.write(next);
        i += 2;
        continue;
      }
      if (_nameTerminators.contains(char)) break;
      name.write(char);
      i++;
    }
    final value = name.toString().toLowerCase();
    if (isRegexSyntax || value.isEmpty || value.startsWith('!')) continue;
    tokens.add(_TagToken(value, closing, start, i));
  }
  return tokens;
}

class _DeclaredTag {
  const _DeclaredTag(this.name, this.display, this.title);
  final String name;
  final TagPresentation? display;
  final String? title;
}

/// 提示词里“输出动作 → 标签”的明确关系（ADR0048）：同一句话里，
/// 包裹／放入类动词与开标签相距不远时，这个标签就是模型要输出的外壳。
/// 同句关键词决定呈现：正文类 → 正文；总结／思考／状态类 → 折叠；
/// 选项类 → 选项；判断不了的只作候选。
List<_DeclaredTag> _promptOutputTags(SillyTavernPreset preset) {
  final byId = preset.promptsById;
  final declared = <String, _DeclaredTag>{};
  for (final entry in preset.selectedOrder.entries) {
    if (!entry.enabled) continue;
    final content = byId[entry.identifier]?.content;
    if (content == null || !content.contains('<')) continue;
    for (final sentence in content.split(_sentenceBreak)) {
      if (!sentence.contains('<')) continue;
      for (final pattern in _outputObjectPatterns) {
        for (final match in pattern.allMatches(sentence)) {
          final name = match.group(1)!.toLowerCase();
          if (_ignoredTagNames.contains(name) || declared.containsKey(name)) {
            continue;
          }
          declared[name] = _classifyDeclaration(name, sentence);
        }
      }
    }
  }
  return declared.values.toList();
}

_DeclaredTag _classifyDeclaration(String name, String sentence) {
  final builtin = _builtinTags[name] ?? _builtinByNameHint(name);
  if (builtin != null) return _DeclaredTag(name, builtin.display, builtin.title);
  final declared = _classifyByWords(sentence);
  return _DeclaredTag(name, declared?.$1, declared?.$2);
}

/// 按说明文字里的关键词判断呈现：选项 > 折叠类 > 正文。
(TagPresentation, String)? _classifyByWords(String text) {
  if (_optionsWord.hasMatch(text)) return (TagPresentation.options, '选项');
  final fold = _foldWord.firstMatch(text);
  if (fold != null) return (TagPresentation.fold, fold[0]!);
  if (_bodyWord.hasMatch(text)) return (TagPresentation.body, '正文');
  return null;
}

final RegExp _sentenceBreak = RegExp(r'[。！？!?\n；;]');
const String _promptTagName = r'([^\s<>/!{}|()\[\]]{1,30})';

/// 标签外常见的反引号、引号包装（如 “`<content>``</content>`进行包裹”）。
const String _quoteGap = '[\\s`\'"“”「」]*';

/// 标签必须是包裹／放入类动作的宾语：紧挨在“包裹、包上”之前
/// （`由<Options>包裹`、`用<game></game>标签包上`），或紧跟在
/// “放在、写在、输出到”之后。只提到名字、章节标题都不算。
final List<RegExp> _outputObjectPatterns = [
  RegExp(
    '<$_promptTagName>$_quoteGap(?:</[^<>]{1,30}>$_quoteGap)?(?:标签)?\\s*'
    '(?:(?:里|中|内|内部)\\s*输出|(?:里|中|内)?\\s*'
    '(?:包上|包住|包裹|包起来|括起来|括住|进行包裹))',
  ),
  RegExp(
    '(?:放在|放入|写在|写入|置于|包裹在|包在|输出(?:在|到|于))\\s*<$_promptTagName>',
  ),
  RegExp(
    '(?:wrap(?:ped)?|enclose[d]?)\\s+(?:it\\s+|them\\s+)?(?:in|with)\\s+<$_promptTagName>',
    caseSensitive: false,
  ),
];
final RegExp _bodyWord = RegExp(r'正文|小说|主体|故事内容|剧情内容');
final RegExp _foldWord = RegExp(r'摘要|总结|思考|思维|推演|状态|小剧场|记录|备注|后话');
final RegExp _optionsWord = RegExp(r'选项|分支|行动选择|choices?|options?',
    caseSensitive: false);

/// `<(?:角色)?状态面板>` 展开为带前缀与不带前缀两种写法。
List<String> _expandOptionalGroups(String source) {
  var variants = [source];
  for (var round = 0; round < 4; round++) {
    final next = <String>[];
    var changed = false;
    for (final variant in variants) {
      final match = _optionalGroupPattern.firstMatch(variant);
      if (match == null) {
        next.add(variant);
        continue;
      }
      changed = true;
      // 同一个可选前缀在开、闭标签里各出现一次，必须同时取舍，否则开闭对不上。
      next
        ..add(variant.replaceAll(match[0]!, match.group(1)!))
        ..add(variant.replaceAll(match[0]!, ''));
    }
    variants = next;
    if (!changed) break;
  }
  return variants;
}

/// 名称含常见词根的变体（如小猫之神的 `think_nya~`）按词根归类。
_BuiltinTag? _builtinByNameHint(String name) {
  if (_thinkingNameHint.hasMatch(name)) {
    return const _BuiltinTag(TagPresentation.fold, '思考');
  }
  if (_optionsNameHint.hasMatch(name)) {
    return const _BuiltinTag(TagPresentation.options, '选项');
  }
  return null;
}

final RegExp _thinkingNameHint = RegExp(r'think|thought|reason|cot\b|思考|思维');
final RegExp _optionsNameHint = RegExp(r'option|branch|choice|选项|分支');


String? _summaryTitle(String replacement) {
  final match = _summaryPattern.firstMatch(replacement);
  if (match == null) return null;
  final text = match
      .group(1)!
      .replaceAll(_markupPattern, '')
      .replaceAll(RegExp(r'\$\d+|\{\{[^}]*\}\}'), '')
      // 只留文字，去掉装饰符号
      .replaceAll(RegExp(r'[^\p{L}\p{N}\s·]', unicode: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (text.isEmpty || text.length > 24) return null;
  return text;
}
