import 'dart:convert';

import 'package:drift/drift.dart';

import 'database.dart';

/// 匯入結果統計。
class ImportReport {
  int added = 0;
  int updated = 0;
  int skipped = 0;

  int get total => added + updated + skipped;

  @override
  String toString() => '新增 $added 筆、更新 $updated 筆、略過 $skipped 筆';
}

/// 全資料庫 JSON 匯出 / 匯入（現階段的跨裝置手動同步方案）。
///
/// - 匯出包含所有資料表「全部列」，含軟刪除的墓碑（讓刪除也能同步）。
/// - 匯入採「合併」而非覆蓋：以 id 比對，updatedAt 較新者勝（Last-Write-Wins），
///   相同或較舊的略過。因此重複匯入是安全的，兩台裝置可以來回匯出入。
class BackupService {
  BackupService(this.db);

  final AppDatabase db;

  static const appId = 'garage_log';
  static const formatVersion = 1;

  Future<Map<String, dynamic>> exportMap() async {
    return {
      'app': appId,
      'formatVersion': formatVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'vehicles': [for (final r in await db.select(db.vehicles).get()) r.toJson()],
      'fuelLogs': [for (final r in await db.select(db.fuelLogs).get()) r.toJson()],
      'maintenanceRecords': [
        for (final r in await db.select(db.maintenanceRecords).get()) r.toJson()
      ],
      'maintenanceItems': [
        for (final r in await db.select(db.maintenanceItems).get()) r.toJson()
      ],
    };
  }

  Future<String> exportJson() async =>
      const JsonEncoder.withIndent('  ').convert(await exportMap());

  /// 合併匯入。格式不符時丟出 [FormatException]。整批在同一個交易內，失敗會整批回滾。
  Future<ImportReport> importJson(String text) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const FormatException('不是有效的 JSON 檔案');
    }
    if (decoded is! Map<String, dynamic> || decoded['app'] != appId) {
      throw const FormatException('這不是本 App 匯出的備份檔');
    }
    final version = decoded['formatVersion'];
    if (version is! int || version > formatVersion) {
      throw const FormatException('備份檔版本較新，請先更新 App');
    }

    final report = ImportReport();
    await db.transaction(() async {
      await _merge<$VehiclesTable, Vehicle>(
        db.vehicles,
        decoded['vehicles'],
        (m) => Vehicle.fromJson(m),
        (r) => r.id,
        (r) => r.updatedAt,
        report,
      );
      await _merge<$FuelLogsTable, FuelLog>(
        db.fuelLogs,
        decoded['fuelLogs'],
        (m) => FuelLog.fromJson(m),
        (r) => r.id,
        (r) => r.updatedAt,
        report,
      );
      await _merge<$MaintenanceRecordsTable, MaintenanceRecord>(
        db.maintenanceRecords,
        decoded['maintenanceRecords'],
        (m) => MaintenanceRecord.fromJson(m),
        (r) => r.id,
        (r) => r.updatedAt,
        report,
      );
      await _merge<$MaintenanceItemsTable, MaintenanceItem>(
        db.maintenanceItems,
        decoded['maintenanceItems'],
        (m) => MaintenanceItem.fromJson(m),
        (r) => r.id,
        (r) => r.updatedAt,
        report,
      );
    });
    return report;
  }

  Future<void> _merge<T extends Table, D extends DataClass>(
    TableInfo<T, D> table,
    Object? rows,
    D Function(Map<String, dynamic>) fromJson,
    String Function(D) idOf,
    int Function(D) updatedOf,
    ImportReport report,
  ) async {
    if (rows == null) return;
    if (rows is! List) throw const FormatException('備份檔格式錯誤');

    final local = <String, int>{
      for (final r in await db.select(table).get()) idOf(r): updatedOf(r),
    };

    for (final raw in rows) {
      final row = fromJson(Map<String, dynamic>.from(raw as Map));
      final localUpdated = local[idOf(row)];
      if (localUpdated == null) {
        await db.into(table).insert(row as Insertable<D>);
        report.added++;
      } else if (updatedOf(row) > localUpdated) {
        await db.into(table).insertOnConflictUpdate(row as Insertable<D>);
        report.updated++;
      } else {
        report.skipped++;
      }
    }
  }
}
