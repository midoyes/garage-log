import 'package:flutter_test/flutter_test.dart';
import 'package:garage_log/domain/fuel_calculator.dart';

FuelEntry e(String id, DateTime d, double odo) => FuelEntry(
      id: id,
      date: d,
      odometer: odo,
      liters: 10,
      amount: 300,
      isFullTank: true,
    );

void main() {
  final logs = [
    e('a', DateTime(2026, 1, 1), 1000),
    e('b', DateTime(2026, 3, 1), 2000),
    e('c', DateTime(2026, 5, 1), 3000),
  ];

  test('補登中間日期：範圍是前後兩筆之間', () {
    final b = fuelOdometerBounds(existing: logs, date: DateTime(2026, 2, 1));
    expect(b.prevMax, 1000);
    expect(b.nextMin, 2000);
  });

  test('比最新還晚：只有下限；比最早還早：只有上限', () {
    final after = fuelOdometerBounds(existing: logs, date: DateTime(2026, 9, 1));
    expect(after.prevMax, 3000);
    expect(after.nextMin, isNull);
    final early = fuelOdometerBounds(existing: logs, date: DateTime(2025, 1, 1));
    expect(early.prevMax, isNull);
    expect(early.nextMin, 1000);
  });

  test('編輯時排除自己', () {
    final b = fuelOdometerBounds(
        existing: logs, date: DateTime(2026, 3, 1), excludeId: 'b');
    expect(b.prevMax, 1000);
    expect(b.nextMin, 3000);
  });
}
