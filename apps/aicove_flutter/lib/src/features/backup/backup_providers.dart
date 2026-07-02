import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/conversation_exporter.dart';
import 'data/conversation_importer.dart';
import 'models/export_format.dart';
import '../../core/database/database_provider.dart';

/// 导出服务 Provider
final conversationExporterProvider = Provider<ConversationExporter>((ref) {
  return ConversationExporter(
    convRepo: ref.watch(conversationRepositoryProvider),
    msgRepo: ref.watch(messageRepositoryProvider),
    blockRepo: ref.watch(messageBlockRepositoryProvider),
  );
});

/// 导入服务 Provider
final conversationImporterProvider = Provider<ConversationImporter>((ref) {
  return ConversationImporter(
    convRepo: ref.watch(conversationRepositoryProvider),
    msgRepo: ref.watch(messageRepositoryProvider),
    blockRepo: ref.watch(messageBlockRepositoryProvider),
  );
});

/// 导出选项状态
class ExportOptionsNotifier extends StateNotifier<ExportOptions> {
  ExportOptionsNotifier() : super(const ExportOptions());

  void toggleScope(String scope) {
    final currentScopes = List<String>.from(state.scopes);
    if (currentScopes.contains(scope)) {
      currentScopes.remove(scope);
    } else {
      currentScopes.add(scope);
    }
    state = state.copyWith(scopes: currentScopes);
  }

  void setScopes(List<String> scopes) {
    state = state.copyWith(scopes: scopes);
  }

  void setIncludeImages(bool value) {
    state = state.copyWith(includeImages: value);
  }

  void setIncludeAudio(bool value) {
    state = state.copyWith(includeAudio: value);
  }

  void setIncludeVideo(bool value) {
    state = state.copyWith(includeVideo: value);
  }

  void reset() {
    state = const ExportOptions();
  }
}

final exportOptionsProvider =
    StateNotifierProvider<ExportOptionsNotifier, ExportOptions>(
  (ref) => ExportOptionsNotifier(),
);

/// 选中的会话 ID 列表（用于导出）
class SelectedConversationsNotifier extends StateNotifier<Set<String>> {
  SelectedConversationsNotifier() : super({});

  void toggle(String id) {
    final newSet = Set<String>.from(state);
    if (newSet.contains(id)) {
      newSet.remove(id);
    } else {
      newSet.add(id);
    }
    state = newSet;
  }

  void selectAll(List<String> ids) {
    state = ids.toSet();
  }

  void clear() {
    state = {};
  }

  bool isSelected(String id) => state.contains(id);
}

final selectedConversationsProvider =
    StateNotifierProvider<SelectedConversationsNotifier, Set<String>>(
  (ref) => SelectedConversationsNotifier(),
);

/// 导出进度状态
final exportProgressProvider = StateProvider<ExportProgress?>((ref) => null);

/// 导入预览状态
final importPreviewProvider = StateProvider<ImportPreview?>((ref) => null);

/// 导入进度状态
final importProgressProvider = StateProvider<ImportProgress?>((ref) => null);

/// 导入冲突解决方案
class ImportConflictResolutionsNotifier
    extends StateNotifier<Map<String, ImportConflictResolution>> {
  ImportConflictResolutionsNotifier() : super({});

  void setResolution(String id, ImportConflictResolution resolution) {
    state = {...state, id: resolution};
  }

  void clear() {
    state = {};
  }
}

final importConflictResolutionsProvider = StateNotifierProvider<
    ImportConflictResolutionsNotifier, Map<String, ImportConflictResolution>>(
  (ref) => ImportConflictResolutionsNotifier(),
);

/// 选中的导入 Scope
class ImportScopesNotifier extends StateNotifier<Set<String>> {
  ImportScopesNotifier() : super({SyncScope.chatHistory, SyncScope.characterCards});

  void toggle(String scope) {
    final newSet = Set<String>.from(state);
    if (newSet.contains(scope)) {
      newSet.remove(scope);
    } else {
      newSet.add(scope);
    }
    state = newSet;
  }

  void reset() {
    state = {SyncScope.chatHistory, SyncScope.characterCards};
  }
}

final importScopesProvider =
    StateNotifierProvider<ImportScopesNotifier, Set<String>>(
  (ref) => ImportScopesNotifier(),
);

/// 选中的导入会话 ID
class ImportSelectedConversationsNotifier extends StateNotifier<Set<String>> {
  ImportSelectedConversationsNotifier() : super({});

  void toggle(String id) {
    final newSet = Set<String>.from(state);
    if (newSet.contains(id)) {
      newSet.remove(id);
    } else {
      newSet.add(id);
    }
    state = newSet;
  }

  void selectAll(List<String> ids) {
    state = ids.toSet();
  }

  void clear() {
    state = {};
  }
}

final importSelectedConversationsProvider =
    StateNotifierProvider<ImportSelectedConversationsNotifier, Set<String>>(
  (ref) => ImportSelectedConversationsNotifier(),
);
