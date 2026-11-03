import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../domain/fuel_calculator.dart';
import '../domain/maintenance_calculator.dart';
import 'database.dart';

/// 輸入資料不合法（里程防呆、欄位範圍等）。
class GarageValidationException implements Exception {
  const GarageValidationException(this.message);
  final String message;

  @override
  String toString() => message;
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

/// 所有讀寫都集中在這裡：
/// - 主鍵一律 UUID v4
/// - 每次寫入更新 updatedAt
/// - 刪除一律軟刪除（isDeleted = true），查詢一律過濾已刪除資料
class GarageRepository {
  GarageRepository(
    this.db, {
    Uuid? uuid,
    int Function()? clock,
  })  : _uuid = uuid ?? const Uuid(),
        _now = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final AppDatabase db;
  final Uuid _uuid;
  final int Function() _now;

  static int dayMillis(DateTime d) =>
      DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;

  // ───────────────────────── 車輛 ─────────────────────────

  Stream<List<Vehicle>> watchVehicles() {
    final q = db.select(db.vehicles)
      ..where((t) => t.isDeleted.equals(false))
      ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]);
    return q.watch();
  }

  Future<String> addVehicle({
    required int type,
    required String name,
    String plate = '',
    double initialOdometer = 0,
  }) async {
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
          ),
        );
    return id;
  }

  Future<void> updateVehicle(
    String id, {
    required int type,
    required String name,
    String plate = '',
    double initialOdometer = 0,
  }) async {
    await (db.update(db.vehicles)..where((t) => t.id.equals(id))).write(
      VehiclesCompanion(
        type: Value(type),
        name: Value(name.trim()),
        plate: Value(plate.trim()),
        initialOdometer: Value(initialOdometer),
        updatedAt: Value(_now()),
      ),
    );
  }

  /// 軟刪除車輛，並連帶軟刪除其加油、保養與明細。
  Future<void> deleteVehicle(String id) async {
    final now = _now();
    await db.transaction(() async {
      final records = await (db.select(db.maintenanceRecords)
            ..where((t) => t.vehicleId.equals(id)))
          .get();
      for (final r in records) {
        await (db.update(db.maintenanceItems)
              ..where((t) => t.recordId.equals(r.id)))
            .write(MaintenanceItemsCompanion(
          isDeleted: const Value(true),
          updatedAt: Value(now),
        ));
      }
      await (db.update(db.maintenanceRecords)
            ..where((t) => t.vehicleId.equals(id)))
          .write(MaintenanceRecordsCompanion(
        isDeleted: const Value(true),
        updatedAt: Value(now),
      ));
      await (db.update(db.fuelLogs)..where((t) => t.vehicleId.equals(id)))
          .write(FuelLogsCompanion(
        isDeleted: const Value(true),
        updatedAt: Value(now),
      ));
      await (db.update(db.vehicles)..where((t) => t.id.equals(id)))
          .write(VehiclesCompanion(
        isDeleted: const Value(true),
        updatedAt: Value(now),
      ));
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
    String note = '',
  }) async {
    if (liters <= 0) throw const GarageValidationException('公升數必須大於 0');
    if (amount < 0) throw const GarageValidationException('金額不可為負數');

    final vehicle = await (db.select(db.vehicles)
          ..where((t) => t.id.equals(vehicleId)))
        .getSingleOrNull();
    if (vehicle == null || vehicle.isDeleted) {
      throw const GarageValidationException('找不到車輛');
    }

    final existing = await (db.select(db.fuelLogs)
          ..where(
              (t) => t.vehicleId.equals(vehicleId) & t.isDeleted.equals(false)))
        .get();

    final error = validateFuelOdometer(
      existing: existing.map(fuelLogToEntry),
      date: date,
      odometer: odometer,
      initialOdometer: vehicle.initialOdometer,
      excludeId: id,
    );
    if (error != null) throw GarageValidationException(error);

    final price = unitPrice ?? (amount / liters);
    final now = _now();

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
        note: Value(note.trim()),
        updatedAt: Value(now),
      ),
    );
    return id;
  }

  Future<void> deleteFuelLog(String id) async {
    await (db.update(db.fuelLogs)..where((t) => t.id.equals(id))).write(
      FuelLogsCompanion(
        isDeleted: const Value(true),
        updatedAt: Value(_now()),
      ),
    );
  }

  // ───────────────────────── 保養 ─────────────────────────

  Stream<List<MaintenanceWithItems>> watchMaintenance(String vehicleId) {
    final q = db.select(db.maintenanceRecords)
      ..where((t) => t.vehicleId.equals(vehicleId) & t.isDeleted.equals(false))
      ..orderBy([(t) => OrderingTerm.desc(t.date)]);

    return q.watch().asyncMap((records) async {
      if (records.isEmpty) return <MaintenanceWithItems>[];
      final items = await (db.select(db.maintenanceItems)
            ..where((t) =>
                t.recordId.isIn(records.map((r) => r.id).toList()) &
                t.isDeleted.equals(false))
            ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
          .get();
      return [
        for (final r in records)
          MaintenanceWithItems(
            r,
            items.where((i) => i.recordId == r.id).toList(),
          ),
      ];
    });
  }

  /// 新增（id == null）或編輯保養單。總金額 = 明細小計加總。
  /// 編輯時：沒出現在 [items] 的舊明細會被軟刪除；有 id 的更新；沒 id 的新增。
  Future<String> saveMaintenance({
    String? id,
    required String vehicleId,
    required DateTime date,
    required double odometer,
    required List<ItemInput> items,
    String note = '',
  }) async {
    if (odometer < 0) throw const GarageValidationException('里程不可為負數');
    final valid = items.where((i) => i.name.trim().isNotEmpty).toList();
    if (valid.isEmpty) throw const GarageValidationException('請至少輸入一個保養項目');

    final total = computeItemsTotal(valid);
    final now = _now();
    final recordId = id ?? _uuid.v4();

    await db.transaction(() async {
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

      final oldItems = await (db.select(db.maintenanceItems)
            ..where((t) =>
                t.recordId.equals(recordId) & t.isDeleted.equals(false)))
          .get();
      final keepIds = valid.map((i) => i.id).whereType<String>().toSet();

      for (final old in oldItems) {
        if (!keepIds.contains(old.id)) {
          await (db.update(db.maintenanceItems)
                ..where((t) => t.id.equals(old.id)))
              .write(MaintenanceItemsCompanion(
            isDeleted: const Value(true),
            updatedAt: Value(now),
          ));
        }
      }

      for (var i = 0; i < valid.length; i++) {
        final item = valid[i];
        if (item.id != null) {
          await (db.update(db.maintenanceItems)
                ..where((t) => t.id.equals(item.id!)))
              .write(MaintenanceItemsCompanion(
            name: Value(item.name.trim()),
            quantity: Value(item.quantity),
            unitPrice: Value(item.unitPrice),
            sortOrder: Value(i),
            updatedAt: Value(now),
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
    });
    return recordId;
  }

  Future<void> deleteMaintenance(String id) async {
    final now = _now();
    await db.transaction(() async {
      await (db.update(db.maintenanceItems)
            ..where((t) => t.recordId.equals(id)))
          .write(MaintenanceItemsCompanion(
        isDeleted: const Value(true),
        updatedAt: Value(now),
      ));
      await (db.update(db.maintenanceRecords)..where((t) => t.id.equals(id)))
          .write(MaintenanceRecordsCompanion(
        isDeleted: const Value(true),
        updatedAt: Value(now),
      ));
    });
  }
}
