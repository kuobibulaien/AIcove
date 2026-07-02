// ignore_for_file: avoid_print

import 'dart:io';

/// 修复 character 模块迁移后的 import 路径

void main() async {
  print('🔧 修复 character 模块的 import 路径\n');
  
  // 1. 修复其他页面对 character 页面的引用
  await _fixExternalReferences();
  
  // 2. 修复 character 页面内部的 import
  await _fixCharacterPages();
  
  print('\n✅ 修复完成！运行 flutter analyze 验证');
}

/// 修复外部页面对 character 页面的引用
Future<void> _fixExternalReferences() async {
  print('修复外部引用:');
  
  final files = [
    'lib/src/features/chat/presentation/pages/main_page.dart',
    'lib/src/features/chat/presentation/pages/split_chat_page.dart',
  ];
  
  for (final filePath in files) {
    final file = File(filePath);
    if (!file.existsSync()) {
      print('  ⚠️  不存在: $filePath');
      continue;
    }
    
    var content = file.readAsStringSync();
    final original = content;
    
    // 修复 role_card_page 引用
    content = content.replaceAll(
      "import 'role_card_page.dart';",
      "import '../../../../ui/features/character/pages/role_card_page.dart';",
    );
    
    if (content != original) {
      file.writeAsStringSync(content);
      print('  ✓ 更新: ${filePath.split('/').last}');
    }
  }
}

/// 修复迁移后的 character 页面内部的 import
Future<void> _fixCharacterPages() async {
  print('\n修复 character 页面内部:');
  
  final files = [
    'lib/src/ui/features/character/pages/role_card_page.dart',
    'lib/src/ui/features/character/pages/character_detail_page.dart',
    'lib/src/ui/features/character/pages/contact_edit_page.dart',
    'lib/src/ui/features/character/pages/favorites_page.dart',
  ];
  
  for (final filePath in files) {
    final file = File(filePath);
    if (!file.existsSync()) {
      print('  ⚠️  不存在: $filePath');
      continue;
    }
    
    var content = file.readAsStringSync();
    final original = content;
    
    // 修复 chat data/providers 引用
    content = content.replaceAll(
      "import '../../../chat/data/",
      "import '../../../../features/chat/data/",
    );
    content = content.replaceAll(
      "import '../../../chat/providers/",
      "import '../../../../features/chat/providers/",
    );
    content = content.replaceAll(
      "import '../../../chat/domain/",
      "import '../../../../features/chat/domain/",
    );
    
    // 修复 settings 引用
    content = content.replaceAll(
      "import '../../../settings/",
      "import '../../../../features/settings/",
    );
    
    // 修复 character data 引用
    content = content.replaceAll(
      "import '../../data/",
      "import '../../../../features/chat/data/",
    );
    content = content.replaceAll(
      "import '../../domain/",
      "import '../../../../features/chat/domain/",
    );
    
    // 同级页面引用保持不变（character_detail_page.dart 等）
    
    if (content != original) {
      file.writeAsStringSync(content);
      print('  ✓ 更新: ${filePath.split('/').last}');
    }
  }
}
