import 'package:aicove_flutter/src/features/chat/domain/quoted_reply.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('compose 与 parse 往返一致', () {
    final text = QuotedReply.compose(quotedContent: '上一条引用消息', text: '继续往下说');
    expect(text, '> Quote: 上一条引用消息\n\n继续往下说');
    final parsed = QuotedReply.parse(text)!;
    expect(parsed.quote, '上一条引用消息');
    expect(parsed.body, '继续往下说');
  });

  test('compose 截断超长摘要并把换行压成空格', () {
    final text = QuotedReply.compose(
      quotedContent: '第一行\n第二行${'字' * 40}',
      text: '好',
    );
    final parsed = QuotedReply.parse(text)!;
    expect(parsed.quote, startsWith('第一行 第二行'));
    expect(parsed.quote, endsWith('...'));
    expect(parsed.quote.length, QuotedReply.maxQuoteLength + 3);
  });

  test('引用一条引用回复时只取它的正文，不层层嵌套', () {
    final first = QuotedReply.compose(quotedContent: '最早那句', text: '第二句');
    final second = QuotedReply.compose(quotedContent: first, text: '第三句');
    expect(QuotedReply.parse(second)!.quote, '第二句');
  });

  test('普通 Markdown 引用与缺正文的文本不识别为引用回复', () {
    expect(QuotedReply.parse('> 这是一句名言\n\n我的看法'), isNull);
    expect(QuotedReply.parse('> Quote: 只有引用'), isNull);
    expect(QuotedReply.parse('正文 > Quote: x\n\ny'), isNull);
  });
}
