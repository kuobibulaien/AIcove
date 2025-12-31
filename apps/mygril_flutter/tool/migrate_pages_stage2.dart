// ignore_for_file: avoid_print

import 'dart:io';

/// 第二阶段迁移：页面分组迁移
/// features/chat/presentation/pages/ → ui/features/*/pages/
/// 
/// 使用方法：dart run tool/migrate_pages_stage2.dart [module]
/// 
/// 支持的模块：
/// - auto_reply  (2个文件，风险低)
/// - plugins     (5个文件，风险低)
/// - settings    (9个文件，风险中)
/// - character   (4个文件，风险中)
/// - chat        (2个文件，风险高)
/// - home        (2个文件，风险高)
/// - all         (全部迁移，谨慎使用)

void main(List<String> args) async {
  final libDir = Directory('lib/src');
  
  if (!libDir.existsSync()) {
    print('❌ 错误：请在 mygril_flutter 目录下运行此脚本');
    exit(1);
  }
  
  // 解析参数
  final module = args.isEmpty ? 'auto_reply' : args[0];
  
  print('🚀 开始第二阶段迁移：页面分组 → ui/features/\n');
  print('📦 目标模块: $module\n');
  
  // 执行迁移
  await migrateModule(module);
  
  print('\n✅ 迁移完成！');
  print('📋 下一步：');
  print('   1. flutter analyze');
  print('   2. flutter run --device-id 2211133C');
  print('   3. git add . && git commit -m "迁移 $module 模块到 ui/features"');
}

/// 迁移指定模块
Future<void> migrateModule(String module) async {
  final migrations = getModuleMigrations(module);
  
  if (migrations.isEmpty) {
    print('❌ 未知模块: $module');
    print('支持的模块: auto_reply, plugins, settings, character, chat, home, all');
    exit(1);
  }
  
  // 第1步：移动文件
  print('📦 第1步：移动页面文件');
  await movePages(migrations);
  
  // 第2步：更新 import 路径
  print('\n🔧 第2步：更新 import 路径');
  await updateImports(migrations);
}

