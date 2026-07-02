// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as path;

/// 导入魅魔纳西妲角色卡到 AIcove 数据库
///
/// 使用方法：
/// ```bash
/// dart run tool/import_nahida_character.dart
/// ```
void main() async {
  print('🎭 开始导入魅魔纳西妲角色卡...\n');

  // 1. 读取角色卡文件
  final projectRoot = Directory.current.path;
  final characterCardPath = path.join(
    projectRoot,
    '参考素材',
    '角色卡与预设',
    '魅魔纳西妲_角色卡.json',
  );

  final characterCardFile = File(characterCardPath);
  if (!characterCardFile.existsSync()) {
    print('❌ 错误：找不到角色卡文件');
    print('   路径：$characterCardPath');
    print('   请确保文件存在');
    exit(1);
  }

  print('📄 读取角色卡文件：$characterCardPath');
  final characterCardJson = await characterCardFile.readAsString();
  final cardData = jsonDecode(characterCardJson) as Map<String, dynamic>;
  final data = cardData['data'] as Map<String, dynamic>;

  // 2. 提取角色信息
  final name = data['name'] as String;
  final description = data['description'] as String;
  final personality = data['personality'] as String;
  final scenario = data['scenario'] as String;
  final firstMessage = data['first_mes'] as String;
  final exampleMessages = data['mes_example'] as String;
  final fullPersona = (data['extensions'] as Map<String, dynamic>)['aicove_persona_full'] as String;

  print('✅ 角色信息：');
  print('   名称：$name');
  print('   描述：${description.substring(0, 50)}...');
  print('   人设长度：${fullPersona.length} 字符\n');

  // 3. 构建完整的 personaPrompt
  // 使用 PersonaPromptCodec 的格式
  final personaPrompt = fullPersona;

  print('📝 人设提示词已准备（${personaPrompt.length} 字符）\n');

  // 4. 显示导入预览
  print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  print('📋 导入预览');
  print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  print('角色名称：$name');
  print('简介：$description');
  print('性格：$personality');
  print('场景：$scenario');
  print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  print('\n第一条消息：');
  print(firstMessage);
  print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

  // 5. 生成 SQL 插入语句
  print('📦 生成 SQL 插入语句...\n');

  final escapedName = name.replaceAll("'", "''");
  final escapedPersona = personaPrompt.replaceAll("'", "''");
  final escapedFirstMessage = firstMessage.replaceAll("'", "''");
  final escapedDescription = description.replaceAll("'", "''");

  final sql = '''
-- 导入魅魔纳西妲角色卡
-- 生成时间：${DateTime.now().toIso8601String()}

INSERT INTO contacts (
  name,
  personaPrompt,
  category,
  isFavorite,
  createdAt,
  updatedAt
) VALUES (
  '$escapedName',
  '$escapedPersona',
  'AI角色',
  1,
  ${DateTime.now().millisecondsSinceEpoch},
  ${DateTime.now().millisecondsSinceEpoch}
);

-- 获取刚插入的角色 ID
-- SELECT last_insert_rowid() as contact_id;

-- 可选：创建初始对话
-- INSERT INTO conversations (
--   contactId,
--   title,
--   createdAt,
--   updatedAt
-- ) VALUES (
--   (SELECT last_insert_rowid()),
--   '与$escapedName的对话',
--   ${DateTime.now().millisecondsSinceEpoch},
--   ${DateTime.now().millisecondsSinceEpoch}
-- );
''';

  // 6. 保存 SQL 文件
  final sqlOutputPath = path.join(
    projectRoot,
    '参考素材',
    '角色卡与预设',
    'import_nahida.sql',
  );
  await File(sqlOutputPath).writeAsString(sql);
  print('✅ SQL 文件已保存：$sqlOutputPath\n');

  // 7. 生成 JSON 导入数据
  final importData = {
    'version': 1,
    'exportedAt': DateTime.now().toIso8601String(),
    'contacts': [
      {
        'name': name,
        'personaPrompt': personaPrompt,
        'category': 'AI角色',
        'isFavorite': true,
        'metadata': {
          'source': 'character_card_v2',
          'description': description,
          'personality': personality,
          'scenario': scenario,
          'firstMessage': firstMessage,
          'exampleMessages': exampleMessages,
        },
      },
    ],
  };

  final jsonOutputPath = path.join(
    projectRoot,
    '参考素材',
    '角色卡与预设',
    'nahida_import_data.json',
  );
  await File(jsonOutputPath).writeAsString(
    const JsonEncoder.withIndent('  ').convert(importData),
  );
  print('✅ JSON 导入数据已保存：$jsonOutputPath\n');

  // 8. 使用说明
  print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  print('📖 使用说明');
  print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  print('');
  print('方法 1：通过 SQL 导入（开发/测试）');
  print('  1. 找到你的 AIcove 数据库文件（通常在应用数据目录）');
  print('  2. 使用 SQLite 工具执行生成的 SQL 文件：');
  print('     sqlite3 aicove.db < $sqlOutputPath');
  print('');
  print('方法 2：通过 App UI 导入（推荐）');
  print('  1. 打开 AIcove App');
  print('  2. 进入角色管理页面');
  print('  3. 点击"导入角色"');
  print('  4. 选择原始角色卡文件：');
  print('     $characterCardPath');
  print('');
  print('方法 3：通过代码导入');
  print('  使用 ConversationImporter 或直接操作数据库');
  print('  参考 nahida_import_data.json 中的数据结构');
  print('');
  print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  print('');
  print('✨ 导入准备完成！');
  print('');
  print('💡 提示：');
  print('   - 记得配置角色头像（可以使用 ComfyUI_01143_.png）');
  print('   - 建议同时导入"双人成行"预设以获得最佳体验');
  print('   - 查看 使用指南.md 了解更多配置选项');
  print('');
}
