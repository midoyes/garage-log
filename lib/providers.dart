import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data/backup_service.dart';
import 'data/connection.dart';
import 'data/csv_export.dart';
import 'data/database.dart';
import 'data/repository.dart';
import 'data/sync_service.dart';
import 'domain/reminders.dart';

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

final csvProvider = Provider<CsvExporter>(
  (ref) => CsvExporter(ref.watch(dbProvider)),
);

final vehiclesProvider = StreamProvider<List<Vehicle>>(
  (ref) => ref.watch(repoProvider).watchVehicles(),
);

/// 使用者選擇的車輛 id，會存到本機，重開 App 後保留。
/// null = 尚未選擇（使用第一台）。
class SelectedVehicleNotifier extends StateNotifier<String?> {
  SelectedVehicleNotifier() : super(null) {
    _load();
  }

  static const _key = 'selected_vehicle_id';

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_key);
      if (mounted && saved != null && state == null) state = saved;
    } catch (_) {
      // 讀不到偏好設定時，退回使用第一台車
    }
  }

  Future<void> select(String id) async {
    state = id;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, id);
    } catch (_) {
      // 存不進去不影響使用
    }
  }
}

final selectedVehicleIdProvider =
    StateNotifierProvider<SelectedVehicleNotifier, String?>(
  (ref) => SelectedVehicleNotifier(),
);

/// 目前使用中的車輛；沒有任何車輛時為 null。
/// 記住的車輛已被刪除或不存在時，退回第一台。
final currentVehicleProvider = Provider<Vehicle?>((ref) {
  final vehicles = ref.watch(vehiclesProvider).valueOrNull ?? const <Vehicle>[];
  if (vehicles.isEmpty) return null;
  final id = ref.watch(selectedVehicleIdProvider);
  return vehicles.firstWhere((v) => v.id == id, orElse: () => vehicles.first);
});

final fuelLogsProvider = StreamProvider<List<FuelLog>>((ref) {
  final v = ref.watch(currentVehicleProvider);
  if (v == null) return Stream.value(const <FuelLog>[]);
  return ref.watch(repoProvider).watchFuelLogs(v.id);
});

final maintenanceProvider = StreamProvider<List<MaintenanceWithItems>>((ref) {
  final v = ref.watch(currentVehicleProvider);
  if (v == null) return Stream.value(const <MaintenanceWithItems>[]);
  return ref.watch(repoProvider).watchMaintenance(v.id);
});

final plansProvider = StreamProvider<List<MaintenancePlan>>((ref) {
  final v = ref.watch(currentVehicleProvider);
  if (v == null) return Stream.value(const <MaintenancePlan>[]);
  return ref.watch(repoProvider).watchPlans(v.id);
});

/// 目前里程 = 初始里程與所有加油 / 保養里程讀數中的最大值
/// （以使用者最後回報的里程為準，不假裝知道即時里程）。
final currentOdometerProvider = Provider<double?>((ref) {
  final v = ref.watch(currentVehicleProvider);
  if (v == null) return null;
  final fuel = ref.watch(fuelLogsProvider).valueOrNull ?? const <FuelLog>[];
  final maint =
      ref.watch(maintenanceProvider).valueOrNull ?? const <MaintenanceWithItems>[];
  return currentOdometerOf(
    initial: v.initialOdometer,
    readings: [
      for (final l in fuel) l.odometer,
      for (final m in maint) m.record.odometer,
    ],
  );
});

/// 「今天」（當地日期 00:00）。
///
/// 日期型提醒要在跨日、或 App 從背景回到前景時重算，所以不能只在
/// 資料變動時才取 DateTime.now()。這裡在午夜以及 App 回到前景時更新；
/// 不需要常駐背景服務。
class TodayNotifier extends StateNotifier<DateTime> with WidgetsBindingObserver {
  TodayNotifier([DateTime Function()? clock])
      : _clock = clock ?? DateTime.now,
        super(_dayOf((clock ?? DateTime.now)())) {
    WidgetsBinding.instance.addObserver(this);
    _schedule();
  }

  final DateTime Function() _clock;
  Timer? _timer;

  static DateTime _dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

  void refresh() {
    final today = _dayOf(_clock());
    if (today != state) state = today;
  }

  void _schedule() {
    _timer?.cancel();
    final now = _clock();
    final nextMidnight = DateTime(now.year, now.month, now.day + 1);
    _timer = Timer(nextMidnight.difference(now) + const Duration(seconds: 1), () {
      refresh();
      _schedule();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.resumed) {
      refresh();
      _schedule();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

final todayProvider = StateNotifierProvider<TodayNotifier, DateTime>(
  (ref) => TodayNotifier(),
);

/// 目前車輛所有週期的提醒結果（已依急迫程度排序）。
final remindersProvider = Provider<List<ReminderResult>>((ref) {
  final plans = ref.watch(plansProvider).valueOrNull ?? const <MaintenancePlan>[];
  final maint =
      ref.watch(maintenanceProvider).valueOrNull ?? const <MaintenanceWithItems>[];
  final odo = ref.watch(currentOdometerProvider) ?? 0;
  final records = partRecordsFrom(maint);
  final now = ref.watch(todayProvider);
  final list = [
    for (final p in plans)
      computeReminder(
        plan: PlanSpec(
          id: p.id,
          name: p.name,
          intervalKm: p.intervalKm,
          intervalDays: p.intervalDays,
        ),
        records: records,
        currentOdometer: odo,
        now: now,
      ),
  ]..sort(compareReminders);
  return list;
});

/// 統計頁期間：3 / 12 = 最近幾個月，0 = 全部。
final statsPeriodProvider = StateProvider<int>((ref) => 12);