/// 获取模块的迁移映射
Map<String, String> getModuleMigrations(String module) {
  final all = <String, String>{};
  
  // 1. auto_reply 模块 (2个文件，风险低)
  final autoReply = {
    'lib/src/features/chat/presentation/pages/auto_reply_settings_page.dart':
        'lib/src/ui/features/auto_reply/pages/auto_reply_settings_page.dart',
    'lib/src/features/chat/presentation/pages/auto_reply_trigger_list_page.dart':
        'lib/src/ui/features/auto_reply/pages/auto_reply_trigger_list_page.dart',
  };
  
  // 2. plugins 模块 (5个文件，风险低)
  final plugins = {
    'lib/src/features/chat/presentation/pages/plugin_settings_page.dart':
        'lib/src/ui/features/plugins/pages/plugin_settings_page.dart',
    'lib/src/features/chat/presentation/pages/tts_plugin_detail_page.dart':
        'lib/src/ui/features/plugins/pages/tts_plugin_detail_page.dart',
    'lib/src/features/chat/presentation/pages/tts_tool_detail_page.dart':
        'lib/src/ui/features/plugins/pages/tts_tool_detail_page.dart',
    'lib/src/features/chat/presentation/pages/memory_plugin_detail_page.dart':
        'lib/src/ui/features/plugins/pages/memory_plugin_detail_page.dart',
    'lib/src/features/chat/presentation/pages/sticker_settings_page.dart':
        'lib/src/ui/features/plugins/pages/sticker_settings_page.dart',
  };
  
  // 3. settings 模块 (9个文件，风险中)
  final settings = {
    'lib/src/features/chat/presentation/pages/settings_page.dart':
        'lib/src/ui/features/settings/pages/settings_page.dart',
    'lib/src/features/chat/presentation/pages/ui_settings_page.dart':
        'lib/src/ui/features/settings/pages/ui_settings_page.dart',
    'lib/src/features/chat/presentation/pages/model_list_page.dart':
        'lib/src/ui/features/settings/pages/model_list_page.dart',
    'lib/src/features/chat/presentation/pages/provider_selector_page.dart':
        'lib/src/ui/features/settings/pages/provider_selector_page.dart',
    'lib/src/features/chat/presentation/pages/import_model_dialog.dart':
        'lib/src/ui/features/settings/pages/import_model_dialog.dart',
    'lib/src/features/chat/presentation/pages/message_format_settings_page.dart':
        'lib/src/ui/features/settings/pages/message_format_settings_page.dart',
    'lib/src/features/chat/presentation/pages/chunk_settings_page.dart':
        'lib/src/ui/features/settings/pages/chunk_settings_page.dart',
    'lib/src/features/chat/presentation/pages/log_viewer_page.dart':
        'lib/src/ui/features/settings/pages/log_viewer_page.dart',
    'lib/src/features/chat/presentation/pages/profile_page.dart':
        'lib/src/ui/features/settings/pages/profile_page.dart',
  };
  
  // 4. character 模块 (4个文件，风险中)
  final character = {
    'lib/src/features/chat/presentation/pages/role_card_page.dart':
        'lib/src/ui/features/character/pages/role_card_page.dart',
    'lib/src/features/chat/presentation/pages/character_detail_page.dart':
        'lib/src/ui/features/character/pages/character_detail_page.dart',
    'lib/src/features/chat/presentation/pages/contact_edit_page.dart':
        'lib/src/ui/features/character/pages/contact_edit_page.dart',
    'lib/src/features/chat/presentation/pages/favorites_page.dart':
        'lib/src/ui/features/character/pages/favorites_page.dart',
  };
  
  // 5. chat 模块 (2个文件，风险高)
  final chat = {
    'lib/src/features/chat/presentation/pages/chat_page.dart':
        'lib/src/ui/features/chat/pages/chat_page.dart',
    'lib/src/features/chat/presentation/pages/split_chat_page.dart':
        'lib/src/ui/features/chat/pages/split_chat_page.dart',
  };
  
  // 6. home 模块 (2个文件，风险高)
  final home = {
    'lib/src/features/chat/presentation/pages/main_page.dart':
        'lib/src/ui/features/home/pages/main_page.dart',
    'lib/src/features/chat/presentation/pages/contacts_page.dart':
        'lib/src/ui/features/home/pages/contacts_page.dart',
  };
  
  // 组合所有模块
  all.addAll(autoReply);
  all.addAll(plugins);
  all.addAll(settings);
  all.addAll(character);
  all.addAll(chat);
  all.addAll(home);
  
  // 根据参数返回对应模块
  switch (module) {
    case 'auto_reply':
      return autoReply;
    case 'plugins':
      return plugins;
    case 'settings':
      return settings;
    case 'character':
      return character;
    case 'chat':
      return chat;
    case 'home':
      return home;
    case 'all':
      return all;
    default:
      return {};
  }
}

/// 移动页面文件
Future<void> movePages(Map<String, String> migrations) async {
  int movedCount = 0;
  
  for (final entry in migrations.entries) {
    final sourceFile = File(entry.key);
    final targetPath = entry.value;
    final targetFile = File(targetPath);
    
    if (sourceFile.existsSync()) {
      // 创建目标目录
      final targetDir = targetFile.parent;
      if (!targetDir.existsSync()) {
        targetDir.createSync(recursive: true);
      }
      
      // 复制文件
      sourceFile.copySync(targetPath);
      sourceFile.deleteSync();
      
      movedCount++;
      print('  ✓ ${sourceFile.path.split('/').last} → ${targetDir.path}');
    } else {
      print('  ⚠️ 文件不存在: ${entry.key}');
    }
  }
  
  print('  📊 移动了 $movedCount 个文件');
}

/// 更新 import 路径
Future<void> updateImports(Map<String, String> migrations) async {
  final libDir = Directory('lib');
  int updateCount = 0;
  
  // 构建替换规则（去掉 lib/src/ 前缀）
  final replacements = <String, String>{};
  for (final entry in migrations.entries) {
    final oldImport = entry.key.replaceFirst('lib/src/', '');
    final newImport = entry.value.replaceFirst('lib/src/', '');
    replacements[oldImport] = newImport;
  }
  
  // 遍历所有 dart 文件
  await for (final entity in libDir.list(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      final content = entity.readAsStringSync();
      var newContent = content;
      var modified = false;
      
      // 替换所有匹配的 import
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
