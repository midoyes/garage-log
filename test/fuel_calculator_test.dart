import 'package:flutter_test/flutter_test.dart';
import 'package:garage_log/domain/cost_summary.dart';
import 'package:garage_log/domain/fuel_calculator.dart';
import 'package:garage_log/domain/maintenance_calculator.dart';

FuelEntry e(String id, int month, int day, double odo, double liters,
        double amount, {bool full = true}) =>
    FuelEntry(
      id: id,
      date: DateTime(2026, month, day),
      odometer: odo,
      liters: liters,
      amount: amount,
      isFullTank: full,
    );

void main() {
  group('computeFuelStats', () {
    test('第一筆加滿只當起點，不計算油耗', () {
      final stats = computeFuelStats([e('a', 1, 1, 1000, 10, 300)]);
      expect(stats, isEmpty);
    });

    test('第二筆加滿：區間里程 / 本次公升數', () {
      final stats = computeFuelStats([
        e('a', 1, 1, 1000, 10, 300),
        e('b', 1, 10, 1400, 20, 600),
      ]);
      final b = stats['b']!;
      expect(b.distanceKm, 400);
      expect(b.kmPerL, closeTo(20, 1e-9));
      expect(b.costPerKm, closeTo(1.5, 1e-9));
      expect(stats.containsKey('a'), isFalse);
    });

    test('中間有未加滿補油：公升與金額累計到下一次加滿', () {
      final stats = computeFuelStats([
        e('a', 1, 1, 1000, 10, 300),
        e('b', 1, 10, 1400, 20, 600),
        e('c', 1, 20, 1600, 8, 240, full: false),
        e('d', 1, 25, 1900, 12, 360),
      ]);
      expect(stats.containsKey('c'), isFalse);
      final d = stats['d']!;
      expect(d.distanceKm, 500); // 1900 - 1400
      expect(d.liters, 20); // 8 + 12
      expect(d.kmPerL, closeTo(25, 1e-9));
      expect(d.costPerKm, closeTo(1.2, 1e-9)); // (240 + 360) / 500
    });

    test('第一次加滿之前的未加滿紀錄被忽略', () {
      final stats = computeFuelStats([
        e('x', 1, 1, 900, 5, 150, full: false),
        e('a', 1, 5, 1000, 10, 300),
        e('b', 1, 10, 1300, 15, 450),
      ]);
      expect(stats.keys, ['b']);
      expect(stats['b']!.kmPerL, closeTo(20, 1e-9));
    });

    test('輸入順序不影響結果（內部依日期、里程排序）', () {
      final stats = computeFuelStats([
        e('b', 1, 10, 1400, 20, 600),
        e('a', 1, 1, 1000, 10, 300),
      ]);
      expect(stats['b']!.kmPerL, closeTo(20, 1e-9));
    });

    test('overallKmPerL 為總里程 / 總公升的加權平均', () {
      final stats = computeFuelStats([
        e('a', 1, 1, 1000, 10, 300),
        e('b', 1, 10, 1400, 20, 600), // 400 km / 20 L
        e('c', 1, 20, 1700, 10, 300), // 300 km / 10 L
      ]);
      expect(overallKmPerL(stats.values), closeTo(700 / 30, 1e-9));
      expect(overallKmPerL(const []), isNull);
    });
  });

  group('validateFuelOdometer', () {
    final existing = [
      e('a', 1, 1, 1000, 10, 300),
      e('b', 1, 10, 1400, 20, 600),
    ];

    test('新紀錄里程必須大於上一筆', () {
      expect(
        validateFuelOdometer(
            existing: existing, date: DateTime(2026, 1, 20), odometer: 1400),
        isNotNull,
      );
      expect(
        validateFuelOdometer(
            existing: existing, date: DateTime(2026, 1, 20), odometer: 1399),
        isNotNull,
      );
      expect(
        validateFuelOdometer(
            existing: existing, date: DateTime(2026, 1, 20), odometer: 1401),
        isNull,
      );
    });

    test('插入歷史中間時必須介於前後兩筆之間', () {
      final date = DateTime(2026, 1, 5);
      expect(
          validateFuelOdometer(existing: existing, date: date, odometer: 1200),
          isNull);
      expect(
          validateFuelOdometer(existing: existing, date: date, odometer: 1400),
          isNotNull);
      expect(
          validateFuelOdometer(existing: existing, date: date, odometer: 1000),
          isNotNull);
    });

    test('編輯自己時排除自己，不會與自己衝突', () {
      expect(
        validateFuelOdometer(
          existing: existing,
          date: DateTime(2026, 1, 10),
          odometer: 1450,
          excludeId: 'b',
        ),
        isNull,
      );
    });

    test('沒有上一筆時不可小於初始里程', () {
      expect(
        validateFuelOdometer(
          existing: const [],
          date: DateTime(2026, 1, 1),
          odometer: 500,
          initialOdometer: 800,
        ),
        isNotNull,
      );
      expect(
        validateFuelOdometer(
          existing: const [],
          date: DateTime(2026, 1, 1),
          odometer: 800,
          initialOdometer: 800,
        ),
        isNull,
      );
    });
  });

  group('保養明細', () {
    test('小計 = 數量 × 單價，總額為小計加總', () {
      const items = [
        ItemInput(name: '機油', quantity: 4, unitPrice: 350),
        ItemInput(name: '機油濾芯', quantity: 1, unitPrice: 180),
        ItemInput(name: '工資', quantity: 1, unitPrice: 500),
      ];
      expect(items[0].subtotal, 1400);
      expect(computeItemsTotal(items), 2080);
    });

    test('小數數量不會累積浮點誤差', () {
      const items = [
        ItemInput(name: '齒輪油', quantity: 0.1, unitPrice: 3),
        ItemInput(name: '齒輪油', quantity: 0.2, unitPrice: 3),
      ];
      expect(computeItemsTotal(items), 0.9);
    });
  });

  group('computeMonthlyCosts', () {
    test('依月份彙總加油與保養並排序', () {
      final months = computeMonthlyCosts(
        fuel: [
          DatedAmount(DateTime(2026, 2, 3), 500),
          DatedAmount(DateTime(2026, 1, 10), 300),
          DatedAmount(DateTime(2026, 1, 25), 200),
        ],
        maintenance: [DatedAmount(DateTime(2026, 2, 14), 2080)],
      );
      expect(months.length, 2);
      expect(months[0].month, DateTime(2026, 1));
      expect(months[0].fuel, 500);
      expect(months[0].maintenance, 0);
      expect(months[1].fuel, 500);
      expect(months[1].maintenance, 2080);
      expect(months[1].total, 2580);
    });
  });
}
