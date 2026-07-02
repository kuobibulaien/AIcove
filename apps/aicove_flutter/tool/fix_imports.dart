// ignore_for_file: avoid_print

import 'dart:io';

/// 全面修复 ui/shared 下的所有 import 路径问题

void main() async {
  print('🔧 全面修复 import 路径...\n');
  
  final files = {
    // widgets 目录下的文件
    'lib/src/ui/shared/widgets/settings_drawer_panel.dart': {
      "../theme/tokens.dart": "../../theme/tokens.dart",
      "../../features/chat/presentation/pages/settings_page.dart": 
          "../../../features/chat/presentation/pages/settings_page.dart",
    },
    'lib/src/ui/shared/widgets/moe_app_bar.dart': {
      "../theme/skin_provider.dart": "../../theme/skin_provider.dart",
      "../theme/tokens.dart": "../../theme/tokens.dart",
    },
    'lib/src/ui/shared/widgets/moe_toast.dart': {
      "../theme/skin_provider.dart": "../../theme/skin_provider.dart",
    },
    'lib/src/ui/shared/widgets/meotalk_dialog.dart': {
      "../theme/tokens.dart": "../../theme/tokens.dart",
    },
    'lib/src/ui/shared/widgets/image_crop_dialog.dart': {
      "../theme/tokens.dart": "../../theme/tokens.dart",
    },
    // effects 目录下的文件
    'lib/src/ui/shared/effects/gradient_blur_card.dart': {
      "../theme/tokens.dart": "../../theme/tokens.dart",
    },
    'lib/src/ui/shared/effects/frosted_glass_card.dart': {
      "../theme/tokens.dart": "../../theme/tokens.dart",
    },
    'lib/src/ui/shared/effects/role_background_hero.dart': {
      "../utils/role_transition_tags.dart": "../../../core/utils/role_transition_tags.dart",
      "../utils/blurred_background_cache.dart": "../../../core/utils/blurred_background_cache.dart",
    },
  };
  
  int fixCount = 0;
  
  for (final entry in files.entries) {
    final file = File(entry.key);
    if (!file.existsSync()) {
      print('  ⚠️ 文件不存在: ${entry.key}');
      continue;
    }
    
    var content = file.readAsStringSync();
    var modified = false;
    
    for (final replacement in entry.value.entries) {
      if (content.contains(replacement.key)) {
        content = content.replaceAll(replacement.key, replacement.value);
        modified = true;
      }
    }
    
    if (modified) {
      file.writeAsStringSync(content);
      fixCount++;
      print('  ✓ 修复: ${entry.key}');
    }
  }
  
  print('\n📊 修复了 $fixCount 个文件');
  print('✅ 完成！');
}
