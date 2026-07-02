// ignore_for_file: avoid_print

import 'dart:io';

/// 目录结构迁移脚本
/// 
/// 使用方法：在 aicove_flutter 目录下运行
/// dart run tool/migrate_structure.dart
/// 
/// 功能：
/// 1. 创建新的 ui/ 目录结构
/// 2. 移动 theme 到 ui/theme
/// 3. 更新所有 import 路径

void main() async {
  final libDir = Directory('lib/src');
  
  if (!libDir.existsSync()) {
    print('❌ 错误：请在 aicove_flutter 目录下运行此脚本');
    exit(1);
  }
  
  print('🚀 开始目录结构迁移...\n');
  
  // 第一步：创建新目录结构
  print('📁 第1步：创建 ui/ 目录结构');
  await createDirectories();
  
  // 第二步：移动 theme
  print('\n📦 第2步：移动 theme 到 ui/theme');
  await moveTheme();
  
  // 第三步：更新 import 路径
  print('\n🔧 第3步：更新 import 路径');
  await updateImports();
  
  print('\n✅ 迁移完成！请运行 flutter analyze 验证');
}

/// 创建新目录结构
Future<void> createDirectories() async {
  final dirs = [
    'lib/src/ui/theme/skins',
    'lib/src/ui/shared/widgets',
    'lib/src/ui/shared/animations',
    'lib/src/ui/shared/effects',
    'lib/src/ui/features/chat/pages',
    'lib/src/ui/features/chat/widgets',
    'lib/src/ui/features/character/pages',
    'lib/src/ui/features/character/widgets',
    'lib/src/ui/features/settings/pages',
    'lib/src/ui/features/settings/widgets',
    'lib/src/ui/features/auto_reply/pages',
    'lib/src/ui/features/plugins/pages',
    'lib/src/ui/features/home/pages',
  ];
  
  for (final dir in dirs) {
    final d = Directory(dir);
    if (!d.existsSync()) {
      d.createSync(recursive: true);
      print('  ✓ 创建: $dir');
    }
  }
}

/// 移动 theme 目录
Future<void> moveTheme() async {
  final sourceDir = Directory('lib/src/core/theme');
  final targetDir = Directory('lib/src/ui/theme');
  
  if (!sourceDir.existsSync()) {
    print('  ⚠️ 源目录不存在: ${sourceDir.path}');
    return;
  }
  
  // 复制所有文件
  await copyDirectory(sourceDir, targetDir);
  
  // 删除源目录
  sourceDir.deleteSync(recursive: true);
  print('  ✓ theme 迁移完成');
}

/// 递归复制目录
Future<void> copyDirectory(Directory source, Directory target) async {
  if (!target.existsSync()) {
    target.createSync(recursive: true);
  }
  
  await for (final entity in source.list(recursive: false)) {
    final targetPath = '${target.path}/${entity.uri.pathSegments.last}';
    
    if (entity is Directory) {
      await copyDirectory(entity, Directory(targetPath));
    } else if (entity is File) {
      entity.copySync(targetPath);
      print('  ✓ 复制: ${entity.path} -> $targetPath');
    }
  }
}

/// 更新所有 import 路径
Future<void> updateImports() async {
  final libDir = Directory('lib');
  int fileCount = 0;
  int updateCount = 0;
  
  // 定义替换规则
  final replacements = <String, String>{
    // theme 路径替换
    "core/theme/tokens.dart": "ui/theme/tokens.dart",
    "core/theme/skin_config.dart": "ui/theme/skin_config.dart",
    "core/theme/skin_provider.dart": "ui/theme/skin_provider.dart",
    "core/theme/skins/moetalk_skin.dart": "ui/theme/skins/moetalk_skin.dart",
    
    // 相对路径替换（core/widgets 引用 theme）
    "../theme/tokens.dart": "../../ui/theme/tokens.dart",
    "../theme/skin_config.dart": "../../ui/theme/skin_config.dart",
    "../theme/skin_provider.dart": "../../ui/theme/skin_provider.dart",
  };
  
  await for (final entity in libDir.list(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      fileCount++;
      
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
  
  print('  📊 扫描 $fileCount 个文件，更新 $updateCount 个文件');
}
