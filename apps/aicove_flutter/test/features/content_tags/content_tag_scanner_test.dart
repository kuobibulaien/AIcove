import 'package:aicove_flutter/src/features/content_tags/domain/content_tag_registry.dart';
import 'package:aicove_flutter/src/features/content_tags/domain/content_tag_scanner.dart';
import 'package:aicove_flutter/src/features/content_tags/domain/content_tag_spec.dart';
import 'package:flutter_test/flutter_test.dart';

const _voice = StaticContentTagProvider(
  providerId: 'voice',
  tagSpecs: [ContentTagSpec(name: 'tts', ownerId: 'voice')],
  toolNames: {'speak'},
);
const _draw = StaticContentTagProvider(
  providerId: 'draw',
  tagSpecs: [ContentTagSpec(name: 'image', ownerId: 'draw')],
);
const _think = StaticContentTagProvider(
  providerId: 'preset:a',
  tagSpecs: [
    ContentTagSpec(
      name: 'thinking',
      aliases: {'think'},
      ownerId: 'preset:a',
      requestWhenActive: ContentTagRequestAction.unwrap,
    ),
  ],
);

ContentTagScanner _scanner({Set<String>? active}) => ContentTagScanner(
      ContentTagRegistry([_voice, _draw, _think], activeProviderIds: active),
    );

void main() {
  test('splits registered elements and keeps unknown tags as text', () {
    final segments = _scanner().scan('a<TTS voice="x>y">hi</tTs>b<ttstyle>c');
    expect(segments, hasLength(3));
    expect((segments[0] as ContentTagText).text, 'a');
    final element = segments[1] as ContentTagElement;
    expect(element.spec.name, 'tts');
    expect(element.inner, 'hi');
    expect(element.attributes, {'voice': 'x>y'});
    expect(element.closed, isTrue);
    expect((segments[2] as ContentTagText).text, 'b<ttstyle>c');
  });

  test('pairs same-name nesting by depth and keeps other tags inside', () {
    final segments =
        _scanner().scan('<image>x<image>y</image><tts>v</tts></image>z');
    final element = segments.first as ContentTagElement;
    expect(element.inner, 'x<image>y</image><tts>v</tts>');
    expect((segments.last as ContentTagText).text, 'z');
  });

  test('marks unclosed elements, self-closing tags and orphan closes', () {
    final segments = _scanner().scan('a<image/>b</tts>c<tts>open');
    expect((segments[1] as ContentTagElement).selfClosing, isTrue);
    expect(segments[3], isA<ContentTagOrphanClose>());
    final tail = segments.last as ContentTagElement;
    expect(tail.closed, isFalse);
    expect(tail.inner, 'open');
  });

  test('aliases resolve to the same spec', () {
    final element = _scanner().scan('<THINK>x</THINK>').single;
    expect((element as ContentTagElement).spec.name, 'thinking');
  });

  test('request filter strips inactive owners even inside kept elements', () {
    final scanner = _scanner(active: {'draw', 'preset:a'});
    expect(
      scanner.filterForRequest('<image>a<tts>b</tts>c</image>d</tts>e'),
      '<image>ac</image>de',
    );
  });

  test('request filter unwraps and keeps orphan closes of active owners', () {
    final scanner = _scanner(active: {'voice', 'draw', 'preset:a'});
    expect(
      scanner.filterForRequest('<think>plan<tts>v</tts></think></tts>x'),
      'plan<tts>v</tts></tts>x',
    );
  });

  test('tool ownership follows provider activity', () {
    final registry = ContentTagRegistry([_voice], activeProviderIds: {});
    expect(registry.allowsTool('speak'), isFalse);
    expect(registry.allowsTool('search'), isTrue);
  });
}
