import 'package:drift/drift.dart';

/// Business tables remain the source of truth. Triggers capture changes in the
/// same SQLite transaction, including writes made while the device is offline.
const cloudTables = <String, String>{
  'conversations': 'id',
  'messages': 'id',
  'message_blocks': 'id',
  'message_projection_mappings': 'id',
  'providers': 'id',
};

/// 同步表的结构版本，写进每条同步记录的 `client_schema`。
/// 只在同步表的列发生变化时才升，不跟整库版本绑定：整库升级（例如 v18 只新增
/// 本地表）时，旧版本设备仍能收到聊天记录。收到的列多于本机时，接收端会拒绝。
const kCloudRowSchema = 17;

/// 已退役、不再同步的类型（ADR0038）。本地不采集、不上传；
/// 云端推下来的旧记录只清掉收件箱，不写本地，也不回传删除。
const retiredCloudKinds = <String>{
  'memories',
  'summarization_records',
  'memory_tombstones',
  'diaries',
  'topic_handoffs',
  'contact_memory',
};

/// 清掉退役类型在本地同步状态里的残留，避免推送删除或反复重试。
Future<void> purgeRetiredCloudKinds(GeneratedDatabase db) async {
  final kinds = retiredCloudKinds.map((k) => "'$k'").join(',');
  for (final table in [
    'cloud_dirty',
    'cloud_outbox',
    'cloud_inbox',
    'cloud_versions',
  ]) {
    await db.customStatement('DELETE FROM $table WHERE kind IN ($kinds)');
  }
}

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
  // 旧版本在退役表上装过的触发器：表删除前也不能再产生同步记录。
  for (final kind in retiredCloudKinds) {
    for (final operation in ['insert', 'update', 'delete']) {
      await db.customStatement('DROP TRIGGER IF EXISTS cloud_${kind}_$operation');
    }
  }
  await purgeRetiredCloudKinds(db);
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
