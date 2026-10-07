import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/monitor_record.dart';

class MonitorRepository {
  Database? _database;

  Future<Database> get database async => _database ??= await _open();

  Future<Database> _open() async {
    final root = await getDatabasesPath();
    return openDatabase(
      p.join(root, 'map_supervisor.db'),
      version: 2,
      onCreate: (db, _) => db.execute('''
        CREATE TABLE monitor_records (
          id TEXT PRIMARY KEY,
          timestamp TEXT NOT NULL,
          character_name TEXT NOT NULL,
          screenshot_path TEXT NOT NULL,
          capture_status TEXT NOT NULL,
          sync_status TEXT NOT NULL,
          analysis_status TEXT NOT NULL,
          siyuan_block_id TEXT,
          asset_path TEXT,
          error_message TEXT,
          retry_count INTEGER NOT NULL DEFAULT 0,
          recognized_character TEXT,
          prompt_text TEXT,
          task_number TEXT,
          task_action TEXT,
          analysis_confidence REAL,
          raw_analysis TEXT
        )
      '''),
      onUpgrade: (db, oldVersion, _) async {
        if (oldVersion < 2) {
          await db.execute(
            'ALTER TABLE monitor_records ADD COLUMN recognized_character TEXT',
          );
          await db.execute(
            'ALTER TABLE monitor_records ADD COLUMN prompt_text TEXT',
          );
          await db.execute(
            'ALTER TABLE monitor_records ADD COLUMN task_number TEXT',
          );
          await db.execute(
            'ALTER TABLE monitor_records ADD COLUMN task_action TEXT',
          );
          await db.execute(
            'ALTER TABLE monitor_records ADD COLUMN analysis_confidence REAL',
          );
          await db.execute(
            'ALTER TABLE monitor_records ADD COLUMN raw_analysis TEXT',
          );
        }
      },
    );
  }

  Future<void> upsert(MonitorRecord record) async {
    final db = await database;
    await db.insert(
      'monitor_records',
      record.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<MonitorRecord>> history({int limit = 200}) async {
    final db = await database;
    final rows = await db.query(
      'monitor_records',
      orderBy: 'timestamp DESC',
      limit: limit,
    );
    return rows.map(MonitorRecord.fromMap).toList();
  }

  Future<MonitorRecord?> find(String id) async {
    final db = await database;
    final rows = await db.query(
      'monitor_records',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : MonitorRecord.fromMap(rows.first);
  }

  Future<List<MonitorRecord>> pending() async {
    final db = await database;
    final rows = await db.query(
      'monitor_records',
      where: 'sync_status != ?',
      whereArgs: [SyncStatus.success.name],
      orderBy: 'timestamp ASC',
    );
    return rows.map(MonitorRecord.fromMap).toList();
  }

  Future<({int pending, int failed})> counts() async {
    final db = await database;
    final result = await db.rawQuery('''
      SELECT
        SUM(CASE WHEN sync_status != 'success' THEN 1 ELSE 0 END) pending,
        SUM(CASE WHEN sync_status = 'failed' THEN 1 ELSE 0 END) failed
      FROM monitor_records
    ''');
    final row = result.first;
    return (
      pending: (row['pending'] as int?) ?? 0,
      failed: (row['failed'] as int?) ?? 0,
    );
  }

  Future<void> close() async {
    await _database?.close();
    _database = null;
  }
}
