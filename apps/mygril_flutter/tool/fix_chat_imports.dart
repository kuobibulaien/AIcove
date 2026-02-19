// ignore_for_file: avoid_print

import 'dart:io';

/// 修复 chat 模块迁移后的 import 路径

void main() async {
  print('🔧 修复 chat 模块的 import 路径\n');
  
  await _fixChatPages();
  
  print('\n✅ 修复完成！运行 flutter analyze 验证');
}

/// 修复迁移后的 chat 页面内部的 import
Future<void> _fixChatPages() async {
  final files = [
    'lib/src/ui/features/chat/pages/chat_page.dart',
    'lib/src/ui/features/chat/pages/split_chat_page.dart',
  ];
  
  for (final filePath in files) {
    final file = File(filePath);
    if (!file.existsSync()) {
      print('⚠️  不存在: $filePath');
      continue;
    }
    
    var content = file.readAsStringSync();
    final original = content;
    
    // 修复 chat data/domain/providers 引用
    content = content.replaceAll(
      "import '../../providers2.dart';",
      "import '../../../../features/chat/providers2.dart';",
    );
    content = content.replaceAll(
      "import '../../domain/",
      "import '../../../../features/chat/domain/",
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
    
    // 修复 settings 引用
    content = content.replaceAll(
      "import '../../../settings/",
      "import '../../../../features/settings/",
    );
    
    // 修复同级页面引用（chat_page.dart）
    content = content.replaceAll(
      "import 'chat_page.dart';",
      "import 'chat_page.dart';", // 同目录，不需要改
    );
    
    // 修复已迁移到ui/features/的页面引用
    // character页面已在ui/features/character/下
    // 路径已经正确，不需要修改
    
    if (content != original) {
      file.writeAsStringSync(content);
      print('✓ 更新: ${filePath.split('/').last}');
    }
  }
}
