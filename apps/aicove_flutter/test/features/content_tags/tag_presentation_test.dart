import 'package:aicove_flutter/src/features/content_tags/domain/tag_presentation.dart';
import 'package:flutter_test/flutter_test.dart';

const TagPresentationMap _map = {
  'thinking': TagPresentationEntry(TagPresentation.fold, '思考'),
  'details': TagPresentationEntry(TagPresentation.fold, '详情'),
  'zw': TagPresentationEntry(TagPresentation.body, '正文'),
  'options': TagPresentationEntry(TagPresentation.options, '选项'),
};

String _describe(List<TagDisplayPart> parts) => parts
    .map((part) => switch (part) {
          TagBodyPart(:final text) => 'body($text)',
          TagFoldPart(:final title, :final content, :final closed) =>
            'fold($title|$content${closed ? '' : '|…'})',
        })
    .join(' ');

void main() {
  test('folds, unwraps body, drops options', () {
    expect(
      _describe(projectTagPresentation(
        '<thinking>想一想</thinking>\n<zw>她笑了。<details><summary>记忆<b>水晶</b></summary><p>要点</p></details></zw>\n<options>A</options>',
        _map,
      )),
      'fold(思考|想一想) body(她笑了。) fold(记忆水晶|要点)',
    );
  });

  test('streaming unfinished fold stays open', () {
    expect(
      _describe(projectTagPresentation('前言<thinking>还在想', _map)),
      'body(前言) fold(思考|还在想|…)',
    );
  });

  test('prefilled reply without opening tag folds the leading part', () {
    expect(
      _describe(projectTagPresentation('推理过程</thinking>正文', _map)),
      'fold(思考|推理过程) body(正文)',
    );
  });

  test('unknown tags stay as body text', () {
    expect(
      _describe(projectTagPresentation('<ztl>状态</ztl>', _map)),
      'body(<ztl>状态</ztl>)',
    );
  });

  test('attribute values containing > do not leak into title or content', () {
    expect(
      _describe(projectTagPresentation(
        '<details><summary title="a>b">标题</summary><p title="x>y">正文</p></details>',
        _map,
      )),
      'fold(标题|正文)',
    );
  });

  test('options nested inside a fold are dropped', () {
    expect(
      _describe(projectTagPresentation(
        '<thinking>A<options>B</options>C</thinking>',
        _map,
      )),
      'fold(思考|AC)',
    );
  });

  group('protectedTagRanges (ADR0047)', () {
    List<String> slices(String text) => [
          for (final r in protectedTagRanges(text, _map))
            '${text.substring(r.start, r.end)}${r.closed ? '' : '|…'}',
        ];

    test('fold and options are components, body tags are prose', () {
      expect(
        slices('<thinking>甲。乙。</thinking><zw>正文。<details>细节。</details></zw><options>A</options>'),
        ['<thinking>甲。乙。</thinking>', '<details>细节。</details>', '<options>A</options>'],
      );
    });

    test('unclosed fold is open to the end', () {
      expect(slices('前言。<thinking>还在想。'), ['<thinking>还在想。|…']);
    });

    test('prefilled fold protects from the start to the orphan close', () {
      expect(slices('推理。过程。</thinking>正文。'), ['推理。过程。</thinking>']);
    });

    test('unknown tags are not components', () {
      expect(slices('我<3你。<b>粗体。</b>'), isEmpty);
    });
  });

  test('tags inside code blocks are never projected (ADR0048)', () {
    const text = '前文\n```html\n<thinking>示例</thinking>\n```\n用 `<zw>` 包正文';
    expect(_describe(projectTagPresentation(text, _map)), 'body($text)');
  });

  test('sole unknown wrapper covering the reply can be unwrapped', () {
    const reply = '<thinking>想</thinking><game>她笑了，推开门走进雨里。</game>';
    expect(soleUnknownBodyWrapper(reply, _map), 'game');
    expect(
      soleUnknownBodyWrapper('<a1>短</a1><b1>也短</b1>', _map),
      isNull,
    );
    expect(
      soleUnknownBodyWrapper('很长很长的一段正文内容，远多于标签。<note>注</note>', _map),
      isNull,
    );
    expect(
      soleUnknownBodyWrapper('```\n<game>代码</game>\n```', _map),
      isNull,
    );
  });
}
