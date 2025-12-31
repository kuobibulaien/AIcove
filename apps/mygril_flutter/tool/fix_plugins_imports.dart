// ignore_for_file: avoid_print

import 'dart:io';

/// 修复 plugins 模块迁移后的 import 路径

void main() async {
  print('🔧 修复 plugins 模块的 import 路径\n');
  
  // 1. 修复 settings_page.dart 的引用
  await _fixSettingsPage();
  
  // 2. 修复迁移文件自身的 import
  await _fixPluginPages();
  
  print('\n✅ 修复完成！运行 flutter analyze 验证');
}

/// 修复 settings_page.dart 中的 import
Future<void> _fixSettingsPage() async {
  final file = File('lib/src/features/chat/presentation/pages/settings_page.dart');
  
  if (!file.existsSync()) {
    print('⚠️  settings_page.dart 不存在');
    return;
  }
  
  var content = file.readAsStringSync();
  final original = content;
  
  // 更新 plugins 页面的引用
  content = content.replaceAll(
    "import 'tts_plugin_detail_page.dart';",
    "import '../../../../ui/features/plugins/pages/tts_plugin_detail_page.dart';",
  );
  content = content.replaceAll(
    "import 'memory_plugin_detail_page.dart';",
    "import '../../../../ui/features/plugins/pages/memory_plugin_detail_page.dart';",
  );
  content = content.replaceAll(
    "import 'sticker_settings_page.dart';",
    "import '../../../../ui/features/plugins/pages/sticker_settings_page.dart';",
  );
  
  if (content != original) {
    file.writeAsStringSync(content);
    print('✓ 更新: settings_page.dart');
  }
}

/// 修复迁移后的 plugin 页面内部的 import
Future<void> _fixPluginPages() async {
  final files = [
    'lib/src/ui/features/plugins/pages/plugin_settings_page.dart',
    'lib/src/ui/features/plugins/pages/tts_plugin_detail_page.dart',
    'lib/src/ui/features/plugins/pages/tts_tool_detail_page.dart',
    'lib/src/ui/features/plugins/pages/memory_plugin_detail_page.dart',
    'lib/src/ui/features/plugins/pages/sticker_settings_page.dart',
  ];
  
  for (final filePath in files) {
    final file = File(filePath);
    if (!file.existsSync()) {
      print('⚠️  不存在: $filePath');
      continue;
    }
    
    var content = file.readAsStringSync();
    final original = content;
    
    // 修复数据层引用（features/plugins/）
    content = content.replaceAll(
      "import '../../../plugins/",
      "import '../../../../features/plugins/",
    );
    
    // 修复 settings 引用
    content = content.replaceAll(
      "import '../../../settings/",
      "import '../../../../features/settings/",
    );
    
    // 修复 chat data 引用
    content = content.replaceAll(
      "import '../../../chat/data/",
      "import '../../../../features/chat/data/",
    );
    content = content.replaceAll(
      "import '../../../chat/providers/",
      "import '../../../../features/chat/providers/",
    );
    
    // theme 和 shared 的路径通常已经是正确的（../../../../ui/...）
    // 但如果有相对引用，也要修复
    content = content.replaceAll(
      "import '../../data/",
      "import '../../../../features/plugins/data/",
    );
    
    if (content != original) {
      file.writeAsStringSync(content);
      print('✓ 更新: ${filePath.split('/').last}');
    }
  }
}
