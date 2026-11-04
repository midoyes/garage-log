import 'package:drift/drift.dart';

import 'tables.dart';

part 'database.g.dart';

@DriftDatabase(
  tables: [
    Vehicles,
    FuelLogs,
    MaintenanceRecords,
    MaintenanceItems,
    MaintenancePlans,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);

  /// 版本紀錄：
  /// - v1：車輛、加油、保養單、保養明細
  /// - v2：新增 maintenance_plans（保養週期）、fuel_logs.fuel_type、vehicles.default_fuel_type
  ///
  /// 規則：每次改動資料結構都必須提高 schemaVersion、在 onUpgrade 補遷移步驟，
  /// 並在 test/migration_test.dart 加上升級前後資料不遺失的測試。
  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.addColumn(fuelLogs, fuelLogs.fuelType);
            await m.addColumn(vehicles, vehicles.defaultFuelType);
            await m.createTable(maintenancePlans);
            await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_plans_vehicle '
              'ON maintenance_plans (vehicle_id)',
            );
          }
        },
      );
}
