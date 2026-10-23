import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/sync/cloud_setting_policy.dart';
import 'builtin_prompt_packs.dart';
import 'prompt_pack.dart';

/// What the store holds: the library plus the one-time migrations done.
class PromptPackState {
  const PromptPackState(this.library, {this.migrations = const {}});

  final PromptPackLibrary library;
  final Set<String> migrations;

  PromptPackState copyWith({
    PromptPackLibrary? library,
    Set<String>? migrations,
  }) => PromptPackState(
    library ?? this.library,
    migrations: migrations ?? this.migrations,
  );

  Map<String, dynamic> toJson() => {
    ...library.toJson(),
    if (migrations.isNotEmpty) 'migrations': migrations.toList()..sort(),
  };

  factory PromptPackState.fromJson(Map<String, dynamic> json) =>
      PromptPackState(
        PromptPackLibrary.fromJson(json, builtins: kBuiltinPromptPacks),
        migrations: {for (final m in json['migrations'] as List? ?? []) '$m'},
      );

  static PromptPackState initial() =>
      PromptPackState(PromptPackLibrary(builtins: kBuiltinPromptPacks));
}

abstract interface class PromptPackStore {
  Future<PromptPackState> load();
  Future<void> save(PromptPackState state);
}

class PreferencesPromptPackStore implements PromptPackStore {
  /// `aicove.plugins.` prefix: synced with settings (ADR0092).
  static const storageKey = 'aicove.plugins.prompt_packs.v1';

  @override
  Future<PromptPackState> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(storageKey);
    if (raw == null || raw.isEmpty) return PromptPackState.initial();
    return PromptPackState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  @override
  Future<void> save(PromptPackState state) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await saveCloudPreference(
      prefs,
      storageKey,
      jsonEncode(state.toJson()),
    )) {
      throw StateError('提示词包未能保存，请重试');
    }
  }
}

final promptPackStoreProvider = Provider<PromptPackStore>(
  (ref) => PreferencesPromptPackStore(),
);

final promptPackProvider =
    AsyncNotifierProvider<PromptPackNotifier, PromptPackState>(
      PromptPackNotifier.new,
    );

class PromptPackNotifier extends AsyncNotifier<PromptPackState> {
  Future<void> _writes = Future.value();

  @override
  Future<PromptPackState> build() => ref.read(promptPackStoreProvider).load();

  Future<PromptPackLibrary> get library async => (await future).library;

  /// Applies [change] in the write queue and saves; returns the new state.
  Future<PromptPackState> transact(
    FutureOr<PromptPackState> Function(PromptPackState current) change,
  ) {
    final operation = _writes.then((_) async {
      // From what is stored, not the cached copy: a sync may have replaced
      // the stored library since this notifier last read it.
      await future;
      final current = await ref.read(promptPackStoreProvider).load();
      final next = await change(current);
      if (!identical(next, current)) {
        await ref.read(promptPackStoreProvider).save(next);
      }
      state = AsyncData(next);
      return next;
    });
    _writes = operation.then((_) {}, onError: (Object _, StackTrace __) {});
    return operation;
  }

  Future<PromptPackState> change(
    PromptPackLibrary Function(PromptPackLibrary library) change,
  ) => transact((s) => s.copyWith(library: change(s.library)));

  Future<void> editSection(
    String packId,
    String sectionId, {
    String? text,
    bool? enabled,
    String? title,
  }) => change(
    (l) => l.editSection(
      packId,
      sectionId,
      text: text,
      enabled: enabled,
      title: title,
    ),
  );

  Future<void> restoreSection(String packId, String sectionId) =>
      change((l) => l.restoreSection(packId, sectionId));

  Future<void> addSection(String packId, PromptSection section) =>
      change((l) => l.addSection(packId, section));

  Future<void> removeSection(String packId, String sectionId) =>
      change((l) => l.removeSection(packId, sectionId));

  /// Returns the new pack's id.
  Future<String> fork(String packId, {String? name}) async {
    final id = newPromptPackId();
    await change((l) => l.fork(packId, newId: id, name: name));
    return id;
  }

  Future<void> saveCustom(PromptPack pack) => change((l) => l.saveCustom(pack));

  /// Changes a custom pack's name and rules on the pack as stored, so its
  /// sections edited meanwhile (here or by a sync) are kept.
  Future<void> editCustomMeta(
    String id, {
    String? name,
    required List<PromptMatchRule> match,
  }) => change((l) {
    final pack = l.require(id);
    return l.saveCustom(pack.copyWith(name: name ?? pack.name, match: match));
  });

  Future<void> deleteCustom(String id) => change((l) => l.deleteCustom(id));
}

String newPromptPackId() =>
    'pack_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

String newPromptSectionId() =>
    'sec_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
