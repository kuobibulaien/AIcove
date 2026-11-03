import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/core/api/image_providers/moss_manga_layout_compiler.dart';

Map<String, dynamic> compile({
  String layout = 'balanced_1',
  int width = 1088,
  int height = 1920,
  List<Object?>? items,
}) =>
    jsonDecode(
          compileMossMangaPromptIfApplicable(
            jsonEncode({
              'layout': layout,
              'summary': {'caption': 'Ink manga.', 'canvas': 'multi_panel'},
              'items':
                  items ??
                  [
                    {
                      'panel': 1,
                      'slot': 'F',
                      'label': 'character',
                      'caption': 'A traveler',
                    },
                  ],
            }),
            width: width,
            height: height,
          ),
        )
        as Map<String, dynamic>;

void main() {
  test('balanced_1 E expands F by eight pixels in both orientations', () {
    for (final landscape in [false, true]) {
      final width = landscape ? 1920 : 1088;
      final height = landscape ? 1088 : 1920;
      final result = compile(
        width: width,
        height: height,
        items: [
          {'panel': 'single', 'slot': 'F'},
          {'panel': 'single', 'slot': 'E'},
        ],
      );
      final frame = result['items'][0]['bbox'] as List;
      final expanded = result['items'][1]['bbox'] as List;
      expect(expanded, [
        frame[0] - 8,
        frame[1] - 8,
        frame[2] + 8,
        frame[3] + 8,
      ]);
      expect(
        expanded,
        landscape ? [-512, -932, 512, 932] : [-932, -512, 932, 512],
      );
      final half = compile(
        width: width ~/ 2,
        height: height ~/ 2,
        items: [
          {'panel': 1, 'slot': 'E'},
        ],
      );
      expect(half['items'][0]['bbox'], [
        for (final value in expanded) value ~/ 2,
      ]);
    }
  });

  test(
    'ordinary, malformed, native bbox and unrelated JSON stay unchanged',
    () {
      for (final prompt in [
        '  cat 雨\n',
        '{"layout":',
        '[]',
        '{"layout":"balanced_1","items":[]}',
        '{"layout":42,"items":[{"panel":1,"slot":"F"}]}',
        '{"layout":"unrelated","items":[{"name":"chair"}]}',
        '{"summary":{"caption":"cat"},"items":[{"bbox":[-1,-1,1,1]}]}',
      ]) {
        expect(
          compileMossMangaPromptIfApplicable(prompt, width: 0, height: 0),
          prompt,
        );
      }
    },
  );

  test(
    'compiles centered yxyx frame, preserves wording and summary metadata',
    () {
      final result = compile(
        items: [
          {
            'panel': 'single',
            'slot': ' f ',
            'label': 'text',
            'caption': 'panel 1: speech',
            'text': '你好，"旅人"！',
          },
        ],
      );
      expect(result['items'], [
        {
          'label': 'text',
          'caption': 'Content of panel 1: speech',
          'text': '你好，"旅人"！',
          'bbox': [-924, -504, 924, 504],
        },
      ]);
      expect(
        result['summary']['caption'],
        startsWith('Page frame guide: exactly 1 distinct comic panels;'),
      );
      expect(result['summary']['caption'], endsWith('Ink manga.'));
      expect(result['summary']['canvas'], 'multi_panel');
      expect(result['summary']['bbox_Normalized'], 'abs_centralized');
      expect(result['summary']['format'], 'yxyx');
      expect(result['bbox_coord_space'], 'abs_centralized');
      expect(result['bbox_format'], 'yxyx');
      expect(result.containsKey('layout'), isFalse);
    },
  );

  test('selects landscape table and resolves names and panel-N references', () {
    for (final ref in [1, '1', 'left', 'panel-1', ' LEFT ']) {
      final result = compile(
        layout: 'balanced_2',
        width: 1920,
        height: 1088,
        items: [
          {'panel': ref, 'slot': 'F', 'label': 'character'},
        ],
      );
      expect(result['items'][0]['bbox'], [-504, -924, 504, -12]);
    }
  });

  test('uniform scaling preserves proportions and centers on a new canvas', () {
    expect(compile(width: 544, height: 960)['items'][0]['bbox'], [
      -462,
      -252,
      462,
      252,
    ]);
    expect(compile(width: 1088, height: 1088)['items'][0]['bbox'], [
      -524,
      -286,
      524,
      286,
    ]);
    // The portrait height is limiting: a square canvas keeps the base scale.
    expect(compile(width: 1920, height: 1920)['items'][0]['bbox'], [
      -924,
      -504,
      924,
      504,
    ]);
  });

  test(
    'same text slot splits vertically in order, other panels stay separate',
    () {
      final result = compile(
        layout: 'balanced_2',
        items: [
          {'panel': 1, 'slot': 'T', 'label': 'text', 'text': '第一句'},
          {'panel': 'top', 'slot': 'T', 'label': 'text', 'text': '第二句'},
          {'panel': 2, 'slot': 'T', 'label': 'text', 'text': '第三句'},
          {'panel': 1, 'slot': 'S', 'label': 'character', 'caption': 'speaker'},
        ],
      );
      final items = result['items'] as List;
      final first = items[0]['bbox'] as List;
      final second = items[1]['bbox'] as List;
      expect(first[2], lessThan(second[0]));
      expect(first[0], -906);
      expect(second[2], -742);
      expect(items.map((i) => i['text']).toList(), ['第一句', '第二句', '第三句', null]);
      expect(items[0]['caption'], contains('Text 1 of 2'));
      expect(items[1]['caption'], contains('Text 2 of 2'));
      expect(items[2]['caption'], isNot(contains('Text 1 of')));
      expect(items[3]['bbox'], [-725, -486, -30, 486]);
    },
  );

  test(
    'bottom text halves are distinct and preserve the source bottom box',
    () {
      final result = compile(
        items: [
          for (final slot in ['B', 'BL', 'BR'])
            {'panel': 1, 'slot': slot, 'label': 'text', 'text': slot},
        ],
      );
      expect((result['items'] as List).map((i) => i['bbox']).toList(), [
        [545, -488, 908, 488],
        [545, -488, 908, -12],
        [545, 12, 908, 488],
      ]);
    },
  );

  test('inset frame guide describes layering, not additional subdivisions', () {
    final result = compile(layout: 'main_with_inset');
    expect(
      result['summary']['caption'],
      contains('panel 2 is in front of panel 1'),
    );
    expect(
      result['summary']['caption'],
      contains('exactly 2 distinct comic panels'),
    );
  });

  test('recognized symbolic requests report invalid references explicitly', () {
    for (final items in <List<Object?>>[
      [
        {'panel': 0, 'slot': 'F'},
      ],
      [
        {'panel': 2, 'slot': 'F'},
      ],
      [
        {'panel': 1.5, 'slot': 'F'},
      ],
      [
        {'panel': 'unknown', 'slot': 'F'},
      ],
      [
        {'panel': 1, 'slot': 'unknown'},
      ],
      [
        {'panel': 1},
      ],
      [
        {'slot': 'F'},
      ],
      [
        {'panel': 1, 'slot': 'F'},
        null,
      ],
      [
        {'panel': 1, 'slot': 'F'},
        {
          'bbox': [0, 0, 1, 1],
        },
      ],
      // Numbered slots must not alias a different region.
      [
        {'panel': 1, 'slot': 'S_2'},
      ],
    ]) {
      expect(() => compile(items: items), throwsFormatException);
    }
    expect(() => compile(layout: 'unknown'), throwsFormatException);
    expect(() => compile(width: 0), throwsFormatException);
    expect(() => compile(height: -1), throwsFormatException);
    expect(() => compile(width: 1, height: 1), throwsFormatException);
  });

  test(
    'all reference built-in layouts resolve every panel and all slot roles',
    () {
      const counts = {
        'balanced_1': 1,
        'balanced_2': 2,
        'balanced_3': 3,
        'balanced_4': 4,
        'wide_then_two': 3,
        'left_main_right_two': 3,
        'right_main_left_three': 4,
        'two_then_large': 3,
        'main_then_strip': 2,
        'main_inset_then_two': 4,
        'right_main_left_four': 5,
        'main_then_two': 3,
        'main_with_inset': 2,
        'two_then_strip': 3,
        'main_then_side': 2,
        'main_then_right_two': 3,
        'strip_main_right_two': 4,
        'two_then_tall': 3,
      };
      for (final landscape in [false, true]) {
        for (final entry in counts.entries) {
          final result = compile(
            layout: entry.key,
            width: landscape ? 1920 : 1088,
            height: landscape ? 1088 : 1920,
            items: [
              for (var panel = 1; panel <= entry.value; panel++)
                for (final slot in [
                  'F',
                  'C',
                  'S',
                  'L',
                  'R',
                  'O',
                  'T',
                  'TL',
                  'TR',
                  'B',
                  'BL',
                  'BR',
                  'ML',
                  'MR',
                ])
                  // The source reserves these regions for the inset, not the main.
                  if (!(entry.key == 'main_inset_then_two' &&
                      panel == 1 &&
                      ['L', 'R', 'O', 'TL', 'TR', 'ML', 'MR'].contains(slot)))
                    {'panel': panel, 'slot': slot, 'label': 'character'},
            ],
          );
          for (final item in result['items']) {
            final box = item['bbox'] as List;
            expect(box, hasLength(4));
            expect(box[0], lessThan(box[2]), reason: '${entry.key}: $item');
            expect(box[1], lessThan(box[3]), reason: '${entry.key}: $item');
          }
        }
      }
      // E retains the reference coordinates on multi-panel layouts.
      final result = compile(
        layout: 'two_then_tall',
        width: 1920,
        height: 1088,
        items: [
          {'panel': 3, 'slot': 'E', 'label': 'character'},
        ],
      );
      expect(result['items'][0]['bbox'], [-168, -932, 512, 932]);
    },
  );

  const taskLayouts = {
    false: {
      'balanced_1': 1,
      'balanced_2': 2,
      'balanced_3': 3,
      'balanced_4': 4,
      'main_then_side': 2,
      'main_then_right_two': 3,
      'strip_main_right_two': 4,
      'two_then_tall': 3,
      'top_focus_bottom_two': 3,
      'three_then_wide': 4,
      'tall_left_stack_right': 3,
      'grid_2x2': 4,
    },
    true: {
      'balanced_1': 1,
      'balanced_2': 2,
      'balanced_3': 3,
      'balanced_4': 4,
      'left_main_right_stack': 3,
      'top_wide_bottom_two': 3,
      'left_two_right_main': 3,
      'grid_2x2': 4,
      'top_two_bottom_wide': 3,
    },
  };
  const slots = [
    'F',
    'C',
    'S',
    'L',
    'R',
    'O',
    'T',
    'TL',
    'TR',
    'B',
    'BL',
    'BR',
    'ML',
    'MR',
    'E',
  ];
  List<Object?> allSlots(int count) => [
    for (var panel = 1; panel <= count; panel++)
      for (final slot in slots)
        {'panel': panel, 'slot': slot, 'label': 'character', 'caption': slot},
  ];
  for (final direction in taskLayouts.entries) {
    for (final layout in direction.value.entries) {
      test(
        'task layout ${direction.key ? 'landscape' : 'portrait'} ${layout.key} resolves every panel and slot',
        () {
          final result = compile(
            layout: layout.key,
            width: direction.key ? 1920 : 1088,
            height: direction.key ? 1088 : 1920,
            items: allSlots(layout.value),
          );
          final items = result['items'] as List;
          expect(items, hasLength(layout.value * 15));
          expect(
            result['summary']['caption'],
            contains('exactly ${layout.value} distinct comic panels'),
          );
          for (final item in items) {
            final box = item['bbox'] as List;
            expect(box.every((v) => v is int), isTrue);
            expect(box[0], lessThan(box[2]));
            expect(box[1], lessThan(box[3]));
            expect(item.containsKey('panel'), isFalse);
            expect(item.containsKey('slot'), isFalse);
          }
        },
      );
    }
  }

  test('task aliases preserve every source slot coordinate and page guide', () {
    const aliases = {
      false: {
        'top_focus_bottom_two': ('main_then_two', 3),
        'tall_left_stack_right': ('left_main_right_two', 3),
        'grid_2x2': ('balanced_4', 4),
      },
      true: {
        'left_main_right_stack': ('left_main_right_two', 3),
        'top_wide_bottom_two': ('wide_then_two', 3),
        'grid_2x2': ('balanced_4', 4),
        'top_two_bottom_wide': ('two_then_large', 3),
      },
    };
    for (final direction in aliases.entries) {
      for (final alias in direction.value.entries) {
        final items = allSlots(alias.value.$2);
        final width = direction.key ? 1920 : 1088;
        final height = direction.key ? 1088 : 1920;
        expect(
          compile(
            layout: alias.key,
            width: width,
            height: height,
            items: items,
          ),
          compile(
            layout: alias.value.$1,
            width: width,
            height: height,
            items: items,
          ),
        );
      }
    }
  });

  test(
    'three_then_wide uses three upper frames, 24px gutters and one lower wide frame',
    () {
      final result = compile(
        layout: 'three_then_wide',
        items: [
          for (final panel in [
            'top-left',
            'top-middle',
            'top-right',
            'bottom-wide',
          ])
            {'panel': panel, 'slot': 'F'},
        ],
      );
      expect((result['items'] as List).map((i) => i['bbox']).toList(), [
        [-924, -504, 40, -184],
        [-924, -160, 40, 160],
        [-924, 184, 40, 504],
        [64, -504, 924, 504],
      ]);
      final source = compile(
        layout: 'two_then_strip',
        items: [
          {'panel': 1, 'slot': 'C'},
          {'panel': 3, 'slot': 'C'},
        ],
      );
      final reframed = compile(
        layout: 'three_then_wide',
        items: [
          {'panel': 1, 'slot': 'C'},
          {'panel': 4, 'slot': 'C'},
        ],
      );
      // C's vertical bounds and the entire bottom panel remain unchanged.
      expect(reframed['items'][0]['bbox'][0], source['items'][0]['bbox'][0]);
      expect(reframed['items'][0]['bbox'][2], source['items'][0]['bbox'][2]);
      expect(reframed['items'][1]['bbox'], source['items'][1]['bbox']);
    },
  );

  test(
    'left_two_right_main mirrors geometry, swaps left/right roles and preserves reading order',
    () {
      const mirroredSlots = {
        'L': 'R',
        'R': 'L',
        'TL': 'TR',
        'TR': 'TL',
        'BL': 'BR',
        'BR': 'BL',
        'ML': 'MR',
        'MR': 'ML',
      };
      for (var panel = 1; panel <= 3; panel++) {
        final sourcePanel = [2, 3, 1][panel - 1];
        for (final slot in slots) {
          final source = compile(
            layout: 'left_main_right_two',
            width: 1920,
            height: 1088,
            items: [
              {'panel': sourcePanel, 'slot': mirroredSlots[slot] ?? slot},
            ],
          );
          final mirrored = compile(
            layout: 'left_two_right_main',
            width: 1920,
            height: 1088,
            items: [
              {'panel': panel, 'slot': slot},
            ],
          );
          final box = source['items'][0]['bbox'] as List;
          expect(mirrored['items'][0]['bbox'], [
            box[0],
            -box[3],
            box[2],
            -box[1],
          ]);
        }
      }
      final frames = compile(
        layout: 'left_two_right_main',
        width: 1920,
        height: 1088,
        items: [
          for (final panel in ['left-top', 'left-bottom', 'right-main'])
            {'panel': panel, 'slot': 'F'},
        ],
      );
      expect((frames['items'] as List).map((i) => i['bbox']).toList(), [
        [-504, -924, -12, -197],
        [12, -924, 504, -197],
        [-504, -173, 504, 924],
      ]);
      expect(
        frames['summary']['caption'],
        contains('panel 1 then panel 2 then panel 3'),
      );
    },
  );
}
