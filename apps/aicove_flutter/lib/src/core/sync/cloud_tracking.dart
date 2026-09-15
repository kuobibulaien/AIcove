import 'package:drift/drift.dart';

/// Business tables remain the source of truth. Triggers capture changes in the
/// same SQLite transaction, including writes made while the device is offline.
const cloudTables = <String, String>{
  'conversations': 'id',
  'messages': 'id',
  'message_blocks': 'id',
  'message_projection_mappings': 'id',
  'providers': 'id',
  'memories': 'id',
  'summarization_records': 'id',
  'memory_tombstones': 'tombstone_id',
  'diaries': 'id',
  'topic_handoffs': 'id',
};

const cloudMessageChildren = <String, String>{
  'message_blocks': 'message_id',
  'message_projection_mappings': 'raw_message_id',
};

Future<void> installCloudTracking(GeneratedDatabase db) async {
  await db.customStatement('''CREATE TABLE IF NOT EXISTS cloud_client_state (
    id INTEGER PRIMARY KEY CHECK(id=1), suspended INTEGER NOT NULL DEFAULT 0,
    enabled INTEGER NOT NULL DEFAULT 0, epoch TEXT, account_key TEXT,
    cursor INTEGER NOT NULL DEFAULT 0, initialized INTEGER NOT NULL DEFAULT 0,
    mode TEXT, backup_path TEXT)''');
  await db.customStatement(
    'INSERT OR IGNORE INTO cloud_client_state(id) VALUES(1)',
  );
  await db.customStatement('''CREATE TABLE IF NOT EXISTS cloud_dirty (
    kind TEXT NOT NULL, entity_id TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY(kind, entity_id))''');
  await db.customStatement('''CREATE TABLE IF NOT EXISTS cloud_versions (
    kind TEXT NOT NULL, entity_id TEXT NOT NULL, version INTEGER NOT NULL,
    local_json TEXT, cloud_json TEXT NOT NULL, conflict_id TEXT,
    PRIMARY KEY(kind, entity_id))''');
  await db.customStatement('''CREATE TABLE IF NOT EXISTS cloud_outbox (
    op_id TEXT PRIMARY KEY, kind TEXT NOT NULL, entity_id TEXT NOT NULL,
    revision INTEGER NOT NULL, mutation_json TEXT NOT NULL, local_json TEXT,
    UNIQUE(kind, entity_id))''');
  await db.customStatement('''CREATE TABLE IF NOT EXISTS cloud_inbox (
    seq INTEGER PRIMARY KEY, kind TEXT NOT NULL, entity_id TEXT NOT NULL,
    document_json TEXT NOT NULL)''');
  await db.customStatement(
    'CREATE TABLE IF NOT EXISTS cloud_local_migrations (name TEXT PRIMARY KEY)',
  );
  await db.customStatement(
    'CREATE TABLE IF NOT EXISTS cloud_acknowledged (seq INTEGER PRIMARY KEY)',
  );
  await db.customStatement('''CREATE TABLE IF NOT EXISTS cloud_read_state (
    id INTEGER PRIMARY KEY CHECK(id=1), through INTEGER NOT NULL,
    stage TEXT NOT NULL, after_seq INTEGER NOT NULL DEFAULT 0)''');
  await db.customStatement(
    '''CREATE TABLE IF NOT EXISTS cloud_media_queue (
    id TEXT PRIMARY KEY, revision INTEGER NOT NULL DEFAULT 1,
    priority INTEGER NOT NULL DEFAULT 1, retry_after INTEGER NOT NULL DEFAULT 0)''',
  );
  await db.customStatement(
    'CREATE INDEX IF NOT EXISTS cloud_inbox_entity ON cloud_inbox(kind,entity_id,seq)',
  );
  for (final child in cloudMessageChildren.entries) {
    // Snapshots include deleted rows, so the UI's partial index is insufficient.
    await db.customStatement(
      'CREATE INDEX IF NOT EXISTS cloud_${child.key}_owner ON ${child.key}(${child.value},id)',
    );
  }
  for (final table in cloudTables.entries) {
    for (final operation in ['INSERT', 'UPDATE', 'DELETE']) {
      final row = operation == 'DELETE' ? 'OLD' : 'NEW';
      final owner = cloudMessageChildren[table.key];
      final kind = owner == null ? table.key : 'messages';
      final entity = owner ?? table.value;
      final trigger = 'cloud_${table.key}_${operation.toLowerCase()}';
      if (owner != null) {
        await db.customStatement('DROP TRIGGER IF EXISTS $trigger');
      }
      await db.customStatement('''CREATE TRIGGER IF NOT EXISTS $trigger
        AFTER $operation ON ${table.key}
        WHEN (SELECT suspended FROM cloud_client_state WHERE id=1)=0
        BEGIN
          INSERT INTO cloud_dirty(kind, entity_id, revision)
          VALUES('$kind', $row.$entity, 1)
          ON CONFLICT(kind, entity_id) DO UPDATE SET revision=revision+1;
          ${owner != null && operation == 'UPDATE' ? "INSERT INTO cloud_dirty(kind,entity_id,revision) SELECT 'messages',OLD.$entity,1 WHERE OLD.$entity<>NEW.$entity ON CONFLICT(kind,entity_id) DO UPDATE SET revision=revision+1;" : ''}
        END''');
    }
  }
}
