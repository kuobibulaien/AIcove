// ignore_for_file: avoid_print

import 'dart:io';

/// 修复 auto_reply 页面的 import 路径
/// 
/// 问题：页面迁移到 ui/features/auto_reply/pages/ 后，
/// 原有的相对路径 import 失效了
/// 
/// 解决：将相对路径改为正确的绝对路径

void main() async {
  print('🔧 修复 auto_reply 模块的 import 路径\n');
  
  final files = [
    'lib/src/ui/features/auto_reply/pages/auto_reply_settings_page.dart',
    'lib/src/ui/features/auto_reply/pages/auto_reply_trigger_list_page.dart',
  ];
  
  for (final filePath in files) {
    final file = File(filePath);
    if (!file.existsSync()) {
      print('⚠️  文件不存在: $filePath');
      continue;
    }
    
    var content = file.readAsStringSync();
    final originalContent = content;
    
    // 修复 import 路径
    // 数据层在 features/chat/data/
    content = content.replaceAll(
      "import '../../data/auto_reply_trigger.dart';",
      "import '../../../../features/chat/data/auto_reply_trigger.dart';",
    );
    content = content.replaceAll(
      "import '../../data/auto_reply_trigger_controller.dart';",
      "import '../../../../features/chat/data/auto_reply_trigger_controller.dart';",
    );
    content = content.replaceAll(
      "import '../../data/auto_reply_service.dart';",
      "import '../../../../features/chat/data/auto_reply_service.dart';",
    );
    
    // 组件层在 features/chat/presentation/widgets/
    content = content.replaceAll(
      "import '../widgets/auto_reply_trigger_form.dart';",
      "import '../../../../features/chat/presentation/widgets/auto_reply_trigger_form.dart';",
    );
    
    // settings 在 features/settings/
    content = content.replaceAll(
      "import '../../../settings/app_settings.dart';",
      "import '../../../../features/settings/app_settings.dart';",
    );
    
    // plugins 在 features/plugins/
    content = content.replaceAll(
      "import '../../../plugins/plugin_providers.dart';",
      "import '../../../../features/plugins/plugin_providers.dart';",
    );
    
    // theme 已经在 ui/theme/，路径是正确的
    // shared 已经在 ui/shared/，路径是正确的
    
    if (content != originalContent) {
      file.writeAsStringSync(content);
      print('✓ 更新: $filePath');
    } else {
      print('  跳过（无需修改）: $filePath');
    }
  }
  
  print('\n✅ 修复完成！运行 flutter analyze 验证');
}
