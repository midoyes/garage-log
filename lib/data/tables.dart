import 'package:drift/drift.dart';

/// 所有實體共用的「同步預留」欄位。
///
/// - [id]：UUID v4 字串（嚴禁自動遞增整數，避免多裝置主鍵衝突）
/// - [createdAt] / [updatedAt]：Unix epoch 毫秒（UTC）
/// - [isDeleted]：軟刪除旗標（墓碑），讓刪除也能在裝置間同步
///
/// 同步合併規則：以 [updatedAt] 較新者為準（Last-Write-Wins）。
/// 刻意不使用外鍵約束：合併時子資料可能早於父資料抵達。
mixin SyncColumns on Table {
  TextColumn get id => text()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

/// 車輛。type: 0 = 汽車, 1 = 機車
@TableIndex(name: 'idx_vehicles_updated', columns: {#updatedAt})
class Vehicles extends Table with SyncColumns {
  IntColumn get type => integer().withDefault(const Constant(0))();
  TextColumn get name => text()();
  TextColumn get plate => text().withDefault(const Constant(''))();
  RealColumn get initialOdometer => real().withDefault(const Constant(0.0))();

  /// 這台車預設油品（92 / 95 / 98 / 柴油 / 其他；空字串 = 未設定）。v2 新增。
  TextColumn get defaultFuelType => text().withDefault(const Constant(''))();
}

/// 加油紀錄。date 為當日 00:00（本地時間）的 epoch 毫秒。
@TableIndex(name: 'idx_fuel_vehicle_date', columns: {#vehicleId, #date})
@TableIndex(name: 'idx_fuel_updated', columns: {#updatedAt})
class FuelLogs extends Table with SyncColumns {
  TextColumn get vehicleId => text()();
  IntColumn get date => integer()();
  RealColumn get odometer => real()();
  RealColumn get liters => real()();
  RealColumn get amount => real()();
  RealColumn get unitPrice => real().withDefault(const Constant(0.0))();

  /// 是否「跳停」（加滿）。油耗以跳停為區間基準。
  BoolColumn get isFullTank => boolean().withDefault(const Constant(true))();
  TextColumn get note => text().withDefault(const Constant(''))();

  /// 油品（92 / 95 / 98 / 柴油 / 其他；空字串 = 未記錄）。v2 新增。
  TextColumn get fuelType => text().withDefault(const Constant(''))();
}

/// 保養維修單（主檔）。totalAmount 由明細累加後寫入，方便統計查詢。
@TableIndex(name: 'idx_maint_vehicle_date', columns: {#vehicleId, #date})
@TableIndex(name: 'idx_maint_updated', columns: {#updatedAt})
class MaintenanceRecords extends Table with SyncColumns {
  TextColumn get vehicleId => text()();
  IntColumn get date => integer()();
  RealColumn get odometer => real().withDefault(const Constant(0.0))();
  RealColumn get totalAmount => real().withDefault(const Constant(0.0))();
  TextColumn get note => text().withDefault(const Constant(''))();
}

/// 保養明細。小計 = quantity × unitPrice（不另存，避免不一致）。
@TableIndex(name: 'idx_maint_items_record', columns: {#recordId})
@TableIndex(name: 'idx_maint_items_updated', columns: {#updatedAt})
class MaintenanceItems extends Table with SyncColumns {
  TextColumn get recordId => text()();
  TextColumn get name => text()();
  RealColumn get quantity => real().withDefault(const Constant(1.0))();
  RealColumn get unitPrice => real().withDefault(const Constant(0.0))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
}

/// 保養週期設定（也兼作「自訂常用項目」：週期都是 0 就只是常用項目）。v2 新增。
///
/// 以 [name] 與保養明細的項目名稱（正規化後）比對，找出該零件最後一次更換。
@TableIndex(name: 'idx_plans_vehicle', columns: {#vehicleId})
class MaintenancePlans extends Table with SyncColumns {
  TextColumn get vehicleId => text()();
  TextColumn get name => text()();

  /// 里程週期（km）；0 = 不依里程提醒
  RealColumn get intervalKm => real().withDefault(const Constant(0.0))();

  /// 日期週期（天）；0 = 不依日期提醒
  IntColumn get intervalDays => integer().withDefault(const Constant(0))();
}
