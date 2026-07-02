// ignore_for_file: avoid_print

import 'dart:io';

/// 修复 home 模块迁移后的 import 路径

void main() async {
  print('🔧 修复 home 模块的 import 路径\n');
  
  await _fixHomePages();
  
  print('\n✅ 修复完成！运行 flutter analyze 验证');
}

/// 修复迁移后的 home 页面内部的 import
Future<void> _fixHomePages() async {
  final files = [
    'lib/src/ui/features/home/pages/main_page.dart',
    'lib/src/ui/features/home/pages/contacts_page.dart',
  ];
  
  for (final filePath in files) {
    final file = File(filePath);
    if (!file.existsSync()) {
      print('⚠️  不存在: $filePath');
      continue;
    }
    
    var content = file.readAsStringSync();
    final original = content;
    
    // 修复 chat providers 引用
    content = content.replaceAll(
      "import '../../providers2.dart';",
      "import '../../../../features/chat/providers2.dart';",
    );
    
    // 修复 widgets 引用（chat/presentation/widgets/）
    content = content.replaceAll(
      "import 'package:aicove_flutter/src/features/chat/presentation/widgets/",
      "import '../../../../features/chat/presentation/widgets/",
    );
    content = content.replaceAll(
      "import '../widgets/",
      "import '../../../../features/chat/presentation/widgets/",
    );
    
    // 修复同级页面引用（main_page 和 contacts_page 引用内容）
    // main_page 引用 contacts_page 和 role_card_page（已迁移到 ui/features/character/）
    content = content.replaceAll(
      "import 'contacts_page.dart';",
      "import 'contacts_page.dart';", // 同目录，不需要改
    );
    
    // role_card_page 已迁移到 ui/features/character/pages/
    // 路径已经正确（由之前的character迁移处理），不需要修改
    
    // profile_page 已迁移到 ui/features/settings/pages/
    // 路径已经正确（由之前的settings迁移处理），不需要修改
    
    if (content != original) {
      file.writeAsStringSync(content);
      print('✓ 更新: ${filePath.split('/').last}');
    }
  }
}
