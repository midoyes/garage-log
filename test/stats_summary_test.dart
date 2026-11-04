import 'package:flutter_test/flutter_test.dart';
import 'package:garage_log/domain/cost_summary.dart';
import 'package:garage_log/domain/fuel_calculator.dart';
import 'package:garage_log/domain/stats_summary.dart';

FuelEntry e(String id, int m, int d, double odo, double l, double amt) => FuelEntry(
      id: id,
      date: DateTime(2026, m, d),
      odometer: odo,
      liters: l,
      amount: amt,
    );

void main() {
  final entries = [
    e('a', 1, 1, 1000, 10, 300),
    e('b', 1, 10, 1400, 20, 600), // 400 km / 20 L
    e('c', 2, 1, 1700, 10, 300), // 300 km / 10 L
    e('d', 2, 20, 2000, 10, 300), // 300 km / 10 L
  ];
  final points = buildStatPoints(entries, computeFuelStats(entries));
  final maintenance = [DatedAmount(DateTime(2026, 2, 5), 800)];

  test('buildStatPoints：只含有油耗結果的紀錄，依日期排序', () {
    expect(points.map((p) => p.id), ['b', 'c', 'd']);
  });

  test('summarizePeriod（全部）：加權平均與每公里花費', () {
    final s = summarizePeriod(
      points: points,
      maintenance: maintenance,
      range: const DateRange(null, null),
    );
    expect(s.distanceKm, 1000);
    expect(s.liters, 40);
    expect(s.avgKmPerL, closeTo(25, 1e-9));
    expect(s.fuelCostPerKm, closeTo(1.2, 1e-9)); // 1200 / 1000
    expect(s.allCostPerKm, closeTo(2.0, 1e-9)); // (1200 + 800) / 1000
    expect(s.intervals, 3);
  });

  test('summarizePeriod（只看 2 月）：只含該期間的區間與保養', () {
    final s = summarizePeriod(
      points: points,
      maintenance: maintenance,
      range: DateRange(DateTime(2026, 2, 1), DateTime(2026, 3, 1)),
    );
    expect(s.distanceKm, 600);
    expect(s.avgKmPerL, closeTo(30, 1e-9));
    expect(s.allCostPerKm, closeTo((600 + 800) / 600, 1e-9));
  });

  test('沒有任何區間時，平均與每公里花費為 null', () {
    final s = summarizePeriod(
      points: points,
      maintenance: maintenance,
      range: DateRange(DateTime(2030, 1, 1), null),
    );
    expect(s.avgKmPerL, isNull);
    expect(s.fuelCostPerKm, isNull);
    expect(s.allCostPerKm, isNull);
  });

  test('periodRange / previousPeriodRange', () {
    final now = DateTime(2026, 2, 15);
    expect(periodRange(now, 3).from, DateTime(2025, 12, 1)); // 12、1、2 月
    expect(periodRange(now, 0).from, isNull);

    final prev = previousPeriodRange(now, 3);
    expect(prev.from, DateTime(2025, 9, 1));
    expect(prev.to, DateTime(2025, 12, 1));
    expect(prev.contains(DateTime(2025, 11, 30)), isTrue);
    expect(prev.contains(DateTime(2025, 12, 1)), isFalse);
  });

  group('countOutliers', () {
    test('偏離中位數超過 40% 的算異常', () {
      expect(countOutliers([10, 10, 10, 10, 10, 20]), 1);
    });

    test('正常波動不算', () {
      expect(countOutliers([10, 11, 9, 10]), 0);
    });

    test('資料少於 4 筆不判斷', () {
      expect(countOutliers([10, 30, 5]), 0);
    });
  });
}
