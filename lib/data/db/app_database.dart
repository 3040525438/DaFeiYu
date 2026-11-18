/// 应用数据库（sqflite 封装）。
///
/// 运行平台统一走 sqflite_common_ffi + sqlite3_flutter_libs 自带 SQLite：
/// Android 系统 SQLite 未编译 FTS5（`no such module: fts5`），必须用自带库；
/// 桌面测试本来就依赖 FFI 内存库。
library;

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'schema.dart';

class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  /// FFI 数据库工厂只需初始化一次
  static bool _ffiReady = false;

  static void _ensureFfi() {
    if (_ffiReady) return;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    _ffiReady = true;
  }

  /// 打开（或创建）应用数据库。
  ///
  /// - [directory]：数据库所在目录；传 `:memory:` 时建内存库（测试用）。
  static Future<AppDatabase> open(String directory) async {
    // 统一走自带 SQLite（FTS5 支持），不依赖系统 SQLite
    _ensureFfi();
    final path = directory == ':memory:'
        ? ':memory:'
        : p.join(directory, 'dafeiyu.db');
    final db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: kSchemaVersion,
        onCreate: (Database db, int version) async {
          final batch = db.batch();
          for (final statement in kSchemaStatements) {
            batch.execute(statement);
          }
          await batch.commit(noResult: true);
        },
        onUpgrade: (Database db, int oldVersion, int newVersion) async {
          final batch = db.batch();
          for (var v = oldVersion + 1; v <= newVersion; v++) {
            final statements = kUpgradeStatements[v];
            if (statements == null) continue;
            for (final statement in statements) {
              batch.execute(statement);
            }
          }
          await batch.commit(noResult: true);
        },
      ),
    );
    return AppDatabase._(db);
  }

  /// 当前设置键值（key → value）。
  Future<Map<String, String>> loadSettings() async {
    final rows = await db.query('settings');
    return <String, String>{
      for (final row in rows) row['key']! as String: row['value']! as String,
    };
  }

  Future<void> writeSetting(String key, String value) async {
    await db.insert(
      'settings',
      <String, Object?>{'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 读单个设置；不存在返回 [fallback]。
  Future<String?> readSetting(String key) async {
    final rows = await db.query(
      'settings',
      where: 'key = ?',
      whereArgs: <Object?>[key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  Future<void> close() async {
    await db.close();
  }
}
