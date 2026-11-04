/// 油耗計算（純 Dart，無 Flutter / Drift 依賴，方便單元測試）。
library;

import 'dart:math' as math;

/// 計算用的加油紀錄（與資料庫 Row 解耦）。
class FuelEntry {
  const FuelEntry({
    required this.id,
    required this.date,
    required this.odometer,
    required this.liters,
    required this.amount,
    this.isFullTank = true,
  });

  final String id;
  final DateTime date;
  final double odometer;
  final double liters;
  final double amount;

  /// 是否跳停（加滿）。
  final bool isFullTank;
}

/// 一個「跳停區間」的油耗結果（掛在區間結束的那一筆加滿紀錄上）。
class FuelStat {
  const FuelStat({
    required this.distanceKm,
    required this.liters,
    required this.amount,
  });

  /// 區間里程 = 本次里程 - 上次加滿里程
  final double distanceKm;

  /// 區間內累計公升數（含中間未加滿的補油 + 本次）
  final double liters;

  /// 區間內累計金額
  final double amount;

  /// 平均油耗 km/L = 區間里程 / 公升數
  double get kmPerL => distanceKm / liters;

  /// 每公里花費 = 金額 / 區間里程
  double get costPerKm => amount / distanceKm;
}

int _compare(FuelEntry a, FuelEntry b) {
  final c = a.date.compareTo(b.date);
  return c != 0 ? c : a.odometer.compareTo(b.odometer);
}

/// 計算每一筆「加滿」紀錄的油耗，回傳 `id -> FuelStat`。
///
/// 規則：
/// 1. 依日期、里程排序（同一天的多筆以里程排先後）。
/// 2. 第一筆加滿僅作為起點（只記錄里程），不計算油耗；
///    它之前的未加滿紀錄也忽略（油箱起始狀態未知）。
/// 3. 之後每一筆加滿：區間里程 = 本次里程 - 上次加滿里程。
///    公升數 / 金額 = 區間內所有補油（未加滿）+ 本次加滿的總和。
///    只有一次加滿、沒有中間補油時，就是「區間里程 / 本次公升數」。
/// 4. 區間里程 <= 0 或公升數 <= 0 的異常資料不產生結果（但仍重設起點）。
Map<String, FuelStat> computeFuelStats(Iterable<FuelEntry> entries) {
  final sorted = entries.toList()..sort(_compare);
  final result = <String, FuelStat>{};

  double? anchorOdometer;
  var accLiters = 0.0;
  var accAmount = 0.0;

  for (final e in sorted) {
    if (anchorOdometer == null) {
      if (e.isFullTank) anchorOdometer = e.odometer;
      continue;
    }
    accLiters += e.liters;
    accAmount += e.amount;
    if (e.isFullTank) {
      final distance = e.odometer - anchorOdometer;
      if (distance > 0 && accLiters > 0) {
        result[e.id] = FuelStat(
          distanceKm: distance,
          liters: accLiters,
          amount: accAmount,
        );
      }
      anchorOdometer = e.odometer;
      accLiters = 0;
      accAmount = 0;
    }
  }
  return result;
}

/// 整體平均油耗（總里程 / 總公升，加權平均）。沒有資料回傳 null。
double? overallKmPerL(Iterable<FuelStat> stats) {
  var km = 0.0;
  var l = 0.0;
  for (final s in stats) {
    km += s.distanceKm;
    l += s.liters;
  }
  return l > 0 ? km / l : null;
}

String _km(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

/// 里程防呆。回傳錯誤訊息；合法回傳 null。
///
/// 規則以「日」為單位，同一天內的多筆以里程自行排序，不互相卡住：
/// - 里程必須大於「更早日期」所有紀錄的最大里程
/// - 里程必須小於「更晚日期」所有紀錄的最小里程
/// - 同一天內不可與其他紀錄里程完全相同
/// - 沒有更早紀錄時，不可小於車輛初始里程
/// - 編輯時以 [excludeId] 排除自己
/// 某個日期的里程可填範圍：[prevMax] 是更早日期的最大里程（必須大於它），
/// [nextMin] 是更晚日期的最小里程（必須小於它）。補登舊紀錄時用來提示正確範圍。
({double? prevMax, double? nextMin}) fuelOdometerBounds({
  required Iterable<FuelEntry> existing,
  required DateTime date,
  String? excludeId,
}) {
  final day = DateTime(date.year, date.month, date.day);
  double? prevMax;
  double? nextMin;
  for (final e in existing) {
    if (e.id == excludeId) continue;
    final d = DateTime(e.date.year, e.date.month, e.date.day);
    if (d.isBefore(day)) {
      prevMax = prevMax == null ? e.odometer : math.max(prevMax, e.odometer);
    } else if (d.isAfter(day)) {
      nextMin = nextMin == null ? e.odometer : math.min(nextMin, e.odometer);
    }
  }
  return (prevMax: prevMax, nextMin: nextMin);
}

String? validateFuelOdometer({
  required Iterable<FuelEntry> existing,
  required DateTime date,
  required double odometer,
  double initialOdometer = 0,
  String? excludeId,
}) {
  if (!odometer.isFinite || odometer < 0) return '里程必須為正數';

  final day = DateTime(date.year, date.month, date.day);

  double? prevMax; // 更早日期的最大里程
  double? nextMin; // 更晚日期的最小里程
  for (final e in existing) {
    if (e.id == excludeId) continue;
    final d = DateTime(e.date.year, e.date.month, e.date.day);
    if (d.isBefore(day)) {
      prevMax = prevMax == null ? e.odometer : math.max(prevMax, e.odometer);
    } else if (d.isAfter(day)) {
      nextMin = nextMin == null ? e.odometer : math.min(nextMin, e.odometer);
    } else if (e.odometer == odometer) {
      return '同一天已有里程相同的紀錄（${_km(odometer)} km）';
    }
  }

  if (prevMax == null && odometer < initialOdometer) {
    return '里程不可小於車輛初始里程（${_km(initialOdometer)} km）';
  }
  if (prevMax != null && odometer <= prevMax) {
    return '里程必須大於上一筆紀錄（${_km(prevMax)} km）';
  }
  if (nextMin != null && odometer >= nextMin) {
    return '里程必須小於下一筆紀錄（${_km(nextMin)} km）';
  }
  return null;
}
