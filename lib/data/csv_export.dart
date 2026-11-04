import 'package:drift/drift.dart';

import '../domain/fuel_calculator.dart';
import 'database.dart';
import 'repository.dart';

/// CSV 匯出（方便用 Excel 整理）。
///
/// - 開頭加 UTF-8 BOM，Excel 才不會把中文開成亂碼。
/// - 欄位含逗號、引號、換行時以雙引號包起來。
/// - 文字欄位若以 = + - @ 開頭，前面補單引號，避免被 Excel 當成公式執行。
class CsvExporter {
  CsvExporter(this.db);

  final AppDatabase db;

  static String _cell(Object? v) {
    if (v == null) return '';
    var s = v is double ? _num(v) : v.toString();
    if (v is String && s.isNotEmpty && '=+-@'.contains(s[0])) {
      s = "'$s";
    }
    if (s.contains(',') || s.contains('"') || s.contains('\n') || s.contains('\r')) {
      s = '"${s.replaceAll('"', '""')}"';
    }
    return s;
  }

  static String _num(double v) {
    if (!v.isFinite) return '';
    final s = v.toStringAsFixed(3);
    return s.contains('.') ? s.replaceFirst(RegExp(r'\.?0+$'), '') : s;
  }

  static String _date(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  /// 將二維資料編碼為 CSV 文字（含 BOM、CRLF 換行）。
  static String encode(List<List<Object?>> rows) =>
      '﻿${rows.map((r) => r.map(_cell).join(',')).join('\r\n')}\r\n';

  Future<List<Vehicle>> _vehicles() => (db.select(db.vehicles)
        ..where((t) => t.isDeleted.equals(false))
        ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
      .get();

  /// 全部車輛的加油紀錄。
  Future<String> fuelCsv() async {
    final rows = <List<Object?>>[
      [
        '車輛', '日期', '里程(km)', '公升(L)', '金額', '單價(每公升)', '油品',
        '是否加滿', '區間油耗(km/L)', '每公里花費', '備註',
      ],
    ];
    for (final v in await _vehicles()) {
      final logs = await (db.select(db.fuelLogs)
            ..where((t) => t.vehicleId.equals(v.id) & t.isDeleted.equals(false))
            ..orderBy([
              (t) => OrderingTerm.asc(t.date),
              (t) => OrderingTerm.asc(t.odometer),
            ]))
          .get();
      final stats = computeFuelStats(logs.map(fuelLogToEntry));
      for (final l in logs) {
        final s = stats[l.id];
        rows.add([
          v.name,
          _date(l.date),
          l.odometer,
          l.liters,
          l.amount,
          l.unitPrice,
          l.fuelType,
          l.isFullTank ? '是' : '否',
          s?.kmPerL,
          s?.costPerKm,
          l.note,
        ]);
      }
    }
    return encode(rows);
  }

  /// 全部車輛的保養紀錄（每個明細一列）。
  Future<String> maintenanceCsv() async {
    final rows = <List<Object?>>[
      ['車輛', '日期', '里程(km)', '項目', '數量', '單價', '小計', '整張單總額', '備註'],
    ];
    for (final v in await _vehicles()) {
      final records = await (db.select(db.maintenanceRecords)
            ..where((t) => t.vehicleId.equals(v.id) & t.isDeleted.equals(false))
            ..orderBy([(t) => OrderingTerm.asc(t.date)]))
          .get();
      for (final r in records) {
        final items = await (db.select(db.maintenanceItems)
              ..where((t) => t.recordId.equals(r.id) & t.isDeleted.equals(false))
              ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
            .get();
        // 沒有任何有效明細的保養單是異常資料（匯入時已回報），不輸出，
        // 避免它的金額混進你拿去算帳的 CSV。資料本身仍保留在資料庫。
        if (items.isEmpty) continue;
        for (final i in items) {
          rows.add([
            v.name,
            _date(r.date),
            r.odometer,
            i.name,
            i.quantity,
            i.unitPrice,
            i.quantity * i.unitPrice,
            r.totalAmount,
            r.note,
          ]);
        }
      }
    }
    return encode(rows);
  }
}
