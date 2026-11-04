import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
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
  late GarageRepository repoA;
  late GarageRepository repoB;
  late BackupService svcA;
  late BackupService svcB;
  var t = 1000;
  int clock() => t++;

  setUp(() {
    t = 1000;
    dbA = memoryDb();
    dbB = memoryDb();
    repoA = GarageRepository(dbA, clock: clock);
    repoB = GarageRepository(dbB, clock: clock);
    svcA = BackupService(dbA, clock: clock);
    svcB = BackupService(dbB, clock: clock);
  });

  tearDown(() async {
    await dbA.close();
    await dbB.close();
  });

  test('A、B 各改保養單的不同部分：合併後保養總額與明細一致', () async {
    final vid = await repoA.addVehicle(type: 0, name: '車');
    final mid = await repoA.saveMaintenance(
      vehicleId: vid,
      date: DateTime(2026, 3, 1),
      odometer: 1000,
      items: const [
        ItemInput(name: '機油', quantity: 1, unitPrice: 500),
        ItemInput(name: '工資', quantity: 1, unitPrice: 300),
      ],
    );
    await svcB.importJson(await svcA.exportJson());

    final items = await (dbA.select(dbA.maintenanceItems)
          ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
        .get();
    final i1 = items[0].id;
    final i2 = items[1].id;

    // A：把工資改成 400（整張單重新儲存，總額 900）
    await repoA.saveMaintenance(
      id: mid,
      vehicleId: vid,
      date: DateTime(2026, 3, 1),
      odometer: 1000,
      items: [
        ItemInput(id: i1, name: '機油', quantity: 1, unitPrice: 500),
        ItemInput(id: i2, name: '工資', quantity: 1, unitPrice: 400),
      ],
    );

    // B：只把機油改成 700，而且時間比 A 的修改更晚（模擬另一台裝置只改了明細）
    await (dbB.update(dbB.maintenanceItems)..where((t) => t.id.equals(i1))).write(
      const MaintenanceItemsCompanion(
        unitPrice: Value(700),
        updatedAt: Value(999999),
      ),
    );

    // 合併前：A 的總額是 900，但 B 的新明細合進來後會變成 700 + 400 = 1100
    final report = await svcA.importJson(await svcB.exportJson());
    expect(report.repaired, greaterThanOrEqualTo(1));

    final rec = (await dbA.select(dbA.maintenanceRecords).get()).single;
    expect(rec.totalAmount, 1100);

    // 再次修復是冪等的
    expect(await svcA.repairIntegrity(), 0);
  });

  test('已刪除的車輛匯入舊備份：不會讓底下的紀錄復活', () async {
    final vid = await repoA.addVehicle(type: 0, name: '車');
    await repoA.saveFuelLog(
      vehicleId: vid,
      date: DateTime(2026, 1, 1),
      odometer: 1000,
      liters: 10,
      amount: 300,
    );
    await svcB.importJson(await svcA.exportJson()); // B 取得舊備份

    // A 之後又新增一筆（B 還不知道）
    await repoA.saveFuelLog(
      vehicleId: vid,
      date: DateTime(2026, 1, 10),
      odometer: 1400,
      liters: 20,
      amount: 600,
    );
    final newer = await svcA.exportJson();

    // B 刪掉這台車，然後匯入 A 的較新備份
    await repoB.deleteVehicle(vid);
    final report = await svcB.importJson(newer);

    expect(report.repaired, greaterThanOrEqualTo(1));
    expect(await repoB.watchVehicles().first, isEmpty);
    expect(await repoB.watchFuelLogs(vid).first, isEmpty);
    final all = await dbB.select(dbB.fuelLogs).get();
    expect(all.length, 2);
    expect(all.every((l) => l.isDeleted), isTrue);
  });

  test('預覽只回報摘要，不會改動資料庫', () async {
    final vid = await repoA.addVehicle(type: 1, name: '勁戰');
    await repoA.saveFuelLog(
      vehicleId: vid,
      date: DateTime(2026, 1, 1),
      odometer: 100,
      liters: 5,
      amount: 150,
    );
    await repoA.savePlan(vehicleId: vid, name: '機油', intervalKm: 3000);
    final json = await svcA.exportJson();

    final preview = await svcB.preview(json);
    expect(preview.vehicles, 1);
    expect(preview.fuelLogs, 1);
    expect(preview.plans, 1);
    expect(preview.exportedAt, isNotNull);
    expect(preview.diff.added, 3);

    expect(await dbB.select(dbB.vehicles).get(), isEmpty);
    expect(await dbB.select(dbB.fuelLogs).get(), isEmpty);
    expect(await dbB.select(dbB.maintenancePlans).get(), isEmpty);

    // 預覽之後真的匯入，結果與預覽一致
    final report = await svcB.importJson(json);
    expect(report.added, preview.diff.added);
    expect(await dbB.select(dbB.vehicles).get(), hasLength(1));
  });

  test('保養週期會隨備份同步', () async {
    final vid = await repoA.addVehicle(type: 0, name: '車');
    await repoA.savePlan(
        vehicleId: vid, name: '機油', intervalKm: 5000, intervalDays: 180);
    await svcB.importJson(await svcA.exportJson());

    final plans = await repoB.watchPlans(vid).first;
    expect(plans.single.name, '機油');
    expect(plans.single.intervalKm, 5000);
    expect(plans.single.intervalDays, 180);
  });

  test('v1 備份（沒有週期與油品欄位）仍可匯入', () async {
    final v1 = {
      'app': 'garage_log',
      'formatVersion': 1,
      'exportedAt': '2026-01-01T00:00:00.000Z',
      'vehicles': [
        {
          'id': 'v-1',
          'createdAt': 1,
          'updatedAt': 1,
          'isDeleted': false,
          'type': 0,
          'name': '舊車',
          'plate': 'ABC-123',
          'initialOdometer': 100.0,
        },
      ],
      'fuelLogs': [
        {
          'id': 'f-1',
          'createdAt': 1,
          'updatedAt': 1,
          'isDeleted': false,
          'vehicleId': 'v-1',
          'date': 1767225600000,
          'odometer': 200.0,
          'liters': 10.0,
          'amount': 300.0,
          'unitPrice': 30.0,
          'isFullTank': true,
          'note': '',
        },
      ],
      'maintenanceRecords': <Object>[],
      'maintenanceItems': <Object>[],
    };
    final report = await svcA.importJson(jsonEncode(v1));
    expect(report.added, 2);

    final v = (await dbA.select(dbA.vehicles).get()).single;
    expect(v.name, '舊車');
    expect(v.defaultFuelType, '');
    final f = (await dbA.select(dbA.fuelLogs).get()).single;
    expect(f.fuelType, '');
  });

  test('欄位型態錯誤的備份被拒絕，且整批回滾', () async {
    final bad = {
      'app': 'garage_log',
      'formatVersion': 2,
      'vehicles': [
        {
          'id': 'ok',
          'createdAt': 1,
          'updatedAt': 1,
          'isDeleted': false,
          'type': 0,
          'name': '正常',
          'plate': '',
          'initialOdometer': 0.0,
          'defaultFuelType': '',
        },
        {
          'id': 'bad',
          'createdAt': 1,
          'updatedAt': 1,
          'isDeleted': false,
          'type': 0,
          'name': 12345, // 應該是字串
          'plate': '',
          'initialOdometer': 0.0,
          'defaultFuelType': '',
        },
      ],
    };
    await expectLater(svcA.importJson(jsonEncode(bad)), throwsFormatException);
    expect(await dbA.select(dbA.vehicles).get(), isEmpty);
  });

  test('不認得的格式與版本被拒絕', () async {
    expect(() => svcA.importJson('not json'), throwsFormatException);
    expect(() => svcA.importJson('{"app":"other"}'), throwsFormatException);
    expect(
      () => svcA.importJson('{"app":"garage_log","formatVersion":99}'),
      throwsFormatException,
    );
    expect(
      () => svcA.importJson('{"app":"garage_log","formatVersion":2,"vehicles":5}'),
      throwsFormatException,
    );
  });

  Map<String, dynamic> emptyBackup() => {
        'app': 'garage_log',
        'formatVersion': 2,
        'exportedAt': '2026-01-01T00:00:00.000Z',
        'vehicles': <Object>[],
        'fuelLogs': <Object>[],
        'maintenanceRecords': <Object>[],
        'maintenanceItems': <Object>[],
        'maintenancePlans': <Object>[],
      };

  Map<String, dynamic> fuelRow(String vehicleId, {double liters = 10}) => {
        'id': 'f-orphan',
        'createdAt': 1,
        'updatedAt': 1,
        'isDeleted': false,
        'vehicleId': vehicleId,
        'date': 1767225600000,
        'odometer': 200.0,
        'liters': liters,
        'amount': 300.0,
        'unitPrice': 30.0,
        'isFullTank': true,
        'note': '',
        'fuelType': '',
      };

  Map<String, dynamic> recordRow(String id, double total) => {
        'id': id,
        'createdAt': 1,
        'updatedAt': 1,
        'isDeleted': false,
        'vehicleId': 'v-x',
        'date': 1767225600000,
        'odometer': 100.0,
        'totalAmount': total,
        'note': '',
      };

  test('找不到車輛的孤立加油紀錄：保留不刪除，並回報為異常', () async {
    final b = emptyBackup()..['fuelLogs'] = [fuelRow('ghost')];
    final report = await svcA.importJson(jsonEncode(b));
    expect(report.anomalies, 1);
    final rows = await dbA.select(dbA.fuelLogs).get();
    expect(rows.single.isDeleted, isFalse); // 沒有被悄悄刪掉
    expect(report.toString(), contains('異常'));
  });

  test('找不到保養單的孤立明細：回報為異常', () async {
    final b = emptyBackup()
      ..['maintenanceItems'] = [
        {
          'id': 'i-1',
          'createdAt': 1,
          'updatedAt': 1,
          'isDeleted': false,
          'recordId': 'no-record',
          'name': '機油',
          'quantity': 1.0,
          'unitPrice': 500.0,
          'sortOrder': 0,
        },
      ];
    final report = await svcA.importJson(jsonEncode(b));
    expect(report.anomalies, 1);
  });

  test('保養單沒有任何有效明細：回報異常，金額不被改寫', () async {
    final b = emptyBackup()
      ..['vehicles'] = [
        {
          'id': 'v-x',
          'createdAt': 1,
          'updatedAt': 1,
          'isDeleted': false,
          'type': 0,
          'name': '車',
          'plate': '',
          'initialOdometer': 0.0,
          'defaultFuelType': '',
        },
      ]
      ..['maintenanceRecords'] = [recordRow('m-1', 3000)];
    final report = await svcA.importJson(jsonEncode(b));
    expect(report.anomalies, 1);
    final rec = (await dbA.select(dbA.maintenanceRecords).get()).single;
    expect(rec.totalAmount, 3000);
    expect(rec.isDeleted, isFalse);
  });

  test('欄位值不合法（負公升數）或缺少資料表：整份拒絕，資料庫不變', () async {
    final neg = emptyBackup()..['fuelLogs'] = [fuelRow('v', liters: -5)];
    await expectLater(svcA.importJson(jsonEncode(neg)), throwsFormatException);

    final missing = emptyBackup()..remove('maintenanceItems');
    await expectLater(svcA.importJson(jsonEncode(missing)), throwsFormatException);
    await expectLater(svcA.preview(jsonEncode(missing)), throwsFormatException);

    expect(await dbA.select(dbA.fuelLogs).get(), isEmpty);
  });

  test('updatedAt 相同但內容不同：兩邊各自合併後收斂到同一個結果', () async {
    Future<void> put(AppDatabase db, String name) =>
        db.into(db.vehicles).insert(VehiclesCompanion.insert(
              id: 'same',
              createdAt: 100,
              updatedAt: 500,
              name: name,
            ));
    await put(dbA, 'AAA');
    await put(dbB, 'ZZZ');

    await svcA.importJson(await svcB.exportJson());
    await svcB.importJson(await svcA.exportJson());

    final a = (await dbA.select(dbA.vehicles).get()).single.name;
    final b = (await dbB.select(dbB.vehicles).get()).single.name;
    expect(a, b);
    expect(a, 'ZZZ');
  });

  test('完整復原：回到備份狀態，之後新增的以墓碑處理，且結果能同步出去', () async {
    final vid = await repoA.addVehicle(type: 0, name: '原名');
    await repoA.saveFuelLog(
      vehicleId: vid,
      date: DateTime(2026, 1, 1),
      odometer: 100,
      liters: 10,
      amount: 300,
    );
    final snapshot = await svcA.exportJson();

    // 之後：改名、再加一筆
    await repoA.updateVehicle(vid, type: 0, name: '改過的名字');
    await repoA.saveFuelLog(
      vehicleId: vid,
      date: DateTime(2026, 1, 10),
      odometer: 500,
      liters: 20,
      amount: 600,
    );
    await svcB.importJson(await svcA.exportJson()); // B 已經拿到「較新」的狀態
    final before = (await dbA.select(dbA.vehicles).get()).single.updatedAt;

    await svcA.restoreSnapshot(snapshot);

    expect((await repoA.watchVehicles().first).single.name, '原名');
    expect(await repoA.watchFuelLogs(vid).first, hasLength(1));
    final all = await dbA.select(dbA.fuelLogs).get();
    expect(all, hasLength(2)); // 另一筆是墓碑
    expect(all.where((l) => l.isDeleted), hasLength(1));
    expect((await dbA.select(dbA.vehicles).get()).single.updatedAt, greaterThan(before));

    // 復原後同步給 B：B 也會回到復原後的狀態，不會被舊資料蓋回來
    await svcB.importJson(await svcA.exportJson());
    expect((await repoB.watchVehicles().first).single.name, '原名');
    expect(await repoB.watchFuelLogs(vid).first, hasLength(1));
  });

  Map<String, dynamic> vehicleRow({String name = '車', bool deleted = false}) => {
        'id': 'v-x',
        'createdAt': 1,
        'updatedAt': 1,
        'isDeleted': deleted,
        'type': 0,
        'name': name,
        'plate': '',
        'initialOdometer': 0.0,
        'defaultFuelType': '',
      };

  Map<String, dynamic> itemRow({
    double quantity = 1,
    double unitPrice = 500,
    String name = '機油',
    bool deleted = false,
  }) =>
      {
        'id': 'i-1',
        'createdAt': 1,
        'updatedAt': 1,
        'isDeleted': deleted,
        'recordId': 'm-1',
        'name': name,
        'quantity': quantity,
        'unitPrice': unitPrice,
        'sortOrder': 0,
      };

  test('異常保養單（沒有有效明細）不進列表與統計，但資料保留、異常筆數會回報', () async {
    final b = emptyBackup()
      ..['vehicles'] = [vehicleRow()]
      ..['maintenanceRecords'] = [recordRow('m-1', 3000), recordRow('m-2', 800)]
      ..['maintenanceItems'] = [
        {...itemRow(), 'recordId': 'm-2', 'id': 'i-2', 'unitPrice': 800.0},
      ];
    final report = await svcA.importJson(jsonEncode(b));
    expect(report.anomalies, 1); // m-1 沒有明細

    final shown = await repoA.watchMaintenance('v-x').first;
    expect(shown.map((m) => m.record.id), ['m-2']);
    expect(shown.fold<double>(0, (s, m) => s + m.record.totalAmount), 800);

    // 資料沒有被刪除
    final all = await dbA.select(dbA.maintenanceRecords).get();
    expect(all, hasLength(2));
    expect(all.every((r) => !r.isDeleted), isTrue);
  });

  test('備份欄位驗證與 Repository 一致：負單價、數量 0、空白名稱都被拒絕', () async {
    Future<void> expectRejected(Map<String, dynamic> b) =>
        expectLater(svcA.importJson(jsonEncode(b)), throwsFormatException);

    // 負的加油單價
    await expectRejected(
        emptyBackup()..['fuelLogs'] = [{...fuelRow('v-x'), 'unitPrice': -1.0}]);
    // 公升數 0（未刪除）
    await expectRejected(
        emptyBackup()..['fuelLogs'] = [fuelRow('v-x', liters: 0)]);
    // 保養明細：數量 0、空白名稱、負單價
    await expectRejected(
        emptyBackup()..['maintenanceItems'] = [itemRow(quantity: 0)]);
    await expectRejected(
        emptyBackup()..['maintenanceItems'] = [itemRow(name: '  ')]);
    await expectRejected(
        emptyBackup()..['maintenanceItems'] = [itemRow(unitPrice: -5)]);
    // 空白車輛名稱
    await expectRejected(emptyBackup()..['vehicles'] = [vehicleRow(name: '  ')]);

    expect(await dbA.select(dbA.fuelLogs).get(), isEmpty);
    expect(await dbA.select(dbA.maintenanceItems).get(), isEmpty);
    expect(await dbA.select(dbA.vehicles).get(), isEmpty);
  });

  test('已刪除的墓碑可以寬鬆一點（數量 0 的舊墓碑不會讓整份備份匯不進來）', () async {
    final b = emptyBackup()
      ..['maintenanceItems'] = [itemRow(quantity: 0, deleted: true)];
    final report = await svcA.importJson(jsonEncode(b));
    expect(report.added, 1);
  });

  test('完整復原的影響預估：本機多出的紀錄會列為「將移除」，且不改動資料庫', () async {
    final vid = await repoA.addVehicle(type: 0, name: '車');
    await repoA.saveFuelLog(
      vehicleId: vid,
      date: DateTime(2026, 1, 1),
      odometer: 100,
      liters: 10,
      amount: 300,
    );
    final snapshot = await svcA.exportJson();
    await repoA.saveFuelLog(
      vehicleId: vid,
      date: DateTime(2026, 1, 10),
      odometer: 500,
      liters: 20,
      amount: 600,
    );

    final impact = await svcA.restoreImpact(snapshot);
    final fuel = impact.tables.firstWhere((t) => t.label == '加油紀錄');
    expect(fuel.local, 2);
    expect(fuel.backup, 1);
    expect(fuel.removed, 1);
    expect(impact.tables.firstWhere((t) => t.label == '車輛').removed, 0);
    expect(impact.totalRemoved, 1);

    expect(await repoA.watchFuelLogs(vid).first, hasLength(2)); // 預估不會改資料
  });

  test('自動備份清單：區分匯入前 / 復原前，最新的在前', () async {
    await repoA.addVehicle(type: 0, name: '車');
    final dir = Directory.systemTemp.createTempSync('garage_log_list_test');
    try {
      await svcA.writeAutoBackup(dir);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await svcA.writeAutoBackup(dir, prefix: BackupService.autoRestorePrefix);
      File('${dir.path}/other.json').writeAsStringSync('{}'); // 不是自動備份，忽略

      final list = BackupService.listAutoBackups(dir);
      expect(list, hasLength(2));
      expect(list.first.kind, 'restore');
      expect(list.last.kind, 'import');
      expect(BackupService.listAutoBackups(Directory('${dir.path}/none')), isEmpty);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('匯入前自動備份：寫出可還原的檔案，並只保留最近幾份', () async {
    await repoA.addVehicle(type: 0, name: '車');
    final dir = Directory.systemTemp.createTempSync('garage_log_backup_test');
    try {
      for (var i = 0; i < 4; i++) {
        await svcA.writeAutoBackup(dir, keep: 2);
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final files = dir.listSync().whereType<File>().toList();
      expect(files.length, 2);

      // 備份檔本身可以被匯入還原
      final restored = await svcB.importJson(await files.first.readAsString());
      expect(restored.added, 1);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}
