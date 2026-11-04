import 'package:intl/intl.dart';

final _date = DateFormat('yyyy-MM-dd');
final _shortDate = DateFormat('MM/dd');
final _km = NumberFormat('#,##0.#');
final _money = NumberFormat('#,##0.##');

String fmtDate(DateTime d) => _date.format(d);
String fmtShortDate(DateTime d) => _shortDate.format(d);
String fmtKm(double v) => _km.format(v);
String fmtMoney(double v) => _money.format(v);

/// 數字輸入框用：預設最多 3 位小數並去掉尾端的 0
/// （公升數等欄位編輯舊紀錄時不會被默默截成兩位）。
String trimNum(double v, {int digits = 3}) {
  final s = v.toStringAsFixed(digits);
  return s.contains('.') ? s.replaceFirst(RegExp(r'\.?0+$'), '') : s;
}
