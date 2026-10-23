import 'package:flutter/services.dart' show rootBundle;

/// One page of the docs library written for the assistant, not for users:
/// what AIcove is like now, which the model cannot know on its own.
class AicoveDoc {
  const AicoveDoc(this.id, this.title, this.summary, {this.generated = false});

  final String id;
  final String title;
  final String summary;

  /// Built at run time from code (the settings whitelist), not an asset.
  final bool generated;

  String get assetPath => 'assets/aicove_docs/$id.md';
}

const kAicoveDocs = <AicoveDoc>[
  AicoveDoc('product_map', '产品与界面地图', '定位边界、底栏三页、各设置入口在哪、术语'),
  AicoveDoc('role_cards', '角色卡结构', '角色字段、人设写法、导入角色卡'),
  AicoveDoc('plugins', '插件与生效规则', '插件清单、生效的四个条件、排查顺序'),
  AicoveDoc('tavern_presets', '酒馆预设、正则与世界书', '绑定规则、条目开关、正则授权、常见问题'),
  AicoveDoc('context_and_models', '上下文装配与模型', '一次请求包含什么、压缩、内置渠道、错误码'),
  AicoveDoc('voice_call', '语音通话', '怎么打、需要的三样配置、常见提示怎么处理、通话里的限制'),
  AicoveDoc('sticker_packs', '表情包：导入与打标', '从网页链接导入、给表情打标签、打标规则、做不到的事'),
  AicoveDoc('known_limits', '已知限制', '还没有的功能，承诺前先查'),
  AicoveDoc(
    kAicoveSettingsDocId,
    '你能改的设置项',
    '设置白名单：key、取值、所在页面、风险',
    generated: true,
  ),
];

const kAicoveSettingsDocId = 'settings';

Future<String?> readBundledAicoveDoc(String id) async {
  final doc = kAicoveDocs.where((d) => d.id == id).firstOrNull;
  if (doc == null || doc.generated) return null;
  return rootBundle.loadString(doc.assetPath);
}
