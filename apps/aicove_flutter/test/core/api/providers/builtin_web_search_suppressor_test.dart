import 'package:aicove_flutter/src/core/api/providers/builtin_web_search_suppressor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const functionTool = {
    'type': 'function',
    'function': {'name': 'web_search', 'parameters': <String, dynamic>{}},
  };

  test('去掉各家内置搜索工具，保留插件函数工具', () {
    final body = <String, dynamic>{
      'tools': [
        functionTool,
        {'type': 'web_search_20250305', 'name': 'web_search'},
        {'type': 'web_fetch_20250910', 'name': 'web_fetch'},
        {'type': 'web_search_preview'},
        {'type': 'x_search'},
        {
          'type': 'web_search',
          'web_search': {'enable': true},
        },
        {
          'type': 'builtin_function',
          'function': {'name': r'$web_search'},
        },
        {'googleSearch': <String, dynamic>{}},
      ],
    };

    final removed = stripBuiltinWebSearch(body);

    expect(body['tools'], [functionTool]);
    expect(removed, hasLength(7));
  });

  test('Anthropic 格式的同名函数工具（无 type）不受影响', () {
    final anthropicTool = {
      'name': 'web_search',
      'input_schema': {'type': 'object'},
    };
    final body = <String, dynamic>{
      'tools': [anthropicTool],
    };
    expect(stripBuiltinWebSearch(body), isEmpty);
    expect(body['tools'], [anthropicTool]);
  });

  test('Gemini 函数声明保留，内置搜索元素去掉', () {
    final declarations = {
      'functionDeclarations': [
        {'name': 'web_search'},
      ],
    };
    final body = <String, dynamic>{
      'tools': [
        declarations,
        {'google_search': <String, dynamic>{}, 'url_context': <String, dynamic>{}},
      ],
    };
    stripBuiltinWebSearch(body);
    expect(body['tools'], [declarations]);
  });

  test('去掉顶层开关、extra_body 字段与 OpenRouter 网页插件', () {
    final body = <String, dynamic>{
      'model': 'm',
      'web_search_options': {'search_context_size': 'low'},
      'search_parameters': {'mode': 'auto'},
      'enable_search': true,
      'extra_body': {'enable_search': true, 'other': 1},
      'plugins': [
        {'id': 'web'},
        {'id': 'file-parser'},
      ],
      'tools': [
        {'type': 'web_search'},
      ],
      'tool_choice': 'auto',
    };

    stripBuiltinWebSearch(body);

    expect(body, {
      'model': 'm',
      'extra_body': {'other': 1},
      'plugins': [
        {'id': 'file-parser'},
      ],
    });
  });

  test('没有内置搜索时不改动请求体', () {
    final body = <String, dynamic>{
      'model': 'm',
      'tools': [functionTool],
      'tool_choice': 'auto',
    };
    final before = Map<String, dynamic>.from(body);
    expect(stripBuiltinWebSearch(body), isEmpty);
    expect(body, before);
  });
}
