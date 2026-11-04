import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import '../domain/maintenance_calculator.dart';
import 'database.dart';

/// 匯入 / 預覽 / 復原結果統計。
class ImportReport {
  int added = 0;
  int updated = 0;
  int skipped = 0;

  /// 匯入後為維持一致性而自動修正的筆數（例如重算保養總額、
  /// 連帶刪除已刪除車輛底下新出現的紀錄）。
  int repaired = 0;

  /// 無法自動判斷如何處理、需要使用者確認的異常資料筆數：
  /// 找不到所屬車輛 / 保養單的孤立紀錄，以及沒有任何有效明細的保養單。
  /// 這些資料會被**保留**（不刪除、不改金額），只是不會顯示在畫面上或不納入重算。
  int anomalies = 0;

  int get total => added + updated + skipped;

  @override
  String toString() {
    final sb = StringBuffer('新增 $added 筆、更新 $updated 筆、略過 $skipped 筆');
    if (repaired > 0) sb.write('（自動修正 $repaired 筆關聯資料）');
    if (anomalies > 0) {
      sb.write('\n發現 $anomalies 筆異常資料（找不到所屬車輛 / 保養單，或保養單沒有明細），'
          '已保留但不顯示，建議確認備份來源。');
    }
    return sb.toString();
  }
}

/// 匯入前的內容預覽（不會寫入資料庫）。
class BackupPreview {
  BackupPreview({
    required this.exportedAt,
    required this.vehicles,
    required this.fuelLogs,
    required this.maintenanceRecords,
    required this.plans,
    required this.diff,
  });

  /// 備份檔的匯出時間（無法解析時為 null）
  final DateTime? exportedAt;

  /// 備份檔內「未刪除」的筆數
  final int vehicles;
  final int fuelLogs;
  final int maintenanceRecords;
  final int plans;

  /// 與本機合併後會發生的變動
  final ImportReport diff;
}

/// 自動備份檔的資訊（給「自動備份與復原」畫面列出用）。
class AutoBackupInfo {
  AutoBackupInfo(this.file, this.modified, this.kind);

  final File file;
  final DateTime modified;

  /// 'import'（匯入前備份）或 'restore'（復原前備份）
  final String kind;

  String get name => p.basename(file.path);
}

/// 完整復原對單一資料表的影響（只計算未刪除的列）。
class TableImpact {
  const TableImpact({
    required this.label,
    required this.local,
    required this.backup,
    required this.removed,
  });

  final String label;

  /// 目前本機的有效筆數
  final int local;

  /// 備份檔內的有效筆數
  final int backup;

  /// 復原後會被移除（變成已刪除）的本機有效筆數：備份裡沒有、或備份裡已是刪除狀態
  final int removed;
}

/// 完整復原前給使用者確認用的影響摘要。
class RestoreImpact {
  const RestoreImpact(this.tables);

  final List<TableImpact> tables;

  int get totalRemoved => tables.fold(0, (s, t) => s + t.removed);
}

class _Snapshot {
  _Snapshot({
    required this.vehicles,
    required this.fuelLogs,
    required this.records,
    required this.items,
    required this.plans,
  });

  final List<Vehicle> vehicles;
  final List<FuelLog> fuelLogs;
  final List<MaintenanceRecord> records;
  final List<MaintenanceItem> items;
  final List<MaintenancePlan> plans;
}

/// 全資料庫 JSON 匯出 / 匯入（現階段的跨裝置手動同步方案）。
///
/// - 匯出包含所有資料表「全部列」，含軟刪除的墓碑（讓刪除也能同步）。
/// - 匯入採「合併」而非覆蓋：以 id 比對，updatedAt 較新者勝（Last-Write-Wins）。
///   updatedAt 完全相同但內容不同時，以內容的穩定排序決勝，
///   讓兩台裝置各自合併後會收斂到同一個結果。
/// - 合併後會做一致性修復（[repairIntegrity]）與異常檢查（[countAnomalies]）。
/// - 「合併」不等於「還原」：要把資料庫退回某個備份的狀態，請用 [restoreSnapshot]。
class BackupService {
  BackupService(this.db, {int Function()? clock})
      : _now = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final AppDatabase db;
  final int Function() _now;

  static const appId = 'garage_log';

  /// v1：4 張表；v2：新增 maintenancePlans、油品欄位。
  static const formatVersion = 2;

  static const _tablesV1 = [
    'vehicles',
    'fuelLogs',
    'maintenanceRecords',
    'maintenanceItems',
  ];

