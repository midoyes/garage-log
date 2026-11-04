import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garage_log/data/database.dart';
import 'package:garage_log/data/repository.dart';
import 'package:garage_log/domain/maintenance_calculator.dart';

/// v1 的資料表結構（與 v1 版 App 建立的一致），用來驗證 v1 → v2 升級不遺失資料。
const _v1Schema = [
  '''CREATE TABLE vehicles (
    id TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
    is_deleted INTEGER NOT NULL DEFAULT 0,
    type INTEGER NOT NULL DEFAULT 0, name TEXT NOT NULL,
    plate TEXT NOT NULL DEFAULT '', initial_odometer REAL NOT NULL DEFAULT 0.0,
    PRIMARY KEY (id))''',
  '''CREATE TABLE fuel_logs (
    id TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
    is_deleted INTEGER NOT NULL DEFAULT 0,
    vehicle_id TEXT NOT NULL, date INTEGER NOT NULL, odometer REAL NOT NULL,
    liters REAL NOT NULL, amount REAL NOT NULL, unit_price REAL NOT NULL DEFAULT 0.0,
    is_full_tank INTEGER NOT NULL DEFAULT 1, note TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (id))''',
  '''CREATE TABLE maintenance_records (
    id TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
    is_deleted INTEGER NOT NULL DEFAULT 0,
    vehicle_id TEXT NOT NULL, date INTEGER NOT NULL,
    odometer REAL NOT NULL DEFAULT 0.0, total_amount REAL NOT NULL DEFAULT 0.0,
    note TEXT NOT NULL DEFAULT '', PRIMARY KEY (id))''',
  '''CREATE TABLE maintenance_items (
    id TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
    is_deleted INTEGER NOT NULL DEFAULT 0,
    record_id TEXT NOT NULL, name TEXT NOT NULL,
    quantity REAL NOT NULL DEFAULT 1.0, unit_price REAL NOT NULL DEFAULT 0.0,
    sort_order INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (id))''',
  "INSERT INTO vehicles (id, created_at, updated_at, type, name, plate, initial_odometer) "
      "VALUES ('v1', 1, 1, 1, '舊車', 'ABC-123', 500.0)",
  "INSERT INTO fuel_logs (id, created_at, updated_at, vehicle_id, date, odometer, liters, amount, unit_price, is_full_tank, note) "
      "VALUES ('f1', 2, 2, 'v1', 1767225600000, 600.0, 5.5, 165.0, 30.0, 1, '舊備註')",
  "INSERT INTO maintenance_records (id, created_at, updated_at, vehicle_id, date, odometer, total_amount, note) "
      "VALUES ('m1', 3, 3, 'v1', 1767225600000, 650.0, 600.0, '')",
  "INSERT INTO maintenance_items (id, created_at, updated_at, record_id, name, quantity, unit_price, sort_order) "
      "VALUES ('i1', 3, 3, 'm1', '機油', 2.0, 300.0, 0)",
];

void main() {
  test('v1 資料庫升級到 v2：舊資料完整保留，新欄位有預設值，新資料表可用', () async {
    final db = AppDatabase(
      NativeDatabase.memory(
        setup: (raw) {
          for (final sql in _v1Schema) {
            raw.execute(sql);
          }
          raw.execute('PRAGMA user_version = 1');
        },
      ),
    );
    addTearDown(db.close);
    final repo = GarageRepository(db);

    // 舊車輛
    final vehicles = await repo.watchVehicles().first;
    expect(vehicles.single.name, '舊車');
    expect(vehicles.single.plate, 'ABC-123');
    expect(vehicles.single.type, 1);
    expect(vehicles.single.initialOdometer, 500);
    expect(vehicles.single.defaultFuelType, ''); // v2 新欄位

    // 舊加油紀錄
    final fuel = await repo.watchFuelLogs('v1').first;
    expect(fuel.single.odometer, 600);
    expect(fuel.single.liters, 5.5);
    expect(fuel.single.note, '舊備註');
    expect(fuel.single.fuelType, ''); // v2 新欄位

    // 舊保養單與明細
    final maint = await repo.watchMaintenance('v1').first;
    expect(maint.single.record.totalAmount, 600);
    expect(maint.single.items.single.name, '機油');
    expect(maint.single.items.single.quantity, 2);

    // v2 新資料表可以使用，索引也存在
    await repo.savePlan(vehicleId: 'v1', name: '機油', intervalKm: 3000);
    expect((await repo.watchPlans('v1').first).single.intervalKm, 3000);
    final idx = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'idx_plans_vehicle'",
        )
        .get();
    expect(idx, hasLength(1));

    // 升級後仍可正常新增（用新欄位）
    await repo.saveFuelLog(
      vehicleId: 'v1',
      date: DateTime(2026, 2, 1),
      odometer: 900,
      liters: 10,
      amount: 300,
      fuelType: '95',
    );
    final after = await repo.watchFuelLogs('v1').first;
    expect(after.length, 2);
    expect(after.last.fuelType, '95');
  });

  test('v1 一路升級到 v3：保養照片資料表與索引存在，可新增與讀取', () async {
    final db = AppDatabase(
      NativeDatabase.memory(
        setup: (raw) {
          for (final sql in _v1Schema) {
            raw.execute(sql);
          }
          raw.execute('PRAGMA user_version = 1');
        },
      ),
    );
    addTearDown(db.close);
    final repo = GarageRepository(db);
    await repo.saveMaintenance(
      id: 'm1',
      vehicleId: 'v1',
      date: DateTime(2026, 1, 1),
      odometer: 650,
      items: const [ItemInput(name: '機油', quantity: 2, unitPrice: 300)],
      photos: const [PhotoInput(fileName: 'a.jpg', sizeBytes: 10)],
    );
    final photos = await repo.watchPhotos().first;
    expect(photos.single.fileName, 'a.jpg');
    expect(photos.single.recordId, 'm1');
    final idx = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'idx_maint_photos_record'",
        )
        .get();
    expect(idx, hasLength(1));
  });

  test('全新安裝直接建立 v3 結構', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    expect(db.schemaVersion, 3);
    final id = await GarageRepository(db).addVehicle(
      type: 0,
      name: '新車',
      defaultFuelType: '95',
    );
    final v = (await db.select(db.vehicles).get()).single;
    expect(v.id, id);
    expect(v.defaultFuelType, '95');
  });
}
