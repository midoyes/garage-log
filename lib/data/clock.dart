/// 單裝置單調遞增的毫秒時鐘，供 updatedAt 使用。
///
/// 系統時間可能因為校時、同一毫秒連續寫入而「沒有前進」。
/// 這裡保證同一個時鐘實例每次呼叫的回傳值嚴格遞增，
/// 不會出現兩次編輯拿到同一個 updatedAt 的情況。
class MonotonicClock {
  MonotonicClock([int Function()? source])
      : _source = source ?? (() => DateTime.now().millisecondsSinceEpoch);

  final int Function() _source;
  int _last = 0;

  int call() {
    final v = _source();
    _last = v > _last ? v : _last + 1;
    return _last;
  }
}
