import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/backup_service.dart';
import 'data/connection.dart';
import 'data/database.dart';
import 'data/repository.dart';
import 'data/sync_service.dart';

final dbProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase(openAppConnection());
  ref.onDispose(db.close);
  return db;
});

final repoProvider = Provider<GarageRepository>(
  (ref) => GarageRepository(ref.watch(dbProvider)),
);

final backupProvider = Provider<BackupService>(
  (ref) => BackupService(ref.watch(dbProvider)),
);

final syncProvider = Provider<SyncService>(
  (ref) => SyncService(ref.watch(backupProvider)),
);

final vehiclesProvider = StreamProvider<List<Vehicle>>(
  (ref) => ref.watch(repoProvider).watchVehicles(),
);

/// 使用者選擇的車輛 id（null = 預設第一台）。
final selectedVehicleIdProvider = StateProvider<String?>((ref) => null);

/// 目前使用中的車輛；沒有任何車輛時為 null。
final currentVehicleProvider = Provider<Vehicle?>((ref) {
  final vehicles = ref.watch(vehiclesProvider).valueOrNull ?? const [];
  if (vehicles.isEmpty) return null;
  final id = ref.watch(selectedVehicleIdProvider);
  return vehicles.firstWhere((v) => v.id == id, orElse: () => vehicles.first);
});

final fuelLogsProvider = StreamProvider.autoDispose<List<FuelLog>>((ref) {
  final v = ref.watch(currentVehicleProvider);
  if (v == null) return Stream.value(const <FuelLog>[]);
  return ref.watch(repoProvider).watchFuelLogs(v.id);
});

final maintenanceProvider =
    StreamProvider.autoDispose<List<MaintenanceWithItems>>((ref) {
  final v = ref.watch(currentVehicleProvider);
  if (v == null) return Stream.value(const <MaintenanceWithItems>[]);
  return ref.watch(repoProvider).watchMaintenance(v.id);
});
