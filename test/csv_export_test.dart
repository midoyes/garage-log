import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garage_log/data/csv_export.dart';
import 'package:garage_log/data/database.dart';
import 'package:garage_log/data/repository.dart';
import 'package:garage_log/domain/maintenance_calculator.dart';

void main() {
  group('CsvExporter.encode', () {
    test('開頭有 UTF-8 BOM、以 CRLF 換行，含逗號與引號的欄位會被包起來', () {
      final csv = CsvExporter.encode([
        ['a', 'b,c'],
        ['x', '"q"'],
      ]);
      expect(csv, '﻿a,"b,c"\r\nx,"""q"""\r\n');
    });

    test('以 = + - @ 開頭的文字會補單引號，避免 Excel 當成公式', () {
      final csv = CsvExporter.encode([
        ['=SUM(A1)', '+1', '-1', '@x', 'ok'],
      ]);
      expect(csv, contains("'=SUM(A1)"));
      expect(csv, contains("'+1"));
      expect(csv, contains("'@x"));
      expect(csv, endsWith(",ok\r\n"));
    });

    test('負數（數字型別）不會被當成公式加引號', () {
      expect(CsvExporter.encode([
        [-5.5],
      ]), '﻿-5.5\r\n');
    });

    test('null 輸出空欄位、數字去掉多餘小數', () {
      expect(
        CsvExporter.encode([
          [null, 20.0, 1.5, 1000.0],
        ]),
        '﻿,20,1.5,1000\r\n',
      );
    });
  });

  group('資料庫匯出', () {
    late AppDatabase db;
    late GarageRepository repo;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      repo = GarageRepository(db);
      final vid = await repo.addVehicle(type: 0, name: '愛車');
      await repo.saveFuelLog(
        vehicleId: vid,
        date: DateTime(2026, 1, 1),
        odometer: 1000,
        liters: 10,
        amount: 300,
      );
      await repo.saveFuelLog(
        vehicleId: vid,
        date: DateTime(2026, 1, 10),
        odometer: 1400,
        liters: 20,
        amount: 600,
      );
      await repo.saveMaintenance(
        vehicleId: vid,
        date: DateTime(2026, 1, 5),
        odometer: 1500,
        items: const [
          ItemInput(name: '機油', quantity: 2, unitPrice: 300),
          ItemInput(name: '工資', quantity: 1, unitPrice: 200),
        ],
      );
    });

    tearDown(() => db.close());

    test('加油 CSV：含標題、區間油耗與每公里花費', () async {
      final csv = await CsvExporter(db).fuelCsv();
      expect(csv, startsWith('﻿車輛,日期,里程(km)'));
      // 第一筆只是起點，沒有油耗
      expect(csv, contains('愛車,2026-01-01,1000,10,300,30,,是,,,'));
      // 第二筆：400 km / 20 L = 20 km/L，600 / 400 = 1.5 每公里
      expect(csv, contains('愛車,2026-01-10,1400,20,600,30,,是,20,1.5,'));
    });

    test('保養 CSV：每個明細一列，整張單總額重複出現', () async {
      final csv = await CsvExporter(db).maintenanceCsv();
      expect(csv, contains('愛車,2026-01-05,1500,機油,2,300,600,800,'));
      expect(csv, contains('愛車,2026-01-05,1500,工資,1,200,200,800,'));
    });

    test('已刪除的車輛不會出現在匯出', () async {
      final vid = (await db.select(db.vehicles).get()).single.id;
      await repo.deleteVehicle(vid);
      final csv = await CsvExporter(db).fuelCsv();
      expect(csv.contains('愛車,'), isFalse);
    });
  });
}
