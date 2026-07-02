// ignore_for_file: avoid_print

import 'dart:io';

/// 批量修复 withOpacity 的 deprecation warnings
/// 将 .withOpacity(x) 替换为 .withValues(alpha: x)

void main() async {
  print('🔧 开始修复 withOpacity deprecation warnings\n');
  
  final libDir = Directory('lib/src');
  if (!libDir.existsSync()) {
    print('❌ 错误：请在 aicove_flutter 目录下运行此脚本');
    exit(1);
  }
  
  int filesProcessed = 0;
  int replacementsCount = 0;
  
  await for (final file in libDir.list(recursive: true)) {
    if (file is File && file.path.endsWith('.dart')) {
      final result = await _processFile(file);
      if (result > 0) {
        filesProcessed++;
        replacementsCount += result;
        print('✓ ${file.path.split('lib/src/').last}: $result 处替换');
      }
    }
  }
  
  print('\n✅ 修复完成！');
  print('📊 处理了 $filesProcessed 个文件，共 $replacementsCount 处替换');
  print('🔍 运行 flutter analyze 验证');
}

Future<int> _processFile(File file) async {
  var content = await file.readAsString();
  final original = content;
  int count = 0;
  
  // 改进正则：匹配 .withOpacity(任意内容)
  // 注意：这可能会误伤嵌套括号，但在这个项目中应该很少见
  final pattern = RegExp(r'\.withOpacity\(([^)]+)\)');
  
  content = content.replaceAllMapped(pattern, (match) {
    count++;
    final content = match.group(1);
    return '.withValues(alpha: $content)';
  });
  
  if (content != original) {
    await file.writeAsString(content);
  }
  
  return count;
}
