// ignore_for_file: avoid_print

import 'dart:io';

/// 修复 settings 模块迁移后的 import 路径

void main() async {
  print('🔧 修复 settings 模块的 import 路径\n');
  
  await _fixSettingsPages();
  
  print('\n✅ 修复完成！运行 flutter analyze 验证');
}

/// 修复迁移后的 settings 页面内部的 import
Future<void> _fixSettingsPages() async {
  final files = [
    'lib/src/ui/features/settings/pages/settings_page.dart',
    'lib/src/ui/features/settings/pages/ui_settings_page.dart',
    'lib/src/ui/features/settings/pages/model_list_page.dart',
    'lib/src/ui/features/settings/pages/provider_selector_page.dart',
    'lib/src/ui/features/settings/pages/import_model_dialog.dart',
    'lib/src/ui/features/settings/pages/message_format_settings_page.dart',
    'lib/src/ui/features/settings/pages/chunk_settings_page.dart',
    'lib/src/ui/features/settings/pages/log_viewer_page.dart',
    'lib/src/ui/features/settings/pages/profile_page.dart',
  ];
  
  for (final filePath in files) {
    final file = File(filePath);
    if (!file.existsSync()) {
      print('⚠️  不存在: $filePath');
      continue;
    }
    
    var content = file.readAsStringSync();
    final original = content;
    
    // 修复 settings 数据层引用
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
    
    // 修复 plugins 引用
    content = content.replaceAll(
      "import '../../../plugins/",
      "import '../../../../features/plugins/",
    );
    
    // 修复同级页面引用（settings内部互相引用）
    // 例如：settings_page.dart 引用 ui_settings_page.dart
    // 从 'import ui_settings_page.dart' 改为完整路径不需要，因为它们在同一目录
    
    // 修复已经迁移的页面引用
    // auto_reply 和 plugins 已经迁移到 ui/features/
    content = content.replaceAll(
      "import '../../../../ui/features/auto_reply/pages/auto_reply_settings_page.dart';",
      "import '../../../auto_reply/pages/auto_reply_settings_page.dart';",
    );
    content = content.replaceAll(
      "import '../../../../ui/features/plugins/pages/",
      "import '../../../plugins/pages/",
    );
    
    if (content != original) {
      file.writeAsStringSync(content);
      print('✓ 更新: ${filePath.split('/').last}');
    }
  }
}
