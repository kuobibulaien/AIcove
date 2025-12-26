/// 记忆时间格式化工具
///
/// 输出格式：n天前的对话摘要"..."
/// 规则：
/// - <1天：今天
/// - 1~29天：{d}天前
/// - 30~364天：{floor(d/30)}个月前
/// - >=365天：{floor(d/365)}年前
class MemoryTimeFormatter {
  /// 格式化记忆为带时间戳的字符串
  /// 输出：`n天前的对话摘要"内容"`
  static String format(DateTime createdAt, String content) {
    final prefix = _formatTimePrefix(createdAt);
    return '$prefix的对话摘要"$content"';
  }

  /// 格式化时间前缀
  static String _formatTimePrefix(DateTime createdAt) {
    final now = DateTime.now();
    final diff = now.difference(createdAt);
    final days = diff.inDays;

    if (days < 1) {
      return '今天';
    } else if (days < 30) {
      return '$days天前';
    } else if (days < 365) {
      final months = days ~/ 30;
      return '$months个月前';
    } else {
      final years = days ~/ 365;
      return '$years年前';
    }
  }

  /// 仅获取时间前缀（不含内容）
  static String getTimePrefix(DateTime createdAt) {
    return _formatTimePrefix(createdAt);
  }
}
