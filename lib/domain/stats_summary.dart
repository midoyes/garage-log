/// 統計期間彙總（純 Dart）。
library;

import 'cost_summary.dart';
import 'fuel_calculator.dart';

/// 一個油耗區間結果，附上結束日期。
class StatPoint {
  const StatPoint({required this.id, required this.date, required this.stat});

  final String id;
  final DateTime date;
  final FuelStat stat;

  double get kmPerL => stat.kmPerL;
}

/// 依日期、里程排序後，把各區間油耗轉成帶日期的資料點。
List<StatPoint> buildStatPoints(
  Iterable<FuelEntry> entries,
  Map<String, FuelStat> stats,
) {
  final sorted = entries.toList()
    ..sort((a, b) {
      final c = a.date.compareTo(b.date);
      return c != 0 ? c : a.odometer.compareTo(b.odometer);
    });
  return [
    for (final e in sorted)
      if (stats[e.id] != null) StatPoint(id: e.id, date: e.date, stat: stats[e.id]!),
  ];
}

/// 日期區間：[from, to)；任一端為 null 代表不設限。
class DateRange {
  const DateRange(this.from, this.to);

  final DateTime? from;
  final DateTime? to;

  bool contains(DateTime d) =>
      (from == null || !d.isBefore(from!)) && (to == null || d.isBefore(to!));
}

/// 最近 [months] 個月（含本月）。months <= 0 代表全部。
DateRange periodRange(DateTime now, int months) {
  if (months <= 0) return const DateRange(null, null);
  return DateRange(DateTime(now.year, now.month - months + 1, 1), null);
}

/// 緊接在 [periodRange] 之前、長度相同的上一期。months <= 0 時不設限（呼叫端應略過）。
DateRange previousPeriodRange(DateTime now, int months) {
  if (months <= 0) return const DateRange(null, null);
  return DateRange(
    DateTime(now.year, now.month - 2 * months + 1, 1),
    DateTime(now.year, now.month - months + 1, 1),
  );
}

class PeriodSummary {
  const PeriodSummary({
    required this.distanceKm,
    required this.liters,
    required this.fuelAmount,
    required this.maintenanceAmount,
    required this.intervals,
  });

  /// 期間內所有「跳停區間」的總里程
  final double distanceKm;
  final double liters;

  /// 這些區間內的加油金額（與 distanceKm 對應，口徑一致）
  final double fuelAmount;

  /// 同期間的保養花費
  final double maintenanceAmount;
  final int intervals;

  /// 平均油耗（總里程 / 總公升）
  double? get avgKmPerL => liters > 0 ? distanceKm / liters : null;

  /// 只含加油的每公里花費
  double? get fuelCostPerKm => distanceKm > 0 ? fuelAmount / distanceKm : null;

  /// 加油＋保養的每公里花費
  double? get allCostPerKm =>
      distanceKm > 0 ? (fuelAmount + maintenanceAmount) / distanceKm : null;
}

/// 彙總 [range] 內的油耗與花費。
PeriodSummary summarizePeriod({
  required Iterable<StatPoint> points,
  required Iterable<DatedAmount> maintenance,
  required DateRange range,
}) {
  var km = 0.0;
  var l = 0.0;
  var fuel = 0.0;
  var n = 0;
  for (final p in points) {
    if (!range.contains(p.date)) continue;
    km += p.stat.distanceKm;
    l += p.stat.liters;
    fuel += p.stat.amount;
    n++;
  }
  var maint = 0.0;
  for (final m in maintenance) {
    if (range.contains(m.date)) maint += m.amount;
  }
  return PeriodSummary(
    distanceKm: km,
    liters: l,
    fuelAmount: fuel,
    maintenanceAmount: maint,
    intervals: n,
  );
}

/// 偏離中位數超過 [tolerance]（預設 40%）的油耗筆數，用來提醒可能漏記或里程輸入錯誤。
int countOutliers(Iterable<double> values, {double tolerance = 0.4}) {
  final list = values.where((v) => v.isFinite).toList()..sort();
  if (list.length < 4) return 0;
  final mid = list.length ~/ 2;
  final median =
      list.length.isOdd ? list[mid] : (list[mid - 1] + list[mid]) / 2;
  if (median <= 0) return 0;
  return list.where((v) => (v - median).abs() / median > tolerance).length;
}
