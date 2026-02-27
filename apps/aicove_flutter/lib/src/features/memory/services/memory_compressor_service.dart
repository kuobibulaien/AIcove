import '../../chat/domain/message.dart';
import '../../../core/database/repositories/memory_repository.dart';

class MemoryCompressorService {
  final MemoryRepository _memoryRepository;

  MemoryCompressorService(this._memoryRepository);

  Future<void> evictIfNeeded(String conversationId) {
    return _memoryRepository.evictIfNeeded(conversationId);
  }

  Future<String> compressToL4(String originalContent) async {
    final lines = originalContent
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    String candidate = lines.isEmpty ? originalContent.trim() : lines.first;
    for (final line in lines) {
      if (line.startsWith('事件：')) {
        candidate = line.replaceFirst('事件：', '').trim();
        break;
      }
    }
    if (candidate.length > 36) {
      candidate = '${candidate.substring(0, 36)}...';
    }
    return candidate;
  }

  Future<String> reEnrich({
    required String compressedContent,
    required List<Message> recentMessages,
  }) async {
    final ctx = recentMessages
        .where((m) => m.content.trim().isNotEmpty)
        .take(3)
        .map((m) => '${m.role}: ${m.content}')
        .join('\n');
    return '''
【重新丰富】
事件：$compressedContent
聊天经过：$ctx
→ 当前状态：基于最近对话重新确认
'''
        .trim();
  }
}
