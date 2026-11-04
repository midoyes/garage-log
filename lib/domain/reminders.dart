/// 保養週期提醒與零件更換歷史（純 Dart）。
///
/// 設計原則：
/// - 週期由車主自訂（里程、天數可擇一或兩者），不假設任何通用數值。
/// - 里程以「使用者最後回報的里程」計算，不假裝知道車輛即時里程。
/// - 同時設定里程與日期時，任一條件先到就提醒。
/// - 「同一個零件」以名稱正規化後比對（忽略空白與大小寫）。
library;

import 'dart:math' as math;

import 'maintenance_calculator.dart';

/// 一筆零件更換紀錄（由保養明細攤平而來）。
class PartRecord {
  const PartRecord({
    required this.name,
    required this.date,
    required this.odometer,
    this.quantity = 1,
    this.unitPrice = 0,
  });

  final String name;
  final DateTime date;
  final double odometer;
  final double quantity;
  final double unitPrice;

  double get subtotal => roundMoney(quantity * unitPrice);
}

/// 保養週期設定。intervalKm / intervalDays 為 0 代表不設定該條件。
class PlanSpec {
  const PlanSpec({
    required this.id,
    required this.name,
    this.intervalKm = 0,
    this.intervalDays = 0,
  });

  final String id;
  final String name;
  final double intervalKm;
  final int intervalDays;

  bool get hasKm => intervalKm > 0;
  bool get hasDays => intervalDays > 0;
}

enum ReminderStatus { overdue, soon, ok, noHistory, noInterval }

class ReminderResult {
  const ReminderResult({
    required this.plan,
    required this.status,
    required this.historyCount,
    this.lastDate,
    this.lastOdometer,
    this.dueOdometer,
    this.dueDate,
    this.remainingKm,
    this.remainingDays,
  });

  final PlanSpec plan;
  final ReminderStatus status;
  final int historyCount;
  final DateTime? lastDate;
  final double? lastOdometer;
  final double? dueOdometer;
  final DateTime? dueDate;

  /// 距離下次保養還剩多少公里（負數 = 已超過）。
  final double? remainingKm;

  /// 距離下次保養還剩多少天（負數 = 已逾期）。
  final int? remainingDays;

  /// 急迫程度，越小越急（已超過為負數）。沒有可比較的條件時為 null。
  double? get urgency {
    final parts = <double>[];
    if (remainingKm != null && plan.hasKm) {
      parts.add(remainingKm! / plan.intervalKm);
    }
    if (remainingDays != null && plan.hasDays) {
      parts.add(remainingDays! / plan.intervalDays);
    }
    return parts.isEmpty ? null : parts.reduce(math.min);
  }
}

/// 目前里程 = 初始里程與所有已知里程讀數中的最大值。
double currentOdometerOf({
  required double initial,
  required Iterable<double> readings,
}) {
  var best = initial;
  for (final r in readings) {
    if (r.isFinite && r > best) best = r;
  }
  return best;
}

/// 取得某零件的更換歷史（最新的在前）。
List<PartRecord> partHistory(Iterable<PartRecord> records, String name) {
  final key = normalizeItemName(name);
  final list = records.where((r) => normalizeItemName(r.name) == key).toList()
    ..sort((a, b) {
      final c = b.date.compareTo(a.date);
      return c != 0 ? c : b.odometer.compareTo(a.odometer);
    });
  return list;
}

/// 計算單一週期的提醒狀態。
ReminderResult computeReminder({
  required PlanSpec plan,
  required Iterable<PartRecord> records,
  required double currentOdometer,
  required DateTime now,
}) {
  final hist = partHistory(records, plan.name);
  final last = hist.isEmpty ? null : hist.first;

  if (!plan.hasKm && !plan.hasDays) {
    return ReminderResult(
      plan: plan,
      status: ReminderStatus.noInterval,
      historyCount: hist.length,
      lastDate: last?.date,
      lastOdometer: last?.odometer,
    );
  }
  if (last == null) {
    return ReminderResult(
      plan: plan,
      status: ReminderStatus.noHistory,
      historyCount: 0,
    );
  }

  final dueOdo = plan.hasKm ? last.odometer + plan.intervalKm : null;
  final dueDate = plan.hasDays
      ? DateTime(last.date.year, last.date.month, last.date.day + plan.intervalDays)
      : null;
  final today = DateTime(now.year, now.month, now.day);
  final remKm = dueOdo == null ? null : dueOdo - currentOdometer;
  final remDays = dueDate?.difference(today).inDays;

  final overdue = (remKm != null && remKm <= 0) || (remDays != null && remDays <= 0);
  final soonKm = math.max(200.0, plan.intervalKm * 0.1);
  final soonDays = math.max(7, (plan.intervalDays * 0.1).round());
  final soon = (remKm != null && remKm <= soonKm) ||
      (remDays != null && remDays <= soonDays);

  return ReminderResult(
    plan: plan,
    status: overdue
        ? ReminderStatus.overdue
        : (soon ? ReminderStatus.soon : ReminderStatus.ok),
    historyCount: hist.length,
    lastDate: last.date,
    lastOdometer: last.odometer,
    dueOdometer: dueOdo,
    dueDate: dueDate,
    remainingKm: remKm,
    remainingDays: remDays,
  );
}

int _rank(ReminderStatus s) => switch (s) {
      ReminderStatus.overdue => 0,
      ReminderStatus.soon => 1,
      ReminderStatus.ok => 2,
      ReminderStatus.noHistory => 3,
      ReminderStatus.noInterval => 4,
    };

/// 排序：已超過 → 即將到期 → 正常 → 無紀錄 → 未設定週期；同組內越急越前面。
int compareReminders(ReminderResult a, ReminderResult b) {
  final r = _rank(a.status).compareTo(_rank(b.status));
  if (r != 0) return r;
  final ua = a.urgency;
  final ub = b.urgency;
  if (ua != null && ub != null) {
    final c = ua.compareTo(ub);
    if (c != 0) return c;
  }
  return a.plan.name.compareTo(b.plan.name);
}

/// 零件總覽（每個零件一列）。
class PartSummary {
  const PartSummary({required this.name, required this.count, required this.last});

  final String name;
  final int count;
  final PartRecord last;
}

/// 將所有更換紀錄依零件彙總，最近更換的在前。
List<PartSummary> summarizeParts(Iterable<PartRecord> records) {
  final groups = <String, List<PartRecord>>{};
  for (final r in records) {
    final key = normalizeItemName(r.name);
    if (key.isEmpty) continue;
    (groups[key] ??= []).add(r);
  }
  final result = <PartSummary>[];
  for (final list in groups.values) {
    list.sort((a, b) {
      final c = b.date.compareTo(a.date);
      return c != 0 ? c : b.odometer.compareTo(a.odometer);
    });
    result.add(PartSummary(name: list.first.name.trim(), count: list.length, last: list.first));
  }
  result.sort((a, b) => b.last.date.compareTo(a.last.date));
  return result;
}
