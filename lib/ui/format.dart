import 'package:intl/intl.dart';

final _date = DateFormat('yyyy-MM-dd');
final _km = NumberFormat('#,##0.#');
final _money = NumberFormat('#,##0.##');

String fmtDate(DateTime d) => _date.format(d);
String fmtKm(double v) => _km.format(v);
String fmtMoney(double v) => _money.format(v);

/// 數字輸入框用：最多 2 位小數並去掉尾端的 0。
String trimNum(double v) {
  final s = v.toStringAsFixed(2);
  return s.contains('.') ? s.replaceFirst(RegExp(r'\.?0+$'), '') : s;
}
