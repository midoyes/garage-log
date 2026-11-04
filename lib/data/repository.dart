import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../domain/fuel_calculator.dart';
import '../domain/maintenance_calculator.dart';
import '../domain/reminders.dart';
import 'clock.dart';
import 'database.dart';
import 'photo_store.dart' show isSafePhotoName;

/// 輸入資料不合法（里程防呆、欄位範圍等）。
class GarageValidationException implements Exception {
  const GarageValidationException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 儲存保養單時帶入的照片清單項目。
/// [id] 為既有照片的 UUID（保留）；null 代表新增（[fileName] 是已存好的圖檔）。
class PhotoInput {
  const PhotoInput({this.id, required this.fileName, this.sizeBytes = 0});
  final String? id;
  final String fileName;
  final int sizeBytes;
}

/// 保養單 + 明細
class MaintenanceWithItems {
  const MaintenanceWithItems(this.record, this.items);
  final MaintenanceRecord record;
  final List<MaintenanceItem> items;
}

FuelEntry fuelLogToEntry(FuelLog l) => FuelEntry(
      id: l.id,
      date: DateTime.fromMillisecondsSinceEpoch(l.date),
      odometer: l.odometer,
      liters: l.liters,
      amount: l.amount,
      isFullTank: l.isFullTank,
    );

/// 把保養單攤平成「零件更換紀錄」。
List<PartRecord> partRecordsFrom(Iterable<MaintenanceWithItems> list) => [
      for (final m in list)
        for (final i in m.items)
          PartRecord(
            name: i.name,
            date: DateTime.fromMillisecondsSinceEpoch(m.record.date),
            odometer: m.record.odometer,
            quantity: i.quantity,
            unitPrice: i.unitPrice,
          ),
    ];

/// 所有讀寫都集中在這裡：
/// - 主鍵一律 UUID v4
/// - 每次寫入更新 updatedAt，且保證嚴格大於該列先前的 updatedAt
///   （同一毫秒連續編輯、或該列來自時鐘較快的裝置時，仍能被同步判定為「較新」）
/// - 刪除一律軟刪除（isDeleted = true），查詢一律過濾已刪除資料
/// - 輸入驗證與歸屬檢查（車輛 / 保養單 / 明細）在這一層做，不依賴 UI
class GarageRepository {
  GarageRepository(
    this.db, {
    Uuid? uuid,
    int Function()? clock,
  })  : _uuid = uuid ?? const Uuid(),
        _now = MonotonicClock(clock).call;

  final AppDatabase db;
  final Uuid _uuid;
  final int Function() _now;

  /// 取得一個「一定比 [previous] 新」的 updatedAt。
  int _stamp(int previous) {
    final n = _now();
    return n > previous ? n : previous + 1;
  }

  /// 軟刪除符合條件的列，updatedAt 取 MAX(現在, 原值 + 1)，不會倒退。
  Future<int> _softDeleteSql(
    TableInfo table,
    String tableName,
    String where,
    List<Variable> args,
    int now,
  ) =>
      db.customUpdate(
        'UPDATE $tableName SET is_deleted = 1, '
        'updated_at = MAX(?, updated_at + 1) WHERE is_deleted = 0 AND $where',
        variables: [Variable.withInt(now), ...args],
        updates: {table},
      );

  Future<List<OdometerReading>> _maintenanceReadings(
    String vehicleId, {
    String? excludeId,
  }) async {
    final rows = await (db.select(db.maintenanceRecords)
          ..where((t) => t.vehicleId.equals(vehicleId) & t.isDeleted.equals(false)))
        .get();
    return [
      for (final r in rows)
        if (r.id != excludeId)
          OdometerReading(
            id: r.id,
            date: DateTime.fromMillisecondsSinceEpoch(r.date),
            odometer: r.odometer,
            label: '保養',
          ),
    ];
  }

  Future<Vehicle> _requireVehicle(String vehicleId) async {
    final v = await (db.select(db.vehicles)
          ..where((t) => t.id.equals(vehicleId)))
        .getSingleOrNull();
    if (v == null || v.isDeleted) {
      throw const GarageValidationException('找不到車輛');
    }
    return v;
  }

  static int dayMillis(DateTime d) =>
      DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;

