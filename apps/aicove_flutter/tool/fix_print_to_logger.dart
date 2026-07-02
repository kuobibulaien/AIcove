// ignore_for_file: avoid_print
import 'dart:io';

/// 批量将 print() 替换为 AppLogger 调用
///
/// 运行: dart run tool/fix_print_to_logger.dart

void main() async {
  final libDir = Directory('lib');
  if (!libDir.existsSync()) {
    print('Error: lib directory not found');
    return;
  }

  int totalFiles = 0;
  int totalReplacements = 0;

  await for (final entity in libDir.list(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      final result = await processFile(entity);
      if (result > 0) {
        totalFiles++;
        totalReplacements += result;
        print('✓ ${entity.path} - $result replacements');
      }
    }
  }

  print('\n=== Summary ===');
  print('Files modified: $totalFiles');
  print('Total replacements: $totalReplacements');
}

Future<int> processFile(File file) async {
  final content = await file.readAsString();
  
  // 跳过 app_logger.dart 自身和工具文件
  if (file.path.contains('app_logger.dart') || 
      file.path.contains('tool\\') ||
      file.path.contains('tool/')) {
    return 0;
  }

  // 检查是否有 print 调用
  if (!content.contains('print(')) {
    return 0;
  }

  // 提取文件名作为模块名
  final fileName = file.path.split(Platform.pathSeparator).last.replaceAll('.dart', '');
  final moduleName = _toModuleName(fileName);

  var newContent = content;
  int replacements = 0;

  // 正则匹配 print(...) 调用
  // 支持多种格式：print('...')、print("...")、print(variable)
  final printPattern = RegExp(
    r'''print\s*\(\s*(['"])(.*?)\1\s*\)''',
    dotAll: true,
  );
  
  // 匹配 print(变量) 或 print(表达式)
  final printExprPattern = RegExp(
    r'''print\s*\(\s*([^'"][^)]+)\s*\)''',
  );

  // 先处理字符串形式的 print
  newContent = newContent.replaceAllMapped(printPattern, (match) {
    replacements++;
    final message = match.group(2) ?? '';
    // 判断日志级别
    final level = _inferLogLevel(message);
    return "AppLogger.$level('$moduleName', '${_escapeString(message)}')";
  });

  // 处理表达式形式的 print（如 print(e) 或 print('Error: \$e')）
  newContent = newContent.replaceAllMapped(printExprPattern, (match) {
    replacements++;
    final expr = match.group(1)?.trim() ?? '';
    // 如果表达式是错误相关的，使用 error 级别
    final level = _inferLogLevelFromExpr(expr);
    // 对于变量形式，使用字符串插值
    return "AppLogger.$level('$moduleName', '\$$expr')";
  });

  if (replacements == 0) {
    return 0;
  }

  // 检查是否需要添加 import
  if (!newContent.contains("import") || 
      !newContent.contains('app_logger.dart')) {
    // 找到第一个 import 语句的位置
    final importMatch = RegExp(r"^import\s+'").firstMatch(newContent);
    if (importMatch != null) {
      final insertPos = importMatch.start;
      // 根据文件路径计算相对路径
      final relativePath = _calculateRelativePath(file.path);
      newContent = '${newContent.substring(0, insertPos)}import \'$relativePath\';\n${newContent.substring(insertPos)}';
    }
  }

  await file.writeAsString(newContent);
  return replacements;
}

String _toModuleName(String fileName) {
  // 将 snake_case 转换为 PascalCase
  return fileName
      .split('_')
      .map((part) => part.isEmpty ? '' : part[0].toUpperCase() + part.substring(1))
      .join('');
}

String _inferLogLevel(String message) {
  final lower = message.toLowerCase();
  if (lower.contains('error') || lower.contains('fail') || lower.contains('exception')) {
    return 'error';
  }
  if (lower.contains('warn') || lower.contains('warning')) {
    return 'warning';
  }
  if (lower.contains('debug') || lower.contains('trace')) {
    return 'debug';
  }
  return 'debug'; // 默认使用 debug 级别
}

String _inferLogLevelFromExpr(String expr) {
  final lower = expr.toLowerCase();
  if (lower.contains('error') || lower.contains('exception') || lower == 'e') {
    return 'error';
  }
  return 'debug';
}

String _escapeString(String s) {
  return s
      .replaceAll("'", "\\'")
      .replaceAll('\n', '\\n');
}

String _calculateRelativePath(String filePath) {
  // 计算从当前文件到 app_logger.dart 的相对路径
  final parts = filePath.replaceAll('\\', '/').split('/');
  final libIndex = parts.indexOf('lib');
  if (libIndex < 0) return "package:aicove_flutter/src/core/app_logger.dart";
  
  final depth = parts.length - libIndex - 2; // -2 for 'lib' and filename
  if (depth <= 0) {
    return "src/core/app_logger.dart";
  }
  return "${'../' * depth}core/app_logger.dart";
}
