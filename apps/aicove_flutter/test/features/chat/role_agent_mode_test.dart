import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/database/converters/database_converters.dart';
import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:aicove_flutter/src/features/assistant/domain/assistant_onboarding.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart'
    as domain;
import 'package:aicove_flutter/src/features/chat/domain/role_agent_mode.dart';

/// ADR0097：角色工作模式。未设置为聊天模式；AIcove酱恒为工具模式。
void main() {
  domain.Conversation roleWith({String id = 'role', RoleAgentMode? mode}) {
    final now = DateTime(2026, 10, 21);
    return domain.Conversation(
      id: id,
      title: 't',
      displayName: 'd',
      createdAt: now,
      updatedAt: now,
      agentMode: mode,
    );
  }

  test('unset role is chat mode; stored mode is used', () {
    expect(roleWith().effectiveAgentMode, RoleAgentMode.chat);
    expect(
      roleWith(mode: RoleAgentMode.tool).effectiveAgentMode,
      RoleAgentMode.tool,
    );
    expect(
      roleWith(mode: RoleAgentMode.chat).effectiveAgentMode,
      RoleAgentMode.chat,
    );
  });

  test('AIcove assistant is always tool mode, even if stored as chat', () {
    expect(
      roleWith(id: kAicoveAssistantId).effectiveAgentMode,
      RoleAgentMode.tool,
    );
    expect(
      roleWith(
        id: kAicoveAssistantId,
        mode: RoleAgentMode.chat,
      ).effectiveAgentMode,
      RoleAgentMode.tool,
    );
  });

  test('copyWith can set and clear the mode', () {
    final tool = roleWith().copyWith(agentMode: RoleAgentMode.tool);
    expect(tool.agentMode, RoleAgentMode.tool);
    expect(tool.copyWith(title: 'x').agentMode, RoleAgentMode.tool);
    expect(tool.copyWith(agentMode: null).agentMode, isNull);
  });

  test('converter round-trips chat, tool and unset', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    for (final mode in [null, ...RoleAgentMode.values]) {
      final id = 'c_${mode?.name ?? 'none'}';
      await db
          .into(db.conversations)
          .insert(
            ConversationConverter.toCompanion(roleWith(id: id, mode: mode)),
          );
      final stored = await (db.select(
        db.conversations,
      )..where((t) => t.id.equals(id))).getSingle();
      expect(ConversationConverter.fromDb(stored).agentMode, mode);
    }
    await db.close();
  });

  test('v24 database upgrades to v25 with unset agent_mode', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customStatement(
      'ALTER TABLE conversations DROP COLUMN agent_mode',
    );
    await db.customStatement(
      "INSERT INTO conversations (id, title, display_name, created_at, updated_at) "
      "VALUES ('c1', 't', 'd', 1, 1)",
    );

    await db.migration.onUpgrade(Migrator(db), 24, 25);

    final row = await db
        .customSelect("SELECT agent_mode FROM conversations WHERE id='c1'")
        .getSingle();
    expect(row.read<String?>('agent_mode'), isNull);
    await db.close();
  });

  test('unknown stored names are ignored', () {
    expect(RoleAgentMode.fromValue('tool'), RoleAgentMode.tool);
    expect(RoleAgentMode.fromValue('bogus'), isNull);
    expect(RoleAgentMode.fromValue(null), isNull);
  });
}
