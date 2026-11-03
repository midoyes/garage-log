import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garage_log/data/backup_service.dart';
import 'package:garage_log/data/database.dart';
import 'package:garage_log/data/repository.dart';
import 'package:garage_log/domain/maintenance_calculator.dart';

AppDatabase memoryDb() => AppDatabase(NativeDatabase.memory());

void main() {
  late AppDatabase dbA;
  late AppDatabase dbB;
  var tick = 1000;
  int clock() => tick++;

  setUp(() {
    dbA = memoryDb();
    dbB = memoryDb();
  });

  tearDown(() async {
    await dbA.close();
    await dbB.close();
  });

  test('主鍵為 UUID，且寫入 createdAt / updatedAt', () async {
    final repo = GarageRepository(dbA, clock: clock);
    final id = await repo.addVehicle(type: 0, name: 'Altis', plate: 'ABC-1234');
    final v = await (dbA.select(dbA.vehicles)..where((t) => t.id.equals(id)))
        .getSingle();
    expect(
      RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
          .hasMatch(v.id),
      isTrue,
    );
    expect(v.createdAt, v.updatedAt);
    expect(v.isDeleted, isFalse);
  });

  test('匯出再匯入到另一台裝置：資料完全一致', () async {
    final repoA = GarageRepository(dbA, clock: clock);
    final vid = await repoA.addVehicle(type: 1, name: '勁戰', initialOdometer: 500);
    await repoA.saveFuelLog(
      vehicleId: vid,
      date: DateTime(2026, 1, 1),
      odometer: 600,
      liters: 5,
      amount: 150,
    );
    await repoA.saveMaintenance(
      vehicleId: vid,
      date: DateTime(2026, 1, 5),
      odometer: 650,
      items: const [
        ItemInput(name: '機油', quantity: 2, unitPrice: 300),
        ItemInput(name: '工資', quantity: 1, unitPrice: 200),
      ],
    );

    final json = await BackupService(dbA).exportJson();
    final report = await BackupService(dbB).importJson(json);
    expect(report.added, 5); // 1 車 + 1 加油 + 1 保養單 + 2 明細

    final repoB = GarageRepository(dbB, clock: clock);
    final fuel = await repoB.watchFuelLogs(vid).first;
    expect(fuel.single.odometer, 600);
    final maint = await repoB.watchMaintenance(vid).first;
    expect(maint.single.record.totalAmount, 800);
    expect(maint.single.items.length, 2);
  });

  test('重複匯入是安全的（全部略過）', () async {
    final repoA = GarageRepository(dbA, clock: clock);
    await repoA.addVehicle(type: 0, name: 'A');
    final json = await BackupService(dbA).exportJson();
    final svcB = BackupService(dbB);
    await svcB.importJson(json);
    final second = await svcB.importJson(json);
    expect(second.added, 0);
    expect(second.updated, 0);
    expect(second.skipped, 1);
  });

  test('LWW：updatedAt 較新者勝；軟刪除也會同步', () async {
    final repoA = GarageRepository(dbA, clock: clock);
    final vid = await repoA.addVehicle(type: 0, name: '舊名稱');
    await BackupService(dbB).importJson(await BackupService(dbA).exportJson());

    // A 之後改名並刪除一筆加油
    await repoA.updateVehicle(vid, type: 0, name: '新名稱');
    final fuelId = await repoA.saveFuelLog(
      vehicleId: vid,
      date: DateTime(2026, 2, 1),
      odometer: 100,
      liters: 5,
      amount: 150,
    );
    await BackupService(dbB).importJson(await BackupService(dbA).exportJson());
    await repoA.deleteFuelLog(fuelId);

    final report =
        await BackupService(dbB).importJson(await BackupService(dbA).exportJson());
    expect(report.updated, greaterThanOrEqualTo(1));

    final repoB = GarageRepository(dbB, clock: clock);
    final vehicles = await repoB.watchVehicles().first;
    expect(vehicles.single.name, '新名稱');
    expect(await repoB.watchFuelLogs(vid).first, isEmpty);

    // 較舊的資料不會覆蓋較新的
    final olderJson = await BackupService(dbA).exportJson();
    await repoA.updateVehicle(vid, type: 0, name: '最新名稱');
    final r2 = await BackupService(dbA).importJson(olderJson);
    expect(r2.updated, 0);
    expect((await repoA.watchVehicles().first).single.name, '最新名稱');
  });

  test('里程防呆：不可小於等於上一筆', () async {
    final repo = GarageRepository(dbA, clock: clock);
    final vid = await repo.addVehicle(type: 0, name: 'A');
    await repo.saveFuelLog(
      vehicleId: vid,
      date: DateTime(2026, 1, 1),
      odometer: 1000,
      liters: 10,
      amount: 300,
    );
    expect(
      () => repo.saveFuelLog(
        vehicleId: vid,
        date: DateTime(2026, 1, 10),
        odometer: 1000,
        liters: 10,
        amount: 300,
      ),
      throwsA(isA<GarageValidationException>()),
    );
  });

  test('格式錯誤的檔案會被拒絕', () async {
    final svc = BackupService(dbA);
    expect(() => svc.importJson('not json'), throwsFormatException);
    expect(() => svc.importJson('{"app":"other"}'), throwsFormatException);
  });
}
