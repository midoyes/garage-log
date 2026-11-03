/// 油耗計算（純 Dart，無 Flutter / Drift 依賴，方便單元測試）。
library;

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
/// 1. 依日期、里程排序。
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
/// - 新增 / 編輯的里程必須大於「前一筆」（日期不晚於本筆者中最新的一筆）
/// - 若插入在歷史中間，也必須小於「下一筆」（日期晚於本筆者中最早的一筆）
/// - 沒有前一筆時不可小於車輛初始里程
/// - 同一天多筆加油請依里程順序輸入
String? validateFuelOdometer({
  required Iterable<FuelEntry> existing,
  required DateTime date,
  required double odometer,
  double initialOdometer = 0,
  String? excludeId,
}) {
  if (odometer.isNaN || odometer < 0) return '里程必須為正數';

  final others = existing.where((e) => e.id != excludeId).toList()
    ..sort(_compare);
  final day = DateTime(date.year, date.month, date.day);

  FuelEntry? prev;
  FuelEntry? next;
  for (final e in others) {
    final d = DateTime(e.date.year, e.date.month, e.date.day);
    if (d.isAfter(day)) {
      next ??= e;
    } else {
      prev = e;
    }
  }

  if (prev == null && odometer < initialOdometer) {
    return '里程不可小於車輛初始里程（${_km(initialOdometer)} km）';
  }
  if (prev != null && odometer <= prev.odometer) {
    return '里程必須大於上一筆紀錄（${_km(prev.odometer)} km）';
  }
  if (next != null && odometer >= next.odometer) {
    return '里程必須小於下一筆紀錄（${_km(next.odometer)} km）';
  }
  return null;
}
