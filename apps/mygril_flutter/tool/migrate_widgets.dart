// ignore_for_file: avoid_print

import 'dart:io';

/// 第二批迁移：core/widgets → ui/shared
/// 
/// 使用方法：dart run tool/migrate_widgets.dart

void main() async {
  final libDir = Directory('lib/src');
  
  if (!libDir.existsSync()) {
    print('❌ 错误：请在 aicove_flutter 目录下运行此脚本');
    exit(1);
  }
  
  print('🚀 开始第二批迁移：widgets → ui/shared\n');
  
  // 分类移动 widgets
  print('📦 第1步：分类移动 widgets');
  await moveWidgets();
  
  // 更新 import 路径
  print('\n🔧 第2步：更新 import 路径');
  await updateImports();
  
  print('\n✅ 迁移完成！请运行 flutter analyze 验证');
}

/// 移动 widgets，按类型分到不同目录
Future<void> moveWidgets() async {
  final sourceDir = Directory('lib/src/core/widgets');
  
  if (!sourceDir.existsSync()) {
    print('  ⚠️ 源目录不存在');
    return;
  }
  
  // 定义文件分类
  // widgets/ → 普通组件
  // effects/ → 视觉效果（毛玻璃、渐变等）
  // animations/ → 动画相关
  final mapping = {
    // UI 组件 → widgets/
    'moe_app_bar.dart': 'lib/src/ui/shared/widgets/',
    'moe_toast.dart': 'lib/src/ui/shared/widgets/',
    'meotalk_dialog.dart': 'lib/src/ui/shared/widgets/',
    'image_crop_dialog.dart': 'lib/src/ui/shared/widgets/',
    'settings_drawer_panel.dart': 'lib/src/ui/shared/widgets/',
    'settings_drawer_wrapper.dart': 'lib/src/ui/shared/widgets/',
    
    // 视觉效果 → effects/
    'frosted_glass_card.dart': 'lib/src/ui/shared/effects/',
    'gradient_blur_card.dart': 'lib/src/ui/shared/effects/',
    'smooth_clip.dart': 'lib/src/ui/shared/effects/',
    'role_background_hero.dart': 'lib/src/ui/shared/effects/',
    
    // 动画 → animations/
    'expanding_page_route.dart': 'lib/src/ui/shared/animations/',
    'parallax_slide_page_route.dart': 'lib/src/ui/shared/animations/',
  };
  
  for (final entry in mapping.entries) {
    final sourceFile = File('${sourceDir.path}/${entry.key}');
    final targetDir = Directory(entry.value);
    
    if (sourceFile.existsSync()) {
      if (!targetDir.existsSync()) {
        targetDir.createSync(recursive: true);
      }
      
      final targetPath = '${entry.value}${entry.key}';
      sourceFile.copySync(targetPath);
      sourceFile.deleteSync();
      print('  ✓ ${entry.key} → ${entry.value}');
    }
  }
  
  // 删除空的源目录
  if (sourceDir.listSync().isEmpty) {
    sourceDir.deleteSync();
    print('  ✓ 删除空目录: core/widgets/');
  }
}

/// 更新 import 路径
Future<void> updateImports() async {
  final libDir = Directory('lib');
  int updateCount = 0;
  
  // 定义替换规则
  final replacements = <String, String>{
    // widgets 组件
    'core/widgets/moe_app_bar.dart': 'ui/shared/widgets/moe_app_bar.dart',
    'core/widgets/moe_toast.dart': 'ui/shared/widgets/moe_toast.dart',
    'core/widgets/meotalk_dialog.dart': 'ui/shared/widgets/meotalk_dialog.dart',
    'core/widgets/image_crop_dialog.dart': 'ui/shared/widgets/image_crop_dialog.dart',
    'core/widgets/settings_drawer_panel.dart': 'ui/shared/widgets/settings_drawer_panel.dart',
    'core/widgets/settings_drawer_wrapper.dart': 'ui/shared/widgets/settings_drawer_wrapper.dart',
    
    // effects 组件
    'core/widgets/frosted_glass_card.dart': 'ui/shared/effects/frosted_glass_card.dart',
    'core/widgets/gradient_blur_card.dart': 'ui/shared/effects/gradient_blur_card.dart',
    'core/widgets/smooth_clip.dart': 'ui/shared/effects/smooth_clip.dart',
    'core/widgets/role_background_hero.dart': 'ui/shared/effects/role_background_hero.dart',
    
    // animations 组件
    'core/widgets/expanding_page_route.dart': 'ui/shared/animations/expanding_page_route.dart',
    'core/widgets/parallax_slide_page_route.dart': 'ui/shared/animations/parallax_slide_page_route.dart',
  };
  
  await for (final entity in libDir.list(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      final content = entity.readAsStringSync();
      var newContent = content;
      var modified = false;
      
      for (final entry in replacements.entries) {
        if (newContent.contains(entry.key)) {
          newContent = newContent.replaceAll(entry.key, entry.value);
          modified = true;
        }
      }
      
      if (modified) {
        entity.writeAsStringSync(newContent);
        updateCount++;
        print('  ✓ 更新: ${entity.path}');
      }
    }
  }
  
  print('  📊 更新了 $updateCount 个文件');
}
