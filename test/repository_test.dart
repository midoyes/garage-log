import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:garage_log/data/database.dart';
import 'package:garage_log/data/repository.dart';
import 'package:garage_log/domain/maintenance_calculator.dart';

void main() {
  late AppDatabase db;
  late GarageRepository repo;
  var t = 1000;
  int clock() => t++;

  setUp(() {
    t = 1000;
    db = AppDatabase(NativeDatabase.memory());
    repo = GarageRepository(db, clock: clock);
  });

  tearDown(() => db.close());

  Future<String> vehicle({double initial = 0}) =>
      repo.addVehicle(type: 0, name: '車', initialOdometer: initial);

  group('加油', () {
    test('同一天兩筆，編輯較早的一筆（保留原里程）可以成功', () async {
      final vid = await vehicle();
      final first = await repo.saveFuelLog(
        vehicleId: vid,
        date: DateTime(2026, 2, 1),
        odometer: 10000,
        liters: 20,
        amount: 600,
      );
      await repo.saveFuelLog(
        vehicleId: vid,
        date: DateTime(2026, 2, 1),
        odometer: 10150,
        liters: 20,
        amount: 600,
      );

      await repo.saveFuelLog(
        id: first,
        vehicleId: vid,
        date: DateTime(2026, 2, 1),
        odometer: 10000,
        liters: 21,
        amount: 630,
      );
      final logs = await repo.watchFuelLogs(vid).first;
      expect(logs.map((l) => l.odometer), [10000, 10150]);
      expect(logs.first.liters, 21);
    });

    test('油品會被儲存', () async {
      final vid = await vehicle();
      await repo.saveFuelLog(
        vehicleId: vid,
        date: DateTime(2026, 2, 1),
        odometer: 100,
        liters: 10,
        amount: 300,
        fuelType: '98',
      );
      expect((await repo.watchFuelLogs(vid).first).single.fuelType, '98');
    });

    test('公升數為 0、負數、NaN 被拒絕', () async {
      final vid = await vehicle();
      for (final l in [0.0, -5.0, double.nan]) {
        await expectLater(
          repo.saveFuelLog(
            vehicleId: vid,
            date: DateTime(2026, 2, 1),
            odometer: 100,
            liters: l,
            amount: 300,
          ),
          throwsA(isA<GarageValidationException>()),
          reason: 'liters=$l',
        );
      }
    });
  });

  group('車輛', () {
    test('初始里程不可大於既有加油紀錄的最小里程', () async {
      final vid = await vehicle(initial: 0);
      await repo.saveFuelLog(
        vehicleId: vid,
        date: DateTime(2026, 2, 1),
        odometer: 1000,
        liters: 10,
        amount: 300,
      );
      await expectLater(
        repo.updateVehicle(vid, type: 0, name: '車', initialOdometer: 1500),
        throwsA(isA<GarageValidationException>()),
      );
      await repo.updateVehicle(vid, type: 0, name: '車', initialOdometer: 1000);
    });

    test('刪除車輛會連帶軟刪除加油、保養與週期', () async {
      final vid = await vehicle();
      await repo.saveFuelLog(
        vehicleId: vid,
        date: DateTime(2026, 2, 1),
        odometer: 1000,
        liters: 10,
        amount: 300,
      );
      await repo.savePlan(vehicleId: vid, name: '機油', intervalKm: 5000);
      await repo.deleteVehicle(vid);

      expect(await repo.watchVehicles().first, isEmpty);
      expect(await repo.watchFuelLogs(vid).first, isEmpty);
      expect(await repo.watchPlans(vid).first, isEmpty);
      // 資料仍在（軟刪除，墓碑可同步）
      expect(await db.select(db.fuelLogs).get(), hasLength(1));
    });

    test('車輛名稱空白被拒絕', () async {
      await expectLater(
        repo.addVehicle(type: 0, name: '  '),
        throwsA(isA<GarageValidationException>()),
      );
    });
  });

  group('保養', () {
    Future<String> save(String vid, List<ItemInput> items) => repo.saveMaintenance(
          vehicleId: vid,
          date: DateTime(2026, 3, 1),
          odometer: 1000,
          items: items,
        );

    test('負數數量、0 數量、負單價、空名稱、NaN 都被 Repository 拒絕', () async {
      final vid = await vehicle();
      final bad = [
        const ItemInput(name: '機油', quantity: -2, unitPrice: 500),
        const ItemInput(name: '機油', quantity: 0, unitPrice: 500),
        const ItemInput(name: '機油', quantity: 1, unitPrice: -1),
        const ItemInput(name: '', quantity: 1, unitPrice: 100),
        const ItemInput(name: '機油', quantity: double.nan, unitPrice: 100),
      ];
      for (final i in bad) {
        await expectLater(
          save(vid, [i]),
          throwsA(isA<GarageValidationException>()),
          reason: '${i.name} ${i.quantity} ${i.unitPrice}',
        );
      }
      expect(await db.select(db.maintenanceRecords).get(), isEmpty);
    });

    test('沒有任何項目被拒絕', () async {
      final vid = await vehicle();
      await expectLater(
        save(vid, const []),
        throwsA(isA<GarageValidationException>()),
      );
    });

    test('單價 0（保固 / 免費）可以儲存', () async {
      final vid = await vehicle();
      await save(vid, const [ItemInput(name: '保固更換', quantity: 1, unitPrice: 0)]);
      expect((await repo.watchMaintenance(vid).first).single.record.totalAmount, 0);
    });

    test('只有明細變動時，監聽也會更新（JOIN 同時監聽兩張表）', () async {
      final vid = await vehicle();
      await save(vid, const [ItemInput(name: '機油', quantity: 1, unitPrice: 500)]);

      final emissions = <List<MaintenanceWithItems>>[];
      final sub = repo.watchMaintenance(vid).listen(emissions.add);
      await pumpEventQueue();
      expect(emissions, isNotEmpty);
      expect(emissions.last.single.items.single.unitPrice, 500);

      // 只改明細表（不碰保養單主檔），模擬匯入只帶來明細變更
      await (db.update(db.maintenanceItems)).write(
        const MaintenanceItemsCompanion(unitPrice: Value(999)),
      );
      await pumpEventQueue();
      expect(emissions.last.single.items.single.unitPrice, 999);
      await sub.cancel();
    });

    test('編輯時移除的明細會被軟刪除，其餘更新', () async {
      final vid = await vehicle();
      final mid = await save(vid, const [
        ItemInput(name: '機油', quantity: 1, unitPrice: 500),
        ItemInput(name: '工資', quantity: 1, unitPrice: 300),
      ]);
      final loaded = (await repo.watchMaintenance(vid).first).single;
      final oil = loaded.items.firstWhere((i) => i.name == '機油');

      await repo.saveMaintenance(
        id: mid,
        vehicleId: vid,
        date: DateTime(2026, 3, 1),
        odometer: 1000,
        items: [ItemInput(id: oil.id, name: '機油', quantity: 2, unitPrice: 500)],
      );
      final after = (await repo.watchMaintenance(vid).first).single;
      expect(after.items.single.quantity, 2);
      expect(after.record.totalAmount, 1000);
      expect(await db.select(db.maintenanceItems).get(), hasLength(2)); // 含墓碑
    });
  });

  group('保養週期', () {
    test('同一台車的項目名稱（正規化後）不可重複', () async {
      final vid = await vehicle();
      await repo.savePlan(vehicleId: vid, name: '機油', intervalKm: 5000);
      await expectLater(
        repo.savePlan(vehicleId: vid, name: ' 機油 ', intervalKm: 3000),
        throwsA(isA<GarageValidationException>()),
      );
    });

    test('編輯自己不會被當成重複；負數週期被拒絕；刪除是軟刪除', () async {
      final vid = await vehicle();
      final id = await repo.savePlan(vehicleId: vid, name: '機油', intervalKm: 5000);
      await repo.savePlan(id: id, vehicleId: vid, name: '機油', intervalKm: 4000);
      expect((await repo.watchPlans(vid).first).single.intervalKm, 4000);

      await expectLater(
        repo.savePlan(vehicleId: vid, name: '輪胎', intervalKm: -1),
        throwsA(isA<GarageValidationException>()),
      );

      await repo.deletePlan(id);
      expect(await repo.watchPlans(vid).first, isEmpty);
      expect(await db.select(db.maintenancePlans).get(), hasLength(1));
    });

    test('不存在或已刪除的車輛不能新增週期', () async {
      await expectLater(
        repo.savePlan(vehicleId: 'no-such', name: '機油', intervalKm: 5000),
        throwsA(isA<GarageValidationException>()),
      );
    });

    test('編輯別台車的週期被拒絕', () async {
      final a = await vehicle();
      final b = await vehicle();
      final planOfA = await repo.savePlan(vehicleId: a, name: '機油', intervalKm: 5000);
      await expectLater(
        repo.savePlan(id: planOfA, vehicleId: b, name: '機油', intervalKm: 1),
        throwsA(isA<GarageValidationException>()),
      );
    });
  });

  group('歸屬檢查與時間戳', () {
    test('保養：不存在的車輛、編輯別台車的保養單、別張單的明細都被拒絕', () async {
      final a = await vehicle();
      final b = await vehicle();
      const oil = ItemInput(name: '機油', quantity: 1, unitPrice: 500);

      await expectLater(
        repo.saveMaintenance(
          vehicleId: 'no-such',
          date: DateTime(2026, 3, 1),
          odometer: 1000,
          items: const [oil],
        ),
        throwsA(isA<GarageValidationException>()),
      );

      final mA = await repo.saveMaintenance(
        vehicleId: a,
        date: DateTime(2026, 3, 1),
        odometer: 1000,
        items: const [oil],
      );
      final mB = await repo.saveMaintenance(
        vehicleId: b,
        date: DateTime(2026, 3, 2),
        odometer: 2000,
        items: const [oil],
      );

      // 用 B 車的名義編輯 A 車的保養單
      await expectLater(
        repo.saveMaintenance(
          id: mA,
          vehicleId: b,
          date: DateTime(2026, 3, 1),
          odometer: 1000,
          items: const [oil],
        ),
        throwsA(isA<GarageValidationException>()),
      );

      // 在 A 的保養單裡塞 B 的明細 id
      final bItem = (await repo.watchMaintenance(b).first)
          .firstWhere((m) => m.record.id == mB)
          .items
          .single;
      await expectLater(
        repo.saveMaintenance(
          id: mA,
          vehicleId: a,
          date: DateTime(2026, 3, 1),
          odometer: 1000,
          items: [ItemInput(id: bItem.id, name: '機油', quantity: 9, unitPrice: 9)],
        ),
        throwsA(isA<GarageValidationException>()),
      );

      // 失敗的操作不會改到任何資料
      final stillB = (await repo.watchMaintenance(b).first).single;
      expect(stillB.items.single.quantity, 1);
      expect(stillB.record.totalAmount, 500);
    });

    test('編輯別台車的加油紀錄被拒絕', () async {
      final a = await vehicle();
      final b = await vehicle();
      final log = await repo.saveFuelLog(
        vehicleId: a,
        date: DateTime(2026, 2, 1),
        odometer: 100,
        liters: 10,
        amount: 300,
      );
      await expectLater(
        repo.saveFuelLog(
          id: log,
          vehicleId: b,
          date: DateTime(2026, 2, 1),
          odometer: 100,
          liters: 10,
          amount: 300,
        ),
        throwsA(isA<GarageValidationException>()),
      );
    });

    test('同一毫秒連續編輯，updatedAt 仍嚴格遞增', () async {
      final fixed = GarageRepository(db, clock: () => 5000); // 時鐘永遠不前進
      final vid = await fixed.addVehicle(type: 0, name: '車');
      final stamps = <int>[];
      for (var i = 0; i < 3; i++) {
        await fixed.updateVehicle(vid, type: 0, name: '車$i');
        final v = (await db.select(db.vehicles).get()).single;
        stamps.add(v.updatedAt);
      }
      expect(stamps[1], greaterThan(stamps[0]));
      expect(stamps[2], greaterThan(stamps[1]));
    });

    test('編輯來自時鐘較快裝置的資料：updatedAt 一定比原值新', () async {
      final vid = await vehicle();
      // 模擬同步進來的資料 updatedAt 在遙遠的未來
      await (db.update(db.vehicles)..where((t) => t.id.equals(vid)))
          .write(const VehiclesCompanion(updatedAt: Value(9000000000000)));
      await repo.updateVehicle(vid, type: 0, name: '改名');
      final v = (await db.select(db.vehicles).get()).single;
      expect(v.updatedAt, greaterThan(9000000000000));
    });

    test('刪除車輛連帶刪除的子資料，updatedAt 也不會倒退', () async {
      final vid = await vehicle();
      final log = await repo.saveFuelLog(
        vehicleId: vid,
        date: DateTime(2026, 2, 1),
        odometer: 100,
        liters: 10,
        amount: 300,
      );
      await (db.update(db.fuelLogs)..where((t) => t.id.equals(log)))
          .write(const FuelLogsCompanion(updatedAt: Value(9000000000000)));
      await repo.deleteVehicle(vid);
      final l = (await db.select(db.fuelLogs).get()).single;
      expect(l.isDeleted, isTrue);
      expect(l.updatedAt, greaterThan(9000000000000));
    });
  });
}
