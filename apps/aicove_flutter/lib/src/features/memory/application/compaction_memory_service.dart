import '../domain/compaction_memory.dart';
import '../domain/contact_memory_port.dart';
import '../../../core/app_logger.dart';

class CompactionMemoryService implements CompactionMemoryPort {
  CompactionMemoryService({
    required this.memory,
    required this.queue,
    required this.allowed,
  });
  final ContactMemoryPort memory;
  final CompactionMemoryQueuePort queue;
  final Future<bool> Function(String owner) allowed;
  final _running = <String, Future<bool>>{};

  @override
  Future<ContactMemoryNotebook?> prepare(String owner) async {
    try {
      if (!await allowed(owner)) return null;
      await flush(owner);
      final notebook = await memory.load(owner);
      return notebook.enabled ? notebook : null;
    } catch (_) {
      // 记忆不可读不阻止上下文压缩；禁止盲写损坏或未知版本的文件。
      return null;
    }
  }

  @override
  Future<bool> flush(String owner) =>
      _running[owner] ??= _flush(owner).whenComplete(() {
        _running.remove(owner);
      });

  Future<bool> _flush(String owner) async {
    try {
      if (!await allowed(owner)) return false;
      for (final job in await queue.pending(owner)) {
        if (!await queue.sourcesValid(job.id)) {
          await queue.finish(job.id, discarded: true);
          continue;
        }
        var completed = false;
        for (var attempt = 0; attempt < 3 && !completed; attempt++) {
          final notebook = await memory.load(owner);
          if (!notebook.enabled || !await allowed(owner)) return false;
          if (notebook.appliedCompactions.contains(job.id)) {
            await queue.finish(job.id);
            completed = true;
            break;
          }
          final events = [...notebook.events];
          for (final update in job.updates) {
            final index = events.indexWhere(
              (e) => update.existingId != null
                  ? e.id == update.existingId
                  : e.generatedKey == update.key,
            );
            final previous = index >= 0 ? events[index] : null;
            if (previous != null && previous.body == update.body) continue;
            if (previous != null) {
              // 手写记录和人工修改过的自动记录均不覆盖。
              if (previous.generatedKey == null ||
                  previous.generatedDigest == null ||
                  memoryEventDigest(previous) != previous.generatedDigest ||
                  update.expectedDigest != previous.generatedDigest) {
                continue;
              }
            } else if (update.existingId != null) {
              continue; // 用户删除后，陈旧的改写建议不复活记录。
            }
            final normalized = update.body
                .replaceAll(RegExp(r'\s+'), '')
                .toLowerCase();
            if (notebook.core
                    .replaceAll(RegExp(r'\s+'), '')
                    .toLowerCase()
                    .contains(normalized) ||
                events.any(
                  (e) =>
                      e.body.replaceAll(RegExp(r'\s+'), '').toLowerCase() ==
                      normalized,
                )) {
              continue;
            }
            final event = ContactMemoryEvent(
              id:
                  previous?.id ??
                  'auto_${memoryTextDigest(update.key).substring(0, 32)}',
              title: update.title,
              body: update.body,
              occurredAt: DateTime.now(),
              generatedKey: update.key,
              generatedDigest: memoryEventDigest(
                ContactMemoryEvent(
                  id: '',
                  title: update.title,
                  body: update.body,
                  memoryKind: update.kind,
                  occurredAt: DateTime.now(),
                ),
              ),
              memoryKind: update.kind,
            );
            if (index >= 0) {
              events[index] = event;
            } else {
              events.add(event);
            }
          }
          try {
            // 常驻手写正文逐字保留；跨进程并发编辑由文件revision锁拒绝并重读。
            if (!await queue.sourcesValid(job.id)) {
              await queue.finish(job.id, discarded: true);
              completed = true;
              break;
            }
            await memory.save(
              notebook.copyWith(
                events: events,
                appliedCompactions: [...notebook.appliedCompactions, job.id],
              ),
            );
            await queue.finish(job.id);
            completed = true;
          } on ContactMemoryConflict {
            if (attempt == 2) rethrow;
          }
        }
      }
      return (await queue.pending(owner)).isEmpty;
    } catch (error) {
      AppLogger.warning(
        'CompactionMemory',
        '摘要已保存，记忆待补写',
        metadata: {
          'conversationId': owner,
          'errorType': error.runtimeType.toString(),
        },
      );
      return false;
    }
  }
}
