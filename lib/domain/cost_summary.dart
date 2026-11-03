/// 每月花費彙總（純 Dart）。
library;

class DatedAmount {
  const DatedAmount(this.date, this.amount);
  final DateTime date;
  final double amount;
}

class MonthlyCost {
  const MonthlyCost({
    required this.month,
    required this.fuel,
    required this.maintenance,
  });

  /// 當月 1 日 00:00
  final DateTime month;
  final double fuel;
  final double maintenance;

  double get total => fuel + maintenance;
}

/// 依月份彙總加油與保養花費，依月份由舊到新排序。
List<MonthlyCost> computeMonthlyCosts({
  required Iterable<DatedAmount> fuel,
  required Iterable<DatedAmount> maintenance,
}) {
  final map = <DateTime, List<double>>{};

  void add(Iterable<DatedAmount> items, int index) {
    for (final i in items) {
      final key = DateTime(i.date.year, i.date.month);
      map.putIfAbsent(key, () => [0.0, 0.0])[index] += i.amount;
    }
  }

  add(fuel, 0);
  add(maintenance, 1);

  final months = map.keys.toList()..sort();
  return [
    for (final m in months)
      MonthlyCost(month: m, fuel: map[m]![0], maintenance: map[m]![1]),
  ];
}
