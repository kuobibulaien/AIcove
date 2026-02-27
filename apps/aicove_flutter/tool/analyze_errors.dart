// ignore_for_file: avoid_print

import 'dart:io';

/// 分析剩余的 error 并输出到文件

void main() async {
  print('🔍 正在分析...');
  
  final result = await Process.run(
    'flutter',
    ['analyze', '--no-fatal-infos', '--no-fatal-warnings'],
    workingDirectory: '.',
    runInShell: true,
  );
  
  final output = result.stdout.toString() + result.stderr.toString();
  final lines = output.split('\n');
  
  final sb = StringBuffer();
  sb.writeln('=== ERROR 列表 ===\n');
  
  int count = 0;
  for (final line in lines) {
    if (line.contains(' error ') && line.contains(' - ')) {
      count++;
      sb.writeln('[$count] $line');
    }
  }
  
  sb.writeln('\n总计: $count 个 error');
  
  // 分类统计
  final preExisting = <String>[];
  final migration = <String>[];
  
  for (final line in lines) {
    if (line.contains(' error ') && line.contains(' - ')) {
      if (line.contains('BlurredBackground') || 
          line.contains('RoleTransitionTags') ||
          line.contains('blurredBackground') ||
          line.contains('database_converters') ||
          line.contains('isDark')) {
        preExisting.add(line);
      } else {
        migration.add(line);
      }
    }
  }
  
  sb.writeln('\n=== 分类 ===');
  sb.writeln('迁移前就存在: ${preExisting.length}');
  sb.writeln('可能与迁移相关: ${migration.length}');
  
  if (migration.isNotEmpty) {
    sb.writeln('\n=== 需要修复 ===');
    for (final e in migration) {
      sb.writeln(e);
    }
  }
  
  File('error_report.txt').writeAsStringSync(sb.toString());
  print('✅ 报告已写入 error_report.txt');
}
