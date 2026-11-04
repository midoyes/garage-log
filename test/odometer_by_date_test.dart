import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garage_log/data/database.dart';
import 'package:garage_log/data/repository.dart';
import 'package:garage_log/domain/fuel_calculator.dart';
import 'package:garage_log/domain/maintenance_calculator.dart';

OdometerReading r(String id, DateTime d, double odo, [String label = '加油']) =>
    OdometerReading(id: id, date: d, odometer: odo, label: label);

void main() {
  final readings = [
    r('a', DateTime(2026, 1, 1), 1000),
    r('b', DateTime(2026, 3, 1), 2000, '保養'),
    r('c', DateTime(2026, 5, 1), 3000),
  ];

  group('validateOdometerByDate', () {
    test('選較早的日期，可以填較小的里程', () {
      expect(validateOdometerByDate(readings: readings, date: DateTime(2026, 2, 1), odometer: 1500), isNull);
    });
    test('選今天卻填比以前小的里程 → 擋下，並提示改日期', () {
      final err = validateOdometerByDate(readings: readings, date: DateTime(2026, 9, 1), odometer: 1500);
      expect(err, contains('改成當時的日期'));
    });
    test('補登日期但里程超過後面的紀錄 → 擋下', () {
      expect(validateOdometerByDate(readings: readings, date: DateTime(2026, 2, 1), odometer: 2500), isNotNull);
    });
    test('可以等於前後紀錄', () {
      expect(validateOdometerByDate(readings: readings, date: DateTime(2026, 2, 1), odometer: 1000), isNull);
      expect(validateOdometerByDate(readings: readings, date: DateTime(2026, 2, 1), odometer: 2000), isNull);
    });
    test('同一天不互相限制', () {
      expect(validateOdometerByDate(readings: readings, date: DateTime(2026, 3, 1), odometer: 1800), isNull);
    });
    test('排除自己（編輯）', () {
      expect(validateOdometerByDate(readings: readings, date: DateTime(2026, 5, 1), odometer: 2500, excludeId: 'c'), isNull);
    });
    test('沒有更早紀錄時不可小於初始里程', () {
      expect(validateOdometerByDate(readings: readings, date: DateTime(2025, 1, 1), odometer: 50, initialOdometer: 100), isNotNull);
    });
  });

  group('跨加油與保養', () {
    late AppDatabase db;
    late GarageRepository repo;
    var t = 1000;
    setUp(() {
      t = 1000;
      db = AppDatabase(NativeDatabase.memory());
      repo = GarageRepository(db, clock: () => t++);
    });
    tearDown(() => db.close());

    test('保養里程不能比較早日期的加油還小；改成舊日期就可以補登', () async {
      final v = await repo.addVehicle(type: 0, name: '車', initialOdometer: 0);
      await repo.saveFuelLog(vehicleId: v, date: DateTime(2026, 6, 1), odometer: 5000, liters: 10, amount: 300);
      final items = [const ItemInput(name: '機油', quantity: 1, unitPrice: 500)];
      await expectLater(
        repo.saveMaintenance(vehicleId: v, date: DateTime(2026, 7, 1), odometer: 4000, items: items),
        throwsA(isA<GarageValidationException>()),
      );
      await repo.saveMaintenance(vehicleId: v, date: DateTime(2026, 5, 1), odometer: 4000, items: items);
    });

    test('加油里程不能比較早日期的保養還小', () async {
      final v = await repo.addVehicle(type: 0, name: '車', initialOdometer: 0);
      await repo.saveMaintenance(
          vehicleId: v, date: DateTime(2026, 6, 1), odometer: 6000,
          items: [const ItemInput(name: '機油', quantity: 1, unitPrice: 500)]);
      await expectLater(
        repo.saveFuelLog(vehicleId: v, date: DateTime(2026, 7, 1), odometer: 5000, liters: 10, amount: 300),
        throwsA(isA<GarageValidationException>()),
      );
    });

    test('單價存成兩位小數', () async {
      final v = await repo.addVehicle(type: 0, name: '車', initialOdometer: 0);
      final id = await repo.saveFuelLog(vehicleId: v, date: DateTime(2026, 6, 1), odometer: 100, liters: 3, amount: 100);
      final log = await (db.select(db.fuelLogs)..where((x) => x.id.equals(id))).getSingle();
      expect(log.unitPrice, 33.33);
    });
  });
}