  // ───────────────────────── 車輛 ─────────────────────────

  Stream<List<Vehicle>> watchVehicles() {
    final q = db.select(db.vehicles)
      ..where((t) => t.isDeleted.equals(false))
      ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]);
    return q.watch();
  }

  void _checkVehicleInput(String name, double initialOdometer) {
    if (name.trim().isEmpty) throw const GarageValidationException('請輸入車輛名稱');
    if (!initialOdometer.isFinite || initialOdometer < 0) {
      throw const GarageValidationException('初始里程必須是不小於 0 的數字');
    }
  }

  Future<String> addVehicle({
    required int type,
    required String name,
    String plate = '',
    double initialOdometer = 0,
    String defaultFuelType = '',
  }) async {
    _checkVehicleInput(name, initialOdometer);
    final id = _uuid.v4();
    final now = _now();
    await db.into(db.vehicles).insert(
          VehiclesCompanion.insert(
            id: id,
            createdAt: now,
            updatedAt: now,
            name: name.trim(),
            type: Value(type),
            plate: Value(plate.trim()),
            initialOdometer: Value(initialOdometer),
            defaultFuelType: Value(defaultFuelType),
          ),
        );
    return id;
  }

  /// 修改車輛。初始里程不可大於這台車既有加油紀錄的最小里程。
  Future<void> updateVehicle(
    String id, {
    required int type,
    required String name,
    String plate = '',
    double initialOdometer = 0,
    String defaultFuelType = '',
  }) async {
    _checkVehicleInput(name, initialOdometer);
    final current = await _requireVehicle(id);

    final logs = await (db.select(db.fuelLogs)
          ..where((t) => t.vehicleId.equals(id) & t.isDeleted.equals(false)))
        .get();
    if (logs.isNotEmpty) {
      final minOdo = logs.map((l) => l.odometer).reduce(math.min);
      if (initialOdometer > minOdo) {
        throw GarageValidationException(
          '初始里程不可大於既有加油紀錄的最小里程（${minOdo.toStringAsFixed(0)} km）',
        );
      }
    }

    await (db.update(db.vehicles)..where((t) => t.id.equals(id))).write(
      VehiclesCompanion(
        type: Value(type),
        name: Value(name.trim()),
        plate: Value(plate.trim()),
        initialOdometer: Value(initialOdometer),
        defaultFuelType: Value(defaultFuelType),
        updatedAt: Value(_stamp(current.updatedAt)),
      ),
    );
  }

  /// 軟刪除車輛，並連帶軟刪除其加油、保養、明細與週期。
  Future<void> deleteVehicle(String id) async {
    final now = _now();
    await db.transaction(() async {
      final vehicle = await (db.select(db.vehicles)
            ..where((t) => t.id.equals(id)))
          .getSingleOrNull();
      if (vehicle == null) {
        throw const GarageValidationException('找不到車輛');
      }
      final v = [Variable.withString(id)];
      await _softDeleteSql(
        db.maintenanceItems,
        'maintenance_items',
        'record_id IN (SELECT id FROM maintenance_records WHERE vehicle_id = ?)',
        v,
        now,
      );
      await _softDeleteSql(
        db.maintenancePhotos,
        'maintenance_photos',
        'record_id IN (SELECT id FROM maintenance_records WHERE vehicle_id = ?)',
        v,
        now,
      );
      await _softDeleteSql(db.maintenanceRecords, 'maintenance_records',
          'vehicle_id = ?', v, now);
      await _softDeleteSql(
          db.maintenancePlans, 'maintenance_plans', 'vehicle_id = ?', v, now);
      await _softDeleteSql(db.fuelLogs, 'fuel_logs', 'vehicle_id = ?', v, now);
      await (db.update(db.vehicles)..where((t) => t.id.equals(id))).write(
        VehiclesCompanion(
          isDeleted: const Value(true),
          updatedAt: Value(_stamp(vehicle.updatedAt)),
        ),
      );
    });
  }

  // ───────────────────────── 加油 ─────────────────────────

  Stream<List<FuelLog>> watchFuelLogs(String vehicleId) {
    final q = db.select(db.fuelLogs)
      ..where((t) => t.vehicleId.equals(vehicleId) & t.isDeleted.equals(false))
      ..orderBy([
        (t) => OrderingTerm.asc(t.date),
        (t) => OrderingTerm.asc(t.odometer),
      ]);
    return q.watch();
  }

  /// 新增（id == null）或編輯加油紀錄。里程不合法時丟出 [GarageValidationException]。
  Future<String> saveFuelLog({
    String? id,
    required String vehicleId,
    required DateTime date,
    required double odometer,
    required double liters,
    required double amount,
    double? unitPrice,
    bool isFullTank = true,
    String fuelType = '',
    String note = '',
  }) async {
    if (!liters.isFinite || liters <= 0) {
      throw const GarageValidationException('公升數必須大於 0');
    }
    if (!amount.isFinite || amount < 0) {
      throw const GarageValidationException('金額不可為負數');
    }
    if (unitPrice != null && (!unitPrice.isFinite || unitPrice < 0)) {
      throw const GarageValidationException('單價不可為負數');
    }

    final vehicle = await _requireVehicle(vehicleId);

    final existing = await (db.select(db.fuelLogs)
          ..where(
              (t) => t.vehicleId.equals(vehicleId) & t.isDeleted.equals(false)))
        .get();

    // 編輯時：這筆紀錄必須存在、未刪除、且屬於指定車輛
    FuelLog? current;
    if (id != null) {
      current = existing.where((l) => l.id == id).firstOrNull;
      if (current == null) {
        throw const GarageValidationException('找不到這筆加油紀錄（可能已被刪除或不屬於這台車）');
      }
    }

    final error = validateFuelOdometer(
      existing: existing.map(fuelLogToEntry),
      date: date,
      odometer: odometer,
      initialOdometer: vehicle.initialOdometer,
      excludeId: id,
    );
    if (error != null) throw GarageValidationException(error);

    // 再和保養紀錄的里程對照（依日期判定，可以相等）
    final maintReadings = await _maintenanceReadings(vehicleId);
    final crossError = validateOdometerByDate(
      readings: maintReadings,
      date: date,
      odometer: odometer,
      initialOdometer: vehicle.initialOdometer,
    );
    if (crossError != null) throw GarageValidationException(crossError);

    // 單價統一四捨五入到小數 2 位（與表單顯示一致）
    final price = double.parse((unitPrice ?? (amount / liters)).toStringAsFixed(2));
    final now = current == null ? _now() : _stamp(current.updatedAt);

    if (id == null) {
      final newId = _uuid.v4();
      await db.into(db.fuelLogs).insert(
            FuelLogsCompanion.insert(
              id: newId,
              createdAt: now,
              updatedAt: now,
              vehicleId: vehicleId,
              date: dayMillis(date),
              odometer: odometer,
              liters: liters,
              amount: amount,
              unitPrice: Value(price),
              isFullTank: Value(isFullTank),
              fuelType: Value(fuelType),
              note: Value(note.trim()),
            ),
          );
      return newId;
    }

    await (db.update(db.fuelLogs)..where((t) => t.id.equals(id))).write(
      FuelLogsCompanion(
        date: Value(dayMillis(date)),
        odometer: Value(odometer),
        liters: Value(liters),
        amount: Value(amount),
        unitPrice: Value(price),
        isFullTank: Value(isFullTank),
        fuelType: Value(fuelType),
        note: Value(note.trim()),
        updatedAt: Value(now),
      ),
    );
    return id;
  }

  Future<void> deleteFuelLog(String id) async {
    final current = await (db.select(db.fuelLogs)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (current == null) return;
    await (db.update(db.fuelLogs)..where((t) => t.id.equals(id))).write(
      FuelLogsCompanion(
        isDeleted: const Value(true),
        updatedAt: Value(_stamp(current.updatedAt)),
      ),
    );
  }

  // ───────────────────────── 保養 ─────────────────────────

  /// 監聽某車的保養單（新的在前），明細一起帶出。
  ///
  /// 用 JOIN 同時監聽主檔與明細兩張表，所以只有明細變動（例如匯入）時也會更新畫面。
  ///
  /// 使用 INNER JOIN：**沒有任何有效明細的保養單視為異常資料，不會出現在列表、
  /// 總覽與統計**（資料仍保留在資料庫，匯入時已回報筆數）。正常操作不可能產生
  /// 這種保養單（儲存時至少要有一個項目）。
  Stream<List<MaintenanceWithItems>> watchMaintenance(String vehicleId) {
    final r = db.maintenanceRecords;
    final i = db.maintenanceItems;
    final query = db.select(r).join([
      innerJoin(i, i.recordId.equalsExp(r.id) & i.isDeleted.equals(false)),
    ])
      ..where(r.vehicleId.equals(vehicleId) & r.isDeleted.equals(false))
      ..orderBy([
        OrderingTerm.desc(r.date),
        OrderingTerm.desc(r.createdAt),
        OrderingTerm.asc(i.sortOrder),
      ]);

    return query.watch().map((rows) {
      final order = <String>[];
      final records = <String, MaintenanceRecord>{};
      final items = <String, List<MaintenanceItem>>{};
      for (final row in rows) {
        final rec = row.readTable(r);
        if (!records.containsKey(rec.id)) {
          records[rec.id] = rec;
          order.add(rec.id);
        }
        final item = row.readTableOrNull(i);
        if (item != null) (items[rec.id] ??= []).add(item);
      }
      return [
        for (final id in order)
          MaintenanceWithItems(records[id]!, items[id] ?? <MaintenanceItem>[]),
      ];
    });
  }

  /// 新增（id == null）或編輯保養單。總金額 = 明細小計加總。
  ///
  /// 驗證（Repository 層，不依賴畫面）：
  /// - 至少一個項目；每個項目名稱不可空白、數量 > 0、單價 >= 0（0 元代表保固 / 免費）
  /// - 里程為不小於 0 的有限數
  ///
  /// 編輯時：沒出現在 [items] 的舊明細會被軟刪除；有 id 的更新；沒 id 的新增。
  Future<String> saveMaintenance({
    String? id,
    required String vehicleId,
    required DateTime date,
    required double odometer,
    required List<ItemInput> items,
    String note = '',
    List<PhotoInput>? photos,
  }) async {
    if (!odometer.isFinite || odometer < 0) {
      throw const GarageValidationException('里程必須是不小於 0 的數字');
    }
    for (final ph in photos ?? const <PhotoInput>[]) {
      if (!isSafePhotoName(ph.fileName)) {
        throw const GarageValidationException('照片檔名不合法');
      }
    }
    if (items.isEmpty) throw const GarageValidationException('請至少輸入一個保養項目');
    for (final i in items) {
      final err = validateItemInput(i);
      if (err != null) throw GarageValidationException(err);
    }

    final total = computeItemsTotal(items);
    final recordId = id ?? _uuid.v4();

    await db.transaction(() async {
      final vehicle = await _requireVehicle(vehicleId);

      // 依日期判定里程：和同一台車所有加油、其他保養紀錄的前後讀數比對
      final fuelRows = await (db.select(db.fuelLogs)
            ..where((t) => t.vehicleId.equals(vehicleId) & t.isDeleted.equals(false)))
          .get();
      final odoError = validateOdometerByDate(
        readings: [
          for (final l in fuelRows)
            OdometerReading(
              id: l.id,
              date: DateTime.fromMillisecondsSinceEpoch(l.date),
              odometer: l.odometer,
              label: '加油',
            ),
          ...await _maintenanceReadings(vehicleId, excludeId: id),
        ],
        date: date,
        odometer: odometer,
        initialOdometer: vehicle.initialOdometer,
      );
      if (odoError != null) throw GarageValidationException(odoError);

      // 編輯時：保養單必須存在、未刪除、且屬於指定車輛
      MaintenanceRecord? current;
      if (id != null) {
        current = await (db.select(db.maintenanceRecords)
              ..where((t) => t.id.equals(id)))
            .getSingleOrNull();
        if (current == null ||
            current.isDeleted ||
            current.vehicleId != vehicleId) {
          throw const GarageValidationException(
              '找不到這張保養單（可能已被刪除或不屬於這台車）');
        }
      }
      final now = current == null ? _now() : _stamp(current.updatedAt);

      final oldItems = await (db.select(db.maintenanceItems)
            ..where((t) =>
                t.recordId.equals(recordId) & t.isDeleted.equals(false)))
          .get();
      final oldById = {for (final o in oldItems) o.id: o};
      // 明細必須屬於這張保養單
      for (final item in items) {
        if (item.id != null && !oldById.containsKey(item.id)) {
          throw const GarageValidationException('保養明細不屬於這張保養單，請重新開啟後再編輯');
        }
      }

      if (id == null) {
        await db.into(db.maintenanceRecords).insert(
              MaintenanceRecordsCompanion.insert(
                id: recordId,
                createdAt: now,
                updatedAt: now,
                vehicleId: vehicleId,
                date: dayMillis(date),
                odometer: Value(odometer),
                totalAmount: Value(total),
                note: Value(note.trim()),
              ),
            );
      } else {
        await (db.update(db.maintenanceRecords)
              ..where((t) => t.id.equals(recordId)))
            .write(MaintenanceRecordsCompanion(
          date: Value(dayMillis(date)),
          odometer: Value(odometer),
          totalAmount: Value(total),
          note: Value(note.trim()),
          updatedAt: Value(now),
        ));
      }

      final keepIds = items.map((i) => i.id).whereType<String>().toSet();

      for (final old in oldItems) {
        if (!keepIds.contains(old.id)) {
          await (db.update(db.maintenanceItems)
                ..where((t) => t.id.equals(old.id)))
              .write(MaintenanceItemsCompanion(
            isDeleted: const Value(true),
            updatedAt: Value(_stamp(old.updatedAt)),
          ));
        }
      }

      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        if (item.id != null) {
          await (db.update(db.maintenanceItems)
                ..where((t) => t.id.equals(item.id!)))
              .write(MaintenanceItemsCompanion(
            name: Value(item.name.trim()),
            quantity: Value(item.quantity),
            unitPrice: Value(item.unitPrice),
            sortOrder: Value(i),
            updatedAt: Value(_stamp(oldById[item.id]!.updatedAt)),
          ));
        } else {
          await db.into(db.maintenanceItems).insert(
                MaintenanceItemsCompanion.insert(
                  id: _uuid.v4(),
                  createdAt: now,
                  updatedAt: now,
                  recordId: recordId,
                  name: item.name.trim(),
                  quantity: Value(item.quantity),
                  unitPrice: Value(item.unitPrice),
                  sortOrder: Value(i),
                ),
              );
        }
      }

      // 照片：null = 不動；否則以傳入清單為準（沒出現的舊照片軟刪除）
      if (photos != null) {
        final oldPhotos = await (db.select(db.maintenancePhotos)
              ..where((t) =>
                  t.recordId.equals(recordId) & t.isDeleted.equals(false)))
            .get();
        final oldPById = {for (final o in oldPhotos) o.id: o};
        for (final ph in photos) {
          if (ph.id != null && !oldPById.containsKey(ph.id)) {
            throw const GarageValidationException('照片不屬於這張保養單，請重新開啟後再編輯');
          }
        }
        final keep = photos.map((x) => x.id).whereType<String>().toSet();
        for (final old in oldPhotos) {
          if (!keep.contains(old.id)) {
            await (db.update(db.maintenancePhotos)
                  ..where((t) => t.id.equals(old.id)))
                .write(MaintenancePhotosCompanion(
              isDeleted: const Value(true),
              updatedAt: Value(_stamp(old.updatedAt)),
            ));
          }
        }
        for (var i = 0; i < photos.length; i++) {
          final ph = photos[i];
          if (ph.id != null) {
            final old = oldPById[ph.id]!;
            if (old.sortOrder != i) {
              await (db.update(db.maintenancePhotos)
                    ..where((t) => t.id.equals(old.id)))
                  .write(MaintenancePhotosCompanion(
                sortOrder: Value(i),
                updatedAt: Value(_stamp(old.updatedAt)),
              ));
            }
          } else {
            await db.into(db.maintenancePhotos).insert(
                  MaintenancePhotosCompanion.insert(
                    id: _uuid.v4(),
                    createdAt: now,
                    updatedAt: now,
                    recordId: recordId,
                    fileName: ph.fileName,
                    sizeBytes: Value(ph.sizeBytes),
                    sortOrder: Value(i),
                  ),
                );
          }
        }
      }
    });
    return recordId;
  }

  /// 所有未刪除的保養照片（依保養單分組由畫面處理）。
  Stream<List<MaintenancePhoto>> watchPhotos() {
    final q = db.select(db.maintenancePhotos)
      ..where((t) => t.isDeleted.equals(false))
      ..orderBy([
        (t) => OrderingTerm.asc(t.sortOrder),
        (t) => OrderingTerm.asc(t.createdAt),
      ]);
    return q.watch();
  }

  Future<void> deleteMaintenance(String id) async {
    final now = _now();
    await db.transaction(() async {
      final record = await (db.select(db.maintenanceRecords)
            ..where((t) => t.id.equals(id)))
          .getSingleOrNull();
      if (record == null) return;
      await _softDeleteSql(db.maintenanceItems, 'maintenance_items',
          'record_id = ?', [Variable.withString(id)], now);
      await _softDeleteSql(db.maintenancePhotos, 'maintenance_photos',
          'record_id = ?', [Variable.withString(id)], now);
      await (db.update(db.maintenanceRecords)..where((t) => t.id.equals(id)))
          .write(MaintenanceRecordsCompanion(
        isDeleted: const Value(true),
        updatedAt: Value(_stamp(record.updatedAt)),
      ));
    });
  }

  // ───────────────────────── 保養週期 ─────────────────────────

  Stream<List<MaintenancePlan>> watchPlans(String vehicleId) {
    final q = db.select(db.maintenancePlans)
      ..where((t) => t.vehicleId.equals(vehicleId) & t.isDeleted.equals(false))
      ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]);
    return q.watch();
  }

  /// 新增（id == null）或編輯週期。同一台車內項目名稱（正規化後）不可重複。
  Future<String> savePlan({
    String? id,
    required String vehicleId,
    required String name,
    double intervalKm = 0,
    int intervalDays = 0,
  }) async {
    if (name.trim().isEmpty) throw const GarageValidationException('項目名稱不可空白');
    if (!intervalKm.isFinite || intervalKm < 0) {
      throw const GarageValidationException('里程週期不可為負數');
    }
    if (intervalDays < 0) {
      throw const GarageValidationException('天數週期不可為負數');
    }

    await _requireVehicle(vehicleId);

    final existing = await (db.select(db.maintenancePlans)
          ..where((t) => t.vehicleId.equals(vehicleId) & t.isDeleted.equals(false)))
        .get();
    final key = normalizeItemName(name);
    final dup = existing.any((p) => p.id != id && normalizeItemName(p.name) == key);
    if (dup) throw GarageValidationException('「${name.trim()}」已經有設定了');

    // 編輯時：週期必須存在、未刪除、且屬於指定車輛
    MaintenancePlan? current;
    if (id != null) {
      current = existing.where((p) => p.id == id).firstOrNull;
      if (current == null) {
        throw const GarageValidationException('找不到這個保養週期（可能已被刪除或不屬於這台車）');
      }
    }

    final now = current == null ? _now() : _stamp(current.updatedAt);
    if (id == null) {
      final newId = _uuid.v4();
      await db.into(db.maintenancePlans).insert(
            MaintenancePlansCompanion.insert(
              id: newId,
              createdAt: now,
              updatedAt: now,
              vehicleId: vehicleId,
              name: name.trim(),
              intervalKm: Value(intervalKm),
              intervalDays: Value(intervalDays),
            ),
          );
      return newId;
    }
    await (db.update(db.maintenancePlans)..where((t) => t.id.equals(id))).write(
      MaintenancePlansCompanion(
        name: Value(name.trim()),
        intervalKm: Value(intervalKm),
        intervalDays: Value(intervalDays),
        updatedAt: Value(now),
      ),
    );
    return id;
  }

  Future<void> deletePlan(String id) async {
    final current = await (db.select(db.maintenancePlans)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (current == null) return;
    await (db.update(db.maintenancePlans)..where((t) => t.id.equals(id))).write(
      MaintenancePlansCompanion(
        isDeleted: const Value(true),
        updatedAt: Value(_stamp(current.updatedAt)),
      ),
    );
  }
}
