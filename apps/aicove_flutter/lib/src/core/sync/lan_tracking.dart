import 'package:drift/drift.dart';
import 'cloud_tracking.dart';

/// Independent journal: acknowledging cloud changes never consumes LAN edits.
Future<void> installLanTracking(GeneratedDatabase db) async {
  await db.customStatement(
    '''CREATE TABLE IF NOT EXISTS lan_state(
    id INTEGER PRIMARY KEY CHECK(id=1),device_id TEXT,
    counter INTEGER NOT NULL DEFAULT 0,suspended INTEGER NOT NULL DEFAULT 0)''',
  );
  await db.customStatement('INSERT OR IGNORE INTO lan_state(id) VALUES(1)');
  await db.customStatement('''CREATE TABLE IF NOT EXISTS lan_dirty(
    kind TEXT NOT NULL,entity_id TEXT NOT NULL,revision INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY(kind,entity_id))''');
  await db.customStatement(
    '''CREATE TABLE IF NOT EXISTS lan_revisions(
    hash TEXT PRIMARY KEY,kind TEXT NOT NULL,entity_id TEXT NOT NULL,document_json TEXT NOT NULL)''',
  );
  await db.customStatement('''CREATE TABLE IF NOT EXISTS lan_entities(
    kind TEXT NOT NULL,entity_id TEXT NOT NULL,heads_json TEXT NOT NULL,
    local_fingerprint TEXT,PRIMARY KEY(kind,entity_id))''');
  await db.customStatement(
    '''CREATE TABLE IF NOT EXISTS lan_media_queue(
    media_id TEXT PRIMARY KEY,peer_id TEXT NOT NULL,asset_json TEXT NOT NULL)''',
  );
  await db.customStatement(
    '''CREATE TABLE IF NOT EXISTS lan_pending_deletions(
    hash TEXT PRIMARY KEY,peer_id TEXT NOT NULL,document_json TEXT NOT NULL)''',
  );
  for (final table in cloudTables.entries) {
    for (final operation in ['INSERT', 'UPDATE', 'DELETE']) {
      final row = operation == 'DELETE' ? 'OLD' : 'NEW';
      final owner = cloudMessageChildren[table.key];
      final kind = owner == null ? table.key : 'messages';
      final entity = owner ?? table.value;
      await db.customStatement(
        '''CREATE TRIGGER IF NOT EXISTS lan_${table.key}_${operation.toLowerCase()}
        AFTER $operation ON ${table.key}
        WHEN (SELECT suspended FROM lan_state WHERE id=1)=0
        BEGIN
          INSERT INTO lan_dirty(kind,entity_id,revision) VALUES('$kind',$row.$entity,1)
          ON CONFLICT(kind,entity_id) DO UPDATE SET revision=revision+1;
          ${owner != null && operation == 'UPDATE' ? "INSERT INTO lan_dirty(kind,entity_id,revision) SELECT 'messages',OLD.$entity,1 WHERE OLD.$entity<>NEW.$entity ON CONFLICT(kind,entity_id) DO UPDATE SET revision=revision+1;" : ''}
        END''',
      );
    }
  }
}