  static const autoImportPrefix = 'auto_before_import';
  static const autoRestorePrefix = 'auto_before_restore';

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
      'maintenancePlans': [
        for (final r in await db.select(db.maintenancePlans).get()) r.toJson()
      ],
    };
  }

  Future<String> exportJson() async =>
      const JsonEncoder.withIndent('  ').convert(await exportMap());

  // ───────────────────────── 解析與驗證 ─────────────────────────

  /// 解析並檢查備份檔外層格式。不符時丟出 [FormatException]。
  ///
  /// v1 必須有 4 張表；v2 必須有全部 5 張表（缺少任何一張都視為不完整的備份）。
  Map<String, dynamic> _parse(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const FormatException('不是有效的 JSON 檔案');
    }
    if (decoded is! Map<String, dynamic> || decoded['app'] != appId) {
      throw const FormatException('這不是本 App 匯出的備份檔');
    }
    final data = decoded;
    final version = data['formatVersion'];
    if (version is! int || version < 1 || version > formatVersion) {
      throw const FormatException('備份檔版本不支援，請先更新 App');
    }
    final mustHave = [..._tablesV1, if (version >= 2) 'maintenancePlans'];
    for (final key in mustHave) {
      if (data[key] is! List) {
        throw FormatException('備份檔不完整：缺少「$key」資料或格式錯誤');
      }
    }
    if (data['maintenancePlans'] != null && data['maintenancePlans'] is! List) {
      throw const FormatException('備份檔格式錯誤');
    }
    return data;
  }

  static bool _nonNeg(num v) => v.isFinite && v >= 0;

  /// 驗證規則與 Repository 一致：**未刪除**的列必須符合「正常操作能建立出來」的標準
  /// （名稱不可空白、公升 / 數量 > 0、金額 / 單價 >= 0 …）；已刪除的墓碑只要求數字有限、非負，
  /// 以免舊版留下的墓碑害整份備份匯不進來。
  static String? _commonCheck(String id, int createdAt, int updatedAt) {
    if (id.isEmpty) return '有資料缺少 id';
    if (createdAt < 0 || updatedAt < 0) return '有資料的時間戳記無效';
    return null;
  }

  static String? _checkVehicle(Vehicle r) {
    final c = _commonCheck(r.id, r.createdAt, r.updatedAt);
    if (c != null) return c;
    if (!_nonNeg(r.initialOdometer)) return '車輛「${r.name}」的初始里程無效';
    if (!r.isDeleted && r.name.trim().isEmpty) return '有車輛沒有名稱';
    return null;
  }

  static String? _checkFuel(FuelLog r) {
    final c = _commonCheck(r.id, r.createdAt, r.updatedAt);
    if (c != null) return c;
    if (!(_nonNeg(r.odometer) &&
        _nonNeg(r.liters) &&
        _nonNeg(r.amount) &&
        _nonNeg(r.unitPrice))) {
      return '有加油紀錄的里程、公升數、金額或單價無效（不可為負數或非數字）';
    }
    if (!r.isDeleted && r.liters <= 0) return '有加油紀錄的公升數不是正數';
    return null;
  }

  static String? _checkRecord(MaintenanceRecord r) =>
      _commonCheck(r.id, r.createdAt, r.updatedAt) ??
      ((_nonNeg(r.odometer) && _nonNeg(r.totalAmount))
          ? null
          : '有保養紀錄的里程或金額無效（不可為負數或非數字）');

  static String? _checkItem(MaintenanceItem r) {
    final c = _commonCheck(r.id, r.createdAt, r.updatedAt);
    if (c != null) return c;
    if (!(_nonNeg(r.quantity) && _nonNeg(r.unitPrice))) {
      return '保養項目「${r.name}」的數量或單價無效（不可為負數或非數字）';
    }
    if (r.isDeleted) return null;
    // 和儲存保養單時完全相同的規則（名稱不可空白、數量 > 0、單價 >= 0）
    return validateItemInput(
      ItemInput(name: r.name, quantity: r.quantity, unitPrice: r.unitPrice),
    );
  }

  static String? _checkPlan(MaintenancePlan r) {
    final c = _commonCheck(r.id, r.createdAt, r.updatedAt);
    if (c != null) return c;
    if (!(_nonNeg(r.intervalKm) && r.intervalDays >= 0)) {
      return '保養週期「${r.name}」的里程或天數無效';
    }
    if (!r.isDeleted && r.name.trim().isEmpty) return '有保養週期沒有名稱';
    return null;
  }

  List<D> _rows<D>(
    Object? raw,
    D Function(Map<String, dynamic>) fromJson,
    Map<String, Object?> defaults,
    String? Function(D) check,
  ) {
    if (raw == null) return <D>[];
    if (raw is! List) throw const FormatException('備份檔格式錯誤');
    final out = <D>[];
    for (final item in raw) {
      if (item is! Map) throw const FormatException('備份檔格式錯誤');
      final row = fromJson({...defaults, ...Map<String, dynamic>.from(item)});
      final err = check(row);
      if (err != null) throw FormatException('備份檔內容不合法：$err');
      out.add(row);
    }
    return out;
  }

  /// 把備份檔轉成有型別的資料列，同時檢查欄位值。任何一筆不合法就整份拒絕。
  _Snapshot _decode(Map<String, dynamic> data) {
    try {
      return _Snapshot(
        vehicles: _rows<Vehicle>(data['vehicles'], Vehicle.fromJson,
            const {'defaultFuelType': ''}, _checkVehicle),
        fuelLogs: _rows<FuelLog>(data['fuelLogs'], FuelLog.fromJson,
            const {'fuelType': ''}, _checkFuel),
        records: _rows<MaintenanceRecord>(data['maintenanceRecords'],
            MaintenanceRecord.fromJson, const {}, _checkRecord),
        items: _rows<MaintenanceItem>(data['maintenanceItems'],
            MaintenanceItem.fromJson, const {}, _checkItem),
        plans: _rows<MaintenancePlan>(data['maintenancePlans'],
            MaintenancePlan.fromJson, const {}, _checkPlan),
      );
    } on TypeError {
      throw const FormatException('備份檔內容格式錯誤（欄位型態不符）');
    }
  }

  int _liveCount(Object? rows) {
    if (rows is! List) return 0;
    return rows.where((r) => r is Map && r['isDeleted'] != true).length;
  }

  // ───────────────────────── 預覽與合併匯入 ─────────────────────────

  /// 預覽匯入結果：回傳備份檔內容摘要與「合併後會新增 / 更新 / 略過幾筆」，
  /// 不會改動資料庫。格式不符時丟出 [FormatException]。
  Future<BackupPreview> preview(String text) async {
    final data = _parse(text);
    final snap = _decode(data);
    final report = ImportReport();
    await _mergeAll(snap, report, dryRun: true);
    return BackupPreview(
      exportedAt: DateTime.tryParse('${data['exportedAt']}')?.toLocal(),
      vehicles: _liveCount(data['vehicles']),
      fuelLogs: _liveCount(data['fuelLogs']),
      maintenanceRecords: _liveCount(data['maintenanceRecords']),
      plans: _liveCount(data['maintenancePlans']),
      diff: report,
    );
  }

  /// 合併匯入。格式不符時丟出 [FormatException]。
  /// 整批在同一個交易內（含一致性修復），失敗會整批回滾。
  Future<ImportReport> importJson(String text) async {
    final snap = _decode(_parse(text));
    final report = ImportReport();
    await _mergeAll(snap, report, dryRun: false);
    return report;
  }

  Future<void> _mergeAll(
    _Snapshot s,
    ImportReport report, {
    required bool dryRun,
  }) async {
    try {
      await db.transaction(() async {
        await _merge<$VehiclesTable, Vehicle>(
            db.vehicles, s.vehicles, (r) => r.id, (r) => r.updatedAt, report);
        await _merge<$FuelLogsTable, FuelLog>(
            db.fuelLogs, s.fuelLogs, (r) => r.id, (r) => r.updatedAt, report);
        await _merge<$MaintenanceRecordsTable, MaintenanceRecord>(
            db.maintenanceRecords,
            s.records,
            (r) => r.id,
            (r) => r.updatedAt,
            report);
        await _merge<$MaintenanceItemsTable, MaintenanceItem>(
            db.maintenanceItems, s.items, (r) => r.id, (r) => r.updatedAt, report);
        await _merge<$MaintenancePlansTable, MaintenancePlan>(
            db.maintenancePlans, s.plans, (r) => r.id, (r) => r.updatedAt, report);

        report.repaired += await repairIntegrity();
        report.anomalies = await countAnomalies();

        if (dryRun) {
          // 預覽：把這個交易整個回滾，確保不留下任何變更。
          throw _DryRunDone();
        }
      });
    } on _DryRunDone {
      // 預覽完成（資料庫已回滾）
    }
  }

  /// 同一列的穩定內容鍵，只用在「updatedAt 相同」時決定誰勝出。
  static String _contentKey(DataClass r) => jsonEncode(r.toJson());

  Future<void> _merge<T extends Table, D extends DataClass>(
    TableInfo<T, D> table,
    List<D> rows,
    String Function(D) idOf,
    int Function(D) updatedOf,
    ImportReport report,
  ) async {
    final local = <String, D>{
      for (final r in await db.select(table).get()) idOf(r): r,
    };

    for (final row in rows) {
      final cur = local[idOf(row)];
      if (cur == null) {
        await db.into(table).insert(row as Insertable<D>);
        local[idOf(row)] = row;
        report.added++;
        continue;
      }
      final incoming = updatedOf(row);
      final existing = updatedOf(cur);
      // updatedAt 相同時以內容鍵決勝：兩台裝置各自合併都會選同一邊，結果會收斂。
      final wins = incoming > existing ||
          (incoming == existing &&
              _contentKey(row).compareTo(_contentKey(cur)) > 0);
      if (wins) {
        await db.into(table).insertOnConflictUpdate(row as Insertable<D>);
        local[idOf(row)] = row;
        report.updated++;
      } else {
        report.skipped++;
      }
    }
  }

  // ───────────────────────── 一致性修復 / 異常檢查 ─────────────────────────

  /// 一致性修復，回傳修正的筆數。可重複執行（冪等）。
  ///
  /// 1. 已刪除的車輛 → 其底下仍未刪除的加油、保養單、週期一併軟刪除
  /// 2. 已刪除的保養單 → 其底下仍未刪除的明細一併軟刪除
  /// 3. 未刪除的保養單：總金額重算為「未刪除明細小計加總」
  ///    （完全沒有有效明細的保養單不動，改由 [countAnomalies] 回報）
  ///
  /// 修正時 updatedAt 取 MAX(現在, 原值 + 1)，保證比被修正的那一列更新，
  /// 修正結果才不會被下一次同步的舊資料蓋回去。
  Future<int> repairIntegrity() async {
    final now = _now();
    var fixed = 0;

    Future<int> cascade(String table, String sql, TableInfo info) =>
        db.customUpdate(
          'UPDATE $table SET is_deleted = 1, '
          'updated_at = MAX(?, updated_at + 1) WHERE is_deleted = 0 AND $sql',
          variables: [Variable.withInt(now)],
          updates: {info},
        );

    fixed += await cascade(
      'fuel_logs',
      'vehicle_id IN (SELECT id FROM vehicles WHERE is_deleted = 1)',
      db.fuelLogs,
    );
    fixed += await cascade(
      'maintenance_records',
      'vehicle_id IN (SELECT id FROM vehicles WHERE is_deleted = 1)',
      db.maintenanceRecords,
    );
    fixed += await cascade(
      'maintenance_plans',
      'vehicle_id IN (SELECT id FROM vehicles WHERE is_deleted = 1)',
      db.maintenancePlans,
    );
    fixed += await cascade(
      'maintenance_items',
      'record_id IN (SELECT id FROM maintenance_records WHERE is_deleted = 1)',
      db.maintenanceItems,
    );

    final records = await (db.select(db.maintenanceRecords)
          ..where((t) => t.isDeleted.equals(false)))
        .get();
    final items = await (db.select(db.maintenanceItems)
          ..where((t) => t.isDeleted.equals(false)))
        .get();
    final byRecord = <String, List<MaintenanceItem>>{};
    for (final i in items) {
      (byRecord[i.recordId] ??= []).add(i);
    }

    for (final r in records) {
      final list = byRecord[r.id];
      if (list == null || list.isEmpty) continue;
      final total = computeItemsTotal([
        for (final i in list)
          ItemInput(name: i.name, quantity: i.quantity, unitPrice: i.unitPrice),
      ]);
      if ((total - r.totalAmount).abs() > 0.005) {
        await (db.update(db.maintenanceRecords)..where((t) => t.id.equals(r.id)))
            .write(MaintenanceRecordsCompanion(
          totalAmount: Value(total),
          updatedAt: Value(math.max(now, r.updatedAt + 1)),
        ));
        fixed++;
      }
    }
    return fixed;
  }

  /// 需要使用者確認的異常資料筆數（只計算「未刪除」的列）：
  /// - 加油 / 保養單 / 週期找不到所屬車輛（車輛根本不存在）
  /// - 保養明細找不到所屬保養單
  /// - 有效的保養單卻沒有任何有效明細
  ///
  /// 這些資料不會被刪除或改寫，只是被隔離（畫面都是從車輛往下查，所以不會顯示）。
  Future<int> countAnomalies() async {
    Future<int> count(String sql) async {
      final row = await db.customSelect(sql).getSingle();
      return row.read<int>('c');
    }

    var n = 0;
    n += await count('SELECT COUNT(*) AS c FROM fuel_logs WHERE is_deleted = 0 '
        'AND vehicle_id NOT IN (SELECT id FROM vehicles)');
    n += await count(
        'SELECT COUNT(*) AS c FROM maintenance_records WHERE is_deleted = 0 '
        'AND vehicle_id NOT IN (SELECT id FROM vehicles)');
    n += await count(
        'SELECT COUNT(*) AS c FROM maintenance_plans WHERE is_deleted = 0 '
        'AND vehicle_id NOT IN (SELECT id FROM vehicles)');
    n += await count(
        'SELECT COUNT(*) AS c FROM maintenance_items WHERE is_deleted = 0 '
        'AND record_id NOT IN (SELECT id FROM maintenance_records)');
    n += await count(
        'SELECT COUNT(*) AS c FROM maintenance_records r WHERE r.is_deleted = 0 '
        'AND NOT EXISTS (SELECT 1 FROM maintenance_items i '
        'WHERE i.record_id = r.id AND i.is_deleted = 0)');
    return n;
  }

  // ───────────────────────── 完整復原 ─────────────────────────

  /// 預估完整復原會影響多少本機資料（不改動資料庫）。格式或欄位不合法時丟出 [FormatException]。
  Future<RestoreImpact> restoreImpact(String text) async {
    final s = _decode(_parse(text));

    Future<TableImpact> one<T extends Table, D extends DataClass>(
      String label,
      TableInfo<T, D> table,
      List<D> rows,
      String Function(D) idOf,
      bool Function(D) deletedOf,
    ) async {
      final backupLive = {
        for (final r in rows)
          if (!deletedOf(r)) idOf(r),
      };
      final localLive = [
        for (final r in await db.select(table).get())
          if (!deletedOf(r)) idOf(r),
      ];
      return TableImpact(
        label: label,
        local: localLive.length,
        backup: backupLive.length,
        removed: localLive.where((id) => !backupLive.contains(id)).length,
      );
    }

    return RestoreImpact([
      await one<$VehiclesTable, Vehicle>(
          '車輛', db.vehicles, s.vehicles, (r) => r.id, (r) => r.isDeleted),
      await one<$FuelLogsTable, FuelLog>(
          '加油紀錄', db.fuelLogs, s.fuelLogs, (r) => r.id, (r) => r.isDeleted),
      await one<$MaintenanceRecordsTable, MaintenanceRecord>('保養紀錄',
          db.maintenanceRecords, s.records, (r) => r.id, (r) => r.isDeleted),
      await one<$MaintenancePlansTable, MaintenancePlan>(
          '保養週期', db.maintenancePlans, s.plans, (r) => r.id, (r) => r.isDeleted),
    ]);
  }

  /// 完整復原：讓資料庫的「有效資料」回到 [text] 備份檔的狀態。
  ///
  /// 與合併匯入不同，這**不是** Last-Write-Wins：
  /// - 備份檔裡的每一列都會寫入，不論本機同一列是否更新。
  /// - 本機有、備份檔沒有的列會被軟刪除（留下墓碑，不是真的刪掉）。
  /// - 所有被寫入 / 被刪除的列，updatedAt 都會設成比本機原值與備份值更新的值，
  ///   所以復原的結果之後同步到其他裝置時也能勝出，不會被舊資料蓋回來。
  ///
  /// 整個過程在同一個交易內，格式或欄位不合法時整批拒絕、資料庫不變。
  /// 呼叫前請先用 [writeAutoBackup] 保存目前的資料。
  Future<ImportReport> restoreSnapshot(String text) async {
    final s = _decode(_parse(text));
    final report = ImportReport();
    final now = _now();
    await db.transaction(() async {
      report.added += await _restoreTable<$VehiclesTable, Vehicle>(
          db.vehicles, 'vehicles', s.vehicles, (r) => r.id, (r) => r.updatedAt, now);
      report.added += await _restoreTable<$FuelLogsTable, FuelLog>(db.fuelLogs,
          'fuel_logs', s.fuelLogs, (r) => r.id, (r) => r.updatedAt, now);
      report.added += await _restoreTable<$MaintenanceRecordsTable,
              MaintenanceRecord>(db.maintenanceRecords, 'maintenance_records',
          s.records, (r) => r.id, (r) => r.updatedAt, now);
      report.added += await _restoreTable<$MaintenanceItemsTable, MaintenanceItem>(
          db.maintenanceItems,
          'maintenance_items',
          s.items,
          (r) => r.id,
          (r) => r.updatedAt,
          now);
      report.added += await _restoreTable<$MaintenancePlansTable, MaintenancePlan>(
          db.maintenancePlans,
          'maintenance_plans',
          s.plans,
          (r) => r.id,
          (r) => r.updatedAt,
          now);
      report.repaired += await repairIntegrity();
      report.anomalies = await countAnomalies();
    });
    return report;
  }

  Future<int> _restoreTable<T extends Table, D extends DataClass>(
    TableInfo<T, D> table,
    String tableName,
    List<D> rows,
    String Function(D) idOf,
    int Function(D) updatedOf,
    int now,
  ) async {
    final local = <String, D>{
      for (final r in await db.select(table).get()) idOf(r): r,
    };
    final seen = <String>{};

    for (final row in rows) {
      final id = idOf(row);
      seen.add(id);
      final prev = local[id];
      final stamp = math.max(
        math.max(now, updatedOf(row) + 1),
        prev == null ? 0 : updatedOf(prev) + 1,
      );
      await db.into(table).insertOnConflictUpdate(row as Insertable<D>);
      await db.customUpdate(
        'UPDATE $tableName SET updated_at = ? WHERE id = ?',
        variables: [Variable.withInt(stamp), Variable.withString(id)],
        updates: {table},
      );
    }

    // 本機有、備份檔沒有：軟刪除（留墓碑）
    for (final id in local.keys) {
      if (seen.contains(id)) continue;
      await db.customUpdate(
        'UPDATE $tableName SET is_deleted = 1, '
        'updated_at = MAX(?, updated_at + 1) WHERE id = ? AND is_deleted = 0',
        variables: [Variable.withInt(now), Variable.withString(id)],
        updates: {table},
      );
    }
    return rows.length;
  }

  // ───────────────────────── 自動備份 ─────────────────────────

  /// 把目前資料完整備份到 [dir]（匯入 / 復原前的保護網），
  /// 同一個 [prefix] 只保留最近 [keep] 份。
  Future<File> writeAutoBackup(
    Directory dir, {
    String prefix = autoImportPrefix,
    int keep = 5,
  }) async {
    await dir.create(recursive: true);
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${n.year}${two(n.month)}${two(n.day)}_'
        '${two(n.hour)}${two(n.minute)}${two(n.second)}_'
        '${n.millisecond.toString().padLeft(3, '0')}';
    final file = File(p.join(dir.path, '${prefix}_$stamp.json'));
    await file.writeAsString(await exportJson(), flush: true);

    final old = dir
        .listSync()
        .whereType<File>()
        .where((f) => p.basename(f.path).startsWith('${prefix}_'))
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    for (final f in old.skip(keep)) {
      try {
        await f.delete();
      } catch (_) {
        // 清不掉舊備份不影響主流程
      }
    }
    return file;
  }

  /// 列出 [dir] 內的自動備份，最新的在前。目錄不存在時回傳空清單。
  static List<AutoBackupInfo> listAutoBackups(Directory dir) {
    if (!dir.existsSync()) return [];
    final out = <AutoBackupInfo>[];
    for (final f in dir.listSync().whereType<File>()) {
      final name = p.basename(f.path);
      if (!name.endsWith('.json')) continue;
      final String kind;
      if (name.startsWith('${autoRestorePrefix}_')) {
        kind = 'restore';
      } else if (name.startsWith('${autoImportPrefix}_')) {
        kind = 'import';
      } else {
        continue;
      }
      out.add(AutoBackupInfo(f, f.lastModifiedSync(), kind));
    }
    out.sort((a, b) {
      final c = b.modified.compareTo(a.modified);
      return c != 0 ? c : b.name.compareTo(a.name);
    });
    return out;
  }
}

/// 內部用：預覽模式在合併完成後丟出，讓交易整個回滾。
class _DryRunDone implements Exception {}
